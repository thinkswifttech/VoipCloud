/// The calling network a call ran on was lost, so the app ended the call.
///
/// Native code appends `calling_network_lost:<wifi|cellular>` to the call's
/// end message, so the screen can say what happened instead of showing a
/// generic "call ended".
const String callingNetworkLostMarker = 'calling_network_lost:';

/// Returns `wifi` or `cellular` when [message] carries the marker, else null.
String? callingNetworkLossPathFrom(String? message) {
  if (message == null) return null;
  final start = message.indexOf(callingNetworkLostMarker);
  if (start < 0) return null;
  final rest = message.substring(start + callingNetworkLostMarker.length);
  if (rest.startsWith('wifi')) return 'wifi';
  if (rest.startsWith('cellular')) return 'cellular';
  return null;
}

/// Plain-language explanation shown after a call ended because its network
/// was lost.
String callingNetworkLossMessage(String path) {
  final connection = path == 'wifi'
      ? 'Wi‑Fi connection'
      : 'mobile data connection';
  return 'Your $connection was lost, so the call ended. '
      'Check your connection and try again. '
      'To keep calls going when the network changes, '
      'choose Auto in Calling network settings.';
}
