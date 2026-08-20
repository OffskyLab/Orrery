public struct ShellFunctionGenerator {
    public static func generate(version: String = OrreryVersion.current) -> String {
        """
        # orrery shell integration — v\(version)
        # Supports: bash (~/.bashrc) and zsh (~/.zshrc)

        orrery() {
          local _orrery_home="${ORRERY_HOME:-$HOME/.orrery}"
          local _notice_file="$_orrery_home/.update-notice"
          local _ts_file="$_orrery_home/.update-ts"

          # Show update notice on every command until orrery update clears it
          # (suppressed while the user is actually running `orrery update`)
          if [ "${1:-}" != "update" ] && [ "${1:-}" != "_check-update" ]; then
            [ -f "$_notice_file" ] && printf '\\033[1;33m%s\\033[0m\\n' "$(cat "$_notice_file")"
          fi

          # Background version check — at most once every 4 hours
          local _now
          _now=$(date +%s 2>/dev/null) || true
          local _last=0
          [ -f "$_ts_file" ] && _last=$(cat "$_ts_file" 2>/dev/null || echo 0)
          if [ $((_now - _last)) -ge 14400 ]; then
            # Double subshell: the inner `&` runs in a child shell that exits
            # immediately, so the interactive shell never sees a background job
            # and never prints `[N] PID` (zsh) or a job notice (bash).
            ( ( echo "$_now" > "$_ts_file"; _r=$(command orrery-bin _check-update 2>/dev/null); [ -n "$_r" ] && echo "$_r" > "$_notice_file" || rm -f "$_notice_file" ) & ) >/dev/null 2>&1
          fi

          local cmd="${1:-}"
          case "$cmd" in
            run)
              # Phantom mode is the default for `orrery run claude` — claude is
              # launched under a supervisor loop that watches for a sentinel
              # written by the /orrery:phantom slash command and relaunches with
              # the new env active + --resume <session-id> so the conversation
              # continues uninterrupted across env switches.
              #
              # The shell directly forks/execs claude (not Swift Process), so the
              # controlling TTY is naturally inherited — no PTY plumbing.
              #
              # Usage:
              #   orrery run [-e <env>] [--non-phantom] [--] <command> [args...]
              #
              # Non-claude commands and --non-phantom invocations fall through to
              # `orrery-bin run` (single-shot execvp via Swift), preserving prior
              # behavior for scripts and non-interactive callers.
              shift
              local _run_target=""
              local _run_non_phantom=0
              local _run_args=()
              while [ $# -gt 0 ]; do
                case "$1" in
                  -e|--env)
                    if [ -z "${2:-}" ]; then
                      echo "orrery run: -e requires an environment name" >&2
                      return 1
                    fi
                    _run_target="$2"
                    shift 2
                    ;;
                  --non-phantom)
                    _run_non_phantom=1
                    shift
                    ;;
                  --)
                    shift
                    while [ $# -gt 0 ]; do _run_args+=("$1"); shift; done
                    break
                    ;;
                  *)
                    _run_args+=("$1")
                    shift
                    ;;
                esac
              done

              # Reload positional params from the parsed args so we can index
              # the first element via "$1" — bash and zsh disagree on whether
              # ${arr[0]} or ${arr[1]} is the first element (zsh is 1-indexed
              # by default), but $1 means the same thing in both.
              #
              # ${_run_args[@]+"${_run_args[@]}"} rather than "${_run_args[@]}":
              # bash 3.2 (the macOS system bash) treats expanding an empty
              # array under `set -u` as an unbound variable and aborts —
              # reachable via plain `orrery run` with no command at all.
              set -- ${_run_args[@]+"${_run_args[@]}"}

              # Phantom mode only applies to `claude` — other commands have no
              # session-resume semantics so a supervisor loop adds no value.
              if [ $_run_non_phantom -eq 0 ] && [ "${1:-}" = "claude" ]; then
                if [ -n "$_run_target" ]; then
                  echo "orrery run claude: -e/--env is not supported for claude — run 'orrery use <account>' first, then 'orrery run claude'." >&2
                  return 1
                fi
                # Supervision now lives in the claude() shim, so bare `claude`
                # gets it too. This branch stays as an equivalent alias.
                shift
                # Strip claude IPC env vars defensively: if `orrery run claude` is
                # ever invoked from inside another claude, these would leak in and
                # make the child claude hang waiting for an MCP host. Bare `claude`
                # never stripped these — this is `run claude`-specific, and it also
                # means the claude() shim's own CLAUDECODE no-supervise guard won't
                # fire here, so a nested `orrery run claude` gets supervised (same
                # as the old dedicated loop did in this exact situation).
                unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH
                claude "$@"
              else
                # Single-shot path: hand off to Swift's `orrery-bin run`, which
                # execvp's the target directly. This branch covers --non-phantom,
                # non-claude commands, and the empty-args case (Swift produces
                # the canonical "no command specified" error).
                #
                # Clear tool config-dir exports left over from an earlier
                # `orrery use` in this same shell — `orrery-bin run` decides
                # fresh what each tool's config dir should be for THIS
                # invocation (set it for the target account, leave it unset
                # for origin) and must not inherit a stale value exported by
                # some earlier, unrelated command in this session.
                #
                # Wrapped in a subshell: `orrery()` is a plain shell function,
                # not a script in its own process, so a bare `unset` here
                # would strip these vars from the CALLER's interactive shell
                # too — silently wiping their `orrery use` pin the next time
                # they ran anything through this fallback. A subshell confines
                # the unset to this one invocation.
                if [ -n "$_run_target" ]; then
                  ( unset CLAUDE_CONFIG_DIR CODEX_HOME GEMINI_CONFIG_DIR; command orrery-bin run -e "$_run_target" "$@" )
                else
                  ( unset CLAUDE_CONFIG_DIR CODEX_HOME GEMINI_CONFIG_DIR; command orrery-bin run "$@" )
                fi
              fi
              ;;
            add)
              # `orrery add --claude` and `--gemini` both need a real TTY-attached
              # REPL. Swift's Process doesn't give the child the foreground process
              # group, so the tool ends up in a background group: claude notices and
              # silently exits, gemini takes SIGTTIN the moment it puts stdin in raw
              # mode and is STOPPED before drawing anything (observed as `STAT T`
              # with the child's PGID != the terminal's TPGID). Route both through
              # the shell so the tool gets the controlling terminal directly.
              #
              # codex genuinely is fine on the plain orrery-bin path: `codex login`
              # opens a browser and waits on a network callback, so it never reads
              # the terminal and never trips the foreground check.
              #
              # Help requests bypass the claude TTY interception so the user sees
              # the public `add` help, not the internal prepare/finalize.
              for _a in "${@:2}"; do
                case "$_a" in
                  -h|--help) command orrery-bin "$@"; return $?; ;;
                esac
              done

              local _is_claude=1 _is_gemini=0
              for _a in "${@:2}"; do
                case "$_a" in
                  --codex)  _is_claude=0 ;;
                  --gemini) _is_claude=0; _is_gemini=1 ;;
                esac
              done
              if [ $_is_gemini -eq 1 ]; then
                local _staging
                _staging=$(command orrery-bin _account-add-prepare "${@:2}") || return $?
                [ -z "$_staging" ] && { echo "orrery: prepare returned empty staging dir" >&2; return 1; }
                printf "\(L10n.Account.loginReadyHintGemini)\\n"
                # gemini-cli ignores GEMINI_CONFIG_DIR and only reads $HOME/.gemini,
                # so the staging dir reaches it through the wrapper that
                # _account-add-prepare just built ("<staging>-home", holding
                # .gemini -> <staging>). Running it here, rather than from
                # orrery-bin, is what keeps it in the foreground process group.
                HOME="${_staging}-home" command gemini
                command orrery-bin _account-add-finalize --staging "$_staging"
                return $?
              fi
              if [ $_is_claude -eq 1 ]; then
                local _staging
                _staging=$(command orrery-bin _account-add-prepare "${@:2}") || return $?
                [ -z "$_staging" ] && { echo "orrery: prepare returned empty staging dir" >&2; return 1; }
                printf "\(L10n.Account.loginReadyHint)\\n"
                # claude's own first-run onboarding (theme picker etc.) overwrites
                # this staging settings.json wholesale, wiping the auth_success
                # hook _account-add-prepare just installed — before OAuth even
                # starts. Re-patch it in the background for as long as claude is
                # running so the hook is back in place well before login
                # completes. Double subshell (as with the update-check job above)
                # keeps this from printing a job-control notice in the shell.
                ( ( while true; do command orrery-bin _account-add-heal-hook --staging "$_staging" 2>/dev/null; sleep 1; done ) & echo $! > "$_staging/.heal-hook.pid" ) >/dev/null 2>&1
                CLAUDE_CONFIG_DIR="$_staging" command claude
                if [ -f "$_staging/.heal-hook.pid" ]; then
                  kill "$(cat "$_staging/.heal-hook.pid")" 2>/dev/null
                  rm -f "$_staging/.heal-hook.pid"
                fi
                command orrery-bin _account-add-finalize --staging "$_staging"
                return $?
              fi
              command orrery-bin "$@"
              ;;
            use)
              # Help / version requests must bypass the v3.1 fast-path —
              # ArgumentParser prints to stdout for --help/--version, and we'd
              # capture it as a (garbage) CLAUDE_CONFIG_DIR otherwise.
              for _a in "${@:2}"; do
                case "$_a" in
                  -h|--help|--version) command orrery-bin "$@"; return $?; ;;
                esac
              done
              shift
              local _is_codex=0 _is_gemini=0
              for _a in "$@"; do
                case "$_a" in
                  --codex) _is_codex=1 ;;
                  --gemini) _is_gemini=1 ;;
                esac
              done
              if [ $_is_codex -eq 1 ]; then
                # Try the v3.1 account-dir fast path first; fall back to the
                # legacy materialize path silently for accounts not yet
                # migrated (suppress _account-dir's "not yet in v3.1 layout"
                # error here — the fallback below handles it).
                local _dir
                if _dir=$(command orrery-bin _account-dir "$@" 2>/dev/null); then
                  export CODEX_HOME="$_dir"
                  echo "orrery: CODEX_HOME=$_dir" >&2
                  # Persist so a brand-new shell restores this pin automatically
                  # (see _current-export in _orrery_init). Best-effort — the
                  # switch itself already succeeded.
                  command orrery-bin _pin-current "$@" >/dev/null 2>&1 || true
                else
                  command orrery-bin use "$@"
                  return $?
                fi
              elif [ $_is_gemini -eq 1 ]; then
                # Same fast-path-with-fallback shape as codex, but gemini-cli
                # ignores GEMINI_CONFIG_DIR — _account-dir returns a HOME-wrapper
                # dir instead (see GeminiAdapter.resolvedExportPath), consumed
                # by the gemini() wrapper function below via ORRERY_GEMINI_HOME.
                local _dir
                if _dir=$(command orrery-bin _account-dir "$@" 2>/dev/null); then
                  export ORRERY_GEMINI_HOME="$_dir"
                  echo "orrery: ORRERY_GEMINI_HOME=$_dir" >&2
                  command orrery-bin _pin-current "$@" >/dev/null 2>&1 || true
                else
                  command orrery-bin use "$@"
                  return $?
                fi
              else
                # Claude (explicit or default). Let _account-dir's stderr flow
                # to the user's terminal naturally; capture only stdout into
                # _dir. On failure _account-dir has already printed an
                # actionable error.
                local _dir
                if _dir=$(command orrery-bin _account-dir "$@"); then
                  export CLAUDE_CONFIG_DIR="$_dir"
                  echo "orrery: CLAUDE_CONFIG_DIR=$_dir" >&2
                  command orrery-bin _pin-current "$@" >/dev/null 2>&1 || true
                else
                  return 1
                fi
              fi
              ;;
            *)
              command orrery-bin "$@"
              ;;
          esac
        }

        _orrery_init() {
          local orrery_home="${ORRERY_HOME:-$HOME/.orrery}"
          local activate_file="$orrery_home/activate.sh"

          # Self-update: if the version stamp in activate.sh doesn't match the
          # installed binary, regenerate and re-source so stale shells heal
          # automatically (e.g. after `brew upgrade` when post_install was skipped).
          local _stamped _binver
          _stamped=$(command grep -m1 '^# orrery shell integration' "$activate_file" 2>/dev/null | command sed 's/.*— v//')
          _binver=$(command orrery-bin --version 2>/dev/null | command awk '{print $NF}')
          if [ -n "$_binver" ] && [ "$_stamped" != "$_binver" ]; then
            command orrery-bin setup >/dev/null 2>&1 || true
            [ -f "$activate_file" ] && . "$activate_file"
            return
          fi

          # Ensure the Orrery memory directory is linked into Claude's auto-memory location
          command orrery-bin _link-memory 2>/dev/null || true

          # Restore whichever account `orrery use` last pinned per tool, so a
          # brand-new shell picks it up automatically — no re-running `use`
          # needed. Silent no-op for any tool that's unpinned, already has its
          # export var set (explicit override wins), or isn't in v3.1 layout.
          eval "$(command orrery-bin _current-export 2>/dev/null)"
        }

        # v3.1 launch wrapper, extracted so the supervisor loop can call it once
        # per iteration: each relaunch may land on a different account dir, so
        # prepare/capture must run every time, not once around the whole loop.
        # If CLAUDE_CONFIG_DIR is set and the dir contains a metadata.json
        # (v3.1 account dir marker), invoke orrery-bin _prepare-claude-launch +
        # _capture-claude-exit around the real claude. Otherwise, pass through
        # to claude unchanged.
        _orrery_claude_launch() {
          if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -f "$CLAUDE_CONFIG_DIR/metadata.json" ]; then
            if ! command orrery-bin _prepare-claude-launch --account-dir "$CLAUDE_CONFIG_DIR"; then
              echo "orrery: prepare-claude-launch failed; launching with existing .claude.json" >&2
            fi
            command claude "$@"
            local _rc=$?
            command orrery-bin _capture-claude-exit --account-dir "$CLAUDE_CONFIG_DIR" 2>/dev/null || true
            return $_rc
          elif [ -z "${CLAUDE_CONFIG_DIR:-}" ] && [ -f "$HOME/.claude/metadata.json" ]; then
            # Bare launch on origin: ~/.claude points at the origin account dir.
            # claude reads ~/.claude.json here (NOT accountdir/.claude.json), so
            # we must NOT merge .claude.json — only sync the workspace symlinks.
            command orrery-bin _prepare-claude-launch --account-dir "$HOME/.claude" --links-only || true
            command claude "$@"
          else
            command claude "$@"
          fi
        }

        # Phantom supervisor. Kept deliberately thin: this text is written into
        # the user's rc file, so it only changes when they re-run `orrery setup`.
        # Every decision that might need updating lives behind orrery-bin.
        #
        # Fast-path guards, in order:
        #   ORRERY_PHANTOM_ID   already inside a supervised relaunch — avoids
        #                       a supervisor-inside-a-supervisor.
        #   CLAUDECODE          already running inside a claude session (e.g. a
        #                       nested `claude` call from a hook/tool) — no
        #                       session-resume semantics apply there.
        #   ORRERY_NO_PHANTOM   explicit opt-out.
        claude() {
          if [ -n "${ORRERY_PHANTOM_ID:-}" ] || [ -n "${CLAUDECODE:-}" ] ||
             [ -n "${ORRERY_NO_PHANTOM:-}" ]; then
            # Fast-path: launch directly, skipping the supervisor loop below.
            # If we got here because ORRERY_PHANTOM_ID was already set (a
            # nested claude call, e.g. triggered from a hook), clear it
            # before launching so this nested claude's SessionStart hook
            # does not stamp its own session id into the OUTER supervisor's
            # registry entry.
            unset ORRERY_PHANTOM_ID
            _orrery_claude_launch "$@"; return $?
          fi

          local _spec
          _spec=$(command orrery-bin _phantom-begin --tool claude --supervisor-pid $$ -- "$@") || {
            _orrery_claude_launch "$@"; return $?
          }
          eval "$_spec"

          local _args=("$@")
          local _rc=0
          local _next
          while true; do
            # ${_args[@]+"${_args[@]}"} rather than "${_args[@]}": bash 3.2
            # (the macOS system bash, and the only one many users ever have)
            # treats expanding an empty array under `set -u` as an unbound
            # variable and aborts the function — this is reachable any time
            # `_phantom-next` emits a bare `set --` (no --resume id).
            _orrery_claude_launch ${_args[@]+"${_args[@]}"}
            _rc=$?
            # `_next` is declared once, above the loop, not re-declared here:
            # in zsh, `local` naming a variable already local in the SAME
            # scope is a listing request, not a declaration, and prints the
            # variable's current value — so a `local _next` inside the loop
            # body would spray shell-quoted internals onto the user's
            # terminal on every iteration after the first.
            _next=$(command orrery-bin _phantom-next --id "$ORRERY_PHANTOM_ID") || break
            eval "$_next"
            _args=("$@")
          done

          command orrery-bin _phantom-end --id "$ORRERY_PHANTOM_ID"
          unset ORRERY_PHANTOM_ID ORRERY_PHANTOM_DIR
          return $_rc
        }

        # gemini-cli ignores GEMINI_CONFIG_DIR and always reads ~/.gemini/,
        # so env isolation is achieved by overriding HOME to a per-env wrapper
        # dir whose `.gemini` symlinks back to the env's gemini config.
        gemini() {
          if [ -n "${ORRERY_GEMINI_HOME:-}" ]; then
            HOME="$ORRERY_GEMINI_HOME" command gemini "$@"
          else
            command gemini "$@"
          fi
        }

        _orrery_init
        """
    }
}
