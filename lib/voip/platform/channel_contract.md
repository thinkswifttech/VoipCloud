# VoIP platform channel contract

Flutter channel name: `voipcloud/linphone`

This contract is intentionally platform-neutral. Android, iOS, macOS, and
Windows should all implement these method names and return the same event
payload shapes.

## Methods

### `initialize`

Initializes the native liblinphone core and starts platform event streams.

### `configureAccount`

Payload:

```json
{
  "username": "1001",
  "authUsername": "1001",
  "password": "<sip-secret>",
  "ha1": "<optional-sip-ha1-digest>",
  "algorithm": "<optional-digest-algorithm>",
  "domain": "sip.example.com",
  "outboundProxy": "sip:sip-proxy.example.com:5061;transport=tls",
  "port": 5061,
  "transport": "tls",
  "displayName": "User"
}
```

The password or HA1 digest is passed only over the in-process Flutter platform
channel from secure storage into liblinphone account configuration. Native code
must never log it, emit it on event channels, or send it to the backend.

### `register`

Starts SIP registration.

This operation is also an explicit refresh: when registration is already
enabled, every native implementation sends a new REGISTER rather than merely
replaying the cached `registered` state. Flutter coalesces lifecycle requests
and does not invoke it periodically.

### `unregister`

Stops SIP registration. For a real logout/reset, Flutter waits for the native
unregistered state and then calls `purgeAccount`, even when Flutter's cached
state has not yet observed a restored native account. Native implementations
must emit `unregistered` immediately when no account exists and only after the
explicit unregister transaction clears an existing account. Temporary
unregister actions do not purge the configured identity.

### `purgeAccount`

Removes all native Linphone accounts and authentication records after SIP
unregistration. This also clears platform-specific persisted SIP credentials.
It prevents a later push wake or process restart from restoring a logged-out
identity. Call pushes that arrive for an already-stale registrar binding are
discarded when no persisted SIP identity remains (with iOS still satisfying
PushKit's CallKit reporting requirement). This method must be idempotent.

### `makeCall`

Payload:

```json
{
  "destination": "1002"
}
```

### `acceptCall`

Payload:

```json
{
  "callId": "native-call-id"
}
```

### `declineCall`

Payload:

```json
{
  "callId": "native-call-id"
}
```

### `endCall`

Payload:

```json
{
  "callId": "native-call-id"
}
```

### `mute`

Payload:

```json
{
  "enabled": true
}
```

### `setSpeaker`

Payload:

```json
{
  "enabled": true
}
```

On desktop this maps to the selected output device/default route, not a mobile
loudspeaker.

### `hold`

Payload:

```json
{
  "callId": "native-call-id"
}
```

### `resume`

Payload:

```json
{
  "callId": "native-call-id"
}
```

### `setBluetooth`

Payload:

```json
{
  "enabled": true
}
```

### `getAudioRoutes` / `setAudioRoute`

Each platform returns its authoritative endpoints with stable identifiers for
the current session. Android sources them from Core-Telecom, iOS from
AVAudioSession, and macOS/Windows from Linphone's native device inventory:

```json
{
  "id": "<Telecom ParcelUuid>",
  "route": "bluetooth",
  "label": "AirPods",
  "available": true,
  "selected": true
}
```

Allowed route families are `earpiece`, `speaker`, `bluetooth`, `wired`, and
`streaming`. `setAudioRoute` accepts both `route` and the optional authoritative
`endpointId`. Android passes that exact endpoint back to Telecom and does not
switch Linphone audio devices while Telecom manages the call. iOS changes the
AVAudioSession route while Linphone follows system routing. Desktop platforms
select the exact Linphone device and pair its input/capture side when available.

### `updateDirectoryCache` / `setNativeDnd`

Flutter supplies a bounded number-to-name directory projection and current DND
state to the native call layer. Device DND is enforced on Android, iOS, macOS,
and Windows before native incoming-call UI is presented. Android encrypts its
cold-start cache with Android Keystore AES-GCM and clears it with
`purgeAccount`; Apple platforms persist DND in platform preferences, while
Windows persists it in the current user's VoipCloud registry settings.

### `sendDtmf`

Payload:

```json
{
  "value": "5"
}
```

### `startPresenceSubscriptions`

Starts or replaces the active BLF subscription set. For each extension, native
code sends SIP `SUBSCRIBE` requests using both the `dialog` event package
(`application/dialog-info+xml`) and the `presence` event package
(`application/pidf+xml`). The signed-in account's domain is used. The contract
is implemented by the Android, iOS, macOS, and Windows bridges.

```json
{
  "extensions": ["210", "211"]
}
```

### `stopPresenceSubscriptions`

Terminates every active BLF subscription. This is called when the Directory
screen closes and before SIP unregistration or native-core disposal.

## Events

Use event channels for long-lived state:

- `voipcloud/linphone/registration`
- `voipcloud/linphone/calls`
- `voipcloud/linphone/presence`

Registration event:

```json
{
  "status": "registered",
  "message": "Registration successful"
}
```

Call event:

```json
{
  "id": "native-call-id",
  "remoteUri": "sip:1002@example.com",
  "remoteDisplayName": "1002",
  "direction": "outgoing",
  "status": "active",
  "isMuted": false,
  "isSpeakerEnabled": false,
  "telecomManaged": true,
  "telecomState": "active",
  "currentEndpointId": "<Telecom ParcelUuid>",
  "availableEndpoints": []
}
```

Presence NOTIFY event:

```json
{
  "kind": "notify",
  "extension": "210",
  "event": "dialog",
  "contentType": "application/dialog-info+xml",
  "body": "<dialog-info>...</dialog-info>"
}
```

Subscription lifecycle event:

```json
{
  "kind": "subscription",
  "extension": "210",
  "event": "presence",
  "state": "active"
}
```

Allowed subscription states are `none`, `incoming`, `progress`, `pending`,
`active`, `terminated`, `error`, and `unknown`. Lifecycle states describe the
subscription itself; they must not be confused with the `<state>` inside a
dialog-info NOTIFY.

Directory presence mapping:

- PIDF `<basic>open</basic>` means registered/available and displays green;
- PIDF `<basic>closed</basic>` means unavailable and displays grey;
- dialog state `early`, `proceeding`, or `trying` displays ringing;
- dialog state `confirmed` displays busy/red;
- dialog ringing/busy states take priority over PIDF reachability;
- an empty dialog list or dialog state `terminated` is used as the legacy idle
  fallback when no PIDF result has arrived;
- subscription state `terminated` or `error` means the live status is unknown
  and displays grey;
- setup states such as `progress`, `pending`, and `active` do not overwrite the
  last valid dialog-info state while awaiting a NOTIFY.

Allowed registration statuses:

- `uninitialized`
- `unregistered`
- `configuring`
- `registering`
- `registered`
- `failed`

Allowed call directions:

- `incoming`
- `outgoing`

Allowed call statuses:

- `ringing`
- `dialing`
- `connecting`
- `active`
- `held`
- `ended`
- `missed`
- `failed`
## Default calling and messaging intents (iOS and Android)

Channel: `voipcloud/external_communication_intents`

Apple's Default Calling App and Default Messaging App integrations deliver
`tel:` and `im:` URLs to the native scene/application delegates. Native code
validates and buffers the destination, then sends:

- `externalCommunicationIntent`: `{id, action: call|message, destination}`
- `consumePendingIntent`: returns the buffered payload after a cold start
- `openSystemMessageFallback`: opens `sms:` when the provisioned tenant does
  not provide VoipCloud messaging
- `openDefaultAppsSettings`: opens the app-specific iOS Settings page, which
  includes Default App controls on supported iOS versions

Flutter waits for an authenticated session and for any active call UI to close.
Call actions carry the destination in the dialer route so it survives cold-start
and navigation timing, then populate the number field; message actions open the
composer. Neither operation places a call or sends content without another
explicit user action.

Android exposes separate `ACTION_PROCESS_TEXT` activities labelled **Call with
VoipCloud** and **Message with VoipCloud**, and handles `ACTION_DIAL` `tel:`
intents. Those native entry points produce the same channel payload and use the
same authenticated-session and active-call guards as iOS.
