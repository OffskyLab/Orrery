# Orrery

<p align="center">
  <img src="assets/icon-1024x1024.png" alt="Orrery" width="256" height="256" />
</p>

[繁體中文](docs/README-zh_TW.md)

**Orrery is a runtime environment manager for AI tools.**

It lets you run Claude Code, Codex CLI, and Gemini CLI across isolated environments — each with its own account and credentials — while keeping your conversations continuous across account switches.

> The CLI command is lowercase `orrery`. The product name is capitalized **Orrery**.

---

## 🧠 Why Orrery?

Working with AI CLI tools today is messy:

- Switching accounts breaks your context
- Conversation history doesn't follow you across accounts
- Tools can't coordinate tasks between environments

Orrery solves this by introducing:

> **Isolated, composable AI environments**

Each environment has its own auth credentials and configuration. But sessions — your conversation history and project context — are **shared by default**, so you can switch accounts and pick up exactly where you left off.

---

## 🧩 Core Concepts

### Environment

An isolated runtime for AI tools:

- Independent account and credentials
- Independent configuration per tool
- Per-shell activation — other terminal windows are unaffected

### Session

Conversations persist across environments. Switch from `work` to `personal` and your sessions are still there — `claude --resume` continues the same conversation even after switching accounts.

### MCP Delegation

Assign tasks to specific environments from within a running session. Enables multi-agent workflows where one Claude instance delegates to another running under a different account.

---

## 🧠 System Model

Orrery introduces a structured runtime model for AI tools:

- **Environment** → isolates identity (accounts, credentials, config)
- **Session** → represents continuity (conversation, context, memory)
- **Delegation (MCP)** → enables coordination between environments

This separation allows:

- Identity isolation without losing context
- Cross-account workflows without duplication
- Multi-agent collaboration with explicit boundaries

In traditional tooling:

- `virtualenv` isolates dependencies
- `nvm` isolates runtime versions

Orrery extends this idea to:

> **AI identity, context, and coordination**

---

## 🎯 Use Cases

- Managing multiple AI accounts (work / personal / clients)
- Running parallel AI workflows without credential conflicts
- Building multi-agent systems across environments
- Experimenting safely without touching your main account

---

## Requirements

- macOS 13+ or Linux
- bash or zsh

---

## Installation

### Native install (macOS, Linux, WSL) — recommended

```bash
curl -fsSL https://offskylab.github.io/Orrery/install.sh | bash
```

Detects your OS/arch, downloads the matching release binary, and installs it to `/usr/local/bin/orrery`. The same command also upgrades an existing install in place.

### Homebrew (macOS)

```bash
brew install OffskyLab/orrery/orrery
```

### Windows

Claude Code on Windows runs inside WSL. Open PowerShell as Administrator and enable WSL first:

```powershell
wsl --install
```

Then, inside your WSL shell, run the native install command above.

### Build from source

Requires Swift 6.0+.

```bash
git clone https://github.com/OffskyLab/Orrery.git
cd Orrery
swift build -c release
cp .build/release/orrery-bin /usr/local/bin/orrery-bin
orrery-bin setup   # writes the `orrery` shell function into your rc file
```

### Shell integration

Run once after installation:

```bash
orrery setup
source ~/.orrery/activate.sh
```

`orrery setup` generates `~/.orrery/activate.sh`, adds a `source` line to your shell rc file (`~/.zshrc` or `~/.bashrc`), and moves your existing tool configs into Orrery storage. New shells activate automatically.

### Migrating from APT (Linux, v2.3.x or earlier)

If you installed Orrery via APT (`apt install orrery`) on v2.3.x or earlier, running `orrery update` may report `already the newest version (2.3.x)` — the APT repo is no longer updated, and the old update path didn't run `apt update` first. Run the native installer once to transition:

```bash
curl -fsSL https://offskylab.github.io/Orrery/install.sh | bash
```

This removes the legacy APT-managed binary, installs the new `orrery-bin`, and switches `orrery update` to the native install flow for all future upgrades. You can optionally clean up the stale APT source afterwards:

```bash
sudo rm /etc/apt/sources.list.d/orrery.list
sudo apt update
```

---

## Quick Start

```bash
# Create environments (sessions are shared by default)
orrery create work --description "Work account"
orrery create personal --description "Personal account"

# Add tools interactively
orrery tools add -e work
orrery tools add -e personal

# Switch environments — your session history carries over
orrery use work
claude                    # start a conversation
orrery use personal
claude --resume           # pick up right where you left off

# Deactivate and return to system config
orrery use origin
```

---

## The `origin` Environment

`origin` is Orrery's reserved name for your original system environment. Switching to it exits Orrery management — all Orrery variables are cleared and tools fall back to their system-wide config, exactly as if Orrery weren't installed.

```bash
orrery use origin     # return to system config
orrery deactivate     # same as above
```

### Origin takeover

`orrery setup` automatically moves your existing tool configs (`~/.claude/`, `~/.codex/`, `~/.gemini/`) into Orrery storage (`~/.orrery/origin/`) and replaces them with symlinks. Your data is untouched — it just lives inside Orrery where it can be managed and synced.

To undo this at any time:

```bash
orrery origin release       # restore all tools to their original locations
orrery origin release --claude  # restore just Claude
orrery origin status        # show current state
```

To completely remove Orrery from your system:

```bash
orrery uninstall            # release all managed configs + remove shell integration
```

---

## Session Sharing

By default, session data is shared across all environments:

- Switch from `work` to `personal` → your Claude conversations are still there
- `claude --resume` continues the same session after switching accounts
- Each environment still has its own **isolated auth credentials**

Session sharing works by symlinking tool session directories (`projects/`, `sessions/`, `session-env/`) to `~/.orrery/shared/`.

For fully isolated sessions (e.g. compliance requirements):

```bash
orrery create secure-env --isolate-sessions
```

---

## Commands

### Environment management

| Command | Description |
|---|---|
| `orrery create <name>` | Create a new environment (sessions shared by default) |
| `orrery create <name> --clone <source>` | Clone tools and env vars from an existing environment |
| `orrery create <name> --isolate-sessions` | Create with fully isolated sessions |
| `orrery delete <name>` | Delete an environment |
| `orrery rename <old> <new>` | Rename an environment |
| `orrery list` | List all environments |
| `orrery info [name]` | Show full details of an environment |

### Switching

> Requires shell integration (`orrery setup`)

| Command | Description |
|---|---|
| `orrery use <name>` | Activate an environment in the current shell |
| `orrery deactivate` | Deactivate and return to origin |
| `orrery current` | Print the active environment name |

### Configuration

| Command | Description |
|---|---|
| `orrery tools add [-e <name>]` | Add a tool via wizard |
| `orrery tools remove [-e <name>]` | Remove a tool |
| `orrery set env <KEY> <VALUE> [-e <name>]` | Set an environment variable |
| `orrery unset env <KEY> [-e <name>]` | Remove an environment variable |
| `orrery which <tool>` | Print the config dir path for a tool |

### Sessions

| Command | Description |
|---|---|
| `orrery sessions` | List sessions for the current project |
| `orrery resume [index]` | Resume a session (interactive picker if no index) |

### Cross-tool

| Command | Description |
|---|---|
| `orrery run -e <name> <command>` | Run a command in a specific environment |
| `orrery delegate -e <name> "prompt"` | Delegate a task to an AI tool in another environment |
| `orrery delegate --resume <id\|index> "prompt"` | Resume a native tool session (UUID, short prefix, or index from `orrery sessions`) |
| `orrery delegate --session [<name>]` | Open a managed-session picker (or resume a named mapping if `<name>` is given) |
| `orrery magi "<topic>"` | Start a multi-model discussion and reach consensus |
| `orrery spec <discussion.md>` | Generate a structured implementation spec from a discussion report |
| `orrery spec-run --mode {verify\|implement\|status} <spec.md>` | Verify a spec, implement it via a delegate agent, or poll status |

### Multi-Model Discussion (Magi)

Inspired by the MAGI system from Neon Genesis Evangelion — three supercomputers that independently evaluate and reach majority decisions. `orrery magi` lets multiple AI models discuss a topic, challenge each other's reasoning, and produce a structured consensus report.

```bash
# All installed tools discuss, 3 rounds (default)
orrery magi "Should we use REST or GraphQL for the new API?"

# Only Claude + Codex, 1 round
orrery magi --claude --codex --rounds 1 "tabs vs spaces"

# Multiple sub-topics (semicolon-separated)
orrery magi "Performance; Developer experience; Maintenance cost"

# Save the report to a file
orrery magi --output report.md "Should we migrate to Swift 6?"
```

| Option | Description |
|---|---|
| `--claude` / `--codex` / `--gemini` | Select participating tools (default: all installed) |
| `--rounds <N>` | Maximum discussion rounds (default: 3) |
| `--output <path>` | Write the markdown report to a file |
| `-e <name>` | Use a specific environment |

At least 2 tools must be installed. Each round, models see their own previous reasoning in full and a structured summary of other participants' positions. The final consensus report uses deterministic majority voting: `agreed` (all agree), `majority` (≥2 agree), `disputed` (≥2 disagree), or `pending` (insufficient data).

Discussion runs are saved as JSON to `~/.orrery/magi/` for later reference.

### Delegate Sessions

`orrery delegate` can resume the delegate tool's own conversation history, not just spawn a fresh one.

```bash
# Resume by short prefix of the native session UUID
orrery delegate -e work --resume 4f2c "follow up on the earlier review"

# Resume by index from `orrery sessions`
orrery delegate -e work --resume 1 "..."

# Open a picker over all managed sessions (across tools and envs)
orrery delegate --session

# Resume a named mapping (auto-infers tool from the saved entry)
orrery delegate --session-name api-redesign "what about the migration plan?"
```

| Option | Description |
|---|---|
| `--resume <id\|index>` | Native session resume — UUID, short prefix, or 1-based index from `orrery sessions` |
| `--session [<name>]` | Open the managed-session picker, or resume the mapping called `<name>` |
| `--session-name <name>` | Resume the named mapping directly (alias of `--session <name>`) |

Named mappings live in `~/.orrery/sessions/mappings.json` and sync across machines via [orrery-sync](https://github.com/OffskyLab/orrery-sync). The three flags are mutually exclusive.

### Spec Pipeline

A three-stage workflow for turning multi-model discussions into shipped code. The pipeline composes naturally with `orrery magi`: discuss → spec → verify → implement → poll.

```bash
# 1. Discuss a problem and save the consensus report
orrery magi --output discussion.md "Should we replace REST with GraphQL?"

# 2. Generate a structured spec from the discussion
orrery spec discussion.md --output spec.md

# 3. Dry-run the acceptance criteria (sandbox-safe)
orrery spec-run --mode verify spec.md

# 4. Hand the spec to a delegate agent in a detached subprocess
orrery spec-run --mode implement spec.md
# → returns a session_id immediately; the delegate keeps running

# 5. Poll until done
orrery spec-run --mode status --session-id <id>
```

| Mode | Behavior |
|---|---|
| `verify` | Parses `## 驗收標準` + `## 介面合約` and runs the acceptance commands. Default dry-run; `--execute` to actually run; `--strict-policy` to fail on policy_blocked. Bounded by a sandbox policy (60s/cmd, 600s overall, 1MB stdout/cmd). |
| `implement` | Spawns a delegate agent in a detached subprocess that writes code per the spec's `## 介面合約` / `## 改動檔案` / `## 實作步驟` / `## 驗收標準` sections. Returns immediately with `session_id` + `status: "running"`; a wrapper shell handles timeout, log redirection, and finalization. |
| `status` | Reads the persisted state under `~/.orrery/spec-runs/{id}.json` and returns `status` + `progress` + (when terminal) full result. Use `--include-log` to tail the progress jsonl, `--since-timestamp` for incremental polling. |

The four mandatory headings (`介面合約` / `改動檔案` / `實作步驟` / `驗收標準`) are checked statically before any subprocess launches — malformed specs are rejected upfront.

### Origin management

| Command | Description |
|---|---|
| `orrery origin status` | Show which tools are managed by Orrery |
| `orrery origin takeover` | Move tool configs into Orrery storage |
| `orrery origin release` | Restore tool configs to their original locations |
| `orrery uninstall` | Remove shell integration and restore all managed configs |

### Shell integration

| Command | Description |
|---|---|
| `orrery setup` | Install shell integration (idempotent) |
| `orrery update` | Update Orrery to the latest version |

---

## MCP Integration

Orrery integrates with Claude Code, Codex CLI, and Gemini CLI via [MCP](https://modelcontextprotocol.io/).

```bash
orrery mcp setup
```

This registers Orrery as an MCP server and installs slash commands.

**Built-in MCP tools** (handled in-process by `orrery-bin`):

| Tool | Description |
|---|---|
| `orrery_delegate` | Delegate a task to another account's AI tool |
| `orrery_list` | List all environments |
| `orrery_sessions` | List sessions for the current project |
| `orrery_current` | Get the active environment |
| `orrery_memory_read` | Read shared project memory |
| `orrery_memory_write` | Write to shared project memory |
| `orrery_spec_status` | Poll the status of an `orrery_spec_implement` session (reads local state file) |

**Sidecar MCP tools** (registered dynamically when the optional `orrery-magi` sidecar is installed — auto-installed by `install.sh` and Homebrew):

| Tool | Description |
|---|---|
| `orrery_magi` | Multi-model discussion → consensus report |
| `orrery_spec` | Generate a spec from a discussion |
| `orrery_spec_verify` | Verify a spec's acceptance criteria |
| `orrery_spec_implement` | Hand a spec to a delegate agent (detached) |

When the sidecar is missing or out of date, the spec MCP tools degrade gracefully — `orrery_magi` keeps working through a single-schema fallback, while the spec tools simply do not register.

**Slash commands installed by `orrery mcp setup`** (available in any project where mcp setup has been run):

| Slash command | Maps to |
|---|---|
| `/orrery:delegate` | `orrery_delegate` MCP tool with environment hints |
| `/orrery:sessions` | `orrery sessions` |
| `/orrery:resume` | `orrery resume <index>` |
| `/orrery:phantom` | `_phantom-trigger` for in-session env switching |
| `/orrery:magi` | `orrery_magi` (with a `/grill-me` pre-flight hint for product/scope topics) |
| `/orrery:spec` | `orrery_spec` |
| `/orrery:spec-verify` | `orrery_spec_verify` |
| `/orrery:spec-implement` | `orrery_spec_implement` |
| `/orrery:spec-status` | `orrery_spec_status` |

**Shared memory**: All AI tools read and write to the same `MEMORY.md` per project. Knowledge saved by Claude is accessible from Codex and Gemini, and vice versa.

**External memory storage**: Redirect memory to any directory — such as an Obsidian vault:

```bash
orrery memory storage ~/Documents/my-wiki/orrery
orrery memory storage --reset   # revert to ~/.orrery
```

---

## P2P Memory Sync

Sync project memory across machines and teammates in real time, powered by [orrery-sync](https://github.com/OffskyLab/orrery-sync).

```bash
# Desktop
orrery sync daemon --port 9527

# Laptop (auto-discovers via Bonjour)
orrery sync daemon --port 9528
```

For cross-network sync, run a rendezvous server on a VPS:

```bash
orrery sync daemon --port 9527 --rendezvous rv.example.com:9600
```

Only project memory is synced — sessions stay local. Memory changes are tracked as conflict-free fragments and consolidated by the AI agent at session start.

| Command | Description |
|---|---|
| `orrery sync daemon` | Start the sync daemon |
| `orrery sync status` | Show daemon and peer status |
| `orrery sync team create <name>` | Create a new team |
| `orrery sync team invite` | Generate an invite code |
| `orrery sync team join <code>` | Join a team |

---

## Storage Layout

```
~/.orrery/
  current                  # active environment name
  origin/                  # original tool configs (after orrery setup takeover)
    claude/                #   ~/.claude/ symlinks here
    codex/
    gemini/
  shared/                  # shared session data across environments
    claude/
      projects/            #   conversation history per project
      sessions/            #   session metadata
  envs/
    <UUID>/
      env.json             #   metadata: tools, env vars, timestamps
      claude/              #   CLAUDE_CONFIG_DIR → here
        .claude.json       #   auth credentials (isolated per env)
        projects/  →  ~/.orrery/shared/claude/projects
        sessions/  →  ~/.orrery/shared/claude/sessions
      codex/               #   CODEX_CONFIG_DIR → here
```

Set `ORRERY_HOME` to use a custom location.

---

## 🚀 Vision

> **The "virtualenv" for AI-native workflows**

As AI tools become core infrastructure, teams need the same isolation, portability, and composability that developers expect from their runtime environments. Orrery brings that to the AI layer.

---

## License

Apache 2.0
