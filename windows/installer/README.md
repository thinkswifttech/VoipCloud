# Windows MSI release

The Windows desktop process owns the live SIP registration. Closing its main
window hides VoipCloud in the notification area; users must choose **Quit** from
the tray menu to terminate registration. An incoming SIP call immediately
restores the existing Flutter window and routes to its incoming-call screen. A
taskbar flash and native notification-area alert remain presentation fallbacks;
they are cleared on answer, decline, CANCEL, or call termination. Answer and
decline in the Flutter call coordinator remain authoritative.

VoipCloud is single-instance per interactive Windows session. A repeat launch
from Start, a shortcut, or the installed executable exits after asking the
existing process to restore and activate its window. The handoff waits briefly
for a first launch that is still creating its Flutter window, so repeated clicks
immediately after installation cannot create multiple SIP cores.

The MSI presents a final options page before installation with these choices
selected by default:

- create a desktop shortcut;
- launch VoipCloud after installation; and
- offer to pin VoipCloud to the taskbar after launch.

The pin option launches VoipCloud with a one-time, dismissible in-app banner.
Only clicking **Pin to taskbar** in that banner calls `TaskbarManager`, which
then shows Windows' native confirmation. The app hides the banner when the API
is unavailable or disabled by policy. Windows does not permit an installer to
call the pin API directly; do not add registry, verb, or PowerShell pinning
workarounds to the MSI.

## Build prerequisites

- Windows 10/11 x64 with Visual Studio C++ desktop tools.
- Flutter and CMake/CPack on `PATH`.
- WiX Toolset supported by the installed CMake version.
- The reviewed stable Linphone SDK 5.5.16 installed as documented in
  `windows/third_party/linphone/README.md`.
- Production Authenticode certificate available in the Windows certificate
  store; expose only its thumbprint as `VOIPCLOUD_WINDOWS_SIGNING_THUMBPRINT`.

Run from PowerShell:

```powershell
.\windows\installer\build_msi.ps1
```

The script fails if Linphone is absent, builds the release bundle, creates an
MSI from CMake's complete install graph, signs it when a thumbprint is supplied,
verifies the signature, and prints its SHA-256 digest. Never distribute an
unsigned production MSI.

Windows MSI builds always use `config/production.json` through Flutter's
`--dart-define-from-file` option. Packaging validates `APP_ENV=production` and
checks every value against Flutter's generated Windows defines before compiling.

Desktop calling cannot receive a Flexisip mobile wake after explicit process
termination or Windows sign-out. Production deployment should instruct users
to leave VoipCloud running in the tray and may deploy a separately approved
login-start policy. A future actionable Windows App SDK notification must use a
stable application identity and COM activation; do not emulate answer/decline
with an unauthenticated helper process.

## Desktop interaction contract

- Windows and macOS use explicit **Decline** and **Answer** buttons for incoming
  calls; the bidirectional swipe control remains mobile-only.
- Enter/Numpad Enter answers and Escape declines while the incoming-call window
  is active.
- `Ctrl+1` through `Ctrl+5` navigate visible destinations on Windows;
  `Ctrl+,` opens Settings. macOS uses the matching Command shortcuts.
- Desktop conversation lists expose Block/Delete from a visible overflow menu;
  touch builds retain swipe actions.
