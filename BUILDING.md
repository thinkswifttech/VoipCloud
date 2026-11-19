# Building VoIPCloud

This repository contains the client source and build definitions. Use your own
service endpoints, Firebase projects, test accounts, and signing identities.
Those deployment-specific values are not included in source control.

## Toolchain

The current mobile baseline is:

- Flutter 3.41.9 with Dart 3.11.5 or a compatible stable release
- JDK 17 and Android SDK 36
- Xcode with an iOS SDK supported by the selected Flutter release
- Liblinphone Android no-video SDK 5.4.124
- Liblinphone iOS SDK 5.5.19 built from source with the bound-interface patches in `ios/sdk_patch` (source also published at <https://github.com/thinkswifttech/linphone-sdk>, tag `5.5.19-voipcloud1`)

A source release must record the exact Flutter version and the exact iOS SDK
source revision used for its store binary.

## Configure a development build

Install dependencies:

```sh
flutter pub get
```

Supply Firebase configuration from a Firebase project you control:

- `android/app/google-services.json`
- `ios/Runner/GoogleService-Info.plist`

Run with non-production endpoints and accounts:

```sh
flutter run \
  --dart-define=APP_ENV=development \
  --dart-define=API_BASE_URL=https://api.example.test \
  --dart-define=MESSAGING_BASE_URL=https://messaging.example.test \
  --dart-define=SIP_DOMAIN=sip.example.test \
  --dart-define=SIP_PROXY_HOST=proxy.example.test \
  --dart-define=SIP_TRANSPORT=tls
```

Optional settings include `STUN_SERVER`, `TURN_SERVER`, and
`ENABLE_VOIP_DEBUG_LOGS`.

## Verify

```sh
flutter analyze
flutter test
```

## Build Android

Create `android/key.properties` from `android/key.properties.example` and
use a signing key you control. Then run `flutter build appbundle --release`
with the same `--dart-define` values required by the target deployment.

## Build iOS

Use an Apple signing identity and provisioning profile you control.

1. Build the patched Liblinphone SDK as described in `ios/sdk_patch/README.md`
   (`build_patched_sdk.sh fetch`, `verify`, `patched`, `package`). The Xcode project
   references the result as a local Swift package; every framework in its
   `Package.swift` is a local `binaryTarget`. Record the SHA-256 of the framework
   zips (see `ios/sdk_patch/SHIPPED-SDK-CHECKSUMS.txt`).
2. Resolve the remaining Swift packages in Xcode and commit the generated
   `Package.resolved`.
3. Run `flutter build ipa --release` with the target deployment's
   `--dart-define` values. The iPhone "Calling network" setting appears only when
   both `CALLING_NETWORK_ENABLED` and `CALLING_NETWORK_IOS_ENABLED` are true.

Do not publish an iOS binary until the SDK source revision (the
`5.5.19-voipcloud1` tag or a later one) is identified in the matching source release.

## Credentials and services

Signing keys, provisioning profiles, Firebase configuration, SIP credentials,
TURN credentials, and production service configuration are intentionally not
published. They are deployment inputs, not source code, and must never be
committed to this public repository.
