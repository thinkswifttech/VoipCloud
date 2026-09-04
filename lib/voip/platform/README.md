Native integration notes
========================

This folder is the boundary for platform-specific VoIP work.

Integration status:

- Android: liblinphone no-video SDK is linked through Linphone Maven and calls
  are registered with AndroidX Core-Telecom. Telecom owns call concurrency and
  audio endpoints; Linphone owns SIP signaling and media.
- iOS: liblinphone no-video SPM and PushKit/CallKit are integrated for incoming
  and outgoing calls. CallKit owns call lifecycle and AVAudioSession owns
  Bluetooth, wired, speaker, AirPlay, and CarPlay routing; build and hardware
  validation must happen on macOS/Xcode.
- macOS: liblinphone no-video SPM package is referenced through the Runner
  Xcode project. The native bridge owns the live desktop SIP registration and
  actionable incoming-call notifications. Closing the final window keeps the
  process resident; explicit Quit ends desktop call availability. Build,
  signing, and hardware validation must happen on macOS/Xcode.
- Windows: the Flutter channel bridge is in place and compiles. It loads
  `linphone.dll` or `liblinphone.dll` at runtime from the executable directory,
  `PATH`, or `LINPHONE_WINDOWS_DLL`. Closing the window keeps the core resident
  in the notification area; explicit Quit ends desktop call availability.
- Linux/web: unsupported for SIP calling until a native/WebRTC calling layer is
  deliberately added.
- Shared: platform event streams for registration, call state, and plain SIP
  `MESSAGE` events. This message bridge is a separate technical SIP capability,
  not carrier SMS/MMS and not user-to-user product chat.

Do not add background calling workarounds here. Flexisip push wake-up, APNs/FCM,
CallKit, and AndroidX Core-Telecom should be implemented through supported
platform APIs.

Desktop scope
-------------

Windows and macOS are first-class targets for this app. They should use the
same Dart-facing `VoipService` contract as mobile:

- `initialize`
- `configureAccount`
- `register` / `unregister`
- `purgeAccount` after a confirmed user logout/reset
- `makeCall`
- `acceptCall`
- `declineCall`
- `endCall`
- `mute`
- `setSpeaker`
- `sendMessage` (plain SIP `MESSAGE` only; do not use for carrier SMS/MMS)
- registration state events
- call state events
- message events

Carrier SMS/MMS is outside this Linphone platform channel. The launch product
uses a separate authenticated HTTPS/realtime messaging service on iOS/iPadOS,
Android, Windows, and macOS. That service derives the sender DID and carrier
from the server-side FlexiAPI assignment. Linux and web omit carrier Messages
navigation and services in the first release. Microsoft Teams owns user-to-user
chat.

Platform-specific behavior belongs behind the native side of the channel:

- Android uses Core-Telecom's compatibility ConnectionService/transactional
  APIs, one CallStyle foreground notification, and a cold-start-safe native
  lock-screen activity.
- iOS uses PushKit/CallKit for incoming calls and starts outgoing SIP calls only
  after CallKit accepts the `CXStartCallAction`.
- macOS provides exact Linphone endpoint selection, pairs a selected output
  with its matching input where available, and presents native Answer/Decline
  notifications while its window is hidden.
- Windows provides exact Linphone sound-device selection and pairs playback with
  capture where the SDK reports that capability. It remains resident in the
  notification area and raises a native incoming-call alert. The alert opens
  the authoritative Flutter call screen; direct notification Answer/Decline is
  a release gate that requires the MSI's stable AUMID and a registered desktop
  notification activator.

iOS incoming-call push contract
-------------------------------

The Flexisip/APNs VoIP payload should identify the SIP transaction and caller:

```json
{
  "call_id": "<SIP INVITE Call-ID>",
  "caller_number": "+14165551234",
  "caller_name": "<optional trusted PBX display name>",
  "from_uri": "sip:+14165551234@tenant.example.com"
}
```

Use an E.164 `caller_number` whenever possible. The iOS bridge reports it as a
CallKit `.phoneNumber` remote handle, allowing the operating system to resolve
the user's local Contacts for the native incoming-call screen. If an explicit
`caller_name` is absent, the bridge deliberately leaves `localizedCallerName`
unset so that native contact resolution is not overridden. SIP users or
prefixed identifiers that are not telephone numbers use a `.generic` handle.

`call_id` must be the INVITE Call-ID expected by liblinphone. The bridge never
passes a missing value to `processPushNotification`; payloads without it use a
registration wake because affected SDK builds dereference a null Call-ID.

The push service is responsible for mapping trusted SIP metadata to this
minimal client payload. Keep its deployment topology, credentials, signing
material, tenant routing, and operational configuration outside this client
repository. Push tokens, secrets, caller metadata, and full SIP URIs must not
be written to logs.

Android incoming-call push contract
-----------------------------------

Android uses a data-only FCM message. The payload is additive to the iOS fields:

```json
{
  "schema_version": "1",
  "event": "incoming_call",
  "call_id": "<SIP INVITE Call-ID>",
  "caller_number": "+14165551234",
  "caller_name": "<optional trusted PBX display name>",
  "from_uri": "sip:+14165551234@tenant.example.com",
  "sent_at_ms": "1786992000000"
}
```

The FCM Android configuration must use `HIGH` priority and a 30-second TTL.
The client checks FCM's delivered timestamp/TTL and never performs a network
request before presenting the call. Payloads without `call_id` wake Linphone
but do not create a guess-matched Telecom placeholder. Tokens, shared secrets,
caller metadata, and full SIP URIs must not be written to logs.

macOS SDK direction
-------------------

Use the official Linphone macOS Swift package:

`https://gitlab.linphone.org/BC/public/linphone-sdk-swift-macos`

Prefer the `novideo/stable` branch while the product is audio-only. Switch to
`stable` only when video calling is explicitly required.

The native macOS layer imports `linphonesw`, owns the liblinphone `Core`,
translates delegates into Flutter events, and avoids logging SIP credentials or
tokens. The app target also needs microphone and network-client entitlements.

Windows SDK direction
---------------------

Use the official Windows package source:

`https://gitlab.linphone.org/api/v4/projects/411/packages/nuget/index.json`

Install `LinphoneSDK.Windows` for the Windows runner/plugin layer or place the
runtime DLLs beside `VoIPCloud.exe`. The native Windows layer owns the
liblinphone core and translates Windows/C++ events into the same Flutter channel
event shapes used by Android, iOS, and macOS.

Do not put Windows-specific SIP behavior in Dart. Dart should remain concerned
with app state and user actions, not SDK lifecycle details.
