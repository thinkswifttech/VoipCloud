# Linphone Windows SDK

Extract the reviewed stable `linphone-sdk-win64-5.5.16.zip` into this
directory. Do not substitute a `pre` build. If 5.5.16 is not available as a
final release, retain the most recent reviewed final 5.5.x package and update
this document after completing the Windows call regression matrix.

The extracted SDK must contain `linphone.dll` or `liblinphone.dll` plus its
companion runtime DLLs. Keep the complete extracted directory structure; do
not copy only the primary Linphone DLL.

The SDK contents are intentionally ignored by Git. The Windows CMake build
copies every DLL from `linphone-sdk/win64/bin` beside `VoipCloud.exe`
automatically. If the SDK is absent, the app can still build, but SIP calling
will report that Linphone is not linked.
