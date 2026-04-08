# orbital

<p align="center">
  <img src="assets/icon-1024x1024.png" alt="orbital" width="128" />
</p>

Per-shell environment manager for AI CLI tools — isolate accounts for Claude Code, Codex CLI, and Gemini CLI across work and personal contexts.

## The Problem

AI CLI tools like Claude Code, Codex, and Gemini store their config (API keys, auth tokens, settings) in a single global directory. If you have a work account and a personal account, switching between them means manually swapping credentials or keeping two separate machines. `orbital` solves this by giving each context its own isolated config directory, activated per shell session.

## How It Works

`orbital` manages named environments stored under `~/.orbital/envs/<name>/`. Each environment has:
- A list of tools (`claude`, `codex`, `gemini`) with isolated config subdirectories
- Custom environment variables (API keys, etc.)

When you run `orbital use work`, a shell function intercepts the command, calls the `orbital _export work` internal command, and `eval`s the output — setting `CLAUDE_CONFIG_DIR`, `CODEX_CONFIG_DIR`, etc. in the current shell session only. Other terminal windows are unaffected.

## Requirements

- macOS 15+
- Swift 6.0+ (for building from source)
- zsh

## Installation

### Build from source

```bash
git clone https://github.com/OffskyLab/orbital.git
cd orbital
swift build -c release
cp .build/release/orbital /usr/local/bin/orbital
```

### Shell integration

Run once after installation:

```bash
orbital setup
```

This appends `eval "$(orbital init)"` to `~/.zshrc`. Restart your terminal or run `source ~/.zshrc`.

## Quick Start

```bash
# Create environments
orbital create work --description "Work account"
orbital create personal --description "Personal account"

# Add AI tools to each environment
orbital add tool claude -e work
orbital add tool codex -e work
orbital add tool claude -e personal

# Store credentials
orbital set env ANTHROPIC_API_KEY sk-ant-work123 -e work
orbital set env ANTHROPIC_API_KEY sk-ant-personal456 -e personal

# Switch environments (requires shell integration)
orbital use work
orbital use personal

# Deactivate (clear all orbital env vars)
orbital deactivate
```

## Commands

### Environment management

| Command | Description |
|---|---|
| `orbital create <name>` | Create a new environment |
| `orbital create <name> --clone <source>` | Clone tools and env vars from an existing environment |
| `orbital delete <name>` | Delete an environment (prompts for confirmation) |
| `orbital delete <name> --force` | Delete without confirmation |
| `orbital list` | List all environments (`*` marks the active one) |
| `orbital info <name>` | Show full details of an environment |

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
| `orbital add tool <tool> -e <name>` | Add a tool (`claude`, `codex`, `gemini`) |
| `orbital remove tool <tool> -e <name>` | Remove a tool |
| `orbital set env <KEY> <VALUE> -e <name>` | Set an environment variable |
| `orbital unset env <KEY> -e <name>` | Remove an environment variable |
| `orbital which <tool>` | Print the config dir path for a tool in the active environment |

> If an environment is active (`orbital use <name>`), the `-e` flag can be omitted.

### Shell integration

| Command | Description |
|---|---|
| `orbital setup` | Install shell integration into `~/.zshrc` (idempotent) |
| `orbital init` | Print the shell integration script (for manual setup) |

## Storage

Environments are stored as directories under `$ORBITAL_HOME` (default: `~/.orbital`):

```
~/.orbital/
  current              # name of the last activated environment
  envs/
    work/
      env.json         # metadata: tools, env vars, timestamps
      claude/          # CLAUDE_CONFIG_DIR points here
      codex/           # CODEX_CONFIG_DIR points here
    personal/
      env.json
      claude/
```

Set `ORBITAL_HOME` to use a custom location.

## Environment Variables Set by orbital use

| Tool | Variable |
|---|---|
| `claude` | `CLAUDE_CONFIG_DIR` |
| `codex` | `CODEX_CONFIG_DIR` |
| `gemini` | `GEMINI_CONFIG_DIR` |

Custom env vars set with `orbital set env` are also exported on `orbital use`.

## License

MIT
