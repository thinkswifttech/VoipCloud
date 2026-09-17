import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/call_history/domain/call_history_item.dart';
import 'package:phone_app/features/call_history/presentation/call_history_providers.dart';
import 'package:phone_app/features/calls/domain/call_direction.dart';
import 'package:phone_app/features/calls/domain/call_status.dart';

void main() {
  final viewedAt = DateTime.utc(2026, 9, 11, 12);

  CallHistoryItem item({
    required String id,
    required CallDirection direction,
    required CallStatus status,
    required DateTime endedAt,
  }) {
    return CallHistoryItem(
      id: id,
      remoteNumber: '210',
      direction: direction,
      status: status,
      startedAt: endedAt.subtract(const Duration(seconds: 10)),
      endedAt: endedAt,
    );
  }

  test('counts only missed calls completed after history was viewed', () {
    final calls = [
      item(
        id: 'old-missed',
        direction: CallDirection.missed,
        status: CallStatus.missed,
        endedAt: viewedAt.subtract(const Duration(minutes: 1)),
      ),
      item(
        id: 'new-missed',
        direction: CallDirection.incoming,
        status: CallStatus.missed,
        endedAt: viewedAt.add(const Duration(minutes: 1)),
      ),
      item(
        id: 'answered',
        direction: CallDirection.incoming,
        status: CallStatus.ended,
        endedAt: viewedAt.add(const Duration(minutes: 2)),
      ),
      CallHistoryItem(
        id: 'declined',
        remoteNumber: '211',
        direction: CallDirection.incoming,
        status: CallStatus.ended,
        disposition: CallHistoryDisposition.declined,
        startedAt: viewedAt,
        endedAt: viewedAt.add(const Duration(minutes: 3)),
      ),
      CallHistoryItem(
        id: 'answered-elsewhere',
        remoteNumber: '212',
        direction: CallDirection.incoming,
        status: CallStatus.ended,
        disposition: CallHistoryDisposition.answeredElsewhere,
        startedAt: viewedAt,
        endedAt: viewedAt.add(const Duration(minutes: 4)),
      ),
    ];

    expect(unreadMissedCallCount(calls, lastViewedAt: viewedAt), 1);
  });

  test('counts existing missed calls before history has ever been opened', () {
    final calls = [
      item(
        id: 'missed',
        direction: CallDirection.missed,
        status: CallStatus.missed,
        endedAt: viewedAt,
      ),
    ];

    expect(unreadMissedCallCount(calls, lastViewedAt: null), 1);
  });
}
