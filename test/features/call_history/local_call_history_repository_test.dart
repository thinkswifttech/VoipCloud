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
