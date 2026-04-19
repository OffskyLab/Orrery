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
                unset CLAUDE_CONFIG_DIR CODEX_CONFIG_DIR GEMINI_CONFIG_DIR ORRERY_GEMINI_HOME
                export ORRERY_ACTIVE_ENV="origin"
                command orrery-bin _set-current origin 2>/dev/null || true
              else
                local exports
                exports=$(command orrery-bin _export "$2") || { echo "orrery: environment '$2' not found" >&2; return 1; }
                eval "$exports"
                export ORRERY_ACTIVE_ENV="$2"
                command orrery-bin _set-current "$2" 2>/dev/null || true
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
