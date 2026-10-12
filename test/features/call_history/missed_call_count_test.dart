import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/features/call_history/domain/call_history_item.dart';
import 'package:phone_app/features/call_history/domain/call_history_repository.dart';
import 'package:phone_app/features/call_history/presentation/call_history_providers.dart';
import 'package:phone_app/features/calls/domain/call_direction.dart';
import 'package:phone_app/features/calls/domain/call_status.dart';

class _Storage implements SecureStorageService {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<void> deleteAll() async => values.clear();
}

class _Repository implements CallHistoryRepository {
  List<CallHistoryItem> items = const [];

  @override
  Future<List<CallHistoryItem>> getCallHistory() async => items;

  @override
  Future<void> clearCallHistory() async => items = const [];

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
    bool serverFinalized = false,
  }) {
    throw UnsupportedError('not used');
  }
}

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

  test(
    'refresh removes badge when server finalizes miss as answered elsewhere',
    () async {
      final repository = _Repository();
      final missed = CallHistoryItem(
        id: 'same-call',
        remoteNumber: '210',
        direction: CallDirection.incoming,
        status: CallStatus.missed,
        disposition: CallHistoryDisposition.missed,
        startedAt: viewedAt,
        endedAt: viewedAt.add(const Duration(seconds: 5)),
      );
      repository.items = [missed];
      final container = ProviderContainer(
        overrides: [
          callHistoryRepositoryProvider.overrideWithValue(repository),
          callHistoryStorageProvider.overrideWithValue(_Storage()),
        ],
      );
      addTearDown(container.dispose);

      expect(await container.read(missedCallCountProvider.future), 1);

      repository.items = [
        CallHistoryItem(
          id: missed.id,
          remoteNumber: missed.remoteNumber,
          direction: missed.direction,
          status: CallStatus.ended,
          disposition: CallHistoryDisposition.answeredElsewhere,
          startedAt: missed.startedAt,
          endedAt: missed.endedAt,
          serverFinalized: true,
        ),
      ];
      await container.read(callHistoryProvider.notifier).refresh();

      expect(
        (await container.read(
          callHistoryProvider.future,
        )).single.effectiveDisposition,
        CallHistoryDisposition.answeredElsewhere,
      );
      expect(await container.read(missedCallCountProvider.future), 0);
    },
  );
}
