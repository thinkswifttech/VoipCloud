# Patched linphone-sdk source (fork)

The modified Linphone SDK used by the VoipCloud iPhone app is published as a fork of linphone-sdk:

- **Repository:** https://github.com/thinkswifttech/linphone-sdk
- **Branch and tag:** `5.5.19-voipcloud1`
- **Base:** upstream tag `5.5.19`, commit `8e1ec723a2091854e3f6c19790fd64cbb7667539` (https://gitlab.linphone.org/BC/public/linphone-sdk)
- **Changes:** one commit on top of the base: the five `*-bound-interface.patch` files in this folder applied to their modules, plus `VOIPCLOUD-CHANGES.md` at the root of the fork, which lists every modified file and the date. All upstream license files and copyright notices are unchanged.

The app release that uses this source is identified by the tag of the app repository (`v1.0.1+<build>`) and by the checksums in `SHIPPED-SDK-CHECKSUMS.txt`.
