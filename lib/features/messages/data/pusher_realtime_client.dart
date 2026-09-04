import 'dart:async';
import 'dart:convert';

import '../../../core/logging/app_logger.dart';
import 'messaging_api_client.dart';
import 'messaging_realtime_socket.dart';

class PusherRealtimeClient {
  PusherRealtimeClient(this._api);

  final MessagingApiClient _api;
  final StreamController<int> _invalidations =
      StreamController<int>.broadcast();
  MessagingRealtimeSocket? _socket;
  StreamSubscription<String>? _subscription;
  Timer? _reconnectTimer;
  bool _started = false;
  bool _disposed = false;
  var _reconnectAttempt = 0;

  Stream<int> get invalidations => _invalidations.stream;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    await _connect();
  }

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    await _subscription?.cancel();
    await _socket?.close();
    await _invalidations.close();
  }

  Future<void> _connect() async {
    if (_disposed) return;
    try {
      final response = await _api.get<Map<String, dynamic>>(
        '/api/v1/messaging/realtime/config',
      );
      final data = response.data;
      if (data == null) throw const FormatException('Missing realtime config');
      final scheme = '${data['scheme']}' == 'https' ? 'wss' : 'ws';
      final host = '${data['host']}'.trim();
      final port = _int(data['port']) ?? (scheme == 'wss' ? 443 : 80);
      final appKey = '${data['app_key']}'.trim();
      final channel = '${data['channel']}'.trim();
      if (host.isEmpty || appKey.isEmpty || channel.isEmpty) {
        throw const FormatException('Incomplete realtime config');
      }

      final uri = Uri(
        scheme: scheme,
        host: host,
        port: port,
        path: '/app/$appKey',
        queryParameters: const {
          'protocol': '7',
          'client': 'voipcloud-flutter',
          'version': '1.0',
          'flash': 'false',
        },
      );
      final socket = await connectMessagingRealtimeSocket(uri);
      _socket = socket;
      _subscription = socket.messages.listen(
        (message) => _handle(message, channel),
        onError: (Object error, StackTrace stackTrace) {
          AppLogger.warning('Messaging realtime connection failed');
          _scheduleReconnect();
        },
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
      _reconnectAttempt = 0;
    } catch (error, stackTrace) {
      AppLogger.error(
        'Messaging realtime connection could not start',
        error: error,
        stackTrace: stackTrace,
      );
      _scheduleReconnect();
    }
  }

  Future<void> _handle(String raw, String channel) async {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final event = '${decoded['event'] ?? ''}';
      final data = _decodeData(decoded['data']);

      if (event == 'pusher:connection_established') {
        final socketId = '${data['socket_id'] ?? ''}'.trim();
        if (socketId.isEmpty) return;
        final response = await _api.post<Map<String, dynamic>>(
          '/api/v1/messaging/realtime/auth',
          data: {'socket_id': socketId, 'channel_name': channel},
        );
        final auth = '${response.data?['auth'] ?? ''}'.trim();
        if (auth.isEmpty) throw const FormatException('Missing channel auth');
        _socket?.add(
          jsonEncode({
            'event': 'pusher:subscribe',
            'data': {'auth': auth, 'channel': channel},
          }),
        );
        return;
      }

      if (event == 'pusher_internal:subscription_succeeded') {
        _invalidations.add(0);
        return;
      }
      if (event == 'pusher:ping') {
        _socket?.add(jsonEncode({'event': 'pusher:pong', 'data': {}}));
        return;
      }
      if (event == 'messaging.event') {
        _invalidations.add(_int(data['sequence']) ?? 0);
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'Messaging realtime frame was rejected',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _scheduleReconnect() {
    if (_disposed || _reconnectTimer?.isActive == true) return;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_socket?.close());
    _socket = null;
    final boundedAttempt = _reconnectAttempt > 5 ? 5 : _reconnectAttempt;
    final seconds = switch (boundedAttempt) {
      0 => 1,
      1 => 2,
      2 => 4,
      3 => 8,
      4 => 16,
      _ => 30,
    };
    _reconnectAttempt++;
    _reconnectTimer = Timer(Duration(seconds: seconds), _connect);
  }
}

Map<String, dynamic> _decodeData(Object? value) {
  final decoded = value is String ? jsonDecode(value) : value;
  return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
}

int? _int(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value');
