public struct ShellFunctionGenerator {
    public static func generate() -> String {
        """
        # orbital shell integration
        # Usage: eval "$(orbital setup)"
        # Supports: bash (~/.bashrc) and zsh (~/.zshrc)

        orbital() {
          local cmd="${1:-}"
          case "$cmd" in
            use)
              if [ -z "${2:-}" ]; then
                echo "Usage: orbital use <name>" >&2
                return 1
              fi
              # Unexport previous env vars if switching
              if [ -n "${ORBITAL_ACTIVE_ENV:-}" ] && [ "$ORBITAL_ACTIVE_ENV" != "origin" ]; then
                eval "$(command orbital _unexport "$ORBITAL_ACTIVE_ENV" 2>/dev/null || true)"
              fi
              if [ "$2" = "origin" ]; then
                unset CLAUDE_CONFIG_DIR CODEX_CONFIG_DIR GEMINI_CONFIG_DIR
                export ORBITAL_ACTIVE_ENV="origin"
                command orbital _set-current origin 2>/dev/null || true
                echo "\(L10n.Use.switchedToOrigin)"
              else
                local exports
                exports=$(command orbital _export "$2") || { echo "orbital: environment '$2' not found" >&2; return 1; }
                eval "$exports"
                export ORBITAL_ACTIVE_ENV="$2"
                command orbital _set-current "$2" 2>/dev/null || true
                echo "Switched to environment: $2"
              fi
              ;;
            deactivate)
              orbital use origin
              ;;
            *)
              command orbital "$@"
              ;;
          esac
        }

        _orbital_init() {
          local orbital_home="${ORBITAL_HOME:-$HOME/.orbital}"
          local current_file="$orbital_home/current"
          # Migrate pre-1.1.0: "default" was renamed to "origin"
          if [ "${ORBITAL_ACTIVE_ENV:-}" = "default" ]; then
            export ORBITAL_ACTIVE_ENV="origin"
          fi
          if [ -f "$current_file" ]; then
            local env_name
            env_name=$(cat "$current_file" 2>/dev/null)
            if [ "$env_name" = "default" ]; then
              env_name="origin"
              echo "origin" > "$current_file" 2>/dev/null || true
            fi
            if [ -n "$env_name" ]; then
              orbital use "$env_name" >/dev/null 2>&1 || true
            fi
          fi
          # Ensure ORBITAL_MEMORY.md is linked into Claude's auto-memory dir
          command orbital _link-memory 2>/dev/null || true
        }

        _orbital_check_update() {
          local orbital_home="${ORBITAL_HOME:-$HOME/.orbital}"
          local notice_file="$orbital_home/.update-notice"
          local ts_file="$orbital_home/.update-ts"

          # Show notice from previous background check
          [ -f "$notice_file" ] && cat "$notice_file"

          # Re-check at most once per day
          local now
          now=$(date +%s 2>/dev/null) || return
          local last=0
          [ -f "$ts_file" ] && last=$(cat "$ts_file" 2>/dev/null || echo 0)
          [ $((now - last)) -lt 86400 ] && return

          # Kick off background check — result visible at next shell start
          (
            echo "$now" > "$ts_file"
            command orbital _check-update > "$notice_file" 2>/dev/null || rm -f "$notice_file"
          ) &
        }

        _orbital_init
        _orbital_check_update
        """
    }
}
