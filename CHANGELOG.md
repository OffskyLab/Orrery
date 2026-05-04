# Changelog

## v2.7.0 - 2026-04-29

- **`orrery delegate --resume <id|index>` — native session resume.** Accepts a
  full session UUID, short prefix, or numeric index (matching the order shown
  by `orrery sessions`) and forwards to the delegate tool's native resume
  mechanism (`claude --resume`, `codex resume`, `gemini --resume`). Index
  resolution is scoped to the active environment + tool, so the same numeric
  "1" is unambiguous across runs.
- **`orrery delegate --session` / `--session-name <name>` — managed session
  picker + named resume.** Without a name, opens an interactive picker over
  all managed sessions across tools and envs (tool icon, env name, last-used
  time, first user message preview). With a name, resumes that mapping
  directly and auto-infers the tool from the saved entry. Mappings persist in
  `~/.orrery/sessions/mappings.json` and survive across machines via
  orrery-sync. `--session` / `--session-name` / `--resume` are mutually
  exclusive.
- **Spec runtime moved to `orrery-magi` v1.1.0; `orrery-bin` is now a thin
  forwarder.**  `orrery magi`, `orrery spec`, `orrery spec-run`, and the
  hidden `orrery _spec-finalize` shim still work exactly as before, but
  `main.swift` now intercepts those entrypoints and execs `orrery-magi`
  transparently.  Homebrew and `install.sh` auto-install the sidecar, so
  the move is user-visible only in the architecture.
- **Spec MCP tools are now sidecar-forwarded at startup.**  `orrery-bin`
  handshakes with `orrery-magi --capabilities`, then fetches tool schemas
  with `--print-mcp-schemas` and registers live forwarders for
  `orrery_magi`, `orrery_spec`, `orrery_spec_verify`, and
  `orrery_spec_implement`.  `orrery_spec_status` stays inline in
  `orrery-bin` because it only reads local state.  When paired with an
  older `orrery-magi v1.0.0`, the shim degrades gracefully to the legacy
  single-schema `--print-mcp-schema` path and only exposes `orrery_magi`.
- **Public spec runtime writers were removed from `OrreryCore`; read-side
  contracts remain.**  `SpecRunState`, `SpecRunStateReader`,
  `SpecRunResult`, `SpecStatusResult`, `SpecRunStateContract`, and
  `SpecRunStateError` remain public for status/result consumers.  The
  mutable runner/writer implementation now lives solely in `orrery-magi`.
- **Environment inheritance contract is now explicit: no filtering.**
  `orrery` inherits all parent environment variables from the shell or MCP
  transport, and `orrery-magi` inherits all environment variables from
  `orrery`.  This release also fixes the explicit `delegate -e <env>`
  propagation bug by always injecting `ORRERY_ACTIVE_ENV` into the child.
- **Five runtime bugs fixed in the same release.**  Atomic state-file
  writes no longer race, concurrent resume is guarded correctly, delegate
  env propagation via `-e` works, CLI tests now target the real
  `.build/debug/orrery-bin` path, and temporary state-file suffixes use a
  UUID to avoid collisions.
- **In-flight v2.6.x implement sessions still finalize after upgrade.**
  The hidden `_spec-finalize` first-argument shim forwards to
  `orrery-magi`, so detached wrapper scripts launched before upgrading can
  still complete and write terminal state under v2.7.0.
- **New slash commands.**  `orrery mcp setup` now also writes
  `.claude/commands/orrery:spec-implement.md` and
  `orrery:spec-status.md`, giving users `/orrery:spec-implement` and
  `/orrery:spec-status` directly from the chat box.
- **Parser gains heredoc awareness.**  `SpecAcceptanceParser` now
  recognises `<<EOF` / `<<'EOF'` / `<<"EOF"` / `<<-EOF` blocks inside
  acceptance code fences and keeps the entire heredoc as a single
  command — previously JSON-RPC bodies inside `cat <<'EOF' | ...` were
  split line-by-line and mis-classified.
- **`orrery spec-run --mode verify` and `--mode implement` keep their
  existing user-facing behaviour.**  `verify` still emits a structured JSON
  result with dry-run-by-default sandboxing, and `implement` still returns
  immediately with an orrery-owned `session_id` plus polling via
  `orrery_spec_status`.  The difference in v2.7.0 is that the runtime now
  executes inside `orrery-magi`, not in `OrreryCore`.
- **Sandbox policy (`SpecSandboxPolicy`) for spec verification.**  Three
  layers of defence: dry-run default, allowlist (word-boundary) +
  blocklist (substring, evaluated first) on shell commands, and hard
  runtime caps (60s per command, 600s overall, 1MB stdout per command
  with `…[truncated]` marker).  Python snippets go through a regex-based
  deny-list lint (Q8 tracks upgrading to a real AST check).
- **`DelegateProcessBuilder` gains `OutputMode`.**  New `.capture` mode
  pipes stdout to a `Pipe` for programmatic reading. Existing
  `.passthrough` behaviour is the default — no change to `delegate` or
  other call sites.

## v2.6.2

- **`/orrery:phantom` now installed by `orrery mcp setup` too.** v2.6.0–v2.6.1 only installed the slash command globally to `~/.claude/commands/`, which only Claude reads when `CLAUDE_CONFIG_DIR` is unset (i.e. only in the `origin` env). For non-origin envs, `CLAUDE_CONFIG_DIR` redirects user-level commands to the env's claude config dir, so the global file isn't found. `orrery mcp setup` now writes a project-local copy to `<project>/.claude/commands/orrery:phantom.md` (alongside the existing delegate/sessions/resume commands) — project-local commands are read regardless of `CLAUDE_CONFIG_DIR`, making `/orrery:phantom` available in any env where mcp setup has been run for the project.

## v2.6.1

- **Fix `/orrery:phantom` failing under Claude Code's caffeinate wrapper.** Newer Claude Code builds re-exec under `caffeinate` to keep the system awake during long sessions, so the process tree becomes `supervisor → caffeinate → claude`. v2.6.0's trigger required `claude.ppid == supervisor` directly and silently fell through with "Could not find a running claude process under the phantom supervisor". The trigger now walks up the full parent chain to the supervisor and kills the outermost claude on the way, so any wrapper layer (caffeinate, future variants) is handled transparently.
- **`install.sh`: strip macOS quarantine xattr + re-adhoc-sign before running setup.** Curl-pipe installs left `com.apple.quarantine` on `/usr/local/bin/orrery-bin`; macOS Gatekeeper SIGKILLs the binary on first launch with exit 137 ("Killed: 9"), which killed the post-install `orrery-bin setup` step. install.sh now does `xattr -c` + `codesign --force --sign -` after the binary lands in `/usr/local/bin`. Also fix the cosmetic "Orrery installed installed." message that fired when the SIGKILL'd `--version` probe fell back to the literal string `"installed"`.

  
## v2.6.0

- **Phantom env switching: `/orrery:phantom <env>` swaps the orrery environment without losing the Claude conversation.** `orrery run claude` is now phantom-supervised by default — when the slash command fires, Claude exits and the supervisor relaunches it with the new env active and `--resume <session-id>`, so the conversation continues uninterrupted across account switches. Opt out with `orrery run --non-phantom claude`.
- **Implementation**: a shell supervisor loop in `activate.sh` directly fork/execs claude (no PTY plumbing), a hidden `_phantom-trigger` subcommand walks up its own parent chain to find the supervised claude (robust against claude's internal forking — it's a Bun-compiled Mach-O), discovers the active session id via `<CLAUDE_CONFIG_DIR>/projects/<encoded-cwd>/<id>.jsonl` highest mtime, and signals claude to exit. The slash command markdown is installed globally to `~/.claude/commands/orrery:phantom.md` by `orrery setup`, so it's available in every project regardless of whether `orrery mcp setup` was run there.

## v2.5.0

- **`orrery install <id>` is now a top-level command.** The previous `orrery thirdparty install` is replaced by `orrery install`, matching `npm install` / `brew install` conventions. `uninstall`, `list`, and `available` remain under `orrery thirdparty` because the top-level slots are taken by orrery's own commands.
- **`--url` overrides the manifest source URL.** `orrery install statusline --url https://github.com/me/my-fork` keeps the manifest's install steps (copy `statusline.js`, patch `settings.json`) but pulls source from a custom git repository.
- **Statusline package renamed `orrery-statusline` → `statusline`.** The legacy id still resolves so existing lock files can be uninstalled, but it is hidden from `orrery thirdparty available`.
- **`"ref": "latest"` resolves to the newest version tag.** GitSource now interprets `latest` by calling `git ls-remote --tags --refs --sort=-v:refname` and picking the topmost semver tag (with `versionsort.suffix=-` so `0.2.5` beats `0.2.5-rc1`). The bundled statusline manifest now uses `latest` instead of `main`, so each install pulls the newest release rather than tracking an unstable branch.
- **`CODEX_HOME` for codex env isolation (was `CODEX_CONFIG_DIR`).** Codex CLI reads `CODEX_HOME`, not `CODEX_CONFIG_DIR` — the old variable was set but ignored, silently falling back to `~/.codex`. `orrery delegate --codex`, `orrery run -t codex`, and `orrery export` now correctly point Codex at the per-env config dir.

## v2.4.7

- **`orrery create claude` prompts to install `orrery-statusline`.** After completing the Claude tool wizard, the `create` command now asks whether to install the statusline (default: yes). Answering yes runs `orrery thirdparty install orrery-statusline` automatically during environment creation.
- **`orrery-statusline` replaces `cc-statusline`.** The built-in third-party registry entry is now `orrery-statusline`; `cc-statusline` has been removed.
- **`orrery thirdparty install` shows the installed ref.** The success message now includes the manifest ref and resolved commit SHA, e.g. `orrery-statusline v0.2.2@470e718 (3 files) → myenv`.

## v2.4.6

- **`orrery-statusline` thirdparty package.** New built-in package `orrery-statusline` — a lightweight Claude Code statusline showing Orrery environment name, working directory, git branch, 5h/7d quota bars, env path, and memory path. Install with `orrery thirdparty install orrery-statusline`. Quota and auth data reflect the active environment's account.

## v2.4.5

- **`orrery thirdparty` works in the origin environment.** Installing or uninstalling packages while in `origin` previously crashed with "Environment 'origin' not found" because the store only searches `~/.orrery/envs/`. The runner now routes `origin` directly to `originConfigDir`, the correct storage path.
- **`install.sh` installs the resource bundle on Linux.** The script previously only copied `orrery_OrreryThirdParty.bundle` (macOS); Linux tarballs include `orrery_OrreryThirdParty.resources` instead, which was silently skipped. Both suffixes are now handled.

## v2.4.4

- **`orrery uninstall` removes the binary.** After clearing shell integration and restoring managed configs, uninstall now also deletes `orrery-bin` from its install location. Complete removal in one command.
- **`orrery thirdparty` fatal error on install fixed.** The `OrreryThirdParty` resource bundle was missing from release tarballs and deb packages — only `orrery-bin` was packaged. CI now includes `orrery_OrreryThirdParty.bundle` alongside the binary; `install.sh` installs it to the same directory.

## v2.4.3

- **`orrery thirdparty` command.** New subcommand group for managing third-party plugin packages: `install <id>`, `uninstall <id>`, `list`, and `available`. Packages are fetched from Git (with a local vendored cache for offline use) and installed into the active environment's tool config directory via a declarative manifest. `--env` is optional on all subcommands — defaults to the current active environment (`ORRERY_ACTIVE_ENV`).
- **`orrery uninstall` fully removes the lazy-bootstrap stub.** The old line-filter left `orrery() { … }` behind after uninstall because it only caught the comment and `source` lines. The uninstaller now reuses the same block-stripping logic as `orrery setup`, which handles all three historic rc-file shapes correctly.
- **Dynamic update notice.** When `orrery _check-update` detects a newer release, it also fetches `docs/update-notice.md` from the repo's `main` branch and appends any matching message to the "new version available" line. Notices are filtered by an `applies-to:` frontmatter constraint (supports `<`, `<=`, `=`, `>=`, `>` with comma-separated AND), cached with HTTP `If-None-Match`, and served from cache on transient network failure. Failure is always silent.

## v2.4.1

- **`activate.sh` self-heals after `brew upgrade`.** The generated script now carries a version stamp on the first line. On every new shell, `_orrery_init` compares the stamp against the installed binary version. If they differ — e.g. because `post_install` was silently skipped — it runs `orrery-bin setup` to regenerate and immediately re-sources the file, so the shell heals itself without any manual intervention.
- **`orrery create` / `orrery tools add`: clone no longer copies account-specific data.** The blocklist expanded from 4 items to 20. Skipped: `cache/`, `agent-memory/`, `statsig/`, `stats-cache.json`, `telemetry/`, `usage-data/`, `mcp-needs-auth-cache.json`, `paste-cache/`, `shell-snapshots/`, `history.jsonl`, `file-history/`, `debug/`, `downloads/`, `plans/`, `tasks/`, `todos/`. Kept: `settings.json`, `commands/`, `skills/`, `plugins/`, `agents/`, `CLAUDE.md`, `statusline.sh`.
- **Claude install command updated to native installer.** Changed from `npm install -g @anthropic-ai/claude-code` to `curl -fsSL https://claude.ai/install.sh | bash` (run via `sh -c` to handle the pipe). `installCommandDisplay` added for human-readable output in prompts and error messages.
- **`ToolSetup` install errors now show the manual command.** `SetupError.installFailed` conforms to `LocalizedError`; on failure the message shows the exact command to run manually. The alternate-screen buffer (`\e[?1049h`/`l`) around `npm install` was removed — it was hiding npm's error output from the user.
- **`OrreryVersion.current` single source of truth.** Version string previously duplicated in `OrreryCommand`, `MCPServer`, and `ShellFunctionGenerator` — now all reference one constant.

## v2.4.0

- **Binary renamed `orrery` → `orrery-bin`.** The `orrery` command is now exclusively a shell function (defined in `~/.orrery/activate.sh`), removing the class of bugs where users accidentally invoked the binary in a shell that hadn't sourced the activation script. The binary itself is an implementation detail called by the shell function.
- **Lazy-bootstrap stub in rc file.** `orrery setup` now writes a tiny stub `orrery()` function to your rc file instead of a `source ~/.orrery/activate.sh` line. Shell startup is effectively free — activate.sh is loaded on first `orrery` invocation. Existing source lines / legacy `eval "$(orrery setup)"` shapes are migrated automatically.
- **Install / upgrade cleanup.** Both `install.sh` and the Homebrew formula remove the legacy `/usr/local/bin/orrery` (and `/opt/homebrew/bin/orrery`) binary so the shell function is the only path. The install tarball now ships `orrery-bin`; `install.sh` also accepts older tarballs that still contain `orrery` so the transition doesn't brick existing curl installs.
- **MCP integration points at `orrery-bin`.** `orrery mcp setup` registers `orrery-bin mcp-server` as the MCP server path, since MCP hosts launch servers as non-interactive subprocesses that never run the shell function.

## v2.3.3

- **Install via curl script; APT dropped.** Recommended install is now `curl -fsSL https://offskylab.github.io/Orrery/install.sh | bash` for macOS / Linux / WSL. Homebrew remains as an alternative for macOS. APT repo is retired.
- **`orrery update` smarter.** On macOS, detects `brew list orrery` and uses `brew upgrade` when installed via Homebrew; otherwise re-runs the install script. On Linux, always re-runs the install script.
- **`orrery setup` auto-runs after install.** Both `install.sh` and the Homebrew formula's `post_install` hook now invoke `orrery setup` immediately, so a single install command is enough to generate `activate.sh`, patch your rc file, and perform origin takeover.
- **Docs aligned with Claude's install layout.** Native Install (recommended) first, Homebrew (macOS) second, WSL note for Windows; origin reframed as Orrery's default-managed environment rather than a system passthrough.

## v2.3.2

- **Fix `orrery info origin` claude missing email/plan.** Under `origin` `CLAUDE_CONFIG_DIR` is unset — Claude stores its credential under the default Keychain entry and `~/.claude.json` at home root, not inside the managed dir. `orrery info` and `orrery auth store` now follow this convention for origin claude lookup.
- **Claude credential lookup on Linux.** Reads `{configDir}/.credentials.json` (Claude Code's non-macOS format) instead of falling through to macOS Keychain code.
- **`orrery create --clone` copies only useful settings.** Skips cache/telemetry/session-ephemeral dirs. Only `settings.json`, `commands/`, `skills/`, `plugins/`, `agents/`, `CLAUDE.md`, and `statusline.sh` carry over.
- **Claude install uses the native installer.** `orrery setup` / `orrery tools add` switch from `npm install -g` to `curl -fsSL https://claude.ai/install.sh | bash`. Install errors now surface the manual install command on failure.
- **Docs.** GitHub Pages aligned with README — added "The Model" section (Environment / Session / MCP Delegation) and origin management commands (`orrery origin status/release/uninstall`) in the Origin section.

## v2.3.1

- **`orrery auth show` renamed to `orrery auth store`.** Reflects that the command displays credential store locations (keychain service name, file path, masked API key). Removed separate `--filename` and `--masked-key` flags — all store info is shown together.

## v2.3.0

- **`orrery auth show` new command.** Displays credential info for tools in an environment. Supports `--env`, `--claude`/`--codex`/`--gemini` filters, `--filename` (keychain service name or credential file path), and `--masked-key` (masked API key). When a specific tool flag is given, output is plain (scriptable). When no tool flag is given, output is grouped with headers.
- **`orrery info` shows auth detail per tool.** Claude shows the Keychain service name (`keychain: Claude Code-credentials-{hash}`), Codex and Gemini show the credential file path. Masked API key is shown in the summary line when the tool uses API key auth mode.

## v2.2.4

- **`orrery setup` no longer gets killed.** All `FileHandle.write(Data(...))` calls
  (ObjC API) have been replaced with posix `write()` syscall helpers in a new
  `PosixIO.swift` module. The ObjC API raises `NSFileHandleOperationException` on
  any write failure — an exception Swift cannot catch — causing a SIGABRT that
  appears as `KILL` in iTerm2. The posix syscall silently returns a negative value
  on error and never throws. 14 files updated.
- **`orrery setup` session/memory prompts shown only once.** Previously the
  per-tool session-sharing and memory-sharing prompts appeared on every `orrery setup`
  run for all managed tools. Now they appear only for tools newly taken over in the
  current run — first-time setup still prompts, subsequent runs are silent.
- **`orrery info origin` shows full structured output.** Matching the layout for
  regular environments: Name, Path, Description, Tools with login info, Memory Mode,
  Memory Path, Session Mode, Env Vars.
- **`orrery memory isolate/share/storage` now works for the origin environment.**
  Was previously blocked with an error. Settings are stored in
  `~/.orrery/origin/config.json`.

## v2.2.3

- **`orrery delegate` no longer deadlocks on large output.** When called as
  a Bash tool inside Claude Code, the parent process receives output via a
  pipe whose buffer is ~64 KB. A long delegate session (code review, multi-step
  task) easily emits more than that before finishing. The previous
  `process.standardOutput = FileHandle.standardOutput` + `waitUntilExit()`
  pattern caused the child to block on `write()` once the buffer was full
  while orrery blocked in `waitUntilExit()` — a classic pipe-buffer deadlock.
  Fixed by routing stdout and stderr through `Pipe` and draining them via
  `readabilityHandler` on background queues, keeping the buffer clear for
  the lifetime of the subprocess.

## v2.2.2

- **`orrery resume` interactive picker now works correctly when launched
  from inside a Claude Code session.** The previous implementation used
  `Process().run()` + `waitUntilExit()` to spawn the tool, which left
  `CLAUDECODE` / `CLAUDE_CODE_ENTRYPOINT` / `CLAUDE_CODE_EXECPATH` in the
  child's environment — causing claude to detect itself as a subprocess
  and hang indefinitely. Now uses `execvp()` (same as `orrery run`),
  replacing the orrery process entirely and stripping those IPC variables
  before exec. Full TTY is inherited cleanly.
- **Picker I/O moved to `/dev/tty`.** `SingleSelect` and `MultiSelect`
  now open `/dev/tty` directly for all keyboard input, ANSI output, and
  terminal-mode changes. `stdin` and `stdout` are never touched, so the
  tool that runs after the picker receives a completely clean TTY.
- **Active session detection.** Sessions that are currently open in
  another window are marked with a green `▶` in the picker. Selecting one
  shows a warning before launching.
- **Session ID shown in picker.** Each entry now displays the first 8
  characters of the session ID (dim, before the title) for quick
  identification.

## v2.2.1

- **`orrery list` no longer deadlocks on large Claude credentials.** When
  Claude Code embeds OAuth tokens for connected MCP servers (figma,
  notion, etc.) into its Keychain entry, the credential JSON can exceed
  the macOS pipe buffer (~16 KB, sometimes less). `ClaudeKeychain.findPassword`
  ran `security find-generic-password`, called `waitUntilExit()` *first*,
  then read the pipe — the textbook pipe-buffer deadlock: `security`
  blocks writing into a full pipe while orrery blocks waiting for
  `security` to exit. Observed in the wild as a multi-minute hang with
  `security find-generic-password -s Claude Code-credentials …` visible
  in `ps` while `orrery list` sat idle. Now drains the pipe before
  `waitUntilExit`. Same deadlock pattern fixed in `MCPServer.execCommand`,
  where both stdout AND stderr pipes are now drained concurrently on
  background queues (sequential drain would still deadlock on whichever
  pipe filled second).
- **`orrery list` runs tool account lookups in parallel.** Each env's
  Claude/Codex/Gemini lookup used to run serially, so a slow Keychain
  read on env 1 blocked envs 2..N. Now flattens all `(env, tool)` pairs
  into a single work list and dispatches them via
  `DispatchQueue.concurrentPerform`. Worst-case wall time drops from
  `O(N envs × M tools × per-call)` to roughly `O(per-call)`. Output
  formatting and ordering are unchanged.
- **Memory path = a directory, not a phantom file.** `orrery info` and
  `orrery memory info` now print the memory **directory** (e.g.
  `~/.orrery/shared/memory/{projectKey}/`) instead of
  `.../ORRERY_MEMORY.md` — a file that never actually existed. The
  original v1.1.0 design wrote a single `ORRERY_MEMORY.md` and symlinked
  it into Claude's auto-memory; v1.1.2 switched to directory-level
  symlinking (so every auto-memory write lands in the shared/syncable
  path), which left the `ORRERY_MEMORY.md` filename as dead weight the
  code kept referencing.
- **MCP `orrery_memory_read/write` now operates on `MEMORY.md`.** Matches
  Claude's auto-memory convention, so Codex and Gemini — which call
  these tools via MCP — read and write the exact same file Claude does
  at session start. The memory folder remains the single source of
  truth; Claude gets it automatically via the existing symlink, other
  tools read it through the MCP tool.
- **Internal rename: `EnvironmentStore.memoryFile()` →
  `memoryDir()`.** Returns the folder URL. Downstream call sites
  (MemoryCommand, InfoCommand, MCPServer) updated. `memory export`
  default output filename changed to `MEMORY.md`.

## v2.2.0

- **Localization moved to JSON + build-time codegen.** All CLI strings now
  live in `Sources/OrreryCore/Resources/Localization/<locale>.json` (with
  `en.json` as the schema base). An SPM build plugin (`L10nCodegen`) reads
  the JSON on every `swift build` and emits the typed `L10n.*` accessors
  plus embedded translation tables, so single-file deploys (Homebrew,
  `.deb`) keep working with no runtime resource lookup. Drift across
  locales (missing keys, mismatched placeholders) fails the build.
- **Japanese locale (`ja.json`).** Currently stubbed from English while the
  translation lands; falls back to EN at runtime via `AppLocale.detect()`
  (matches `LANG=ja*`). Adding a future locale is now drop-a-JSON +
  `AppLocale` case + `Localizer` switch arm.
- **Translator key reference (`Resources/Localization/keys.md`).** Per-key
  context, placeholder meanings, and formatting rules (literal commands,
  trailing whitespace in prompts, `\n` placement) for every key — the
  context that can't live inside the flat JSON.
- **`orrery list` rewritten with a multi-line layout.** Each environment
  now shows on its own block with one tool per indented line — much easier
  to read once an env has multiple tools or longer suffixes. Tool rows are
  prefixed with `·`, and the active environment header is highlighted
  (cyan) so it pops out at a glance. Per-field colors keep the readout
  scannable: email near-white, plan mid-gray, model dim. Strips ANSI
  cleanly for non-TTY output (pipes, MCP).

## v2.1.2

- **Gemini env isolation.** gemini-cli ignores `GEMINI_CONFIG_DIR` and always
  reads `~/.gemini/`, so each orrery env now gets a sibling `gemini-home/`
  dir whose `.gemini` symlinks back to the env's gemini config. `orrery use`
  exports `ORRERY_GEMINI_HOME` and a shell `gemini()` wrapper runs gemini
  with `HOME=$ORRERY_GEMINI_HOME` so it lands in the right config dir.
  `orrery delegate --gemini` sets `HOME` on the child process directly.
  Setup is idempotent and backfilled for existing envs on `orrery use`.
- **`orrery delegate --gemini` works with API-key auth.** gemini-cli's
  non-interactive validator (`gemini -p …`) only looks at
  `process.env.GEMINI_API_KEY` and won't fall through to its own Keychain /
  encrypted-file lookup — so delegate now pre-extracts the stored key
  (macOS Keychain first, then decrypts `gemini-credentials.json` via scrypt
  + AES-256-GCM, same derivation gemini-cli uses) and injects it before
  invoking the child.
- **`orrery list` shows API-key auth for gemini.** Detects
  `security.auth.selectedType` (new schema) or `auth.selectedType` (legacy)
  in `settings.json` and renders `gemini(api key)` / `gemini(vertex)`
  alongside the OAuth email case.
- **Background update check no longer prints `[N] PID`.** The background
  version check is now wrapped in a double subshell so the interactive
  shell never registers it as a job — silences both zsh's `[N] PID` line
  and bash's equivalent, replacing the earlier `& disown` dance that still
  leaked a notice on some setups.

## v2.1.1

- **Fix: `orrery delegate` no longer triggers Claude's "no stdin data
  received in 3s" warning.** The delegated tool (`claude -p`, `codex exec`,
  `gemini -p`) takes the prompt as an arg, so the child's stdin is now wired
  to `/dev/null` instead of inheriting the caller's. Removes the warning and
  the 3-second startup latency in non-TTY callers (other scripts, SSH
  without a pty, the MCP server).

## v2.1.0

- **`orrery delete` without args opens a multi-select.** Pick any number of envs
  with arrow keys + space, confirm once, and delete them in one go. Useful
  after testing or when cleaning out a pile of throwaway envs. `--force`
  skips the confirmation; passing a name still does the single-env delete
  with the original confirmation prompt.

Bug fixes carried over (originally drafted for v2.0.1):

- **`orrery create --tool X` now still runs the sub-wizard** for the chosen
  tool (login source, clone source, sessions, memory). The flag was supposed
  to mean "skip the per-tool yes/no loop", not "skip every wizard step".
- **Self-login + clone no longer adopts the source's identity.** Identity
  keys (`oauthAccount`, `userID`, `anonymousId`) and onboarding markers
  (`hasCompletedOnboarding`, `lastOnboardingVersion`) are stripped from
  the cloned `.claude.json` so Claude runs its own onboarding + login flow
  at next launch.
- **Clone skips `backups/`.** `.claude.json.backup.<ts>` snapshots carry a
  full identity. Without this, the heal-from-backup pass would later
  restore the source's identity into the new env, defeating the strip above.
- **Origin's tool logins shown in `list` and `info`.** The `* origin` row
  shows each tool's email + plan, same format as regular envs.
- **Stale session symlinks healed on `orrery use`.** After migration, env's
  `claude/projects` etc. symlinks still pointed at `~/.orbital/shared/...`.
  `linkSharedSessionDirs` now detects misaligned symlinks (not just real
  directories) and recreates them pointing at `~/.orrery/shared/...`.
- **Background version-check no longer prints `[N] done` notices** in zsh —
  the subshell is `disown`'d after backgrounding.
- **Migration heals lost `.claude.json` from backups** when a migrated env
  has `claude/backups/.claude.json.backup.<ts>` present but the main file
  missing (Claude Code refuses to launch in that state).
- **Migration prompt wording tightened.**

## v2.0.0

Orbital has been renamed to **Orrery** and forked to `OffskyLab/Orrery`. This
release continues from Orbital v1.1.6 with no feature changes — the entire
diff is the rename.

**Breaking:**
- CLI binary: `orbital` → `orrery`
- Config directory: `~/.orbital/` → `~/.orrery/`
- Env vars: `ORBITAL_HOME` → `ORRERY_HOME`, `ORBITAL_ACTIVE_ENV` → `ORRERY_ACTIVE_ENV`, `ORBITAL_MEMORY.md` → `ORRERY_MEMORY.md`
- Swift module: `OrbitalCore` → `OrreryCore`
- Homebrew tap: `OffskyLab/orbital/orbital` → `OffskyLab/orrery/orrery`

**Interactive migration:** on each `orrery` invocation, if `~/.orbital/` still
has envs or shared data that haven't been migrated (or previously declined),
`orrery` prompts `[Y/n]` once. Say yes and it moves everything (envs, shared
sessions/memory, `current`, `sync-config.json`), regenerates `activate.sh`
with the new env var names, and updates `source` lines in your shell rc
files. Say no and the declined env IDs are remembered in
`~/.orrery/.migration-state.json` so we don't re-ask. If new orbital envs
appear later, the prompt comes back for just those.

**Claude Keychain migration:** the Keychain service name includes
`SHA256(configDir)`, so renaming the env's config dir would normally
invalidate the stored token and force you to re-login. Migration copies each
env's credential from the old-path service name to the new-path one so your
Claude sessions keep working without re-authenticating.

**Transitional compatibility:** The old `OffskyLab/Orbital` repo remains
published as a deprecated wrapper — it ships a `orbital` command that
forwards to `orrery` with a deprecation notice so existing shell aliases,
MCP configs, and scripts keep working.

## v1.1.6

- **Per-tool setup flow** — new `ToolFlow` protocol with `ClaudeFlow`/`CodexFlow`/`GeminiFlow`; each tool owns its own login copy and settings clone logic
- **Create wizard rewritten** — yes/no per tool (claude → codex → gemini), each "yes" runs a per-tool sub-wizard (login copy → clone settings → sessions → memory for claude)
- **Copy login state** — new wizard step copies credentials + `.claude.json` from origin or another env; Claude uses Keychain (SHA256-hashed service name) + `.claude.json`; Codex uses `auth.json`; Gemini uses `oauth_creds.json`
- **`.claude.json` identity/prefs split** — when login source and clone source are both picked, preferences (theme, dismissed dialogs, projects, usage counters) follow clone; identity keys (`oauthAccount`, `userID`, `anonymousId`, `hasCompletedOnboarding`, `lastOnboardingVersion`) overlay from login; per-account caches (`cachedGrowthBookFeatures`, `cachedStatsigGates`) are stripped so Claude refreshes them
- **Per-tool session isolation** — `OrreryEnvironment.isolateSessions: Bool` (env-wide) split into `isolatedSessionTools: Set<Tool>` (per-tool); backward-compat decoder migrates old env.json on load
- **`tools` subcommand split** — `orrery tools add` (wizard lists un-added tools) and `orrery tools remove` (wizard lists added tools) replace the previous free-form multi-select
- **Login account info in `list` and `info`** — each tool shown as `claude(email, plan)`, `codex(email, plan)`, `gemini(email)` when logged in
- **Login wizard** — options deduplicated by account (email), shows `查詢登入狀況中…` while querying; fast-path email lookup skips Keychain subprocess calls for already-seen accounts
- **Fix: merge preserves existing identity** — if the login source has a partial `.claude.json` (e.g. missing `hasCompletedOnboarding`), merge no longer strips those keys from the target; it only overlays keys that exist in the source
- **`--tool` flag is single-value** — multi-tool non-interactive create was removed; multi-tool envs go through the wizard or through `tools add`

## v1.1.5

- **Wizard cleanup** — create wizard prompts and options are fully cleared after each step, leaving only the final summary visible
- **Post-create switch prompt** — after `orrery create`, asks whether to switch to the new environment immediately
- **Remove Claude auth login step** — `claude auth login` does not respect `CLAUDE_CONFIG_DIR`; removed from create flow — Claude prompts for login naturally on first interactive run
- **Fix: update check empty notice** — background version check no longer creates empty notice files when already up to date

## v1.1.4

- **Update notification redesign** — notice now shows on every `orrery` command (in yellow) until `orrery update` clears it; version check runs in background at most once every 4 hours triggered by command invocation, not shell startup; eliminates Powerlevel10k instant prompt conflict

## v1.1.3

- **Fix: `orrery use <env>` not persisting** — new shell always restored to origin instead of the last used environment; `_set-current` is now called after every successful `orrery use`

## v1.1.2

- **Memory directory symlink** — Claude's auto-memory directory for each project is now symlinked directly to the orrery shared memory location; all memories Claude writes automatically land in the shared (and syncable) location without requiring any CLAUDE.md instructions
- **Fix: `_check-update` version** — now reads from `OrreryCommand.configuration.version` instead of a separate hardcoded string, eliminating version drift

## v1.1.1

- **`ORRERY_MEMORY.md` auto-loaded by Claude** — on `orrery create` (with Claude tool) and on first MCP memory access, a symlink is created inside Claude's auto-memory directory so Claude picks up shared memory automatically at session start
- **Fix: `orrery update` runs `brew update` first** — prevents Homebrew tap cache from reporting an old version as already installed
- **Fix: `orrery list` after upgrade** — migrates `ORRERY_ACTIVE_ENV="default"` and `current` file to `"origin"` on first shell start after upgrading from pre-1.1.0

## v1.1.0

- **Memory external storage** — `orrery memory storage <path>` redirects `ORRERY_MEMORY.md` and fragments to any directory (e.g. Obsidian vault); prompts to copy existing memory when new path is empty; `--reset` to revert
- **Update check at shell startup** — `activate.sh` checks for new releases in background (at most once per day) and shows a notice at the next shell open; runs `orrery update` to upgrade

## v1.0.7

- **`orrery update`** — new command to self-update: uses `brew upgrade orrery` on macOS, `apt-get install --only-upgrade orrery` on Linux
- **`orrery sync` marked experimental** — abstract and discussion now indicate experimental status; `team` subcommands also labeled

## v1.0.6

- **Rename `default` → `origin`** — the reserved system environment is now called `origin`; `orrery use origin` / `orrery deactivate` return to unmanaged system config
- **Switch-to-origin message** — informative locale-aware message when switching to `origin` instead of plain "Switched to environment"
- **GitHub Pages** — new `origin` section explaining its special role; nav link added; `orrery env set/unset` corrected in commands grid

## v1.0.5

- **`orrery env set/unset`** — moved from `orrery set env` / `orrery unset env` to `orrery env set` / `orrery env unset`
- **`orrery info`** — now displays memory path, memory mode (isolated/shared), and session mode (isolated/shared)
- **`orrery memory` redesign** — interactive settings menu with `info`, `export`, `isolate`, `share` subcommands; discard migration requires explicit confirmation
- **Fix: `orrery tools`** — guard against default environment; prompts auth login for newly added tools
- **Fix: `orrery delegate` with Codex** — use `codex exec` for non-interactive mode
- **Fix: default environment** — `orrery set env`, `orrery unset env`, `orrery export`, `orrery unexport` no longer crash on default environment

## v1.0.4

- **Per-environment memory isolation** — `orrery memory isolate` / `orrery memory share` with fragment-based migration; `orrery create` wizard includes memory sharing step (default: isolated)
- **Interactive auth login in `orrery create`** — after selecting tools, prompts to log in to each tool via `execvp` for proper TTY
- **Fix: `orrery create` auth login TTY** — correct `execvp` argv construction, login now works correctly
- **Fix: Strip `ANTHROPIC_API_KEY` in `run` and `delegate`** — inherited API key no longer leaks into non-default environments

## v1.0.2

- **Fix: Strip `ANTHROPIC_API_KEY` in `run` and `delegate`** — inherited API key from shell no longer leaks into non-default environments, ensuring each environment's own credentials are used

## v1.0.1

- **Fix: `orrery run` supports interactive tools** — uses `execvp` to inherit full TTY, fixing `orrery run claude` / `orrery run codex` hanging
- **Fix: Strip Claude IPC env vars** in `run` and `delegate` commands to prevent child processes from hanging
- **Fix: Gemini MCP setup** — updated `gemini mcp add` to new CLI format
- **P2P Sync section** added to README and GitHub Pages (EN + 中文)
- **Fix: scroll-padding-top** for sticky nav on GitHub Pages

## v1.0.0

- **P2P sync** — `orrery sync` delegates to orrery-sync daemon for real-time memory sync across machines
- **Memory fragment integration** — `orrery_memory_read` detects pending sync fragments and prompts agent to consolidate
- **Fragment cleanup** — overwrite mode (`append=false`) automatically cleans up integrated fragments
- **CLAUDE.md** — development guidelines added
- orrery-sync bundled as dependency via Homebrew/APT

## v0.3.3

- **Memory fragment log** — each `orrery_memory_write` now produces an append-only fragment file in `fragments/` alongside `ORRERY_MEMORY.md`, keyed by UUID + peer name. Prepares for future P2P sync with conflict-free replication.

## v0.3.2

- **`/orrery:resume` slash command** — resume session by index from `orrery sessions`
- Slash commands renamed to `/orrery:delegate` and `/orrery:sessions`
- GitHub Pages badge updated

## v0.3.1

- **`orrery memory export`** — export shared project memory to file
- Improved MCP memory tool descriptions with usage scenarios and guidance

## v0.3.0

- **Shared memory across AI tools** — `orrery_memory_read` / `orrery_memory_write` MCP tools let Claude, Codex, and Gemini share the same project memory (`ORRERY_MEMORY.md`)
- **`orrery mcp setup` registers with all tools** — automatically registers MCP server with Claude Code, Codex CLI, and Gemini CLI (skips uninstalled ones)
- AI tool integration section on GitHub Pages (renamed from "Claude Code Integration" to cover all tools)

## v0.2.8

- **MCP server** — `orrery mcp-server` exposes tools via Model Context Protocol (stdin/stdout JSON-RPC)
- **`orrery mcp setup`** — one command registers MCP server + installs `/delegate` and `/sessions` slash commands
- **`orrery delegate`** — delegate tasks to AI tools in other environments (`--claude`/`--codex`/`--gemini`)
- **`orrery resume`** — resume sessions by index from `orrery sessions`, with passthrough args (e.g. `--dangerously-skip-permissions`)
- **`orrery run`** — run any command in a specific environment (`orrery run -e work claude --resume <id>`)
- **`activate.sh`** — `orrery setup` generates `~/.orrery/activate.sh`, rc file uses `source` instead of `eval`
- Shell init silenced for Powerlevel10k instant prompt compatibility
- Linux static linking (`--static-swift-stdlib`) — no runtime dependencies
- Linux built on Ubuntu 22.04 (jammy) for glibc 2.35 compatibility
- APT repo i386 empty Packages to prevent 404 on multiarch systems
- `.deb` postinst runs `orrery setup` automatically
- Localized `--claude`/`--codex`/`--gemini` flag help strings
- `install.sh --main` flag to build from latest main branch

## v0.2.0

- Built-in `default` environment — `orrery use default` returns to system config
- `orrery deactivate` now aliases to `orrery use default`
- Clone wizard in `orrery create` — single-select to clone from `default` or any existing environment
- Session sharing wizard changed to single-select UI
- Each create wizard step is independent — only skipped if its flag is provided
- `orrery sessions` command with `--claude`, `--codex`, `--gemini` flags
- Sessions display with branded tool names, indexed card layout, full session ID
- Pre-built binary releases for macOS (arm64), Linux (x86_64, arm64)
- `.deb` packages and APT repository (Ubuntu/Debian)
- GitHub Pages with Use Cases section, language switcher (English / 繁體中文)

## v0.1.9

- `orrery sessions` command — list AI tool sessions for the current project
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

- `orrery sessions` — list Claude sessions for the current project
- Session support for Codex (`sessions/`) and Gemini (`tmp/`) directories
- Remove auth login instructions from create flow

## v0.1.5

- Fix locale detection — skip empty `LC_ALL`/`LC_MESSAGES` before falling through to `LANG`
- Lazy session symlink migration — `orrery use` auto-creates symlinks for existing environments
- Pre-built binary releases via GitHub Actions

## v0.1.4

- Capitalize product name to Orrery (CLI command stays lowercase)
- Mobile hamburger menu for GitHub Pages
- Language dropdown switcher (English / 繁體中文)
- Copy buttons on install code blocks
- GitHub Pages with Traditional Chinese version

## v0.1.3 (not released as tag)

- Session sharing across environments (default: shared, `--isolate-sessions` to opt out)
- Bash shell support (`orrery setup` auto-detects shell)
- `orrery setup` outputs shell function to stdout for immediate `eval`
- `post_install` in Homebrew formula
- i18n support — Traditional Chinese and English (auto-detect from system locale)
- Traditional Chinese README

## v0.1.2

- Interactive multi-select wizard for tool management
- `orrery info` defaults to active environment
- Linux support with auth instructions
- Switch to Apache 2.0 license

## v0.1.1

- UUID-based environment directories (rename no longer moves dirs)
- `orrery rename` command
- `orrery use` command with shell integration
- Hide internal commands from help

## v0.1.0

- Initial release
- `orrery create`, `delete`, `list`, `info` commands
- `orrery set env`, `unset env`, `tools` commands
- `orrery setup` and `orrery init` for shell integration
- Per-shell environment activation via `orrery use`
- Support for Claude Code, Codex CLI, and Gemini CLI
- Homebrew formula and install script
