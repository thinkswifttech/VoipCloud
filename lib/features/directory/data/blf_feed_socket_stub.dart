abstract interface class BlfFeedSocket {
  Stream<String> get messages;

  int? get closeCode;

  String? get closeReason;

  void add(String message);

  Future<void> close();
}

Future<BlfFeedSocket> connectBlfFeedSocket(
  Uri uri, {
  required Map<String, String> headers,
  required String protocol,
  Duration pingInterval = const Duration(seconds: 25),
}) {
  throw UnsupportedError('The BLF feed is unavailable on this platform.');
}
