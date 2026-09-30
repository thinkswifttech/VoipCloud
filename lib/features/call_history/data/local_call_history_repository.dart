import 'dart:convert';

import '../../../core/constants/storage_keys.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../../calls/domain/call_direction.dart';
import '../../calls/domain/call_status.dart';
import '../domain/call_history_item.dart';
import '../domain/call_history_reconciliation.dart';
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
            .where((item) => !_isLegacyProvisionalServerMiss(item))
            .toList()
          ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return items;
  }

  /// Removes records cached by endpoint revisions that represented an
  /// unfinished statistics row as a zero-duration missed call. Server call IDs
  /// are SHA-256 hex values; native call IDs use platform-specific formats, so
  /// this migration does not discard genuine native history.
  bool _isLegacyProvisionalServerMiss(CallHistoryItem item) {
    if (item.effectiveDisposition != CallHistoryDisposition.missed ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(item.id)) {
      return false;
    }
    final endedAt = item.endedAt;
    return endedAt == null || !endedAt.isAfter(item.startedAt);
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
    final deduped = [
      item,
      ...current.where(
        (entry) => entry.id != id && !isSameLogicalCall(entry, item),
      ),
    ]..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final limited = deduped.take(200).map((entry) => entry.toJson()).toList();
    try {
      await _storage.write(StorageKeys.appCallHistory, jsonEncode(limited));
    } catch (error) {
      AppLogger.warning('Call history write skipped', data: error);
      rethrow;
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
