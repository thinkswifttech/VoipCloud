import 'dart:convert';
import 'dart:io';

abstract interface class MessagingRealtimeSocket {
  Stream<String> get messages;

  void add(String message);

  Future<void> close();
}

Future<MessagingRealtimeSocket> connectMessagingRealtimeSocket(
  Uri uri, {
  Duration pingInterval = const Duration(seconds: 25),
}) async {
  final socket = await WebSocket.connect(
    uri.toString(),
    headers: {'Origin': '${uri.scheme}://${uri.host}'},
  );
  socket.pingInterval = pingInterval;
  return _IoMessagingRealtimeSocket(socket);
}

class _IoMessagingRealtimeSocket implements MessagingRealtimeSocket {
  const _IoMessagingRealtimeSocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<String> get messages => _socket.map((message) {
    if (message is String) return message;
    if (message is List<int>) return utf8.decode(message);
    return '$message';
  });

  @override
  void add(String message) => _socket.add(message);

  @override
  Future<void> close() async {
    await _socket.close(WebSocketStatus.normalClosure, 'client closing');
  }
}
