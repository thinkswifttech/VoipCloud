import 'dart:async';

import '../../core/errors/app_exception.dart';
import '../../features/calls/domain/call_direction.dart';
import '../../features/calls/domain/call_status.dart';
import '../../features/calls/domain/voip_call.dart';
import '../domain/sip_account.dart';
import '../domain/sip_registration_state.dart';
import '../domain/voip_service.dart';
import '../platform/voip_platform_channel.dart';

class LinphoneVoipService implements VoipService {
  LinphoneVoipService({VoipPlatformChannel? platformChannel})
    : _platformChannel = platformChannel ?? const VoipPlatformChannel() {
    _registrationController.add(_registrationState);
    _callController.add(null);
  }

  final VoipPlatformChannel _platformChannel;
  final StreamController<SipRegistrationState> _registrationController =
      StreamController<SipRegistrationState>.broadcast();
  final StreamController<VoipCall?> _callController =
      StreamController<VoipCall?>.broadcast();

  StreamSubscription<Map<String, dynamic>>? _registrationSubscription;
  StreamSubscription<Map<String, dynamic>>? _callSubscription;
  SipRegistrationState _registrationState = SipRegistrationState.initial();
  SipAccount? _account;
  VoipCall? _activeCall;

  @override
  SipRegistrationState get currentRegistrationState => _registrationState;

  @override
  VoipCall? get activeCall => _activeCall;

  @override
  Stream<SipRegistrationState> get registrationStateStream =>
      _registrationController.stream;

  @override
  Stream<VoipCall?> get callStateStream => _callController.stream;

  @override
  Future<void> initialize() async {
    _bindNativeEvents();
    await _platformChannel.initialize();
    _emitRegistration(
      SipRegistrationState(
        status: SipRegistrationStatus.unregistered,
        updatedAt: DateTime.now(),
      ),
    );
  }

  @override
  Future<void> configureAccount(SipAccount account) async {
    _account = account;
    _emitRegistration(
      SipRegistrationState(
        status: SipRegistrationStatus.configuring,
        updatedAt: DateTime.now(),
        message: account.hasCredentials
            ? 'SIP account loaded'
            : 'SIP credentials are not provisioned yet',
      ),
    );

    await _platformChannel.configureAccount({
      'sipUsername': account.username,
      'authUsername': account.authUsername,
      'password': account.password,
      'domain': account.domain,
      'outboundProxy': account.proxyUri,
      'transport': account.transport.name,
      'displayName': account.displayName,
      'stunServer': account.stunServer,
      'turnServer': account.turnServer,
    });
  }

  @override
  Future<void> register() async {
    final account = _account;
    if (account == null) {
      throw const VoipException(message: 'No SIP account configured');
    }

    _emitRegistration(
      SipRegistrationState(
        status: SipRegistrationStatus.registering,
        updatedAt: DateTime.now(),
        message: 'Preparing SIP registration',
      ),
    );

    if (!account.hasCredentials) {
      _emitRegistration(
        SipRegistrationState(
          status: SipRegistrationStatus.failed,
          updatedAt: DateTime.now(),
          message: 'SIP password is not provisioned',
        ),
      );
      return;
    }

    await _platformChannel.register();
  }

  @override
  Future<void> unregister() async {
    await _platformChannel.unregister();
    _emitRegistration(
      SipRegistrationState(
        status: SipRegistrationStatus.unregistered,
        updatedAt: DateTime.now(),
      ),
    );
  }

  @override
  Future<void> makeCall(String destination) async {
    if (destination.trim().isEmpty) {
      throw const VoipException(
        message: 'Missing destination',
        userMessage: 'Enter a number or SIP address.',
      );
    }

    await _platformChannel.makeCall(destination);
  }

  @override
  Future<void> acceptCall(String callId) async {
    await _platformChannel.acceptCall(callId);
  }

  @override
  Future<void> declineCall(String callId) async {
    await _platformChannel.rejectCall(callId);
  }

  @override
  Future<void> endCall(String callId) async {
    await _platformChannel.endCall(callId);
  }

  @override
  Future<void> mute(bool enabled) async {
    await _platformChannel.mute(enabled);
  }

  @override
  Future<void> setSpeaker(bool enabled) async {
    await _platformChannel.setSpeaker(enabled);
  }

  @override
  Future<void> dispose() async {
    await _registrationSubscription?.cancel();
    await _callSubscription?.cancel();
    try {
      await _platformChannel.dispose();
    } catch (_) {
      // Native bridge can be absent in unit tests.
    }
    await _registrationController.close();
    await _callController.close();
  }

  void _emitRegistration(SipRegistrationState state) {
    _registrationState = state;
    _registrationController.add(state);
  }

  void _bindNativeEvents() {
    _registrationSubscription ??= _platformChannel.registrationEvents().listen(
      (event) => _emitRegistration(_registrationFromEvent(event)),
      onError: (_) {
        _emitRegistration(
          SipRegistrationState(
            status: SipRegistrationStatus.failed,
            updatedAt: DateTime.now(),
            message: 'Linphone native registration events are unavailable.',
          ),
        );
      },
    );
    _callSubscription ??= _platformChannel.callEvents().listen((event) {
      final call = _callFromEvent(event);
      _activeCall = call.status == CallStatus.ended ? null : call;
      _callController.add(_activeCall);
    }, onError: (_) {});
  }
}

SipRegistrationState _registrationFromEvent(Map<String, dynamic> event) {
  return SipRegistrationState(
    status: _registrationStatus('${event['status']}'),
    updatedAt: DateTime.now(),
    message: _nullableString(event['message']),
  );
}

VoipCall _callFromEvent(Map<String, dynamic> event) {
  return VoipCall(
    id: _string(event['id'], fallback: 'native-call'),
    remoteUri: _string(event['remoteUri']),
    remoteDisplayName: _nullableString(event['remoteDisplayName']),
    direction: _callDirection('${event['direction']}'),
    status: _callStatus('${event['status']}'),
    startedAt: _date(event['startedAt']) ?? DateTime.now(),
    endedAt: _date(event['endedAt']),
    isMuted: event['isMuted'] == true,
    isSpeakerEnabled: event['isSpeakerEnabled'] == true,
  );
}

SipRegistrationStatus _registrationStatus(String value) {
  return switch (value.trim().toLowerCase()) {
    'uninitialized' => SipRegistrationStatus.uninitialized,
    'unregistered' => SipRegistrationStatus.unregistered,
    'configuring' => SipRegistrationStatus.configuring,
    'registering' => SipRegistrationStatus.registering,
    'registered' => SipRegistrationStatus.registered,
    'failed' => SipRegistrationStatus.failed,
    _ => SipRegistrationStatus.failed,
  };
}

CallDirection _callDirection(String value) {
  return switch (value.trim().toLowerCase()) {
    'incoming' => CallDirection.incoming,
    'missed' => CallDirection.missed,
    _ => CallDirection.outgoing,
  };
}

CallStatus _callStatus(String value) {
  return switch (value.trim().toLowerCase()) {
    'ringing' => CallStatus.ringing,
    'dialing' => CallStatus.dialing,
    'connecting' => CallStatus.connecting,
    'active' => CallStatus.active,
    'held' => CallStatus.held,
    'ended' => CallStatus.ended,
    'missed' => CallStatus.missed,
    'failed' => CallStatus.failed,
    _ => CallStatus.failed,
  };
}

String _string(Object? value, {String fallback = ''}) {
  if (value == null) {
    return fallback;
  }
  final text = '$value'.trim();
  return text.isEmpty ? fallback : text;
}

String? _nullableString(Object? value) {
  final text = _string(value);
  return text.isEmpty ? null : text;
}

DateTime? _date(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse('$value');
}
