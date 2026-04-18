---
applies-to: <0.0.1
---
<!--
This file is fetched by `orrery _check-update` when the CLI detects a newer
release than the one installed.

Format:
  - `applies-to:` takes a comma-separated list of version constraints (logical AND).
    Supported operators: <, <=, =, >=, >. Example: `>=2.0.0, <2.3.0`.
  - The body below the closing `---` is printed verbatim to the user's terminal.

When the current value (<0.0.1) matches nobody, this file is effectively dormant.
Edit `applies-to:` and replace this comment block with a real notice when needed.
Users will see the updated message within 4 hours of their next shell command
(shell wrapper throttles `_check-update` at 14400 s — see ShellFunctionGenerator.swift).
-->
