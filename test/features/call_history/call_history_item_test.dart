import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/call_history/domain/call_history_item.dart';
import 'package:phone_app/features/calls/domain/call_direction.dart';
import 'package:phone_app/features/calls/domain/call_status.dart';

void main() {
  test('persists an explicit declined disposition', () {
    final item = CallHistoryItem(
      id: 'call-1',
      remoteNumber: '210',
      direction: CallDirection.incoming,
      status: CallStatus.ended,
      disposition: CallHistoryDisposition.declined,
      startedAt: DateTime.utc(2026, 9, 15, 12),
      endedAt: DateTime.utc(2026, 9, 15, 12, 0, 5),
    );

    final restored = CallHistoryItem.fromJson(item.toJson());

    expect(restored.effectiveDisposition, CallHistoryDisposition.declined);
  });

  test('infers dispositions for history saved by older app versions', () {
    CallHistoryItem legacy({
      required CallDirection direction,
      required CallStatus status,
    }) {
      return CallHistoryItem(
        id: '${direction.name}-${status.name}',
        remoteNumber: '210',
        direction: direction,
        status: status,
        startedAt: DateTime.utc(2026, 9, 15),
      );
    }

    expect(
      legacy(
        direction: CallDirection.outgoing,
        status: CallStatus.ended,
      ).effectiveDisposition,
      CallHistoryDisposition.outgoing,
    );
    expect(
      legacy(
        direction: CallDirection.incoming,
        status: CallStatus.ended,
      ).effectiveDisposition,
      CallHistoryDisposition.answered,
    );
    expect(
      legacy(
        direction: CallDirection.missed,
        status: CallStatus.missed,
      ).effectiveDisposition,
      CallHistoryDisposition.missed,
    );
  });
}
