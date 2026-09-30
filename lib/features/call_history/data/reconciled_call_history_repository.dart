import '../../../core/logging/app_logger.dart';
import '../../calls/domain/call_direction.dart';
import '../../calls/domain/call_status.dart';
import '../domain/call_history_item.dart';
import '../domain/call_history_reconciliation.dart';
import '../domain/call_history_repository.dart';

/// Keeps fast/offline device history while filling gaps from SIP-edge events.
class ReconciledCallHistoryRepository implements CallHistoryRepository {
  ReconciledCallHistoryRepository({required this.local, required this.server});

  final CallHistoryRepository local;
  final CallHistoryRepository server;

  @override
  Future<List<CallHistoryItem>> getCallHistory() async {
    final storedLocalItems = await local.getCallHistory();
    List<CallHistoryItem> serverItems;
    try {
      serverItems = await server.getCallHistory();
    } catch (error) {
      AppLogger.warning(
        'Server call-history reconciliation skipped',
        data: error,
      );
      return coalesceLogicalCalls(storedLocalItems);
    }

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
        await local.syncCallLog(
          remoteNumber: item.remoteNumber,
          remoteDisplayName: item.remoteDisplayName,
          direction: item.direction,
          status: item.status,
          disposition: item.effectiveDisposition,
          startedAt: item.startedAt,
          endedAt: item.endedAt,
          sipCallId: item.id,
        );
      } catch (error) {
        AppLogger.warning(
          'Server call-history item was not cached',
          data: error,
        );
        break;
      }
    }
    return merged;
  }

  @override
  Future<void> clearCallHistory() => local.clearCallHistory();

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
    return local.syncCallLog(
      remoteNumber: remoteNumber,
      remoteDisplayName: remoteDisplayName,
      direction: direction,
      status: status,
      disposition: disposition,
      startedAt: startedAt,
      endedAt: endedAt,
      sipCallId: sipCallId,
    );
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
        left.endedAt == right.endedAt;
  }
}
