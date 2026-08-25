Output ../assets/demo/add.gif
Output add-check.txt

Require orrery-bin

# `orrery add --claude` prepares a staging dir, then hands off to a real
# interactive `claude` running against it. Authentication happens in the
# BROWSER — vhs drives a headless terminal on a fixed timeline and can't
# click through OAuth, so whoever records this must already be signed in as
# the identity they want captured.
#
# Claude's first-run sequence, as of v2.1.237 (measured, not guessed):
#   1. theme picker, cursor pre-parked on "2. Dark mode"    → Enter
#   2. "Select login method", option 1 pre-selected         → Enter
#   3. a long OAuth URL plus a "Paste code here if prompted >" prompt,
#      which sits there until the browser round trip finishes
#   4. "Logged in as <email> / Press Enter to continue…"
#
# Step 2 is easy to miss: an early probe sent three blind Enters and its
# frames only showed the theme picker and then the browser, which read as
# "theme leads straight to login". It does not. Sending a single Enter
# leaves the run parked on the login-method picker forever.
#
# Hard-won: do NOT send keys after step 3 begins. The gap between the
# browser finishing and the TUI repainting step 4 is unbounded — 90s was
# not always enough — and any Enter or text arriving while step 3 is on
# screen lands in its paste prompt, submits an empty code, and fails the
# login outright ("OAuth error: Invalid code"). Several takes died that way.
# The account does not need those keystrokes: `auth_success` fires as a
# claude hook, independently of the TUI, so the import happens regardless.
# This tape therefore stops typing after step 2 and just watches.
#
# Because nothing types `/exit`, `_account-add-finalize` never runs, so its
# cleanup is skipped: the staging dir stays behind at
# $TMPDIR/orrery-login-<uuid>, and if the login completed, Claude Code also
# leaves a `Claude Code-credentials-<sha256(stagingDir)[0:8]>` item in the
# login Keychain. Sweep both after recording — five such orphans piled up
# over the takes that produced this tape.
#
# Step 2 is hidden for a second reason: that OAuth URL carries PKCE and
# state parameters, and a public docs page is no place for them.
#
# Running this tape CREATES a real account. Remove any existing one of the
# same name first (`orrery remove --claude --force demo-1`) or prepare fails.

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

Type "orrery add --claude demo-1"
Sleep 0.5s
Enter

# _account-add-prepare, the hand-off hint, then claude booting into its
# theme picker.
Sleep 9s

# 1. accept the theme
Enter
Sleep 3s

# 2. accept the pre-selected login method — the last keystroke this tape sends
Enter

Hide
# 3. OAuth URL + browser round trip. Hidden; over-provisioned on purpose,
#    since overshooting costs only wall-clock, never gif length.
Sleep 90s
Show

# 4. whatever the screen reached — ideally "Logged in as <email>".
Sleep 5s
