# Orbital

<p align="center">
  <img src="assets/icon-1024x1024.png" alt="Orbital" width="256" height="256" />
</p>

[繁體中文](docs/README-zh_TW.md)

Per-shell environment manager for AI CLI tools — isolate accounts for Claude Code, Codex CLI, and Gemini CLI across work and personal contexts, **while keeping your conversations continuous across account switches**.

> **Note:** The CLI command is lowercase `orbital`. The product name is capitalized as **Orbital**.

## The Problem

AI CLI tools like Claude Code, Codex, and Gemini store their config (API keys, auth tokens, settings) in a single global directory. If you have a work account and a personal account, switching between them means manually swapping credentials or keeping two separate machines.

Worse, switching accounts usually means **losing your conversation history**. You're mid-task with Claude, switch to a different account, and your session is gone — you have to start over and re-explain all the context.

## How Orbital Solves This

Orbital manages named environments stored under `~/.orbital/envs/`. Each environment has its own isolated auth credentials, while **session data is shared by default** — so you can switch accounts and pick up exactly where you left off.

- **Auth isolation**: each environment gets its own config directory per tool, so credentials never leak between accounts
- **Session sharing**: conversation history, project context, and session data are symlinked to a shared location (`~/.orbital/shared/`), so `claude --resume` works seamlessly after switching environments
- **Per-shell activation**: `orbital use work` only affects the current terminal — other windows keep their own environment

## Requirements

- macOS 13+ or Linux
- bash or zsh

## Installation

### Install script (recommended)

Downloads a pre-built binary for your platform. No Swift required.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/OffskyLab/Orbital/main/install.sh)"
```

Supports macOS (arm64, x86_64) and Linux (x86_64, arm64). Falls back to building from source if a pre-built binary is not available.

### Homebrew (macOS / Linux)

```bash
brew install OffskyLab/orbital/orbital
```

### APT (Ubuntu / Debian)

```bash
echo "deb [trusted=yes] https://offskylab.github.io/apt stable main" | sudo tee /etc/apt/sources.list.d/orbital.list
sudo apt update && sudo apt install orbital
```

### Build from source

Requires Swift 6.0+.

```bash
git clone https://github.com/OffskyLab/Orbital.git
cd Orbital
swift build -c release
cp .build/release/orbital /usr/local/bin/orbital
```

### Shell integration

Run once after installation:

```bash
orbital setup
source ~/.orbital/activate.sh
```

`orbital setup` generates `~/.orbital/activate.sh` and adds `source` to your shell rc file (`~/.zshrc` or `~/.bashrc`, auto-detected). New shells will activate automatically.

## Quick Start

```bash
# Create environments (sessions are shared by default)
orbital create work --description "Work account"
orbital create personal --description "Personal account"

# Manage tools for an environment (interactive multi-select)
orbital tools -e work
orbital tools -e personal

# Store credentials
orbital set env ANTHROPIC_API_KEY sk-ant-work123 -e work
orbital set env ANTHROPIC_API_KEY sk-ant-personal456 -e personal

# Switch environments — your session history carries over
orbital use work
claude                    # start a conversation
orbital use personal
claude --resume           # pick up right where you left off

# Deactivate (clear all Orbital env vars)
orbital deactivate
```

## The `origin` Environment

`origin` is Orbital's reserved name for your unmodified system environment. It cannot be deleted, renamed, or configured with tools or environment variables.

Switching to `origin` exits Orbital management — all Orbital variables are cleared and tools fall back to their system-wide config, exactly as if Orbital weren't installed:

```bash
orbital use origin     # exit Orbital, return to system config
orbital deactivate     # same as above
```

This makes `origin` a clean escape hatch: run a command under your default system credentials without affecting any Orbital environment.

## Session Sharing

By default, session data (conversation history, project context) is shared across all environments. This means:

- Switch from `work` to `personal` → your Claude conversations are still there
- Use `claude --resume` after switching → continues the exact same session
- Each environment still has its own **isolated auth credentials**

Session sharing works by symlinking tool-specific session directories (`projects/`, `sessions/`, `session-env/`) to a shared location under `~/.orbital/shared/`.

If you need fully isolated sessions (e.g., for compliance reasons), you can opt out per environment:

```bash
orbital create secure-env --isolate-sessions
```

The interactive wizard also asks about session sharing when creating an environment.

## Commands

### Environment management

| Command | Description |
|---|---|
| `orbital create <name>` | Create a new environment (sessions shared by default) |
| `orbital create <name> --clone <source>` | Clone tools and env vars from an existing environment |
| `orbital create <name> --isolate-sessions` | Create with fully isolated sessions |
| `orbital delete <name>` | Delete an environment (prompts for confirmation) |
| `orbital delete <name> --force` | Delete without confirmation |
| `orbital rename <old> <new>` | Rename an environment |
| `orbital list` | List all environments (`*` marks the active one) |
| `orbital info [name]` | Show full details of an environment (defaults to active) |

### Switching

> Requires shell integration (`orbital setup`)

| Command | Description |
|---|---|
| `orbital use <name>` | Activate an environment in the current shell |
| `orbital deactivate` | Deactivate the current environment |
| `orbital current` | Print the name of the active environment |

### Configuration

| Command | Description |
|---|---|
| `orbital tools [-e <name>]` | Manage tools interactively (multi-select) |
| `orbital set env <KEY> <VALUE> -e <name>` | Set an environment variable |
| `orbital unset env <KEY> -e <name>` | Remove an environment variable |
| `orbital which <tool>` | Print the config dir path for a tool in the active environment |

> If an environment is active (`orbital use <name>`), the `-e` flag can be omitted.

### Sessions

| Command | Description |
|---|---|
| `orbital sessions` | List all AI tool sessions for the current project |
| `orbital sessions --claude` | Show only Anthropic Claude sessions |
| `orbital sessions --codex` | Show only OpenAI Codex sessions |
| `orbital sessions --gemini` | Show only Google Gemini sessions |

### Cross-tool

| Command | Description |
|---|---|
| `orbital run -e <name> <command>` | Run a command in a specific environment |
| `orbital delegate -e <name> "prompt"` | Delegate a task to an AI tool in another environment |
| `orbital resume <index>` | Resume a session by index (from `orbital sessions`) |

### AI Tool Integration (MCP)

Orbital integrates with Claude Code, Codex CLI, and Gemini CLI via [MCP](https://modelcontextprotocol.io/).

```bash
orbital mcp setup
```

This registers Orbital as an MCP server and installs `/delegate` and `/sessions` slash commands. Available MCP tools:

| Tool | Description |
|---|---|
| `orbital_delegate` | Delegate a task to another account's AI tool |
| `orbital_list` | List all environments |
| `orbital_sessions` | List sessions for the current project |
| `orbital_current` | Get the active environment |
| `orbital_memory_read` | Read shared project memory |
| `orbital_memory_write` | Write to shared project memory |

**Shared memory**: All AI tools read and write to the same `ORBITAL_MEMORY.md` per project. Knowledge saved by Claude is accessible from Codex and Gemini, and vice versa.

**External memory storage**: By default memory is stored under `~/.orbital`. You can redirect it to any directory — such as an Obsidian vault — with `orbital memory storage <path>`. When the new path is empty, Orbital offers to copy your existing memory there:

```bash
orbital memory storage ~/Documents/my-wiki/orbital
# New path has no memory yet. Copy current memory there?
# ▶ Copy memory to new path
#   No, start fresh

orbital memory storage --reset   # revert to ~/.orbital
```

Fragments and AI consolidation work the same way regardless of where memory is stored.

### Shell integration

| Command | Description |
|---|---|
| `orbital setup` | Install shell integration into shell rc file (idempotent) |
| `orbital init` | Print the shell integration script (for manual setup) |

## P2P Memory Sync

Sync project memory across machines and teammates in real time, powered by [orbital-sync](https://github.com/OffskyLab/orbital-sync).

### Desktop + Laptop

Same person, two machines on the same network:

```bash
# Desktop
orbital sync daemon --port 9527

# Laptop (auto-discovers via Bonjour)
orbital sync daemon --port 9528
```

### Team Collaboration

```bash
# Create team and generate invite
orbital sync team create my-team
orbital sync team invite --port 9527
# → share the invite code with teammates

# Teammate joins
orbital sync team join <code>
orbital sync daemon --port 9528
```

### Cross-Network (Rendezvous)

```bash
# Run rendezvous on a VPS
orbital sync rendezvous --port 9600

# Each peer
orbital sync daemon --port 9527 --rendezvous rv.example.com:9600
```

### Encrypted (mTLS)

```bash
orbital sync daemon --port 9527 \
  --tls-ca ca.pem --tls-cert node.pem --tls-key node-key.pem
```

Only project memory is synced — sessions stay local. New teammates get all existing memory on first connect. Memory changes are tracked as conflict-free fragments and consolidated by the AI agent at session start.

| Command | Description |
|---|---|
| `orbital sync daemon` | Start the sync daemon |
| `orbital sync status` | Show daemon and peer status |
| `orbital sync pair <host:port>` | Pair with a remote peer |
| `orbital sync team create <name>` | Create a new team |
| `orbital sync team invite` | Generate an invite code |
| `orbital sync team join <code>` | Join a team |
| `orbital sync team info` | Show team and known peers |
| `orbital sync rendezvous` | Run a rendezvous server |

## Storage

Environments are stored under `$ORBITAL_HOME` (default: `~/.orbital`):

```
~/.orbital/
  current                # name of the last activated environment
  shared/                # shared session data across environments
    claude/
      projects/          # conversation history per project
      sessions/          # session metadata
      session-env/       # session environment snapshots
  envs/
    <UUID>/
      env.json           # metadata: tools, env vars, timestamps
      claude/            # CLAUDE_CONFIG_DIR points here
        .claude.json     # auth credentials (isolated per env)
        projects/  -> ~/.orbital/shared/claude/projects   (symlink)
        sessions/  -> ~/.orbital/shared/claude/sessions   (symlink)
      codex/             # CODEX_CONFIG_DIR points here
    <UUID>/
      env.json
      claude/
```

Set `ORBITAL_HOME` to use a custom location.

## Environment Variables Set by `orbital use`

| Tool | Variable |
|---|---|
| `claude` | `CLAUDE_CONFIG_DIR` |
| `codex` | `CODEX_CONFIG_DIR` |
| `gemini` | `GEMINI_CONFIG_DIR` |

Custom env vars set with `orbital set env` are also exported on `orbital use`.

## Localization

Orbital auto-detects your system locale (`LC_ALL`, `LC_MESSAGES`, `LANG`) and displays messages in Traditional Chinese (`zh_TW`) or English.

## License

Apache 2.0
