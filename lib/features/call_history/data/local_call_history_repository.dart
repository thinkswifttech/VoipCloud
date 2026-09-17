import 'dart:convert';

import '../../../core/constants/storage_keys.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../../calls/domain/call_direction.dart';
import '../../calls/domain/call_status.dart';
import '../domain/call_history_item.dart';
import '../domain/call_history_repository.dart';

class LocalCallHistoryRepository implements CallHistoryRepository {
  LocalCallHistoryRepository(this._storage);

  final SecureStorageService _storage;
  Future<void> _writeSerial = Future<void>.value();

  @override
  Future<List<CallHistoryItem>> getCallHistory() async {
    final raw = await _storage.read(StorageKeys.appCallHistory);
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const [];
    }
    final items =
        decoded
            .whereType<Map>()
            .map(
              (item) =>
                  CallHistoryItem.fromJson(Map<String, dynamic>.from(item)),
            )
            .toList()
          ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return items;
  }

  @override
  Future<void> clearCallHistory() async {
    try {
      await _storage.delete(StorageKeys.appCallHistory);
    } catch (error) {
      AppLogger.warning('Call history clear skipped', data: error);
    }
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
    final operation = _writeSerial.then(
      (_) => _syncCallLog(
        remoteNumber: remoteNumber,
        remoteDisplayName: remoteDisplayName,
        direction: direction,
        status: status,
        disposition: disposition,
        startedAt: startedAt,
        endedAt: endedAt,
        sipCallId: sipCallId,
      ),
    );
    _writeSerial = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<CallHistoryItem> _syncCallLog({
    required String remoteNumber,
    String? remoteDisplayName,
    required CallDirection direction,
    required CallStatus status,
    required CallHistoryDisposition disposition,
    required DateTime startedAt,
    DateTime? endedAt,
    String? sipCallId,
  }) async {
    final id = sipCallId?.trim().isNotEmpty == true
        ? sipCallId!.trim()
        : 'call-${startedAt.microsecondsSinceEpoch}';
    final item = CallHistoryItem(
      id: id,
      remoteNumber: remoteNumber,
      remoteDisplayName: remoteDisplayName,
      direction: direction,
      status: status,
      disposition: disposition,
      startedAt: startedAt,
      endedAt: endedAt,
    );
    final current = await _safeCallHistoryForSync();
    final deduped = [item, ...current.where((entry) => entry.id != id)]
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final limited = deduped.take(200).map((entry) => entry.toJson()).toList();
    try {
      await _storage.write(StorageKeys.appCallHistory, jsonEncode(limited));
    } catch (error) {
      AppLogger.warning('Call history write skipped', data: error);
    }
    return item;
  }

  Future<List<CallHistoryItem>> _safeCallHistoryForSync() async {
    try {
      return await getCallHistory();
    } catch (error) {
      AppLogger.warning('Call history read skipped during sync', data: error);
      return const [];
    }
  }
}
