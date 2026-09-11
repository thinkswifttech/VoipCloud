# VoIPCloud

VoIPCloud is an open-source softphone client built with Flutter and the
Liblinphone SDK.

## Features

- SIP voice calling and account registration
- Native incoming-call integration on Android and iOS
- Contacts, directory, quick dial, and call history
- Messaging and attachment support
- Mobile push-notification handling
- Audio-device and call-control integration

## Platform support

| Platform | Status |
| --- | --- |
| Android | Supported with the Liblinphone no-video SDK |
| iOS | Supported with the Liblinphone Swift package |
| macOS | Native Liblinphone bridge included |
| Windows | Native bridge included; the SDK is supplied locally |
| Linux and web | SIP calling is not currently implemented |

## Getting started

### Requirements

- Flutter stable with Dart `^3.11.5`
- A Firebase project for mobile push notifications
- SIP service credentials for development and testing

### Setup

1. Clone the repository.
2. Run `flutter pub get`.
3. Add configuration files from your own Firebase project:
   - `android/app/google-services.json`
   - `ios/Runner/GoogleService-Info.plist`
4. Start the application with the required `--dart-define` values.

```sh
flutter run \
  --dart-define=APP_ENV=development \
  --dart-define=API_BASE_URL=https://api.example.test \
  --dart-define=MESSAGING_BASE_URL=https://messaging.example.test \
  --dart-define=SIP_DOMAIN=sip.example.test \
  --dart-define=SIP_PROXY_HOST=proxy.example.test \
  --dart-define=SIP_TRANSPORT=tls
```

Supported configuration values include `APP_ENV`, `API_BASE_URL`,
`MESSAGING_BASE_URL`, `SIP_DOMAIN`, `SIP_PROXY_HOST`, `SIP_TRANSPORT`,
`STUN_SERVER`, `TURN_SERVER`, and `ENABLE_VOIP_DEBUG_LOGS`.

Run the standard checks with:

```sh
flutter analyze
flutter test
```

Never commit production credentials, signing keys, SIP passwords, TURN
credentials, service-account keys, or private infrastructure configuration.
See [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change.

## Build and source releases

See [BUILDING.md](BUILDING.md) for local build instructions. Every distributed
binary must map to an exact public source tag using the mandatory process in
[SOURCE_RELEASES.md](SOURCE_RELEASES.md).

## Project scope

This repository contains the VoIPCloud client applications. Backend services
and Flexisip server deployment are maintained separately.

## License

VoIPCloud is licensed under the GNU Affero General Public License version 3
only (`AGPL-3.0-only`). See [LICENSE](LICENSE).

Liblinphone and related Belledonne Communications components retain their own
copyright notices and licensing terms. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The VoIPCloud and ThinkSwift names and logos are trademarks of their respective
owners. The source-code license does not grant trademark rights.

## Security

Please follow [SECURITY.md](SECURITY.md) when reporting a vulnerability.
