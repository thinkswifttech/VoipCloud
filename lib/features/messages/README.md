# Carrier messaging frontend boundary

This feature is the product-facing carrier SMS/MMS client. It must not import
or invoke Linphone, `SipService`, the SIP message stream, or the native
`sendMessage` platform method.

It is also carrier-neutral. Twilio, VoIP.ms, and every future provider belong
behind server-side carrier adapters. Client code must not select a carrier,
branch on provider names, consume provider webhook payloads, or expose provider
identifiers and credentials. The VoIPCloud messaging API owns normalization.

The repository binds to the authenticated messaging HTTPS/realtime data plane
when `MESSAGING_BASE_URL` is configured, and remains fail-closed otherwise.
Outbound composition is controlled by the data plane's per-inbox capability
response. Standard APNs/FCM tokens are registered separately from SIP call
push tokens; carrier-message pushes never start the Linphone core.

The implementation must:

- use the authenticated app session and the provisioned inbox UUID;
- treat the provisioned DID as display/readiness metadata, never as a
  client-selected sender value;
- load server history as the system of record and use local storage only as a
  protected cache;
- use client idempotency IDs for every outbound submission;
- normalize API and realtime events into `CarrierMessage`;
- accept only VoIPCloud-normalized statuses, attachments, errors, and
  capabilities rather than carrier-specific values;
- reconnect and resynchronize after realtime interruptions;
- refresh the authoritative inbox index after realtime activity so outbound
  messages, read state, blocks, and deletions synchronize across every device
  logged into the same messaging inbox;
- derive unread badges from the server conversation index rather than replayed
  history, preventing old events from appearing as newly unread after initial
  provisioning;
- keep private media URLs and message bodies out of routine logs;
- clear protected cached data on logout, revocation, suspension, reassignment,
  and reprovisioning; and
- route standard APNs/FCM and desktop notification payloads to conversations.

Do not add concrete endpoint paths, payload fields, retention behavior, or
realtime protocols here until the versioned messaging data-plane contract is
approved.

## SMS reply and reaction compatibility

SMS/MMS has no carrier-neutral reply or reaction metadata. The client therefore
uses a visible, plain-text compatibility format instead of inventing hidden
fields or depending on one carrier:

- replies are transmitted as a single-line `"quoted excerpt"`, a blank line,
  and the response; older `> quoted excerpt` replies remain readable;
- reactions use the Google Messages-style visible fallback
  `👍 to "message excerpt"`; the parser also accepts Apple-style fallbacks
  such as `Liked "message excerpt"`;
- composer shortcodes such as `:smile:` are expanded to Unicode before
  submission; and
- every encoded message remains understandable in an external SMS client.

The Flutter presentation layer reconstructs quote cards and reaction badges on
all supported platforms. A reaction fallback is collapsed only when it matches
one unique earlier message. Ambiguous, localized, malformed, pending, or failed
fallbacks remain visible as ordinary SMS. The server continues to store and
forward the exact carrier body, and the existing client idempotency/outbox flow
is used without carrier-specific branching.

When the referenced message is available in loaded history, a reconstructed
quote is an in-thread anchor: selecting it scrolls to the nearest matching
earlier message and briefly highlights that bubble. Photo replies show a local
photo icon while keeping the external carrier payload as `"Photo"`, a blank
line, and the response; no private attachment URL or app token is exposed.

## Concatenated SMS

A long SMS remains one logical VoIPCloud message. The client submits the full
body once with one idempotency ID; it must never split the body into separate
API requests. The carrier adapter/provider applies standard concatenated-SMS
headers and the recipient handset normally reassembles the transport segments.
This preserves ordering, retry safety, cross-device synchronization, aggregate
status, and one bubble in the app.

Before enqueueing, the client calculates GSM-7 septets (including extension
table escapes) or UCS-2/UTF-16 units and applies the standard 160/153 and 70/67
single/concatenated capacities. The capability response may advertise
`outbound_sms_max_segments`; the compatibility default is 10. The client
disables sending above that ceiling, while the server remains authoritative
and must enforce the same adapter-specific limit before carrier dispatch.
