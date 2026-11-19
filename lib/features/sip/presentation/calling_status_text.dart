import '../domain/sip_registration_state.dart';

/// Customer-facing wording for the calling connection. The raw registration
/// message stays in the diagnostics screen and the SIP log.
class CallingStatusText {
  const CallingStatusText._();

  /// Short label, e.g. for a status pill.
  static String label(
    SipRegistrationStatus status, {
    bool reconnecting = false,
  }) {
    return switch (status) {
      SipRegistrationStatus.registered => 'Connected',
      SipRegistrationStatus.registering =>
        reconnecting ? 'Reconnecting' : 'Connecting',
      SipRegistrationStatus.configuring => 'Setting up',
      SipRegistrationStatus.failed => 'Not connected',
      SipRegistrationStatus.unregistered => 'Not connected',
      SipRegistrationStatus.uninitialized => 'Offline',
    };
  }

  /// Headline for the calling status row.
  static String title(
    SipRegistrationStatus status, {
    bool reconnecting = false,
  }) {
    return switch (status) {
      SipRegistrationStatus.registered => 'Calling is ready',
      SipRegistrationStatus.registering =>
        reconnecting ? 'Reconnecting to calling' : 'Connecting to calling',
      SipRegistrationStatus.configuring => 'Setting up calling',
      SipRegistrationStatus.failed => "Calling isn't connected",
      SipRegistrationStatus.unregistered => "Calling isn't connected",
      SipRegistrationStatus.uninitialized => 'Calling is starting',
    };
  }

  /// One friendly sentence about what is happening and what to do.
  static String description(
    SipRegistrationStatus status, {
    bool reconnecting = false,
  }) {
    return switch (status) {
      SipRegistrationStatus.registered => 'You can make and receive calls.',
      SipRegistrationStatus.registering =>
        reconnecting
            ? 'Your connection changed. This usually takes a few seconds.'
            : 'This usually takes a few seconds.',
      SipRegistrationStatus.configuring => 'Almost ready.',
      SipRegistrationStatus.failed =>
        "Check your internet connection. We'll keep trying. If it doesn't "
            'connect, open Help.',
      SipRegistrationStatus.unregistered =>
        "Check your internet connection. We'll reconnect automatically.",
      SipRegistrationStatus.uninitialized =>
        'Calling will be ready in a moment.',
    };
  }

  /// Extra line under the status on the dialer; only shown when something
  /// needs the customer's attention.
  static String? dialerDetail(SipRegistrationStatus status) {
    return switch (status) {
      SipRegistrationStatus.failed => description(status),
      SipRegistrationStatus.unregistered => description(status),
      _ => null,
    };
  }
}
