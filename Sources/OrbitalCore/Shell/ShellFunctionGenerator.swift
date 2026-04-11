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
                echo "Switched to environment: origin"
              else
                local exports
                exports=$(command orbital _export "$2") || { echo "orbital: environment '$2' not found" >&2; return 1; }
                eval "$exports"
                export ORBITAL_ACTIVE_ENV="$2"
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
          if [ -f "$current_file" ]; then
            local env_name
            env_name=$(cat "$current_file" 2>/dev/null)
            if [ -n "$env_name" ]; then
              orbital use "$env_name" >/dev/null 2>&1 || true
            fi
          fi
        }
        _orbital_init
        """
    }
}
