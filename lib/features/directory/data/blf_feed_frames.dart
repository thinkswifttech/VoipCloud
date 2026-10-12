import 'dart:convert';

import '../domain/directory_entry.dart';

const _maxFrameLength = 256 * 1024;
const _maxStates = 1000;
final _extensionPattern = RegExp(r'^[0-9]{2,8}$');

bool isBlfFeedExtension(String value) => _extensionPattern.hasMatch(value);

class BlfFeedState {
  const BlfFeedState({
    required this.presence,
    required this.observedAt,
    required this.fresh,
  });

  final DirectoryPresence presence;
  final DateTime? observedAt;
  final bool fresh;
}

/// A decoded server frame. [parse] returns null for anything that is not a
/// recognised frame (not JSON, not an object, unknown `t`) and throws a
/// [FormatException] for a recognised frame whose payload is invalid.
sealed class BlfFeedFrame {
  const BlfFeedFrame();

  static BlfFeedFrame? parse(String raw) {
    if (raw.length > _maxFrameLength) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    return switch (decoded['t']) {
      'hello' => BlfHelloFrame._parse(decoded),
      'snapshot' => BlfStatesFrame._parse(decoded, snapshot: true),
      'delta' => BlfStatesFrame._parse(decoded, snapshot: false),
      'hb' => BlfHeartbeatFrame._parse(decoded),
      'error' => BlfErrorFrame._parse(decoded),
      _ => null,
    };
  }
}

class BlfHelloFrame extends BlfFeedFrame {
  const BlfHelloFrame({
    required this.epoch,
    required this.seq,
    required this.maxTargets,
    required this.heartbeatSeconds,
  });

  factory BlfHelloFrame._parse(Map<dynamic, dynamic> json) {
    if (json['proto'] != 1) throw const FormatException('Unsupported protocol');
    final maxTargets = json['maxTargets'];
    final heartbeat = json['heartbeatSeconds'];
    return BlfHelloFrame(
      epoch: _epoch(json),
      seq: _seq(json),
      maxTargets: maxTargets is int && maxTargets >= 1 && maxTargets <= 250
          ? maxTargets
          : 250,
      heartbeatSeconds: heartbeat is int && heartbeat >= 5 && heartbeat <= 120
          ? heartbeat
          : 15,
    );
  }

  final String epoch;
  final int seq;
  final int maxTargets;
  final int heartbeatSeconds;
}

class BlfStatesFrame extends BlfFeedFrame {
  const BlfStatesFrame({
    required this.snapshot,
    required this.epoch,
    required this.seq,
    required this.reqId,
    required this.states,
    this.degraded = false,
  });

  factory BlfStatesFrame._parse(
    Map<dynamic, dynamic> json, {
    required bool snapshot,
  }) {
    final reqId = json['reqId'];
    if (reqId != null && reqId is! int) {
      throw const FormatException('Invalid reqId');
    }
    final raw = json[snapshot ? 'states' : 'changes'];
    if (raw is! Map || raw.length > _maxStates) {
      throw const FormatException('Invalid states');
    }
    final states = <String, BlfFeedState>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || !isBlfFeedExtension(key) || value is! Map) {
        throw const FormatException('Invalid state entry');
      }
      final presence = value['p'];
      final observed = value['o'];
      final fresh = value['f'];
      if (presence is! String ||
          fresh is! bool ||
          (observed != null &&
              (observed is! int ||
                  observed < 0 ||
                  observed > 8640000000000000))) {
        throw const FormatException('Invalid state value');
      }
      states[key] = BlfFeedState(
        presence: directoryPresenceFromValue(presence),
        observedAt: observed == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(observed as int, isUtc: true),
        fresh: fresh,
      );
    }
    return BlfStatesFrame(
      snapshot: snapshot,
      epoch: _epoch(json),
      seq: _seq(json),
      reqId: reqId as int?,
      states: states,
      degraded: _degraded(json),
    );
  }

  final bool snapshot;
  final String epoch;
  final int seq;
  final int? reqId;
  final Map<String, BlfFeedState> states;
  final bool degraded;
}

class BlfHeartbeatFrame extends BlfFeedFrame {
  const BlfHeartbeatFrame({
    required this.epoch,
    required this.seq,
    this.degraded = false,
  });

  factory BlfHeartbeatFrame._parse(Map<dynamic, dynamic> json) =>
      BlfHeartbeatFrame(
        epoch: _epoch(json),
        seq: _seq(json),
        degraded: _degraded(json),
      );

  final String epoch;
  final int seq;
  final bool degraded;
}

class BlfErrorFrame extends BlfFeedFrame {
  const BlfErrorFrame({required this.code, required this.fatal});

  factory BlfErrorFrame._parse(Map<dynamic, dynamic> json) {
    final code = json['code'];
    final fatal = json['fatal'];
    if (code is! String) throw const FormatException('Invalid error code');
    return BlfErrorFrame(code: code, fatal: fatal == true);
  }

  final String code;
  final bool fatal;
}

/// A missing or unknown `watcher` is treated as healthy.
bool _degraded(Map<dynamic, dynamic> json) => json['watcher'] == 'degraded';

String _epoch(Map<dynamic, dynamic> json) {
  final value = json['epoch'];
  if (value is! String || value.isEmpty || value.length > 64) {
    throw const FormatException('Invalid epoch');
  }
  return value;
}

int _seq(Map<dynamic, dynamic> json) {
  final value = json['seq'];
  if (value is! int || value < 0) throw const FormatException('Invalid seq');
  return value;
}
