Output ../assets/demo/workspace-pin.gif

Require orrery-bin

# Requires a throwaway demo account (claude: demo-1) and the `demo`
# workspace created by workspace-create.tape — run that one first.
#
# Replaces the old sandbox-enter demo. `orrery enter` / `orrery exit` were
# removed — an account now reaches a workspace by being pinned to it, and
# `orrery use` activates that account (and with it, the workspace's shared
# memory/session dirs).

Set Shell "zsh"
Set FontSize 32
Set Width 1200
Set Height 1200

Hide
Type "source ~/.orrery/activate.sh"
Enter
Sleep 500ms
Type "clear"
Enter
Show

Type "orrery pin demo-1 --workspace demo"
Sleep 0.5s
Enter
Sleep 3s

Type "orrery use demo-1"
Sleep 0.5s
Enter
Sleep 3s

Type "orrery show"
Sleep 0.5s
Enter
Sleep 4s
