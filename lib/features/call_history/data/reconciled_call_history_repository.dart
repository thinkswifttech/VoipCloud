import '../../../core/logging/app_logger.dart';
import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../../calls/domain/call_direction.dart';
import '../../calls/domain/call_status.dart';
import '../domain/call_history_item.dart';
import '../domain/call_history_reconciliation.dart';
import '../domain/call_history_repository.dart';

/// Keeps fast/offline device history while filling gaps from SIP-edge events.
class ReconciledCallHistoryRepository implements CallHistoryRepository {
  ReconciledCallHistoryRepository({
    required this.local,
    required this.server,
    this.visibilityStorage,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final CallHistoryRepository local;
  final CallHistoryRepository server;
  final SecureStorageService? visibilityStorage;
  final DateTime Function() _now;
  Future<void> _writes = Future.value();
  int _generation = 0;
  DateTime? _visibleSince;

  Future<DateTime?> _readBoundary() async {
    final raw = await visibilityStorage?.read(
      StorageKeys.appCallHistoryVisibleSince,
    );
    if (raw != null) {
      final persisted = DateTime.parse(raw).toUtc();
      if (_visibleSince == null || persisted.isAfter(_visibleSince!)) {
        _visibleSince = persisted;
      }
    }
    return _visibleSince;
  }

  bool _visible(CallHistoryItem item, DateTime? boundary) =>
      boundary == null || !item.startedAt.toUtc().isBefore(boundary);

  Future<T> _write<T>(Future<T> Function() action) {
    final operation = _writes.then((_) => action());
    _writes = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  @override
  Future<List<CallHistoryItem>> getCallHistory() async {
    final generation = _generation;
    await _writes;
    final boundary = await _readBoundary();
    final storedLocalItems = (await local.getCallHistory())
        .where((item) => _visible(item, boundary))
        .toList();
    if (generation != _generation) return const [];
    List<CallHistoryItem> serverItems;
    try {
      serverItems = (await server.getCallHistory())
          .where((item) => _visible(item, boundary))
          .toList();
    } catch (error) {
      AppLogger.warning(
        'Server call-history reconciliation skipped',
        data: error,
      );
      return generation == _generation
          ? coalesceLogicalCalls(storedLocalItems)
          : const [];
    }
    if (generation != _generation) return const [];

    final merged = _merge(
      coalesceLogicalCalls(storedLocalItems),
      coalesceLogicalCalls(serverItems),
    );
    for (final item in merged) {
      final saved = storedLocalItems
          .where((candidate) => isSameLogicalCall(candidate, item))
          .toList(growable: false);
      if (saved.length == 1 && _sameStoredValue(saved.single, item)) continue;
      try {
        await _write(() async {
          if (generation != _generation) return;
          await local.syncCallLog(
            remoteNumber: item.remoteNumber,
            remoteDisplayName: item.remoteDisplayName,
            direction: item.direction,
            status: item.status,
            disposition: item.effectiveDisposition,
            startedAt: item.startedAt,
            endedAt: item.endedAt,
            sipCallId: item.id,
            serverFinalized: item.serverFinalized,
          );
        });
      } catch (error) {
        AppLogger.warning(
          'Server call-history item was not cached',
          data: error,
        );
        break;
      }
    }
    return generation == _generation ? merged : const [];
  }

  @override
  Future<void> clearCallHistory() {
    ++_generation;
    final resetAt = _now().toUtc();
    if (_visibleSince == null || resetAt.isAfter(_visibleSince!)) {
      _visibleSince = resetAt;
    }
    return _write(() async {
      try {
        // Preserve a previous reset boundary even if the device clock moved back.
        final boundary = (await _readBoundary())!.toIso8601String();
        // Never erase account-wide server history or another device's badge.
        // A failed durable boundary must be reported, not called a successful reset.
        await visibilityStorage?.write(
          StorageKeys.appCallHistoryVisibleSince,
          boundary,
        );
        await visibilityStorage?.write(
          StorageKeys.appCallHistoryLastViewedAt,
          boundary,
        );
      } finally {
        await local.clearCallHistory();
      }
    });
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
    bool serverFinalized = false,
  }) {
    final generation = _generation;
    return _write(() async {
      final boundary = await _readBoundary();
      if (generation != _generation ||
          (boundary != null && startedAt.toUtc().isBefore(boundary))) {
        // Acknowledge obsolete native replay without putting it back in history.
        return CallHistoryItem(
          id: sipCallId ?? 'discarded-${startedAt.microsecondsSinceEpoch}',
          remoteNumber: remoteNumber,
          remoteDisplayName: remoteDisplayName,
          direction: direction,
          status: status,
          disposition: disposition,
          startedAt: startedAt,
          endedAt: endedAt,
        );
      }
      return local.syncCallLog(
        remoteNumber: remoteNumber,
        remoteDisplayName: remoteDisplayName,
        direction: direction,
        status: status,
        disposition: disposition,
        startedAt: startedAt,
        endedAt: endedAt,
        sipCallId: sipCallId,
        serverFinalized: serverFinalized,
      );
    });
  }

  List<CallHistoryItem> _merge(
    List<CallHistoryItem> localItems,
    List<CallHistoryItem> serverItems,
  ) {
    final remainingLocal = [...localItems];
    final result = <CallHistoryItem>[];
    for (final serverItem in serverItems) {
      final matches = remainingLocal
          .where((localItem) => isSameLogicalCall(localItem, serverItem))
          .toList(growable: false);
      if (matches.isEmpty) {
        result.add(serverItem);
        continue;
      }
      final localItem = matches.firstWhere(
        (item) => item.id != serverItem.id,
        orElse: () => matches.first,
      );
      remainingLocal.removeWhere(
        (candidate) => isSameLogicalCall(candidate, serverItem),
      );
      result.add(mergeLogicalCall(localItem, serverItem));
    }
    result.addAll(remainingLocal);
    result.sort((left, right) => right.startedAt.compareTo(left.startedAt));
    return result.take(200).toList(growable: false);
  }

  bool _sameStoredValue(CallHistoryItem left, CallHistoryItem right) {
    return left.remoteNumber == right.remoteNumber &&
        left.remoteDisplayName == right.remoteDisplayName &&
        left.direction == right.direction &&
        left.status == right.status &&
        left.effectiveDisposition == right.effectiveDisposition &&
        left.startedAt == right.startedAt &&
        left.endedAt == right.endedAt &&
        left.serverFinalized == right.serverFinalized;
  }
}
