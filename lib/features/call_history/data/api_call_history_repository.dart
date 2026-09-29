import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/constants/storage_keys.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../../calls/domain/call_direction.dart';
import '../../calls/domain/call_status.dart';
import '../../directory/domain/directory_access.dart';
import '../domain/call_history_item.dart';
import '../domain/call_history_repository.dart';

/// Read-only view of the history observed by the SIP edge.
///
/// It deliberately reuses the per-device directory bearer credential. That
/// credential already identifies both the account and the device, allowing
/// the server to distinguish answered-on-this-device from answered-elsewhere.
class ApiCallHistoryRepository implements CallHistoryRepository {
  ApiCallHistoryRepository({
    required SecureStorageService storage,
    required Uri? endpointPath,
    Dio? dio,
  }) : _storage = storage,
       _endpointPath = endpointPath,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 8),
               receiveTimeout: const Duration(seconds: 15),
             ),
           );

  final SecureStorageService _storage;
  final Uri? _endpointPath;
  final Dio _dio;

  @override
  Future<List<CallHistoryItem>> getCallHistory() async {
    final access = await _readAccess();
    final endpointPath = _endpointPath;
    if (access == null || endpointPath == null) return const [];

    final endpoint = access.endpoint.resolveUri(endpointPath);
    final items = <CallHistoryItem>[];
    for (var page = 1; page <= 2; page += 1) {
      final response = await _dio.getUri<Object?>(
        endpoint.replace(
          queryParameters: {'page': page.toString(), 'size': '100'},
        ),
        options: Options(
          responseType: ResponseType.json,
          headers: {'Authorization': 'Bearer ${access.token}'},
        ),
      );
      final body = response.data;
      if (body is! Map) {
        throw const ApiException(
          statusCode: null,
          message: 'Invalid server call-history response',
        );
      }
      final payload = Map<String, dynamic>.from(body);
      final content = payload['content'] ?? payload['data'];
      if (content is! List) break;
      items.addAll(
        content.whereType<Map>().map(
          (item) => _itemFromJson(Map<String, dynamic>.from(item)),
        ),
      );
      final lastPage = _integer(payload['lastPage'] ?? payload['last_page']);
      if (content.length < 100 || (lastPage != null && page >= lastPage)) {
        break;
      }
    }
    return items;
  }

  @override
  Future<void> clearCallHistory() async {
    // Reset clears only this device's local view. Server history is retained.
  }

  @override
  Future<CallHistoryItem> syncCallLog({
    required String remoteNumber,
    String? remoteDisplayName,
    required CallDirection direction,
    required CallStatus status,
    required CallHistoryDisposition disposition,
    required DateTime startedAt,
    DateTime? endedAt,
    String? sipCallId,
  }) {
    throw UnsupportedError('Server call history is read-only');
  }

  Future<DirectoryAccess?> _readAccess() async {
    final raw = await _storage.read(StorageKeys.appDirectoryAccess);
    if (raw == null || raw.trim().isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return DirectoryAccess.fromJson(Map<String, dynamic>.from(decoded));
  }

  CallHistoryItem _itemFromJson(Map<String, dynamic> json) {
    final direction = _directionFromApi(_requiredString(json, 'direction'));
    final apiStatus = _requiredString(json, 'status');
    return CallHistoryItem(
      id: _requiredString(json, 'id'),
      remoteNumber: _requiredString(json, 'remoteParty'),
      remoteDisplayName: _optionalString(json['remoteDisplayName']),
      direction: direction,
      status: _statusFromApi(apiStatus),
      startedAt: _requiredDate(json, 'startedAt'),
      endedAt: _optionalDate(json['endedAt']),
      disposition: _dispositionFromApi(direction: direction, status: apiStatus),
    );
  }

  CallHistoryDisposition _dispositionFromApi({
    required CallDirection direction,
    required String status,
  }) {
    if (direction == CallDirection.outgoing) {
      return CallHistoryDisposition.outgoing;
    }
    return switch (status) {
      'COMPLETED' => CallHistoryDisposition.answered,
      'ANSWERED_ELSEWHERE' => CallHistoryDisposition.answeredElsewhere,
      'REJECTED' => CallHistoryDisposition.declined,
      _ => CallHistoryDisposition.missed,
    };
  }

  CallDirection _directionFromApi(String value) {
    return value == 'OUTBOUND'
        ? CallDirection.outgoing
        : CallDirection.incoming;
  }

  CallStatus _statusFromApi(String value) {
    return switch (value) {
      'COMPLETED' || 'ANSWERED_ELSEWHERE' => CallStatus.ended,
      'MISSED' => CallStatus.missed,
      'REJECTED' || 'FAILED' => CallStatus.failed,
      _ => CallStatus.failed,
    };
  }

  String _requiredString(Map<String, dynamic> json, String key) {
    final value = _optionalString(json[key]);
    if (value != null) return value;
    throw ApiException(statusCode: null, message: 'Missing "$key"');
  }

  String? _optionalString(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  DateTime _requiredDate(Map<String, dynamic> json, String key) {
    final date = _optionalDate(json[key]);
    if (date == null) {
      throw ApiException(statusCode: null, message: 'Missing "$key"');
    }
    return date;
  }

  DateTime? _optionalDate(Object? value) {
    final text = _optionalString(value);
    return text == null ? null : DateTime.tryParse(text)?.toLocal();
  }

  int? _integer(Object? value) =>
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
}
