# Third-party notices

VoIPCloud uses open-source software provided by third parties. Copyrights and
licenses remain with their respective owners.

## Liblinphone SDK

Copyright Belledonne Communications SARL and contributors.

License: GNU Affero General Public License, version 3.

Source: <https://gitlab.linphone.org/BC/public/linphone-sdk>

SDK references in this source tree:

- Android no-video SDK: `5.4.124`
- macOS Swift package: `5.5.16`
- Windows SDK documentation: `5.5.16`
- iOS: linphone-sdk `5.5.19` (commit `8e1ec723a2091854e3f6c19790fd64cbb7667539`) with VoIPCloud's modifications (five patches in `ios/sdk_patch`, published as tag `5.5.19-voipcloud1` of <https://github.com/thinkswifttech/linphone-sdk>; the changes are listed in `VOIPCLOUD-CHANGES.md` there)

The Linphone SDK bundles additional open-source components with their own
licenses and notice requirements. Belledonne publishes the component inventory
and applicable notices at:

<https://wiki.linphone.org/xwiki/wiki/public/view/Linphone/Third%20party%20components%20/>

## Flutter and Dart packages

The Flutter and Dart dependencies used by the application are recorded in
`pubspec.yaml` and `pubspec.lock`. Each dependency remains subject to the
license published with its source distribution.
