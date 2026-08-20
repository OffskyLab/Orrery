Output ../assets/demo/workspace-create.gif

Require orrery-bin

# Creates a throwaway `demo` workspace. Run this before workspace-pin.tape,
# which pins an account into it. Delete it afterwards with
# `orrery workspace delete demo` if you don't want it lying around.

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

Type "orrery workspace create demo"
Sleep 0.5s
Enter
Sleep 1s

# The wizard asks one yes/no per tool, then a sub-wizard (login source,
# clone source, session isolation, memory isolation) for each "yes". These
# bare Enters accept the defaults all the way through — if the wizard gains
# or loses a step, adjust the count here to match.
Enter
Sleep 2s

Enter
Sleep 2s

Enter
Sleep 2s

Enter
Sleep 2s

Enter
Sleep 2s

Enter
Sleep 2s

Enter
Sleep 2s

Enter
Sleep 2s

Type "Y"
Enter
Sleep 3s
