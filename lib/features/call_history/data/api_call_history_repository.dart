import '../../../core/errors/app_exception.dart';
import '../../../core/network/app_client.dart';
import '../../calls/domain/call_direction.dart';
import '../../calls/domain/call_status.dart';
import '../domain/call_history_item.dart';
import '../domain/call_history_repository.dart';

class ApiCallHistoryRepository implements CallHistoryRepository {
  const ApiCallHistoryRepository(this._client);

  final AppClient _client;

  @override
  Future<List<CallHistoryItem>> getCallHistory() async {
    final response = await _client.get<Map<String, dynamic>>(
      '/api/v1/calls/history',
      queryParameters: const {'page': 0, 'size': 50, 'sort': 'startedAt,desc'},
    );
    final content = response.data?['content'];
    if (content is! List) {
      return const [];
    }
    return content
        .whereType<Map>()
        .map((item) => _itemFromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  @override
  Future<void> clearCallHistory() async {
    // Local app reset does not delete server-side history.
  }

  @override
  Future<CallHistoryItem> syncCallLog({
    required String remoteNumber,
    required CallDirection direction,
    required CallStatus status,
    required DateTime startedAt,
    DateTime? endedAt,
    String? sipCallId,
  }) async {
    final response = await _client.post<Map<String, dynamic>>(
      '/api/v1/calls/sync',
      data: {
        'remoteParty': remoteNumber,
        'direction': _apiDirection(direction),
        'status': _apiStatus(status),
        'startedAt': startedAt.toUtc().toIso8601String(),
        if (endedAt != null) 'endedAt': endedAt.toUtc().toIso8601String(),
        'durationSeconds': endedAt == null
            ? 0
            : endedAt.difference(startedAt).inSeconds.clamp(0, 1 << 31),
        if (sipCallId != null && sipCallId.isNotEmpty) 'sipCallId': sipCallId,
      },
    );

    final data = response.data;
    if (data == null) {
      throw const ApiException(
        statusCode: null,
        message: 'Missing synced call response',
      );
    }
    return _itemFromJson(data);
  }

  CallHistoryItem _itemFromJson(Map<String, dynamic> json) {
    return CallHistoryItem(
      id: _requiredString(json, 'id'),
      remoteNumber: _requiredString(json, 'remoteParty'),
      direction: _directionFromApi(_requiredString(json, 'direction')),
      status: _statusFromApi(_requiredString(json, 'status')),
      startedAt: _requiredDate(json, 'startedAt'),
      endedAt: _optionalDate(json['endedAt']),
    );
  }

  CallDirection _directionFromApi(String value) {
    return switch (value) {
      'OUTBOUND' => CallDirection.outgoing,
      'MISSED' => CallDirection.missed,
      _ => CallDirection.incoming,
    };
  }

  CallStatus _statusFromApi(String value) {
    return switch (value) {
      'COMPLETED' => CallStatus.ended,
      'MISSED' => CallStatus.missed,
      'REJECTED' || 'FAILED' => CallStatus.failed,
      _ => CallStatus.failed,
    };
  }

  String _apiDirection(CallDirection direction) {
    return switch (direction) {
      CallDirection.incoming => 'INBOUND',
      CallDirection.outgoing => 'OUTBOUND',
      CallDirection.missed => 'MISSED',
    };
  }

  String _apiStatus(CallStatus status) {
    return switch (status) {
      CallStatus.ended => 'COMPLETED',
      CallStatus.missed => 'MISSED',
      CallStatus.failed => 'FAILED',
      _ => 'COMPLETED',
    };
  }

  String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    throw ApiException(statusCode: null, message: 'Missing "$key"');
  }

  DateTime _requiredDate(Map<String, dynamic> json, String key) {
    final date = _optionalDate(json[key]);
    if (date == null) {
      throw ApiException(statusCode: null, message: 'Missing "$key"');
    }
    return date;
  }

  DateTime? _optionalDate(Object? value) {
    if (value is! String || value.isEmpty) {
      return null;
    }
    return DateTime.tryParse(value)?.toLocal();
  }
}
