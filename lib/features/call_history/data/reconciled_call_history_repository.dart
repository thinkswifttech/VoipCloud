import '../../../core/logging/app_logger.dart';
import '../../calls/domain/call_direction.dart';
import '../../calls/domain/call_status.dart';
import '../domain/call_history_item.dart';
import '../domain/call_history_repository.dart';

/// Keeps fast/offline device history while filling gaps from SIP-edge events.
class ReconciledCallHistoryRepository implements CallHistoryRepository {
  ReconciledCallHistoryRepository({required this.local, required this.server});

  final CallHistoryRepository local;
  final CallHistoryRepository server;

  @override
  Future<List<CallHistoryItem>> getCallHistory() async {
    final localItems = await local.getCallHistory();
    List<CallHistoryItem> serverItems;
    try {
      serverItems = await server.getCallHistory();
    } catch (error) {
      AppLogger.warning(
        'Server call-history reconciliation skipped',
        data: error,
      );
      return localItems;
    }

    final merged = _merge(localItems, serverItems);
    final localById = {for (final item in localItems) item.id: item};
    for (final item in merged) {
      final saved = localById[item.id];
      if (saved != null && _sameStoredValue(saved, item)) continue;
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
          .where((localItem) => _sameCall(localItem, serverItem))
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
        (candidate) => _sameCall(candidate, serverItem),
      );
      result.add(
        CallHistoryItem(
          id: localItem.id,
          remoteNumber: localItem.remoteNumber,
          remoteDisplayName:
              localItem.remoteDisplayName ?? serverItem.remoteDisplayName,
          direction: localItem.direction,
          status: serverItem.status,
          disposition: serverItem.effectiveDisposition,
          startedAt: localItem.startedAt,
          endedAt: serverItem.endedAt ?? localItem.endedAt,
        ),
      );
    }
    result.addAll(remainingLocal);
    result.sort((left, right) => right.startedAt.compareTo(left.startedAt));
    return result.take(200).toList(growable: false);
  }

  bool _sameCall(CallHistoryItem left, CallHistoryItem right) {
    if (left.id == right.id) return true;
    if ((left.direction == CallDirection.outgoing) !=
        (right.direction == CallDirection.outgoing)) {
      return false;
    }
    if (_digits(left.remoteNumber) != _digits(right.remoteNumber)) return false;
    return left.startedAt.difference(right.startedAt).abs() <=
        const Duration(seconds: 8);
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

  String _digits(String value) {
    final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.isEmpty ? value.trim().toLowerCase() : digits;
  }
}
