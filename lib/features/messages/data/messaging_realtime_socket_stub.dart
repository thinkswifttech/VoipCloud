abstract interface class MessagingRealtimeSocket {
  Stream<String> get messages;

  void add(String message);

  Future<void> close();
}

Future<MessagingRealtimeSocket> connectMessagingRealtimeSocket(
  Uri uri, {
  Duration pingInterval = const Duration(seconds: 25),
}) {
  throw UnsupportedError('Messaging realtime is unavailable on this platform.');
}
