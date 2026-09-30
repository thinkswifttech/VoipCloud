import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/call_history/data/reconciled_call_history_repository.dart';
import 'package:phone_app/features/call_history/domain/call_history_item.dart';
import 'package:phone_app/features/call_history/domain/call_history_repository.dart';
import 'package:phone_app/features/calls/domain/call_direction.dart';
import 'package:phone_app/features/calls/domain/call_status.dart';

void main() {
  group('ReconciledCallHistoryRepository', () {
    final startedAt = DateTime.utc(2026, 9, 28, 14, 30);

    test('adds server-only calls and caches them locally', () async {
      final local = _FakeRepository();
      final serverItem = _item(
        id: 'server-1',
        remoteNumber: '4165550100',
        startedAt: startedAt,
        disposition: CallHistoryDisposition.missed,
      );
      final repository = ReconciledCallHistoryRepository(
        local: local,
        server: _FakeRepository(items: [serverItem]),
      );

      final result = await repository.getCallHistory();

      expect(result, [serverItem]);
      expect(local.synced, hasLength(1));
      expect(local.synced.single.id, 'server-1');
    });

    test('server disposition corrects matching local call', () async {
      final localItem = _item(
        id: 'native-call-id',
        remoteNumber: '+1 (416) 555-0100',
        remoteDisplayName: 'SUP: Caller',
        startedAt: startedAt,
        disposition: CallHistoryDisposition.missed,
        direction: CallDirection.missed,
      );
      final serverItem = _item(
        id: '42',
        remoteNumber: '14165550100',
        startedAt: startedAt.add(const Duration(seconds: 3)),
        disposition: CallHistoryDisposition.answeredElsewhere,
      );
      final local = _FakeRepository(items: [localItem]);
      final repository = ReconciledCallHistoryRepository(
        local: local,
        server: _FakeRepository(items: [serverItem]),
      );

      final result = await repository.getCallHistory();

      expect(result, hasLength(1));
      expect(result.single.id, 'native-call-id');
      expect(result.single.remoteDisplayName, 'SUP: Caller');
      expect(
        result.single.effectiveDisposition,
        CallHistoryDisposition.answeredElsewhere,
      );
      expect(local.synced.single.id, 'native-call-id');
    });

    test(
      'prefers a delayed native event over a cached server duplicate',
      () async {
        final serverItem = _item(
          id: 'server-42',
          remoteNumber: '14165550100',
          startedAt: startedAt,
          disposition: CallHistoryDisposition.answeredElsewhere,
        );
        final nativeItem = _item(
          id: 'native-call-id',
          remoteNumber: '+1 (416) 555-0100',
          remoteDisplayName: 'SUP: Caller',
          startedAt: startedAt.add(const Duration(seconds: 2)),
          disposition: CallHistoryDisposition.missed,
          direction: CallDirection.missed,
        );
        final repository = ReconciledCallHistoryRepository(
          local: _FakeRepository(items: [serverItem, nativeItem]),
          server: _FakeRepository(items: [serverItem]),
        );

        final result = await repository.getCallHistory();

        expect(result, hasLength(1));
        expect(result.single.id, 'native-call-id');
        expect(result.single.remoteDisplayName, 'SUP: Caller');
        expect(
          result.single.effectiveDisposition,
          CallHistoryDisposition.answeredElsewhere,
        );
      },
    );

    test('uses local history when the server is unavailable', () async {
      final localItem = _item(
        id: 'local-1',
        remoteNumber: '204',
        startedAt: startedAt,
        disposition: CallHistoryDisposition.answered,
      );
      final repository = ReconciledCallHistoryRepository(
        local: _FakeRepository(items: [localItem]),
        server: _FakeRepository(error: StateError('offline')),
      );

      expect(await repository.getCallHistory(), [localItem]);
    });

    test(
      'collapses queue legs and never lets server missed override local answer',
      () async {
        final localAnswered = _item(
          id: 'windows-native-call',
          remoteNumber: '211',
          remoteDisplayName: 'TEST: Abdul Test User',
          startedAt: startedAt.add(const Duration(seconds: 2)),
          disposition: CallHistoryDisposition.answered,
        );
        final serverOuterLeg = _item(
          id: 'server-outer-leg',
          remoteNumber: '211',
          startedAt: startedAt,
          disposition: CallHistoryDisposition.missed,
          direction: CallDirection.missed,
        );
        final serverB2buaLeg = _item(
          id: 'server-b2bua-leg',
          remoteNumber: '211',
          startedAt: startedAt.add(const Duration(seconds: 4)),
          disposition: CallHistoryDisposition.missed,
          direction: CallDirection.missed,
        );
        final local = _FakeRepository(items: [localAnswered]);
        final repository = ReconciledCallHistoryRepository(
          local: local,
          server: _FakeRepository(items: [serverOuterLeg, serverB2buaLeg]),
        );

        final result = await repository.getCallHistory();

        expect(result, hasLength(1));
        expect(result.single.id, 'windows-native-call');
        expect(result.single.remoteDisplayName, 'TEST: Abdul Test User');
        expect(
          result.single.effectiveDisposition,
          CallHistoryDisposition.answered,
        );
      },
    );

    test(
      'collapses cached duplicates and keeps answered-elsewhere evidence',
      () async {
        final missedNative = _item(
          id: 'android-native-call',
          remoteNumber: '211',
          startedAt: startedAt.add(const Duration(seconds: 1)),
          disposition: CallHistoryDisposition.missed,
          direction: CallDirection.missed,
        );
        final cachedMissedLeg = _item(
          id: 'server-missed-leg',
          remoteNumber: '211',
          startedAt: startedAt,
          disposition: CallHistoryDisposition.missed,
          direction: CallDirection.missed,
        );
        final answeredElsewhereLeg = _item(
          id: 'server-answered-leg',
          remoteNumber: '211',
          startedAt: startedAt.add(const Duration(seconds: 3)),
          disposition: CallHistoryDisposition.answeredElsewhere,
        );
        final local = _FakeRepository(items: [missedNative, cachedMissedLeg]);
        final repository = ReconciledCallHistoryRepository(
          local: local,
          server: _FakeRepository(
            items: [cachedMissedLeg, answeredElsewhereLeg],
          ),
        );

        final result = await repository.getCallHistory();

        expect(result, hasLength(1));
        expect(
          result.single.effectiveDisposition,
          CallHistoryDisposition.answeredElsewhere,
        );
        expect(local.synced, hasLength(1));
      },
    );

    test('keeps sequential calls from the same caller separate', () async {
      final first = _item(
        id: 'call-1',
        remoteNumber: '211',
        startedAt: startedAt,
        disposition: CallHistoryDisposition.missed,
        direction: CallDirection.missed,
      );
      final second = _item(
        id: 'call-2',
        remoteNumber: '211',
        startedAt: startedAt.add(const Duration(minutes: 1)),
        disposition: CallHistoryDisposition.missed,
        direction: CallDirection.missed,
      );
      final repository = ReconciledCallHistoryRepository(
        local: _FakeRepository(),
        server: _FakeRepository(items: [first, second]),
      );

      expect(await repository.getCallHistory(), hasLength(2));
    });

    test('new call events are written only to local storage', () async {
      final local = _FakeRepository();
      final server = _FakeRepository();
      final repository = ReconciledCallHistoryRepository(
        local: local,
        server: server,
      );

      await repository.syncCallLog(
        remoteNumber: '211',
        direction: CallDirection.outgoing,
        status: CallStatus.ended,
        disposition: CallHistoryDisposition.outgoing,
        startedAt: startedAt,
      );

      expect(local.synced, hasLength(1));
      expect(server.synced, isEmpty);
    });
  });
}

CallHistoryItem _item({
  required String id,
  required String remoteNumber,
  String? remoteDisplayName,
  required DateTime startedAt,
  required CallHistoryDisposition disposition,
  CallDirection? direction,
}) {
  return CallHistoryItem(
    id: id,
    remoteNumber: remoteNumber,
    remoteDisplayName: remoteDisplayName,
    direction:
        direction ??
        (disposition == CallHistoryDisposition.outgoing
            ? CallDirection.outgoing
            : CallDirection.incoming),
    status: disposition == CallHistoryDisposition.missed
        ? CallStatus.missed
        : CallStatus.ended,
    disposition: disposition,
    startedAt: startedAt,
    endedAt: startedAt.add(const Duration(seconds: 10)),
  );
}

class _FakeRepository implements CallHistoryRepository {
  _FakeRepository({List<CallHistoryItem>? items, this.error})
    : items = items ?? [];

  final List<CallHistoryItem> items;
  final Object? error;
  final List<CallHistoryItem> synced = [];

  @override
  Future<List<CallHistoryItem>> getCallHistory() async {
    if (error != null) throw error!;
    return List.unmodifiable(items);
  }

  @override
  Future<void> clearCallHistory() async => items.clear();

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
  }) async {
    final item = CallHistoryItem(
      id: sipCallId ?? 'generated-${synced.length}',
      remoteNumber: remoteNumber,
      remoteDisplayName: remoteDisplayName,
      direction: direction,
      status: status,
      disposition: disposition,
      startedAt: startedAt,
      endedAt: endedAt,
    );
    synced.add(item);
    return item;
  }
}
