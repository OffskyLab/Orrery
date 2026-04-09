# Orbital — Development Guidelines

## Versioning

- Orbital and orbital-sync share the same version number (e.g. both at 1.0.0).
- When bumping version, update both repos together.
- Version locations in this repo:
  - `Sources/OrbitalCore/Commands/OrbitalCommand.swift` — `version:` field
  - `Sources/OrbitalCore/MCP/MCPServer.swift` — `currentVersion()` return value
  - `CHANGELOG.md`
  - `docs/index.html` — badge
  - `docs/zh_TW.html` — badge

## Release Checklist

1. Bump version in all locations above
2. Update `CHANGELOG.md`
3. Commit and push
4. Tag `vX.Y.Z` and push tag (triggers CI)
5. Wait for CI to complete
6. Update `homebrew-orbital/Formula/orbital.rb` with new sha256
7. Push homebrew formula

## Architecture

- `OrbitalCore` — all logic, commands, MCP server
- `orbital` — thin executable target
- `orbital sync` — delegates to `orbital-sync` binary (separate repo)

## Memory Fragments

- `orbital_memory_write` produces fragment files in `fragments/` alongside `ORBITAL_MEMORY.md`
- `orbital_memory_read` detects pending fragments and prompts agent to consolidate
- Overwrite (`append=false`) cleans up fragment files after consolidation
