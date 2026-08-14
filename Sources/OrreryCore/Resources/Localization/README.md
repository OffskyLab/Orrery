# Localization

This directory holds the translation source-of-truth for orrery's CLI strings.
The build plugin (`Plugins/L10nCodegen/`) reads these files on every `swift build`
and generates `L10n+Generated.swift` containing both the typed accessors
(`L10n.Create.abstract`, `L10n.Memory.migrationDone(_:_:)`, …) and the embedded
translation dictionaries. There is no runtime resource lookup — all strings ship
inside the binary, so single-file deploys (Homebrew, `.deb`) keep working.

## Files

- `en.json` — **authoritative base.** Its key set defines the schema. Every other
  locale must contain exactly these keys with matching placeholders, or the build
  fails.
- `zh-Hant.json` — Traditional Chinese.
- `ja.json` — Japanese. Currently stubbed from English; awaiting translation.
- `l10n-signatures.json` — generated metadata describing each accessor's Swift
  signature (kind, parameter labels/names/types, branch variants). The codegen
  reads this so the generated typed API stays stable across translation edits.
  Translators should NOT touch this file; only edit it when the *Swift API*
  needs to grow (new key, new parameter, etc.).
- `keys.md` — translator reference. Per-key context, placeholder meanings, and
  formatting rules that can't live inside the flat JSON (JSON has no comment
  syntax). Read this before translating; edit when a key's meaning changes.

## Schema

Each locale file is a flat JSON object:

```json
{
  "create.abstract": "Create a new orrery environment",
  "create.alreadyExists": "Environment '{name}' already exists.",
  "memory.migrationDone.isolated": "Memory for '{envName}' switched to isolated mode.",
  "memory.migrationDone.shared":   "Memory for '{envName}' switched to shared mode."
}
```

- **Keys** use dot-paths that mirror the Swift namespace (`L10n.<Namespace>.<accessor>` → `<namespace>.<accessor>`).
- **Placeholders** use `{name}` syntax. The placeholder name must match a parameter
  declared in `l10n-signatures.json` for that accessor. Mismatches fail validation.
- **Variants** (Bool / Optional dispatch) are sub-keys of the parent. For a Bool
  parameter that selects between two phrasings, the parent has no key — only the
  branches do (e.g. `memory.migrationDone.isolated` + `memory.migrationDone.shared`,
  no `memory.migrationDone`). The signatures file declares which sub-key names
  correspond to `true` / `false` / `present` / `absent`.

## Adding a new locale

1. Copy `en.json` to `<code>.json` (use BCP-47-ish codes: `ja`, `pt-BR`, `de`).
2. Translate the values. Keep keys and placeholders unchanged.
3. Add a case to `AppLocale` in `Sources/OrreryCore/Localization/AppLocale.swift`:
   - new `case`,
   - matching `detect()` branch (e.g. `if raw.hasPrefix("ja")`).
4. Add the `case` to `Localizer.table(for:)` returning the corresponding
   `L10nData.<propertyName>` (codegen names properties in lowerCamel —
   `pt-BR` → `ptBR`).
5. `swift build` — the codegen plugin auto-discovers the new file. If keys or
   placeholders drift from `en.json`, the build fails with a clear diagnostic.
6. `swift test` runs the localization sanity tests across all locales.

## Drift validation (CI guard)

The codegen runs validation before emitting any Swift:

- All locales must have **identical key sets** to `en.json`.
- All placeholders per key must be **identical** across locales.
- Every key in `en.json` must have a matching signature, and vice versa.

A failure here halts `swift build`. Both `localization-check.yml` (every push +
PR) and `release.yml`'s `verify-localization` job (every tag) run this, so a
locale slip can never reach a tagged release.

## Translator workflow

A translator only ever needs to touch one file: their locale's `<code>.json`.
After editing:

1. Run `swift build` locally (optional but fast) to confirm validation passes.
2. Open a PR. CI will validate again and reject drift automatically.
3. No Swift code changes are needed for translation-only PRs.
