import 'dart:io';

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
}) async {
  final socket = await WebSocket.connect(
    uri.toString(),
    protocols: [protocol],
    headers: headers,
  );
  socket.pingInterval = pingInterval;
  return _IoBlfFeedSocket(socket);
}

class _IoBlfFeedSocket implements BlfFeedSocket {
  const _IoBlfFeedSocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<String> get messages =>
      _socket.where((message) => message is String).cast<String>();

  @override
  int? get closeCode => _socket.closeCode;

  @override
  String? get closeReason => _socket.closeReason;

  @override
  void add(String message) => _socket.add(message);

  @override
  Future<void> close() async {
    await _socket.close(WebSocketStatus.normalClosure, 'client closing');
  }
}
