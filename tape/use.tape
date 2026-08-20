Output ../assets/demo/use.gif

Require orrery-bin

# Requires throwaway demo accounts, so the recording never shows a real
# identity and never disturbs a real pin:
#   claude: demo-1, demo-2
#   codex:  demo-1
#   gemini: demo-1

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

Type "orrery use demo-1"
Sleep 0.5s
Enter
Sleep 3s

Type "orrery use demo-2 --claude"
Sleep 0.5s
Enter
Sleep 3s

Type "orrery use demo-1 --codex"
Sleep 0.5s
Enter
Sleep 3s

Type "orrery use demo-1 --gemini"
Sleep 0.5s
Enter
Sleep 3s

# `orrery use` also persists the pin, so a brand-new shell restores it
# automatically — `orrery current` is what that shell reads back.
Type "orrery current"
Sleep 0.5s
Enter
Sleep 4s
