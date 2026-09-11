import '../../calls/domain/call_direction.dart';
import '../../calls/domain/call_status.dart';

typedef CallHistoryClassification = ({
  CallDirection direction,
  CallStatus status,
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
}) {
  final missed =
      wasDndRejected ||
      direction == CallDirection.missed ||
      status == CallStatus.missed ||
      (direction == CallDirection.incoming && wasRinging && !wasAnswered);
  if (missed) {
    return (direction: CallDirection.missed, status: CallStatus.missed);
  }
  return (direction: direction, status: status);
}
