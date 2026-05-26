Output ../assets/demo/use.gif

Require orrery-bin

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

Type "orrery use work"
Sleep 0.5s
Enter
Sleep 3s

Type "orrery use personal --claude"
Sleep 0.5s
Enter
Sleep 3s

Type "orrery use work --codex"
Sleep 0.5s
Enter
Sleep 3s


Type "orrery use work --gemini"
Sleep 0.5s
Enter
Sleep 3s