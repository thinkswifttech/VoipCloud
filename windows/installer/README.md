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

Before installation, the MSI presents the choices that affect installed
Windows resources. Both are selected by default:

- create a desktop shortcut;
- start VoipCloud in the notification area when the current user signs in to
  Windows.

Before initializing Flutter or the SIP SDK, the executable sets its working
directory to its own installation folder. MSI completion, Windows sign-in, and
update relaunches must not depend on an inherited installer/system directory;
native SDK resource initialization can otherwise abort before a window appears.

The completed page presents the standard preselected **Launch VoipCloud**
checkbox. Launching from that page also displays the app-owned, dismissible
taskbar pin offer. Install-time properties are marked secure so desktop and
sign-in choices survive MSI elevation. The sign-in entry is owned by the MSI,
removed on uninstall, and uses `--background` so it keeps SIP registered
without opening the main window.

The MSI does not present a separate license page. Like every other platform,
Windows displays the current ThinkSwift Master Services Agreement after a
successful provisioning and before SIP is activated. The agreement is loaded
from the versioned, checksummed VoIPCloud legal endpoint configured through
`LEGAL_TERMS_URL`; it is not compiled into the installer.

The completed-page launch starts or activates VoipCloud with a one-time,
dismissible in-app pin banner, including when an existing tray instance
receives the installer handoff.
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
verifies the signature, and prints its SHA-256 digest. Signing is strongly
recommended; an unsigned MSI still shows Windows' Unknown publisher prompt.

Windows MSI builds always use `config/production.json` through Flutter's
`--dart-define-from-file` option. Packaging validates `APP_ENV=production` and
checks every value against Flutter's generated Windows defines before compiling.

## Publishing desktop updates

The production config points the desktop app at the deployment-specific HTTPS
update manifest. Settings > About exposes **Check for updates**. On Windows,
**Update** downloads the versioned MSI into the user's temporary directory,
checks its size and SHA-256 against the HTTPS manifest, and asks for confirmation
before closing the app. A separate helper rechecks SHA-256 after VoipCloud exits,
starts the MSI with Windows' normal UAC approval and passive progress UI, waits
for completion, then reopens VoipCloud. If UAC is declined or setup fails, the
helper reports the error, leaves a verbose MSI log beside the downloaded MSI,
and reopens the existing app. Updates are deferred
while a call is active. On macOS, the release still opens in the browser.

The Windows helper is installed beside VoipCloud.exe but copied to the user's
temporary directory for each update so the MSI can replace the installed files.
The new code first ships in a normal MSI; an older installed build without the
helper cannot perform this automatic handoff and must be upgraded manually once.
The updater never bypasses UAC or the unsigned-publisher warning.

CPack/WiX currently enables `AllowSameVersionUpgrades`, so a new MSI with a new
ProductCode but the same three-field ProductVersion can replace the previous
build. The portal's filename and ProductVersion validation can therefore stay
as-is. Windows Installer cannot distinguish build numbers in this case, so a
manually launched older same-version MSI could downgrade the app; the in-app
updater only offers a manifest build newer than the installed build.

Windows and macOS also perform one quiet update check when the app opens. When
a newer desktop build is available, the Settings icon displays a badge and the
About section presents the release and update action. Network failures never
block startup and can be retried manually from About.

After building the MSI, publish it with:

```powershell
.\tool\publish_windows_update.ps1 `
  -MsiPath .\build\windows\msi\VoipCloud-1.0.1+28-windows-x64.msi `
  -Version 1.0.1 `
  -Build 28 `
  -OutputDirectory .\build\desktop-update `
  -ReleaseNotes 'Reliability and desktop usability improvements.' `
  -AllowUnsigned
```

The publisher refuses an MSI without a valid Authenticode signature by default
and emits the versioned MSI plus `stable.json`. For a deployment that accepts
Windows' **Unknown publisher** warning, add `-AllowUnsigned`. Upload the MSI
first and the manifest last. Host these files from the HTTPS web server on the
Flexisip host, not from the SIP process. The nginx example and deployment notes
are in `server_staging/desktop_updates/`.

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
