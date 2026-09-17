import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/call_history/domain/call_history_classification.dart';
import 'package:phone_app/features/call_history/domain/call_history_item.dart';
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
      wasDeclined: false,
      wasAnsweredElsewhere: false,
    );

    expect(result.direction, CallDirection.missed);
    expect(result.status, CallStatus.missed);
    expect(result.disposition, CallHistoryDisposition.missed);
  });

  test('keeps an answered incoming call as ended', () {
    final result = classifyCompletedCall(
      direction: CallDirection.incoming,
      status: CallStatus.ended,
      wasRinging: true,
      wasAnswered: true,
      wasDndRejected: false,
      wasDeclined: false,
      wasAnsweredElsewhere: false,
    );

    expect(result.direction, CallDirection.incoming);
    expect(result.status, CallStatus.ended);
    expect(result.disposition, CallHistoryDisposition.answered);
  });

  test('keeps an incoming setup failure that never rang as failed', () {
    final result = classifyCompletedCall(
      direction: CallDirection.incoming,
      status: CallStatus.failed,
      wasRinging: false,
      wasAnswered: false,
      wasDndRejected: false,
      wasDeclined: false,
      wasAnsweredElsewhere: false,
    );

    expect(result.direction, CallDirection.incoming);
    expect(result.status, CallStatus.failed);
    expect(result.disposition, CallHistoryDisposition.missed);
  });

  test('marks a DND rejection as missed', () {
    final result = classifyCompletedCall(
      direction: CallDirection.incoming,
      status: CallStatus.ended,
      wasRinging: true,
      wasAnswered: false,
      wasDndRejected: true,
      wasDeclined: false,
      wasAnsweredElsewhere: false,
    );

    expect(result.direction, CallDirection.missed);
    expect(result.status, CallStatus.missed);
    expect(result.disposition, CallHistoryDisposition.missed);
  });

  test('marks an explicitly declined incoming call as declined', () {
    final result = classifyCompletedCall(
      direction: CallDirection.incoming,
      status: CallStatus.ended,
      wasRinging: true,
      wasAnswered: false,
      wasDndRejected: false,
      wasDeclined: true,
      wasAnsweredElsewhere: false,
    );

    expect(result.direction, CallDirection.incoming);
    expect(result.disposition, CallHistoryDisposition.declined);
  });

  test('marks a queue branch completed elsewhere distinctly', () {
    final result = classifyCompletedCall(
      direction: CallDirection.incoming,
      status: CallStatus.ended,
      wasRinging: true,
      wasAnswered: false,
      wasDndRejected: false,
      wasDeclined: false,
      wasAnsweredElsewhere: true,
    );

    expect(result.disposition, CallHistoryDisposition.answeredElsewhere);
  });

  test('recognizes only answered-elsewhere termination reasons', () {
    expect(isAnsweredElsewhereReason('Call completed elsewhere'), isTrue);
    expect(isAnsweredElsewhereReason('Answered elsewhere'), isTrue);
    expect(isAnsweredElsewhereReason('Call terminated'), isFalse);
    expect(isAnsweredElsewhereReason('Declined'), isFalse);
  });
}
