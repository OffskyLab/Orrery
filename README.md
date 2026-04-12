# Orrery

<p align="center">
  <img src="assets/icon-1024x1024.png" alt="Orrery" width="256" height="256" />
</p>

[繁體中文](docs/README-zh_TW.md)

Per-shell environment manager for AI CLI tools — isolate accounts for Claude Code, Codex CLI, and Gemini CLI across work and personal contexts, **while keeping your conversations continuous across account switches**.

> **Note:** The CLI command is lowercase `orrery`. The product name is capitalized as **Orrery**.

## The Problem

AI CLI tools like Claude Code, Codex, and Gemini store their config (API keys, auth tokens, settings) in a single global directory. If you have a work account and a personal account, switching between them means manually swapping credentials or keeping two separate machines.

Worse, switching accounts usually means **losing your conversation history**. You're mid-task with Claude, switch to a different account, and your session is gone — you have to start over and re-explain all the context.

## How Orrery Solves This

Orrery manages named environments stored under `~/.orrery/envs/`. Each environment has its own isolated auth credentials, while **session data is shared by default** — so you can switch accounts and pick up exactly where you left off.

- **Auth isolation**: each environment gets its own config directory per tool, so credentials never leak between accounts
- **Session sharing**: conversation history, project context, and session data are symlinked to a shared location (`~/.orrery/shared/`), so `claude --resume` works seamlessly after switching environments
- **Per-shell activation**: `orrery use work` only affects the current terminal — other windows keep their own environment

## Requirements

- macOS 13+ or Linux
- bash or zsh

## Installation

### Install script (recommended)

Downloads a pre-built binary for your platform. No Swift required.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/OffskyLab/Orrery/main/install.sh)"
```

Supports macOS (arm64, x86_64) and Linux (x86_64, arm64). Falls back to building from source if a pre-built binary is not available.

### Homebrew (macOS / Linux)

```bash
brew install OffskyLab/orrery/orrery
```

### APT (Ubuntu / Debian)

```bash
echo "deb [trusted=yes] https://offskylab.github.io/apt stable main" | sudo tee /etc/apt/sources.list.d/orrery.list
sudo apt update && sudo apt install orrery
```

### Build from source

Requires Swift 6.0+.

```bash
git clone https://github.com/OffskyLab/Orrery.git
cd Orrery
swift build -c release
cp .build/release/orrery /usr/local/bin/orrery
```

### Shell integration

Run once after installation:

```bash
orrery setup
source ~/.orrery/activate.sh
```

`orrery setup` generates `~/.orrery/activate.sh` and adds `source` to your shell rc file (`~/.zshrc` or `~/.bashrc`, auto-detected). New shells will activate automatically.

## Quick Start

```bash
# Create environments (sessions are shared by default)
orrery create work --description "Work account"
orrery create personal --description "Personal account"

# Add / remove tools interactively (each invocation handles one tool via a wizard)
orrery tools add -e work
orrery tools remove -e work

# Store credentials
orrery set env ANTHROPIC_API_KEY sk-ant-work123 -e work
orrery set env ANTHROPIC_API_KEY sk-ant-personal456 -e personal

# Switch environments — your session history carries over
orrery use work
claude                    # start a conversation
orrery use personal
claude --resume           # pick up right where you left off

# Deactivate (clear all Orrery env vars)
orrery deactivate
```

## The `origin` Environment

`origin` is Orrery's reserved name for your unmodified system environment. It cannot be deleted, renamed, or configured with tools or environment variables.

Switching to `origin` exits Orrery management — all Orrery variables are cleared and tools fall back to their system-wide config, exactly as if Orrery weren't installed:

```bash
orrery use origin     # exit Orrery, return to system config
orrery deactivate     # same as above
```

This makes `origin` a clean escape hatch: run a command under your default system credentials without affecting any Orrery environment.

## Session Sharing

By default, session data (conversation history, project context) is shared across all environments. This means:

- Switch from `work` to `personal` → your Claude conversations are still there
- Use `claude --resume` after switching → continues the exact same session
- Each environment still has its own **isolated auth credentials**

Session sharing works by symlinking tool-specific session directories (`projects/`, `sessions/`, `session-env/`) to a shared location under `~/.orrery/shared/`.

If you need fully isolated sessions (e.g., for compliance reasons), you can opt out per environment:

```bash
orrery create secure-env --isolate-sessions
```

The interactive wizard also asks about session sharing when creating an environment.

## Commands

### Environment management

| Command | Description |
|---|---|
| `orrery create <name>` | Create a new environment (sessions shared by default) |
| `orrery create <name> --clone <source>` | Clone tools and env vars from an existing environment |
| `orrery create <name> --isolate-sessions` | Create with fully isolated sessions |
| `orrery delete <name>` | Delete an environment (prompts for confirmation) |
| `orrery delete <name> --force` | Delete without confirmation |
| `orrery rename <old> <new>` | Rename an environment |
| `orrery list` | List all environments (`*` marks the active one) |
| `orrery info [name]` | Show full details of an environment (defaults to active) |

### Switching

> Requires shell integration (`orrery setup`)

| Command | Description |
|---|---|
| `orrery use <name>` | Activate an environment in the current shell |
| `orrery deactivate` | Deactivate the current environment |
| `orrery current` | Print the name of the active environment |

### Configuration

| Command | Description |
|---|---|
| `orrery tools add [-e <name>]` | Add a tool via wizard (login copy + settings clone) |
| `orrery tools remove [-e <name>]` | Remove a tool from the environment |
| `orrery set env <KEY> <VALUE> -e <name>` | Set an environment variable |
| `orrery unset env <KEY> -e <name>` | Remove an environment variable |
| `orrery which <tool>` | Print the config dir path for a tool in the active environment |

> If an environment is active (`orrery use <name>`), the `-e` flag can be omitted.

### Sessions

| Command | Description |
|---|---|
| `orrery sessions` | List all AI tool sessions for the current project |
| `orrery sessions --claude` | Show only Anthropic Claude sessions |
| `orrery sessions --codex` | Show only OpenAI Codex sessions |
| `orrery sessions --gemini` | Show only Google Gemini sessions |

### Cross-tool

| Command | Description |
|---|---|
| `orrery run -e <name> <command>` | Run a command in a specific environment |
| `orrery delegate -e <name> "prompt"` | Delegate a task to an AI tool in another environment |
| `orrery resume <index>` | Resume a session by index (from `orrery sessions`) |

### AI Tool Integration (MCP)

Orrery integrates with Claude Code, Codex CLI, and Gemini CLI via [MCP](https://modelcontextprotocol.io/).

```bash
orrery mcp setup
```

This registers Orrery as an MCP server and installs `/delegate` and `/sessions` slash commands. Available MCP tools:

| Tool | Description |
|---|---|
| `orrery_delegate` | Delegate a task to another account's AI tool |
| `orrery_list` | List all environments |
| `orrery_sessions` | List sessions for the current project |
| `orrery_current` | Get the active environment |
| `orrery_memory_read` | Read shared project memory |
| `orrery_memory_write` | Write to shared project memory |

**Shared memory**: All AI tools read and write to the same `ORRERY_MEMORY.md` per project. Knowledge saved by Claude is accessible from Codex and Gemini, and vice versa.

**External memory storage**: By default memory is stored under `~/.orrery`. You can redirect it to any directory — such as an Obsidian vault — with `orrery memory storage <path>`. When the new path is empty, Orrery offers to copy your existing memory there:

```bash
orrery memory storage ~/Documents/my-wiki/orrery
# New path has no memory yet. Copy current memory there?
# ▶ Copy memory to new path
#   No, start fresh

orrery memory storage --reset   # revert to ~/.orrery
```

Fragments and AI consolidation work the same way regardless of where memory is stored.

### Shell integration

| Command | Description |
|---|---|
| `orrery setup` | Install shell integration into shell rc file (idempotent) |
| `orrery init` | Print the shell integration script (for manual setup) |

## P2P Memory Sync

Sync project memory across machines and teammates in real time, powered by [orrery-sync](https://github.com/OffskyLab/orrery-sync).

### Desktop + Laptop

Same person, two machines on the same network:

```bash
# Desktop
orrery sync daemon --port 9527

# Laptop (auto-discovers via Bonjour)
orrery sync daemon --port 9528
```

### Team Collaboration

```bash
# Create team and generate invite
orrery sync team create my-team
orrery sync team invite --port 9527
# → share the invite code with teammates

# Teammate joins
orrery sync team join <code>
orrery sync daemon --port 9528
```

### Cross-Network (Rendezvous)

```bash
# Run rendezvous on a VPS
orrery sync rendezvous --port 9600

# Each peer
orrery sync daemon --port 9527 --rendezvous rv.example.com:9600
```

### Encrypted (mTLS)

```bash
orrery sync daemon --port 9527 \
  --tls-ca ca.pem --tls-cert node.pem --tls-key node-key.pem
```

Only project memory is synced — sessions stay local. New teammates get all existing memory on first connect. Memory changes are tracked as conflict-free fragments and consolidated by the AI agent at session start.

| Command | Description |
|---|---|
| `orrery sync daemon` | Start the sync daemon |
| `orrery sync status` | Show daemon and peer status |
| `orrery sync pair <host:port>` | Pair with a remote peer |
| `orrery sync team create <name>` | Create a new team |
| `orrery sync team invite` | Generate an invite code |
| `orrery sync team join <code>` | Join a team |
| `orrery sync team info` | Show team and known peers |
| `orrery sync rendezvous` | Run a rendezvous server |

## Storage

Environments are stored under `$ORRERY_HOME` (default: `~/.orrery`):

```
~/.orrery/
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
        projects/  -> ~/.orrery/shared/claude/projects   (symlink)
        sessions/  -> ~/.orrery/shared/claude/sessions   (symlink)
      codex/             # CODEX_CONFIG_DIR points here
    <UUID>/
      env.json
      claude/
```

Set `ORRERY_HOME` to use a custom location.

## Environment Variables Set by `orrery use`

| Tool | Variable |
|---|---|
| `claude` | `CLAUDE_CONFIG_DIR` |
| `codex` | `CODEX_CONFIG_DIR` |
| `gemini` | `GEMINI_CONFIG_DIR` |

Custom env vars set with `orrery set env` are also exported on `orrery use`.

## Localization

Orrery auto-detects your system locale (`LC_ALL`, `LC_MESSAGES`, `LANG`) and displays messages in Traditional Chinese (`zh_TW`) or English.

## License

Apache 2.0
