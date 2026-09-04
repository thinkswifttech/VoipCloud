class RouteNames {
  const RouteNames._();

  static const splash = 'splash';
  static const provisioning = 'provisioning';
  static const provisioningScanner = 'provisioning-scanner';
  static const accountStatus = 'account-status';
  static const home = 'home';
  static const dialer = 'dialer';
  static const activeCall = 'active-call';
  static const incomingCall = 'incoming-call';
  static const callEnded = 'call-ended';
  static const callHistory = 'call-history';
  static const contacts = 'contacts';
  static const directory = 'directory';
  static const messages = 'messages';
  static const settings = 'settings';
  static const sipDiagnostics = 'sip-diagnostics';
  static const sipLogs = 'sip-logs';
}

class RoutePaths {
  const RoutePaths._();

  static const splash = '/';
  static const provisioning = '/provisioning';
  static const provisioningScanner = '/provisioning/scan';
  static const accountStatus = '/account-status';
  static const home = '/home';
  static const dialer = '/dialer';
  static const activeCall = '/calls/:callId';
  static const incomingCall = '/calls/incoming/:callId';
  static const callEnded = '/calls/ended';
  static const callHistory = '/history';
  static const contacts = '/contacts';
  static const directory = '/directory';
  static const messages = '/messages';
  static const settings = '/settings';
  static const sipDiagnostics = '/settings/sip-diagnostics';
  static const sipLogs = '/settings/sip-logs';

  static String activeCallPath(String callId) =>
      '/calls/${Uri.encodeComponent(callId)}';

  static String incomingCallPath(String callId) =>
      '/calls/incoming/${Uri.encodeComponent(callId)}';

  static String callEndedPath({required String status, String? caller}) {
    final normalizedStatus = Uri.encodeComponent(status);
    final callerQuery = caller == null || caller.isEmpty
        ? ''
        : '&caller=${Uri.encodeComponent(caller)}';
    return '/calls/ended?status=$normalizedStatus$callerQuery';
  }
}
