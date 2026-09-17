import '../../calls/domain/call_direction.dart';
import '../../calls/domain/call_status.dart';
import 'call_history_item.dart';

typedef CallHistoryClassification = ({
  CallDirection direction,
  CallStatus status,
  CallHistoryDisposition disposition,
});

/// Normalizes a completed native call into the status shown in call history.
///
/// Linphone reports a remotely cancelled incoming call as `ended` on every
/// native platform. It is missed when it rang and was never accepted/connected.
CallHistoryClassification classifyCompletedCall({
  required CallDirection direction,
  required CallStatus status,
  required bool wasRinging,
  required bool wasAnswered,
  required bool wasDndRejected,
  required bool wasDeclined,
  required bool wasAnsweredElsewhere,
}) {
  if (direction == CallDirection.incoming && wasAnsweredElsewhere) {
    return (
      direction: CallDirection.incoming,
      status: status,
      disposition: CallHistoryDisposition.answeredElsewhere,
    );
  }
  if (direction == CallDirection.incoming && wasDeclined && !wasDndRejected) {
    return (
      direction: CallDirection.incoming,
      status: status,
      disposition: CallHistoryDisposition.declined,
    );
  }
  final missed =
      wasDndRejected ||
      direction == CallDirection.missed ||
      status == CallStatus.missed ||
      (direction == CallDirection.incoming && wasRinging && !wasAnswered);
  if (missed) {
    return (
      direction: CallDirection.missed,
      status: CallStatus.missed,
      disposition: CallHistoryDisposition.missed,
    );
  }
  return (
    direction: direction,
    status: status,
    disposition: direction == CallDirection.outgoing
        ? CallHistoryDisposition.outgoing
        : wasAnswered
        ? CallHistoryDisposition.answered
        : CallHistoryDisposition.missed,
  );
}

bool isAnsweredElsewhereReason(String? message) {
  final normalized = message?.trim().toLowerCase() ?? '';
  return normalized.contains('call completed elsewhere') ||
      normalized.contains('answered elsewhere') ||
      normalized.contains('completed elsewhere');
}
