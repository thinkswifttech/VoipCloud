import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/features/call_history/data/local_call_history_repository.dart';
import 'package:phone_app/features/call_history/domain/call_history_item.dart';
import 'package:phone_app/features/calls/domain/call_direction.dart';
import 'package:phone_app/features/calls/domain/call_status.dart';

void main() {
  test('serializes rapid terminal calls without losing either entry', () async {
    final repository = LocalCallHistoryRepository(_SlowStorage());
    final startedAt = DateTime.utc(2026, 9, 16, 12);

    await Future.wait([
      repository.syncCallLog(
        remoteNumber: 'sales:14165550123',
        remoteDisplayName: 'Sales: External caller',
        direction: CallDirection.missed,
        status: CallStatus.missed,
        disposition: CallHistoryDisposition.missed,
        startedAt: startedAt,
        endedAt: startedAt.add(const Duration(seconds: 8)),
        sipCallId: 'queue-branch-a',
      ),
      repository.syncCallLog(
        remoteNumber: 'support:14165550124',
        remoteDisplayName: 'Support: External caller',
        direction: CallDirection.missed,
        status: CallStatus.missed,
        disposition: CallHistoryDisposition.missed,
        startedAt: startedAt.add(const Duration(seconds: 1)),
        endedAt: startedAt.add(const Duration(seconds: 9)),
        sipCallId: 'queue-branch-b',
      ),
    ]);

    final history = await repository.getCallHistory();
    expect(history.map((item) => item.id).toSet(), {
      'queue-branch-a',
      'queue-branch-b',
    });
    expect(history.first.remoteNumber, 'support:14165550124');
    expect(history.first.remoteDisplayName, 'Support: External caller');
    expect(
      history.every(
        (item) => item.effectiveDisposition == CallHistoryDisposition.missed,
      ),
      isTrue,
    );
  });

  test(
    'replaces a cached server record with its delayed native event',
    () async {
      final repository = LocalCallHistoryRepository(_SlowStorage());
      final startedAt = DateTime.utc(2026, 9, 28, 12);

      await repository.syncCallLog(
        remoteNumber: '14165550100',
        direction: CallDirection.incoming,
        status: CallStatus.missed,
        disposition: CallHistoryDisposition.missed,
        startedAt: startedAt,
        sipCallId: 'server-42',
      );
      await repository.syncCallLog(
        remoteNumber: '+1 (416) 555-0100',
        remoteDisplayName: 'SUP: Caller',
        direction: CallDirection.missed,
        status: CallStatus.ended,
        disposition: CallHistoryDisposition.answeredElsewhere,
        startedAt: startedAt.add(const Duration(seconds: 2)),
        sipCallId: 'native-call-id',
      );

      final history = await repository.getCallHistory();
      expect(history, hasLength(1));
      expect(history.single.id, 'native-call-id');
      expect(history.single.remoteDisplayName, 'SUP: Caller');
      expect(
        history.single.effectiveDisposition,
        CallHistoryDisposition.answeredElsewhere,
      );
    },
  );

  test('removes overlapping queue-leg duplicates already in storage', () async {
    final storage = InMemorySecureStorageService();
    final repository = LocalCallHistoryRepository(storage);
    final startedAt = DateTime.utc(2026, 9, 29, 15, 57);

    await repository.syncCallLog(
      remoteNumber: '211',
      direction: CallDirection.missed,
      status: CallStatus.missed,
      disposition: CallHistoryDisposition.missed,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(seconds: 15)),
      sipCallId: 'server-outer-leg',
    );
    await repository.syncCallLog(
      remoteNumber: '211',
      remoteDisplayName: 'TEST: Abdul Test User',
      direction: CallDirection.incoming,
      status: CallStatus.ended,
      disposition: CallHistoryDisposition.answered,
      startedAt: startedAt.add(const Duration(seconds: 3)),
      endedAt: startedAt.add(const Duration(seconds: 12)),
      sipCallId: 'windows-native-call',
    );

    final history = await repository.getCallHistory();
    expect(history, hasLength(1));
    expect(history.single.id, 'windows-native-call');
    expect(
      history.single.effectiveDisposition,
      CallHistoryDisposition.answered,
    );
  });

  test('hides a cached zero-duration provisional server miss', () async {
    final repository = LocalCallHistoryRepository(
      InMemorySecureStorageService(),
    );
    final startedAt = DateTime.utc(2026, 9, 29, 19, 50);

    await repository.syncCallLog(
      remoteNumber: '211',
      remoteDisplayName: 'TEST: Abdul Test User',
      direction: CallDirection.missed,
      status: CallStatus.missed,
      disposition: CallHistoryDisposition.missed,
      startedAt: startedAt,
      endedAt: startedAt,
      sipCallId:
          'b7d8e6bcdb6f4b96cdf67a61156efee92eb68967fcb1fed4d0bfb0e614334562',
    );

    expect(await repository.getCallHistory(), isEmpty);
  });
}

class _SlowStorage extends InMemorySecureStorageService {
  @override
  Future<String?> read(String key) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await super.write(key, value);
  }
}
