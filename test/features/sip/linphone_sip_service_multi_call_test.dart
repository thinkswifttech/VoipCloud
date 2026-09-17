import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/config/sip_transport.dart';
import 'package:phone_app/features/call_history/domain/call_history_item.dart';
import 'package:phone_app/features/call_history/domain/call_history_repository.dart';
import 'package:phone_app/features/calls/domain/call_direction.dart';
import 'package:phone_app/features/calls/domain/call_status.dart';
import 'package:phone_app/features/sip/application/linphone_sip_service.dart';
import 'package:phone_app/features/sip/domain/sip_config.dart';
import 'package:phone_app/voip/platform/voip_platform_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LinphoneSipService multi-call coordination', () {
    late _FakeVoipPlatformChannel platform;
    late _MemoryCallHistoryRepository history;
    late LinphoneSipService service;

    setUp(() async {
      platform = _FakeVoipPlatformChannel();
      history = _MemoryCallHistoryRepository();
      service = LinphoneSipService(
        platformChannel: platform,
        callHistoryRepository: history,
      );
      await service.initialize(_config);
    });

    tearDown(() async {
      await service.dispose();
      await platform.close();
    });

    test('holds the active call before answering a waiting call', () async {
      platform.emitCall(_event('first', 'active', direction: 'outgoing'));
      platform.emitCall(_event('second', 'ringing'));
      await _flushEvents();

      await service.acceptCall('second');
      await _flushEvents();

      expect(platform.actions, ['hold:first', 'accept:second']);
      expect(service.liveCalls, hasLength(2));
      expect(
        service.liveCalls.firstWhere((call) => call.id == 'first').status,
        CallStatus.held,
      );
      expect(
        service.liveCalls.firstWhere((call) => call.id == 'second').status,
        CallStatus.active,
      );
    });

    test('swaps the active and held calls in a serialized order', () async {
      platform.emitCall(_event('first', 'held', direction: 'outgoing'));
      platform.emitCall(_event('second', 'active'));
      await _flushEvents();

      await service.switchToCall('first');
      await _flushEvents();

      expect(platform.actions, ['hold:second', 'resume:first']);
      expect(service.activeCall?.id, 'first');
      expect(service.activeCall?.status, CallStatus.active);
      expect(
        service.liveCalls.firstWhere((call) => call.id == 'second').status,
        CallStatus.held,
      );
    });

    test('ends the current call before answering the waiting call', () async {
      platform.emitCall(_event('first', 'active', direction: 'outgoing'));
      platform.emitCall(_event('second', 'ringing'));
      await _flushEvents();

      await service.endCurrentAndAcceptCall('second');
      await _flushEvents();

      expect(platform.actions, ['end:first', 'accept:second']);
      expect(service.liveCalls, hasLength(1));
      expect(service.activeCall?.id, 'second');
      expect(service.activeCall?.status, CallStatus.active);
    });

    test(
      'automatically resumes the sole held call when its peer ends',
      () async {
        platform.emitCall(_event('first', 'held', direction: 'outgoing'));
        platform.emitCall(_event('second', 'active'));
        await _flushEvents();

        platform.emitCall(_event('second', 'ended'));
        await _flushEvents();
        await _flushEvents();

        expect(platform.actions, ['resume:first']);
        expect(service.liveCalls, hasLength(1));
        expect(service.activeCall?.id, 'first');
        expect(service.activeCall?.status, CallStatus.active);
      },
    );

    test(
      'persists an iOS answered-elsewhere event without marking it missed',
      () async {
        platform.emitCall(_event('queue-branch', 'ringing'));
        await _flushEvents();

        platform.emitCall(
          _event(
            'queue-branch',
            'ended',
            stateMessage: 'Call completed elsewhere',
          ),
        );
        await _flushEvents();
        await _flushEvents();

        expect(history.items, hasLength(1));
        expect(
          history.items.single.effectiveDisposition,
          CallHistoryDisposition.answeredElsewhere,
        );
        expect(history.items.single.direction, CallDirection.incoming);
        expect(
          history.items.single.effectiveDisposition,
          isNot(CallHistoryDisposition.missed),
        );
      },
    );

    test(
      'upgrades an early Android missed event when Telecom supplies answered elsewhere',
      () async {
        platform.emitCall(_event('android-branch', 'ringing'));
        await _flushEvents();

        // Linphone reports End first. Android Telecom then supplies the more
        // specific remote completion reason for the same SIP Call-ID.
        platform.emitCall(_event('android-branch', 'ended'));
        platform.emitCall(
          _event(
            'android-branch',
            'ended',
            stateMessage: 'Call completed elsewhere',
          ),
        );
        await _flushEvents();
        await _flushEvents();

        expect(history.items, hasLength(1));
        expect(
          history.items.single.effectiveDisposition,
          CallHistoryDisposition.answeredElsewhere,
        );
        expect(history.items.single.direction, CallDirection.incoming);
      },
    );
  });
}

const _config = SipConfig(
  extension: '210',
  sipUsername: '210',
  authUsername: '210',
  password: 'secret',
  domain: 'example.test',
  registrar: 'example.test',
  outboundProxy: '',
  port: 5061,
  transport: SipTransport.tls,
);

Map<String, dynamic> _event(
  String id,
  String status, {
  String direction = 'incoming',
  String? stateMessage,
}) {
  return {
    'id': id,
    'remoteUri': 'sip:$id@example.test',
    'direction': direction,
    'status': status,
    'startedAt': DateTime(2026, 9, 17, 10).millisecondsSinceEpoch,
    'stateMessage': stateMessage,
  };
}

Future<void> _flushEvents() => Future<void>.delayed(Duration.zero);

class _FakeVoipPlatformChannel extends VoipPlatformChannel {
  _FakeVoipPlatformChannel();

  final _registrationEvents =
      StreamController<Map<String, dynamic>>.broadcast();
  final _callEvents = StreamController<Map<String, dynamic>>.broadcast();
  final _messageEvents = StreamController<Map<String, dynamic>>.broadcast();
  final List<String> actions = [];
  final Map<String, Map<String, dynamic>> _calls = {};

  @override
  Stream<Map<String, dynamic>> registrationEvents() =>
      _registrationEvents.stream;

  @override
  Stream<Map<String, dynamic>> callEvents() => _callEvents.stream;

  @override
  Stream<Map<String, dynamic>> messageEvents() => _messageEvents.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> configureAccount(Map<String, Object?> account) async {}

  @override
  Future<void> register() async {}

  @override
  Future<bool> hasActiveCall() async => _calls.values.any(
    (call) => !const {'ended', 'missed', 'failed'}.contains(call['status']),
  );

  @override
  Future<void> hold(String callId) async {
    actions.add('hold:$callId');
    _changeStatus(callId, 'held');
  }

  @override
  Future<void> resume(String callId) async {
    actions.add('resume:$callId');
    _changeStatus(callId, 'active');
  }

  @override
  Future<void> acceptCall(String callId) async {
    actions.add('accept:$callId');
    _changeStatus(callId, 'active');
  }

  @override
  Future<void> endCall(String callId) async {
    actions.add('end:$callId');
    _changeStatus(callId, 'ended');
  }

  @override
  Future<void> dispose() async {}

  void emitCall(Map<String, dynamic> event) {
    _calls['${event['id']}'] = Map<String, dynamic>.from(event);
    _callEvents.add(event);
  }

  void _changeStatus(String callId, String status) {
    final current = _calls[callId];
    if (current == null) return;
    emitCall({...current, 'status': status});
  }

  Future<void> close() async {
    await _registrationEvents.close();
    await _callEvents.close();
    await _messageEvents.close();
  }
}

class _MemoryCallHistoryRepository implements CallHistoryRepository {
  final List<CallHistoryItem> items = [];

  @override
  Future<void> clearCallHistory() async => items.clear();

  @override
  Future<List<CallHistoryItem>> getCallHistory() async => List.of(items);

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
      id: sipCallId ?? 'call-${startedAt.microsecondsSinceEpoch}',
      remoteNumber: remoteNumber,
      remoteDisplayName: remoteDisplayName,
      direction: direction,
      status: status,
      disposition: disposition,
      startedAt: startedAt,
      endedAt: endedAt,
    );
    items
      ..removeWhere((entry) => entry.id == item.id)
      ..add(item);
    return item;
  }
}
