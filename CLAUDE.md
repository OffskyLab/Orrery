# Orrery — Development Guidelines

## Versioning

- Version locations in this repo:
  - `Sources/OrreryCore/Commands/OrreryCommand.swift` — `version:` field
  - `Sources/OrreryCore/MCP/MCPServer.swift` — `currentVersion()` return value
  - `CHANGELOG.md`
  - `docs/index.html` — badge
  - `docs/zh_TW.html` — badge

## Release Checklist

1. Bump version in all locations above
2. Update `CHANGELOG.md`
3. Commit and push
4. Tag `vX.Y.Z` and push tag (triggers CI)
5. Wait for CI to complete
6. Update `homebrew-orrery/Formula/orrery.rb` with new sha256
7. Push homebrew formula

## Architecture

- `OrreryCore` — all logic, commands, MCP server
- `orrery` — thin executable target
- `orrery sync` — delegates to `orrery-sync` binary (separate repo)

## Memory Fragments

- `orrery_memory_write` produces fragment files in `fragments/` alongside `ORRERY_MEMORY.md`
- `orrery_memory_read` detects pending fragments and prompts agent to consolidate
- Overwrite (`append=false`) cleans up fragment files after consolidation
