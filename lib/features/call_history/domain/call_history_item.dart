import '../../calls/domain/call_direction.dart';
import '../../calls/domain/call_status.dart';

class CallHistoryItem {
  const CallHistoryItem({
    required this.id,
    required this.remoteNumber,
    required this.direction,
    required this.status,
    required this.startedAt,
    this.remoteDisplayName,
    this.endedAt,
  });

  final String id;
  final String remoteNumber;
  final String? remoteDisplayName;
  final CallDirection direction;
  final CallStatus status;
  final DateTime startedAt;
  final DateTime? endedAt;

  Duration? get duration {
    final ended = endedAt;
    if (ended == null) {
      return null;
    }
    return ended.difference(startedAt);
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
    );
  }
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
