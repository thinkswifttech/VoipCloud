import 'call_history_item.dart';
import '../../calls/domain/call_direction.dart';
import '../../calls/domain/call_status.dart';

abstract class CallHistoryRepository {
  Future<List<CallHistoryItem>> getCallHistory();

  Future<void> clearCallHistory();

  Future<CallHistoryItem> syncCallLog({
    required String remoteNumber,
    required CallDirection direction,
    required CallStatus status,
    required DateTime startedAt,
    DateTime? endedAt,
    String? sipCallId,
  });
}
