import '../../accounts/domain/account_line.dart';
import '../../calls/domain/call_direction.dart';
import '../../calls/domain/call_status.dart';

enum CallHistoryDisposition {
  outgoing,
  answered,
  answeredElsewhere,
  missed,
  declined,
}

const _maxRingDuration = Duration(minutes: 10);

class CallHistoryItem {
  const CallHistoryItem({
    required this.id,
    required this.remoteNumber,
    required this.direction,
    required this.status,
    required this.startedAt,
    this.disposition,
    this.remoteDisplayName,
    this.endedAt,
    this.serverFinalized = false,
    this.line,
  });

  final String id;
  final String remoteNumber;
  final String? remoteDisplayName;
  final CallDirection direction;
  final CallStatus status;
  final DateTime startedAt;
  final DateTime? endedAt;
  final bool serverFinalized;
  final CallHistoryDisposition? disposition;

  /// Which of the two accounts the call was on; null for calls from before a
  /// second account existed (those were all on the primary account).
  final AccountLine? line;

  CallHistoryDisposition get effectiveDisposition {
    final saved = disposition;
    if (saved != null) return saved;
    if (direction == CallDirection.outgoing) {
      return CallHistoryDisposition.outgoing;
    }
    if (direction == CallDirection.missed || status == CallStatus.missed) {
      return CallHistoryDisposition.missed;
    }
    if (status == CallStatus.ended) {
      return CallHistoryDisposition.answered;
    }
    return CallHistoryDisposition.missed;
  }

  Duration? get duration {
    final ended = endedAt;
    if (ended == null) {
      return null;
    }
    final length = ended.difference(startedAt);
    // Older builds could stamp a replay time as the end of an unanswered call,
    // giving hours of "ringing". No ring lasts this long, so show it as unknown.
    if (length > _maxRingDuration &&
        effectiveDisposition != CallHistoryDisposition.answered &&
        effectiveDisposition != CallHistoryDisposition.outgoing) {
      return null;
    }
    return length;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'remoteNumber': remoteNumber,
      'remoteDisplayName': remoteDisplayName,
      'direction': direction.name,
      'status': status.name,
      'startedAt': startedAt.toIso8601String(),
      'endedAt': endedAt?.toIso8601String(),
      'disposition': disposition?.name,
      'serverFinalized': serverFinalized,
      'line': line?.name,
    };
  }

  factory CallHistoryItem.fromJson(Map<String, dynamic> json) {
    return CallHistoryItem(
      id: _string(
        json['id'],
        fallback: 'call-${DateTime.now().microsecondsSinceEpoch}',
      ),
      remoteNumber: _string(json['remoteNumber']),
      remoteDisplayName: _nullableString(json['remoteDisplayName']),
      direction: _callDirection(json['direction']),
      status: _callStatus(json['status']),
      startedAt:
          DateTime.tryParse(_string(json['startedAt'])) ?? DateTime.now(),
      endedAt: DateTime.tryParse(_string(json['endedAt'])),
      disposition: _callDisposition(json['disposition']),
      serverFinalized: json['serverFinalized'] == true,
      line: AccountLine.tryParse(json['line']),
    );
  }
}

CallHistoryDisposition? _callDisposition(Object? value) {
  final name = _string(value);
  if (name.isEmpty) return null;
  for (final disposition in CallHistoryDisposition.values) {
    if (disposition.name == name) return disposition;
  }
  return null;
}

String _string(Object? value, {String fallback = ''}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

String? _nullableString(Object? value) {
  final text = _string(value);
  return text.isEmpty ? null : text;
}

CallDirection _callDirection(Object? value) {
  return CallDirection.values.firstWhere(
    (item) => item.name == _string(value),
    orElse: () => CallDirection.outgoing,
  );
}

CallStatus _callStatus(Object? value) {
  return CallStatus.values.firstWhere(
    (item) => item.name == _string(value),
    orElse: () => CallStatus.ended,
  );
}
