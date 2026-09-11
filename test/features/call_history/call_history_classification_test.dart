import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/call_history/domain/call_history_classification.dart';
import 'package:phone_app/features/calls/domain/call_direction.dart';
import 'package:phone_app/features/calls/domain/call_status.dart';

void main() {
  test('marks an unanswered ringing incoming call as missed', () {
    final result = classifyCompletedCall(
      direction: CallDirection.incoming,
      status: CallStatus.ended,
      wasRinging: true,
      wasAnswered: false,
      wasDndRejected: false,
    );

    expect(result.direction, CallDirection.missed);
    expect(result.status, CallStatus.missed);
  });

  test('keeps an answered incoming call as ended', () {
    final result = classifyCompletedCall(
      direction: CallDirection.incoming,
      status: CallStatus.ended,
      wasRinging: true,
      wasAnswered: true,
      wasDndRejected: false,
    );

    expect(result.direction, CallDirection.incoming);
    expect(result.status, CallStatus.ended);
  });

  test('keeps an incoming setup failure that never rang as failed', () {
    final result = classifyCompletedCall(
      direction: CallDirection.incoming,
      status: CallStatus.failed,
      wasRinging: false,
      wasAnswered: false,
      wasDndRejected: false,
    );

    expect(result.direction, CallDirection.incoming);
    expect(result.status, CallStatus.failed);
  });

  test('marks a DND rejection as missed', () {
    final result = classifyCompletedCall(
      direction: CallDirection.incoming,
      status: CallStatus.ended,
      wasRinging: true,
      wasAnswered: false,
      wasDndRejected: true,
    );

    expect(result.direction, CallDirection.missed);
    expect(result.status, CallStatus.missed);
  });
}
