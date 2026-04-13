public struct ShellFunctionGenerator {
    public static func generate() -> String {
        """
        # orrery shell integration
        # Usage: eval "$(orrery setup)"
        # Supports: bash (~/.bashrc) and zsh (~/.zshrc)

        orrery() {
          local _orrery_home="${ORRERY_HOME:-$HOME/.orrery}"
          local _notice_file="$_orrery_home/.update-notice"
          local _ts_file="$_orrery_home/.update-ts"

          # Show update notice on every command until orrery update clears it
          [ -f "$_notice_file" ] && printf '\\033[1;33m%s\\033[0m\\n' "$(cat "$_notice_file")"

          # Background version check — at most once every 4 hours
          local _now
          _now=$(date +%s 2>/dev/null) || true
          local _last=0
          [ -f "$_ts_file" ] && _last=$(cat "$_ts_file" 2>/dev/null || echo 0)
          if [ $((_now - _last)) -ge 14400 ]; then
            (echo "$_now" > "$_ts_file"; _r=$(command orrery _check-update 2>/dev/null); [ -n "$_r" ] && echo "$_r" > "$_notice_file" || rm -f "$_notice_file") &
            disown 2>/dev/null || true
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
                eval "$(command orrery _unexport "$ORRERY_ACTIVE_ENV" 2>/dev/null || true)"
              fi
              if [ "$2" = "origin" ]; then
                unset CLAUDE_CONFIG_DIR CODEX_CONFIG_DIR GEMINI_CONFIG_DIR
                export ORRERY_ACTIVE_ENV="origin"
                command orrery _set-current origin 2>/dev/null || true
                echo "\(L10n.Use.switchedToOrigin)"
              else
                local exports
                exports=$(command orrery _export "$2") || { echo "orrery: environment '$2' not found" >&2; return 1; }
                eval "$exports"
                export ORRERY_ACTIVE_ENV="$2"
                command orrery _set-current "$2" 2>/dev/null || true
                echo "Switched to environment: $2"
              fi
              ;;
            deactivate)
              orrery use origin
              ;;
            create)
              command orrery "$@"
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
              command orrery "$@"
              ;;
          esac
        }

        _orrery_init() {
          local orrery_home="${ORRERY_HOME:-$HOME/.orrery}"
          local current_file="$orrery_home/current"
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
          # Ensure ORRERY_MEMORY.md is linked into Claude's auto-memory dir
          command orrery _link-memory 2>/dev/null || true
        }

        _orrery_init
        """
    }
}
