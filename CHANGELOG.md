# Changelog

## v1.0.6

- **Rename `default` → `origin`** — the reserved system environment is now called `origin`; `orbital use origin` / `orbital deactivate` return to unmanaged system config
- **Switch-to-origin message** — informative locale-aware message when switching to `origin` instead of plain "Switched to environment"
- **GitHub Pages** — new `origin` section explaining its special role; nav link added; `orbital env set/unset` corrected in commands grid

## v1.0.5

- **`orbital env set/unset`** — moved from `orbital set env` / `orbital unset env` to `orbital env set` / `orbital env unset`
- **`orbital info`** — now displays memory path, memory mode (isolated/shared), and session mode (isolated/shared)
- **`orbital memory` redesign** — interactive settings menu with `info`, `export`, `isolate`, `share` subcommands; discard migration requires explicit confirmation
- **Fix: `orbital tools`** — guard against default environment; prompts auth login for newly added tools
- **Fix: `orbital delegate` with Codex** — use `codex exec` for non-interactive mode
- **Fix: default environment** — `orbital set env`, `orbital unset env`, `orbital export`, `orbital unexport` no longer crash on default environment

## v1.0.4

- **Per-environment memory isolation** — `orbital memory isolate` / `orbital memory share` with fragment-based migration; `orbital create` wizard includes memory sharing step (default: isolated)
- **Interactive auth login in `orbital create`** — after selecting tools, prompts to log in to each tool via `execvp` for proper TTY
- **Fix: `orbital create` auth login TTY** — correct `execvp` argv construction, login now works correctly
- **Fix: Strip `ANTHROPIC_API_KEY` in `run` and `delegate`** — inherited API key no longer leaks into non-default environments

## v1.0.2

- **Fix: Strip `ANTHROPIC_API_KEY` in `run` and `delegate`** — inherited API key from shell no longer leaks into non-default environments, ensuring each environment's own credentials are used

## v1.0.1

- **Fix: `orbital run` supports interactive tools** — uses `execvp` to inherit full TTY, fixing `orbital run claude` / `orbital run codex` hanging
- **Fix: Strip Claude IPC env vars** in `run` and `delegate` commands to prevent child processes from hanging
- **Fix: Gemini MCP setup** — updated `gemini mcp add` to new CLI format
- **P2P Sync section** added to README and GitHub Pages (EN + 中文)
- **Fix: scroll-padding-top** for sticky nav on GitHub Pages

## v1.0.0

- **P2P sync** — `orbital sync` delegates to orbital-sync daemon for real-time memory sync across machines
- **Memory fragment integration** — `orbital_memory_read` detects pending sync fragments and prompts agent to consolidate
- **Fragment cleanup** — overwrite mode (`append=false`) automatically cleans up integrated fragments
- **CLAUDE.md** — development guidelines added
- orbital-sync bundled as dependency via Homebrew/APT

## v0.3.3

- **Memory fragment log** — each `orbital_memory_write` now produces an append-only fragment file in `fragments/` alongside `ORBITAL_MEMORY.md`, keyed by UUID + peer name. Prepares for future P2P sync with conflict-free replication.

## v0.3.2

- **`/orbital:resume` slash command** — resume session by index from `orbital sessions`
- Slash commands renamed to `/orbital:delegate` and `/orbital:sessions`
- GitHub Pages badge updated

## v0.3.1

- **`orbital memory export`** — export shared project memory to file
- Improved MCP memory tool descriptions with usage scenarios and guidance

## v0.3.0

- **Shared memory across AI tools** — `orbital_memory_read` / `orbital_memory_write` MCP tools let Claude, Codex, and Gemini share the same project memory (`ORBITAL_MEMORY.md`)
- **`orbital mcp setup` registers with all tools** — automatically registers MCP server with Claude Code, Codex CLI, and Gemini CLI (skips uninstalled ones)
- AI tool integration section on GitHub Pages (renamed from "Claude Code Integration" to cover all tools)

## v0.2.8

- **MCP server** — `orbital mcp-server` exposes tools via Model Context Protocol (stdin/stdout JSON-RPC)
- **`orbital mcp setup`** — one command registers MCP server + installs `/delegate` and `/sessions` slash commands
- **`orbital delegate`** — delegate tasks to AI tools in other environments (`--claude`/`--codex`/`--gemini`)
- **`orbital resume`** — resume sessions by index from `orbital sessions`, with passthrough args (e.g. `--dangerously-skip-permissions`)
- **`orbital run`** — run any command in a specific environment (`orbital run -e work claude --resume <id>`)
- **`activate.sh`** — `orbital setup` generates `~/.orbital/activate.sh`, rc file uses `source` instead of `eval`
- Shell init silenced for Powerlevel10k instant prompt compatibility
- Linux static linking (`--static-swift-stdlib`) — no runtime dependencies
- Linux built on Ubuntu 22.04 (jammy) for glibc 2.35 compatibility
- APT repo i386 empty Packages to prevent 404 on multiarch systems
- `.deb` postinst runs `orbital setup` automatically
- Localized `--claude`/`--codex`/`--gemini` flag help strings
- `install.sh --main` flag to build from latest main branch

## v0.2.0

- Built-in `default` environment — `orbital use default` returns to system config
- `orbital deactivate` now aliases to `orbital use default`
- Clone wizard in `orbital create` — single-select to clone from `default` or any existing environment
- Session sharing wizard changed to single-select UI
- Each create wizard step is independent — only skipped if its flag is provided
- `orbital sessions` command with `--claude`, `--codex`, `--gemini` flags
- Sessions display with branded tool names, indexed card layout, full session ID
- Pre-built binary releases for macOS (arm64), Linux (x86_64, arm64)
- `.deb` packages and APT repository (Ubuntu/Debian)
- GitHub Pages with Use Cases section, language switcher (English / 繁體中文)

## v0.1.9

- `orbital sessions` command — list AI tool sessions for the current project
- `--claude`, `--codex`, `--gemini` filter flags
- APT repository auto-update in release workflow
- GitHub Pages and README updated with sessions command and APT install

## v0.1.8

- Branded tool names in sessions output (Anthropic Claude, OpenAI Codex, Google Gemini)
- Sessions card layout with full session ID for `claude --resume`
- GitHub Pages badge and hero title updates

## v0.1.7

- Linux build fix — replace C stdio with Foundation `FileHandle` for Swift 6 concurrency safety
- Remove macOS x86_64 from release workflow (Apple Silicon only)
- Release workflow outputs `.tar.gz` archives

## v0.1.6

- `orbital sessions` — list Claude sessions for the current project
- Session support for Codex (`sessions/`) and Gemini (`tmp/`) directories
- Remove auth login instructions from create flow

## v0.1.5

- Fix locale detection — skip empty `LC_ALL`/`LC_MESSAGES` before falling through to `LANG`
- Lazy session symlink migration — `orbital use` auto-creates symlinks for existing environments
- Pre-built binary releases via GitHub Actions

## v0.1.4

- Capitalize product name to Orbital (CLI command stays lowercase)
- Mobile hamburger menu for GitHub Pages
- Language dropdown switcher (English / 繁體中文)
- Copy buttons on install code blocks
- GitHub Pages with Traditional Chinese version

## v0.1.3 (not released as tag)

- Session sharing across environments (default: shared, `--isolate-sessions` to opt out)
- Bash shell support (`orbital setup` auto-detects shell)
- `orbital setup` outputs shell function to stdout for immediate `eval`
- `post_install` in Homebrew formula
- i18n support — Traditional Chinese and English (auto-detect from system locale)
- Traditional Chinese README

## v0.1.2

- Interactive multi-select wizard for tool management
- `orbital info` defaults to active environment
- Linux support with auth instructions
- Switch to Apache 2.0 license

## v0.1.1

- UUID-based environment directories (rename no longer moves dirs)
- `orbital rename` command
- `orbital use` command with shell integration
- Hide internal commands from help

## v0.1.0

- Initial release
- `orbital create`, `delete`, `list`, `info` commands
- `orbital set env`, `unset env`, `tools` commands
- `orbital setup` and `orbital init` for shell integration
- Per-shell environment activation via `orbital use`
- Support for Claude Code, Codex CLI, and Gemini CLI
- Homebrew formula and install script
