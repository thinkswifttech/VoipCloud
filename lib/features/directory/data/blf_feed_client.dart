import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import '../../../core/logging/app_logger.dart';
import 'blf_feed_frames.dart';
import 'blf_feed_socket.dart';

export 'blf_feed_frames.dart' show BlfFeedState;

const blfFeedSubprotocol = 'voipcloud.blf.v1';
const _backoffSeconds = [1, 2, 4, 8, 16, 30];
const _capabilitiesTtl = Duration(minutes: 5);
const _disabledRecheck = Duration(minutes: 5);
const _targetsInterval = Duration(milliseconds: 250);
const _snapshotDeadline = Duration(seconds: 8);
const _connectTimeout = Duration(seconds: 10);
const _maxMalformedFrames = 5;

/// Jittered reconnect delay: between half and all of the scheduled step.
Duration blfFeedBackoffDelay(int attempt, double random) {
  final base = _backoffSeconds[attempt.clamp(0, _backoffSeconds.length - 1)];
  return Duration(milliseconds: (base * 1000 * (0.5 + 0.5 * random)).round());
}

enum BlfFeedStatus {
  stopped,
  paused,
  connecting,
  connected,
  live,
  backoff,
  unavailable,
}

enum BlfFeedLossReason {
  /// The feed failed but is reconnecting; SIP is a fallback after a grace.
  retrying,

  /// The feed will not come back soon (disabled for the Space, auth failed).
  unavailable,

  /// Deliberately closed (mobile background); not a failure.
  paused,
}

sealed class BlfFeedEvent {
  const BlfFeedEvent();
}

/// Complete state for the whole requested target set.
class BlfFeedSnapshot extends BlfFeedEvent {
  const BlfFeedSnapshot(this.states);

  final Map<String, BlfFeedState> states;
}

class BlfFeedDelta extends BlfFeedEvent {
  const BlfFeedDelta(this.states);

  final Map<String, BlfFeedState> states;
}

class BlfFeedLost extends BlfFeedEvent {
  const BlfFeedLost(this.reason);

  final BlfFeedLossReason reason;
}

/// What the presence monitor needs from a server-fed BLF source.
abstract interface class BlfFeedSource {
  Stream<BlfFeedEvent> get events;

  BlfFeedStatus get status;

  void setTargets(Set<String> targets);
}

class BlfFeedCredentials {
  const BlfFeedCredentials({
    required this.baseUri,
    required this.token,
    required this.deviceId,
  });

  final Uri baseUri;
  final String token;
  final String deviceId;

  Map<String, String> get headers => {
    'Authorization': 'Bearer $token',
    'X-VoIPCloud-Device-ID': deviceId,
  };

  @override
  bool operator ==(Object other) =>
      other is BlfFeedCredentials &&
      other.baseUri == baseUri &&
      other.token == token &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(baseUri, token, deviceId);
}

class BlfCapabilities {
  const BlfCapabilities({
    required this.enabled,
    this.wsUrl,
    this.maxTargets = 250,
    this.heartbeatSeconds = 15,
  });

  factory BlfCapabilities.parse(Object? json) {
    if (json is! Map || json['enabled'] is! bool) {
      throw const FormatException('Invalid BLF capabilities');
    }
    if (json['enabled'] != true) return const BlfCapabilities(enabled: false);
    final wsUrl = Uri.tryParse('${json['wsUrl'] ?? ''}');
    final maxTargets = json['maxTargets'];
    final heartbeat = json['heartbeatSeconds'];
    if (json['protocol'] != 1 || wsUrl == null) {
      throw const FormatException('Unsupported BLF capabilities');
    }
    return BlfCapabilities(
      enabled: true,
      wsUrl: wsUrl,
      maxTargets: maxTargets is int && maxTargets >= 1 && maxTargets <= 250
          ? maxTargets
          : 250,
      heartbeatSeconds: heartbeat is int && heartbeat >= 5 && heartbeat <= 120
          ? heartbeat
          : 15,
    );
  }

  final bool enabled;
  final Uri? wsUrl;
  final int maxTargets;
  final int heartbeatSeconds;
}

/// The directory token was rejected (HTTP 401/403 or close code 4401).
class BlfFeedAuthException implements Exception {
  const BlfFeedAuthException();
}

typedef BlfCapabilitiesFetcher =
    Future<BlfCapabilities> Function(BlfFeedCredentials credentials);
typedef BlfFeedSocketFactory =
    Future<BlfFeedSocket> Function(
      Uri uri, {
      required Map<String, String> headers,
      required String protocol,
    });

BlfCapabilitiesFetcher dioBlfCapabilitiesFetcher([Dio? dio]) {
  final client =
      dio ??
      Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
  return (credentials) async {
    try {
      final response = await client.getUri<Object?>(
        credentials.baseUri.replace(
          path: '/blf/v1/capabilities',
          query: '',
          fragment: '',
        ),
        options: Options(
          responseType: ResponseType.json,
          headers: credentials.headers,
        ),
      );
      return BlfCapabilities.parse(response.data);
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) throw const BlfFeedAuthException();
      rethrow;
    }
  };
}

/// Client of the server-aggregated BLF WebSocket feed (protocol v1).
///
/// It only reports what the server says; deciding whether SIP presence is
/// still needed is the presence monitor's job.
class BlfFeedClient implements BlfFeedSource {
  BlfFeedClient({
    required this.fetchCapabilities,
    BlfFeedSocketFactory? socketFactory,
    DateTime Function()? now,
    Random? random,
  }) : _socketFactory = socketFactory ?? _defaultSocketFactory,
       _now = now ?? DateTime.now,
       _random = random ?? Random();

  final BlfCapabilitiesFetcher fetchCapabilities;
  final BlfFeedSocketFactory _socketFactory;
  final DateTime Function() _now;
  final Random _random;
  final _events = StreamController<BlfFeedEvent>.broadcast();

  BlfFeedCredentials? _credentials;
  Set<String> _targets = {};
  bool _foreground = true;
  bool _releasing = false;
  bool _closed = false;
  String? _blockedToken;
  BlfFeedStatus _status = BlfFeedStatus.stopped;
  BlfFeedLossReason? _lastLoss;
  int _session = 0;
  bool _starting = false;
  int _attempt = 0;
  Timer? _retryTimer;
  BlfCapabilities? _capabilities;
  BlfFeedCredentials? _capabilitiesFor;
  DateTime? _capabilitiesAt;

  BlfFeedSocket? _socket;
  StreamSubscription<String>? _socketSubscription;
  Timer? _idleTimer;
  Timer? _snapshotTimer;
  Timer? _targetsTimer;
  bool _helloSeen = false;
  String? _epoch;
  int? _seq;
  bool _awaitingSnapshot = false;
  int _maxTargets = 250;
  int _heartbeatSeconds = 15;
  Set<String>? _sentTargets;
  int _sentId = 0;
  int _confirmedId = 0;
  bool _targetsCooling = false;
  bool _live = false;
  bool _degraded = false;
  int _malformed = 0;

  @override
  Stream<BlfFeedEvent> get events => _events.stream;

  @override
  BlfFeedStatus get status => _status;

  static Future<BlfFeedSocket> _defaultSocketFactory(
    Uri uri, {
    required Map<String, String> headers,
    required String protocol,
  }) => connectBlfFeedSocket(uri, headers: headers, protocol: protocol);

  void setCredentials(BlfFeedCredentials? credentials) {
    if (_closed) return;
    if (credentials == null) {
      _releasing = false;
    } else if (_releasing) {
      return;
    }
    if (credentials == _credentials) return;
    _credentials = credentials;
    _capabilities = null;
    _attempt = 0;
    unawaited(_teardown());
    _evaluate();
  }

  @override
  void setTargets(Set<String> targets) {
    if (_closed) return;
    final next = {
      for (final target in targets)
        if (isBlfFeedExtension(target)) target,
    };
    if (_sameSet(next, _targets)) return;
    _targets = next;
    _evaluate();
  }

  void setForeground(bool foreground) {
    if (_closed || foreground == _foreground) return;
    _foreground = foreground;
    _evaluate();
  }

  /// Closes the socket and ignores credentials until the session is cleared,
  /// so it can complete before the directory token is revoked.
  Future<void> release() async {
    if (_closed) return;
    _releasing = true;
    _credentials = null;
    _capabilities = null;
    await _teardown();
    _status = BlfFeedStatus.stopped;
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    await _teardown();
    await _events.close();
  }

  void _evaluate() {
    if (_closed) return;
    final credentials = _credentials;
    if (credentials == null || _targets.isEmpty) {
      unawaited(_teardown());
      _status = BlfFeedStatus.stopped;
    } else if (credentials.token == _blockedToken) {
      unawaited(_teardown());
      _status = BlfFeedStatus.unavailable;
      _emitLost(BlfFeedLossReason.unavailable);
    } else if (!_foreground) {
      unawaited(_teardown());
      _status = BlfFeedStatus.paused;
      _emitLost(BlfFeedLossReason.paused);
    } else if (_socket == null && !_starting && _retryTimer == null) {
      unawaited(_start(credentials));
    } else if (_helloSeen) {
      _flushTargets();
    }
  }

  Future<void> _start(BlfFeedCredentials credentials) async {
    final session = ++_session;
    _starting = true;
    _status = BlfFeedStatus.connecting;
    try {
      final capabilities = await _readCapabilities(credentials);
      if (!_isCurrent(session)) return;
      if (!capabilities.enabled) {
        _enterUnavailable(recheck: true);
        return;
      }
      final uri = capabilities.wsUrl!;
      if (uri.scheme != 'wss' || uri.host != credentials.baseUri.host) {
        throw const FormatException('Unexpected BLF feed URL');
      }
      _maxTargets = capabilities.maxTargets;
      _heartbeatSeconds = capabilities.heartbeatSeconds;
      final socket = await _socketFactory(
        uri,
        headers: credentials.headers,
        protocol: blfFeedSubprotocol,
      ).timeout(_connectTimeout);
      if (!_isCurrent(session)) {
        unawaited(_closeQuietly(socket));
        return;
      }
      _starting = false;
      _socket = socket;
      _socketSubscription = socket.messages.listen(
        (raw) => _onMessage(session, raw),
        onError: (_) => _onClosed(session, socket),
        onDone: () => _onClosed(session, socket),
        cancelOnError: true,
      );
      _armIdleTimer(session);
    } on BlfFeedAuthException {
      if (!_isCurrent(session)) return;
      _blockedToken = credentials.token;
      _enterUnavailable(recheck: false);
    } catch (error) {
      if (!_isCurrent(session)) return;
      final status = _handshakeStatus(error);
      if (status == 401) {
        _blockedToken = credentials.token;
        _enterUnavailable(recheck: false);
        return;
      }
      if (status == 403) {
        _enterUnavailable(recheck: true);
        return;
      }
      AppLogger.warning(
        'BLF feed connection failed',
        data: {'errorType': error.runtimeType.toString()},
      );
      _fail();
    }
  }

  Future<BlfCapabilities> _readCapabilities(
    BlfFeedCredentials credentials,
  ) async {
    final cached = _capabilities;
    final at = _capabilitiesAt;
    if (cached != null &&
        _capabilitiesFor == credentials &&
        at != null &&
        _now().difference(at) < _capabilitiesTtl) {
      return cached;
    }
    final fetched = await fetchCapabilities(credentials);
    _capabilities = fetched;
    _capabilitiesFor = credentials;
    _capabilitiesAt = _now();
    return fetched;
  }

  /// HTTP status of a rejected WebSocket upgrade (dart:io reports it in the message).
  static int? _handshakeStatus(Object error) {
    final match = RegExp(r'HTTP status code: (\d{3})').firstMatch('$error');
    return match == null ? null : int.parse(match.group(1)!);
  }

  bool _isCurrent(int session) => !_closed && session == _session;

  void _onMessage(int session, String raw) {
    if (!_isCurrent(session)) return;
    _armIdleTimer(session);
    final BlfFeedFrame? frame;
    try {
      frame = BlfFeedFrame.parse(raw);
    } on FormatException {
      _onMalformed(session);
      return;
    }
    if (frame == null) return;
    _malformed = 0;
    try {
      switch (frame) {
        case BlfHelloFrame():
          _onHello(frame);
        case BlfStatesFrame():
          if (_helloSeen) _onStates(frame);
        case BlfHeartbeatFrame():
          if (_helloSeen) _onHeartbeat(frame);
        case BlfErrorFrame():
          AppLogger.warning(
            'BLF feed error',
            data: {'code': frame.code, 'fatal': frame.fatal},
          );
          if (frame.fatal) _failIfCurrent(session);
      }
    } catch (error) {
      AppLogger.warning(
        'BLF feed frame handling failed',
        data: {'errorType': error.runtimeType.toString()},
      );
      _failIfCurrent(session);
    }
  }

  void _onMalformed(int session) {
    if (++_malformed >= _maxMalformedFrames || !_helloSeen) {
      _failIfCurrent(session);
      return;
    }
    _beginResync();
  }

  void _onHello(BlfHelloFrame frame) {
    if (_helloSeen) return;
    _helloSeen = true;
    _epoch = frame.epoch;
    _seq = frame.seq;
    _heartbeatSeconds = frame.heartbeatSeconds;
    _maxTargets = min(_maxTargets, frame.maxTargets);
    _status = BlfFeedStatus.connected;
    _flushTargets();
  }

  void _onStates(BlfStatesFrame frame) {
    if (frame.epoch != _epoch) {
      _epoch = frame.epoch;
      _seq = null;
      _beginResync();
      return;
    }
    if (_awaitingSnapshot) {
      if (!frame.snapshot) return;
    } else if (frame.seq != _seq! + 1) {
      _beginResync();
      return;
    }
    _seq = frame.seq;
    _awaitingSnapshot = false;
    if (!frame.snapshot) {
      if (_live) _emit(BlfFeedDelta(frame.states));
      _noteWatcher(frame.degraded);
      return;
    }
    final reqId = frame.reqId;
    if (reqId != null && reqId > _confirmedId) _confirmedId = reqId;
    final sent = _sentTargets;
    if (_confirmedId != _sentId ||
        sent == null ||
        !_sameSet(sent, _desiredTargets())) {
      // Complete, but for an older target set; the reply to the newest
      // request follows and is the authoritative one.
      return;
    }
    _snapshotTimer?.cancel();
    _attempt = 0;
    _live = true;
    _lastLoss = null;
    _status = BlfFeedStatus.live;
    _emit(BlfFeedSnapshot(frame.states));
    _degraded = false;
    _noteWatcher(frame.degraded);
  }

  /// A degraded server watcher keeps the socket open, but its values are no
  /// longer trustworthy: report one loss per episode so SIP can take over,
  /// and resync once the watcher recovers.
  void _noteWatcher(bool degraded) {
    if (degraded == _degraded) return;
    _degraded = degraded;
    if (degraded) {
      _emitLost(BlfFeedLossReason.retrying);
    } else {
      _beginResync();
    }
  }

  void _onHeartbeat(BlfHeartbeatFrame frame) {
    if (frame.epoch != _epoch) {
      _epoch = frame.epoch;
      _seq = null;
      _beginResync();
    } else if (!_awaitingSnapshot && frame.seq > _seq!) {
      _beginResync();
    } else if (!_awaitingSnapshot) {
      _noteWatcher(frame.degraded);
    }
  }

  void _beginResync() {
    final alreadyWaiting = _awaitingSnapshot;
    _awaitingSnapshot = true;
    _armSnapshotDeadline();
    if (!alreadyWaiting) _send({'t': 'resync'});
  }

  Set<String> _desiredTargets() => _targets.length <= _maxTargets
      ? _targets
      : (_targets.toList()..sort()).take(_maxTargets).toSet();

  void _flushTargets() {
    if (!_helloSeen || _targetsCooling) return;
    final desired = _desiredTargets();
    final sent = _sentTargets;
    if (sent != null && _sameSet(sent, desired)) return;
    _sentTargets = desired;
    _send({'t': 'targets', 'id': ++_sentId, 'set': desired.toList()..sort()});
    _armSnapshotDeadline();
    // The server accepts at most four target frames per second.
    _targetsCooling = true;
    _targetsTimer = Timer(_targetsInterval, () {
      _targetsCooling = false;
      if (_socket != null) _flushTargets();
    });
  }

  void _send(Map<String, Object?> frame) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.add(jsonEncode(frame));
    } catch (_) {
      _fail();
    }
  }

  void _armIdleTimer(int session) {
    _idleTimer?.cancel();
    _idleTimer = Timer(
      Duration(seconds: _heartbeatSeconds * 3),
      () => _failIfCurrent(session),
    );
  }

  void _armSnapshotDeadline() {
    final session = _session;
    _snapshotTimer?.cancel();
    _snapshotTimer = Timer(_snapshotDeadline, () => _failIfCurrent(session));
  }

  void _onClosed(int session, BlfFeedSocket socket) {
    if (!_isCurrent(session)) return;
    final code = socket.closeCode;
    switch (code) {
      case 4401:
        _blockedToken = _credentials?.token;
        _enterUnavailable(recheck: false);
      case 4403:
        _enterUnavailable(recheck: true);
      default:
        // 4408, 4429, 4500, 1000/1001 and anything unexpected.
        AppLogger.info('BLF feed closed', data: {'code': code});
        _fail();
    }
  }

  void _failIfCurrent(int session) {
    if (_isCurrent(session)) _fail();
  }

  void _fail() {
    if (_closed) return;
    unawaited(_teardown());
    _status = BlfFeedStatus.backoff;
    _emitLost(BlfFeedLossReason.retrying);
    final delay = blfFeedBackoffDelay(_attempt++, _random.nextDouble());
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      _evaluate();
    });
  }

  void _enterUnavailable({required bool recheck}) {
    if (_closed) return;
    unawaited(_teardown());
    _status = BlfFeedStatus.unavailable;
    _emitLost(BlfFeedLossReason.unavailable);
    if (!recheck) return;
    _retryTimer = Timer(_disabledRecheck, () {
      _retryTimer = null;
      _capabilities = null;
      _evaluate();
    });
  }

  Future<void> _teardown() {
    ++_session;
    _starting = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _idleTimer?.cancel();
    _snapshotTimer?.cancel();
    _targetsTimer?.cancel();
    _targetsCooling = false;
    _helloSeen = false;
    _epoch = null;
    _seq = null;
    _awaitingSnapshot = false;
    _sentTargets = null;
    _sentId = 0;
    _confirmedId = 0;
    _live = false;
    _degraded = false;
    _malformed = 0;
    final socket = _socket;
    final subscription = _socketSubscription;
    _socket = null;
    _socketSubscription = null;
    unawaited(subscription?.cancel());
    return socket == null ? Future.value() : _closeQuietly(socket);
  }

  Future<void> _closeQuietly(BlfFeedSocket socket) async {
    try {
      await socket.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  void _emitLost(BlfFeedLossReason reason) {
    if (_lastLoss == reason) return;
    _lastLoss = reason;
    _emit(BlfFeedLost(reason));
  }

  void _emit(BlfFeedEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  static bool _sameSet(Set<String> left, Set<String> right) =>
      left.length == right.length && left.containsAll(right);
}
