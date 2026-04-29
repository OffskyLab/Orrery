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
            use)
              if [ -z "${2:-}" ]; then
                echo "Usage: orrery use <name>" >&2
                return 1
              fi
              # Unexport previous env vars if switching
              if [ -n "${ORRERY_ACTIVE_ENV:-}" ] && [ "$ORRERY_ACTIVE_ENV" != "origin" ]; then
                eval "$(command orrery-bin _unexport "$ORRERY_ACTIVE_ENV" 2>/dev/null || true)"
              fi
              if [ "$2" = "origin" ]; then
                unset CLAUDE_CONFIG_DIR CODEX_HOME CODEX_CONFIG_DIR GEMINI_CONFIG_DIR ORRERY_GEMINI_HOME
                export ORRERY_ACTIVE_ENV="origin"
                command orrery-bin _set-current origin 2>/dev/null || true
              else
                local exports
                exports=$(command orrery-bin _export "$2") || { echo "orrery: environment '$2' not found" >&2; return 1; }
                eval "$exports"
                export ORRERY_ACTIVE_ENV="$2"
                command orrery-bin _set-current "$2" 2>/dev/null || true
                # Background quota refresh so `orrery list` shows fresh data
                # next time. Double subshell hides the job notice from
                # interactive shells, just like the update check above.
                ( ( command orrery-bin quota refresh -e "$2" >/dev/null 2>&1 ) & ) >/dev/null 2>&1
              fi
              printf "\(L10n.Use.switched)\\n" "$2"
              ;;
            deactivate)
              orrery use origin
              ;;
            create)
              command orrery-bin "$@"
              if [ $? -eq 0 ]; then
                local _env_name="" _skip=0
                for _arg in "${@:2}"; do
                  if [ $_skip -eq 1 ]; then _skip=0; continue; fi
                  case "$_arg" in
                    --description|--clone|--tool) _skip=1 ;;
                    --*) ;;
                    *) _env_name="$_arg"; break ;;
                  esac
                done
                if [ -n "$_env_name" ]; then
                  printf "切換到環境 '%s'？[Y/n] " "$_env_name"
                  read -r _ans </dev/tty
                  case "${_ans:-Y}" in
                    [Yy]*|"") orrery use "$_env_name" ;;
                  esac
                fi
              fi
              ;;
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
              set -- "${_run_args[@]}"

              # Phantom mode only applies to `claude` — other commands have no
              # session-resume semantics so a supervisor loop adds no value.
              if [ $_run_non_phantom -eq 0 ] && [ "${1:-}" = "claude" ]; then
                if [ -n "$_run_target" ]; then
                  orrery use "$_run_target" || return $?
                fi
                local _phantom_sentinel="$_orrery_home/.phantom-sentinel"
                rm -f "$_phantom_sentinel"
                export ORRERY_PHANTOM_SHELL_PID=$$
                # Drop the leading "claude" — `command claude` below adds it back.
                shift
                local _phantom_args=("$@")
                # Strip claude IPC env vars defensively: if `orrery run claude` is
                # ever invoked from inside another claude, these would leak in and
                # make the child claude hang waiting for an MCP host.
                unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH
                while true; do
                  command claude "${_phantom_args[@]}"
                  [ -f "$_phantom_sentinel" ] || break
                  local TARGET_ENV='' SESSION_ID=''
                  . "$_phantom_sentinel"
                  rm -f "$_phantom_sentinel"
                  if [ -n "$TARGET_ENV" ]; then
                    orrery use "$TARGET_ENV" || break
                  fi
                  # After a phantom switch, --resume <new-session-id> is the only
                  # arg we want — the user's original flags don't carry over (they
                  # may have included --resume themselves with a now-stale id).
                  _phantom_args=()
                  if [ -n "$SESSION_ID" ]; then
                    _phantom_args=(--resume "$SESSION_ID")
                  fi
                done
                unset ORRERY_PHANTOM_SHELL_PID
              else
                # Single-shot path: hand off to Swift's `orrery-bin run`, which
                # execvp's the target directly. This branch covers --non-phantom,
                # non-claude commands, and the empty-args case (Swift produces
                # the canonical "no command specified" error).
                if [ -n "$_run_target" ]; then
                  command orrery-bin run -e "$_run_target" "$@"
                else
                  command orrery-bin run "$@"
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
          local current_file="$orrery_home/current"

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

          # Migrate pre-1.1.0: "default" was renamed to "origin"
          if [ "${ORRERY_ACTIVE_ENV:-}" = "default" ]; then
            export ORRERY_ACTIVE_ENV="origin"
          fi
          if [ -f "$current_file" ]; then
            local env_name
            env_name=$(cat "$current_file" 2>/dev/null)
            if [ "$env_name" = "default" ]; then
              env_name="origin"
              echo "origin" > "$current_file" 2>/dev/null || true
            fi
            if [ -n "$env_name" ]; then
              orrery use "$env_name" >/dev/null 2>&1 || true
            fi
          fi
          # Ensure the Orrery memory directory is linked into Claude's auto-memory location
          command orrery-bin _link-memory 2>/dev/null || true
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
