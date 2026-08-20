Output ../assets/demo/phantom.gif

Require orrery-bin

Set Shell "zsh"
Set FontSize 32
Set Width 1200
Set Height 1200

# Phantom supervision is the default for a bare `claude` — the shell
# function in activate.sh wraps it. `orrery run claude` is no longer the
# entry point, and `orrery exit` (the old reset step here) no longer exists.
# Pin a known starting account instead, so the switch below is deterministic.

Hide
Type "source ~/.orrery/activate.sh"
Enter
Sleep 500ms
Type "orrery use personal"
Enter
Sleep 1s
Type "clear"
Enter
Show

Type "claude"
Sleep 0.5s
Enter
Sleep 5s

Type "/orrery:phantom work"
Sleep 2s
Enter
Sleep 15s
