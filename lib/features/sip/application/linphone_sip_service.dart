import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/errors/app_exception.dart';
import '../../../voip/platform/voip_platform_channel.dart';
import '../../call_history/domain/call_history_classification.dart';
import '../../call_history/domain/call_history_repository.dart';
import '../../calls/domain/audio_output_route.dart';
import '../../calls/domain/audio_volume_levels.dart';
import '../../calls/domain/call_direction.dart';
import '../../calls/domain/call_quality_info.dart';
import '../../calls/domain/call_status.dart';
import '../../calls/domain/voip_call.dart';
import '../domain/sip_message.dart';
import '../domain/sip_config.dart';
import '../domain/sip_registration_state.dart';
import 'sip_log_store.dart';
import 'sip_service.dart';

class LinphoneSipService implements SipService {
  LinphoneSipService({
    CallHistoryRepository? callHistoryRepository,
    void Function()? onCallHistoryChanged,
    VoipPlatformChannel? platformChannel,
    String stunServer = '',
    String turnServer = '',
    this.isDndEnabled,
    SipLogStore? sipLogStore,
  }) : _callHistoryRepository = callHistoryRepository,
       _onCallHistoryChanged = onCallHistoryChanged,
       _platformChannel = platformChannel ?? const VoipPlatformChannel(),
       _stunServer = stunServer.trim(),
       _turnServer = turnServer.trim(),
       _sipLogStore = sipLogStore {
    _registrationController.add(_registrationState);
    _callController.add(null);
    _liveCallsController.add(const []);
  }

  /// When true, incoming ringing calls are rejected client-side without UI.
  bool Function()? isDndEnabled;

  final CallHistoryRepository? _callHistoryRepository;
  final void Function()? _onCallHistoryChanged;
  final VoipPlatformChannel _platformChannel;
  final SipLogStore? _sipLogStore;
  final String _stunServer;
  final String _turnServer;
  final StreamController<SipRegistrationState> _registrationController =
      StreamController<SipRegistrationState>.broadcast();
  final StreamController<VoipCall?> _callController =
      StreamController<VoipCall?>.broadcast();
  final StreamController<List<VoipCall>> _liveCallsController =
      StreamController<List<VoipCall>>.broadcast();
  final StreamController<SipMessage> _messageController =
      StreamController<SipMessage>.broadcast();

  StreamSubscription<Map<String, dynamic>>? _registrationSubscription;
  StreamSubscription<Map<String, dynamic>>? _callSubscription;
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;
  SipRegistrationState _registrationState = SipRegistrationState.initial();
  SipConfig? _config;
  VoipCall? _activeCall;
  final Map<String, VoipCall> _knownCalls = {};
  final Set<String> _dndRejectedCallIds = {};
  bool _disposed = false;
  final Set<String> _ringingIncomingCallIds = {};
  final Set<String> _answeredIncomingCallIds = {};
  final Set<String> _declinedIncomingCallIds = {};
  final Set<String> _featureCodeCallIds = {};
  bool _pendingPbxDndToggle = false;
  bool _featureCodeDialInFlight = false;
  bool _initialized = false;
  Future<void>? _registrationOperation;
  Future<void> _audioRouteSerial = Future<void>.value();
  Timer? _windowsCallReconciliationTimer;
  bool _windowsSyncInFlight = false;
  final Stopwatch _callTraceClock = Stopwatch()..start();
  int _callTraceSequence = 0;

  static const _pbxDndToggleCode = '*76';

  @override
  Stream<SipRegistrationState> get registrationStateStream =>
      _registrationController.stream;

  @override
  VoipCall? get activeCall => _activeCall;

  @override
  Stream<VoipCall?> get callStateStream => _callController.stream;

  @override
  List<VoipCall> get liveCalls => _orderedLiveCalls();

  @override
  Stream<List<VoipCall>> get liveCallsStream => _liveCallsController.stream;

  @override
  Stream<SipMessage> get messageStream => _messageController.stream;

  @override
  SipRegistrationState getRegistrationState() => _registrationState;

  @override
  SipConfig? get currentConfig => _config;

  @override
  Future<void> initialize(SipConfig config) async {
    _config = config;
    _logConfig('initialize', config);
    _emitRegistration(
      SipRegistrationState(
        status: SipRegistrationStatus.configuring,
        updatedAt: DateTime.now(),
        message: 'Preparing Linphone core',
      ),
    );

    try {
      if (!_initialized) {
        _bindNativeEvents();
        await _platformChannel.initialize();
        _initialized = true;
      }
      if (await hasActiveCall()) {
        await syncCurrentCall();
        return;
      }
      await _configureNativeAccount(config);
      await syncCurrentCall();
    } on Object catch (error) {
      _emitRegistration(
        SipRegistrationState(
          status: SipRegistrationStatus.failed,
          updatedAt: DateTime.now(),
          message: _nativeErrorMessage(error),
        ),
      );
      rethrow;
    }
  }

  @override
  Future<void> refreshConfig(SipConfig config) async {
    _config = config;
    _logConfig('refreshConfig', config);
    if (await hasActiveCall()) {
      await syncCurrentCall();
      return;
    }
    await _configureNativeAccount(config);
    await syncCurrentCall();
  }

  @override
  Future<void> register() {
    final current = _registrationOperation;
    if (current != null) return current;
    final operation = _register();
    _registrationOperation = operation;
    return operation;
  }

  Future<void> _register() async {
    final config = _config;
    if (config == null || !config.hasCredentials) {
      throw const VoipException(
        message: 'SIP credentials are not provisioned',
        userMessage: 'SIP provisioning is incomplete. Reprovision this device.',
      );
    }

    _emitRegistration(
      SipRegistrationState(
        status: SipRegistrationStatus.registering,
        updatedAt: DateTime.now(),
        message: 'Registering with PBX',
      ),
    );
    _logConfig('register', config);
    try {
      await _platformChannel.register();
    } on Object catch (error) {
      _emitRegistration(
        SipRegistrationState(
          status: SipRegistrationStatus.failed,
          updatedAt: DateTime.now(),
          message: _nativeErrorMessage(error),
        ),
      );
      rethrow;
    } finally {
      _registrationOperation = null;
    }
  }

  @override
  Future<void> syncCurrentCall() async {
    try {
      final snapshot = await _platformChannel.syncCurrentCall();
      if (snapshot != null) {
        _handleNativeCallEvent(snapshot);
      }
      final call = _activeCall;
      if (call != null) {
        _callController.add(call);
      }
    } catch (_) {
      // Some platforms do not need an explicit native call-state replay.
    }
  }

  @override
  Future<bool> hasActiveCall() async {
    final call = _activeCall;
    if (call != null && !_isFinished(call.status)) {
      return true;
    }
    return _platformChannel.hasActiveCall();
  }

  /// Sync often emits `none` during registration refresh even while a call is
  /// still live. Never tear down a local in-progress call from `none` alone —
  /// only explicit ended/failed/missed events (or a finished local state) clear it.
  void _handleNativeCallCleared() {
    final remaining = _orderedLiveCalls();
    if (remaining.isNotEmpty) {
      final previous = _activeCall ?? remaining.first;
      AppLogger.info(
        'Ignoring native call none while local call is active '
        'id=${previous.id} status=${previous.status}',
      );
      // Re-assert the live call so consumers do not briefly treat the stream
      // as idle when native sync races a registration refresh.
      _callController.add(previous);
      _liveCallsController.add(remaining);
      return;
    }
    _activeCall = null;
    _callController.add(null);
    _liveCallsController.add(const []);
  }

  @override
  Future<void> unregister() async {
    Completer<void>? nativeUnregistered;
    StreamSubscription<SipRegistrationState>? unregisterSubscription;
    if (_initialized) {
      // Subscribe before invoking native code so a fast Cleared callback cannot
      // race past us. Always wait when the native bridge is initialized:
      // Flutter's cached registration state can lag a restored native account,
      // and purging that account immediately would leave its registrar contact
      // alive until expiry. Native emits an immediate unregistered event when
      // no account exists, so the idempotent case does not incur this timeout.
      nativeUnregistered = Completer<void>();
      unregisterSubscription = registrationStateStream.listen(
        (state) {
          if (state.status == SipRegistrationStatus.unregistered &&
              !nativeUnregistered!.isCompleted) {
            nativeUnregistered.complete();
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!nativeUnregistered!.isCompleted) {
            nativeUnregistered.completeError(error, stackTrace);
          }
        },
      );
    }
    try {
      await _platformChannel.unregister();
      if (nativeUnregistered != null) {
        await nativeUnregistered.future.timeout(const Duration(seconds: 5));
      }
    } on TimeoutException catch (error, stackTrace) {
      AppLogger.warning(
        'Timed out waiting for SIP unregister confirmation; '
        'native account purge and registrar expiry remain safety nets',
        data: error,
      );
      AppLogger.debug('SIP unregister timeout stack', data: stackTrace);
    } catch (_) {
      // Unregister must be idempotent so local reset/revoke can always finish.
    } finally {
      await unregisterSubscription?.cancel();
      _emitRegistration(
        SipRegistrationState(
          status: SipRegistrationStatus.unregistered,
          updatedAt: DateTime.now(),
        ),
      );
    }
  }

  @override
  Future<void> purgeAccount() async {
    try {
      // Disabling registration alone leaves the account in linphonerc. A
      // later push wake can otherwise restore and refresh the logged-out
      // identity. This method is called only for a real logout/reset, after
      // unregister has had a chance to reach the registrar.
      await _platformChannel.purgeAccount();
    } catch (error, stackTrace) {
      // Local logout must remain possible even if native cleanup fails. The
      // registrar binding will still expire and server reconciliation remains
      // a safety net.
      AppLogger.warning('Native SIP account purge failed', data: error);
      AppLogger.debug(
        'Native SIP account purge failure stack',
        data: stackTrace,
      );
    } finally {
      // Do not retain credentials or push configuration in Dart after logout.
      // This also makes any delayed registration retry fail closed.
      _config = null;
    }
  }

  @override
  Future<void> makeCall(String destination) async {
    final trimmed = destination.trim();
    if (trimmed.isEmpty) {
      throw const VoipException(
        message: 'Missing destination',
        userMessage: 'Enter a number or SIP address.',
      );
    }
    if (!_registrationState.isRegistered) {
      throw VoipException(
        message: 'SIP account is not registered',
        userMessage: _registrationState.message == null
            ? 'SIP is not registered. Open diagnostics and check provisioning.'
            : 'SIP is not registered: ${_registrationState.message}',
      );
    }
    final started = Stopwatch()..start();
    final placeholder = VoipCall(
      id: 'local-outgoing-${DateTime.now().microsecondsSinceEpoch}',
      remoteUri: trimmed,
      direction: CallDirection.outgoing,
      status: CallStatus.dialing,
      startedAt: DateTime.now(),
    );
    _knownCalls[placeholder.id] = placeholder;
    _activeCall = placeholder;
    _callController.add(placeholder);
    _liveCallsController.add(_orderedLiveCalls());
    _startWindowsCallReconciliation();
    _traceCall('make_call_requested', identity: trimmed);
    try {
      await _platformChannel.makeCall(trimmed);
      _traceCall(
        'make_call_native_accepted',
        identity: trimmed,
        detail: 'durationMs=${started.elapsedMilliseconds}',
      );
    } on PlatformException catch (error) {
      _clearOutgoingPlaceholder(placeholder);
      _traceCall(
        'make_call_failed',
        identity: trimmed,
        detail: 'durationMs=${started.elapsedMilliseconds} code=${error.code}',
        error: error,
      );
      final nativeMessage = error.message ?? '';
      if (error.code == 'TELECOM_UNAVAILABLE' &&
          nativeMessage.contains('previous call is still closing')) {
        throw const VoipException(
          message: 'Android Telecom is still releasing the previous call',
          userMessage: 'The previous call is still closing. Please try again.',
        );
      }
      throw VoipException(
        message: 'Native call start failed: ${error.code}',
        userMessage: nativeMessage.trim().isNotEmpty
            ? nativeMessage
            : 'Call could not start. Please try again.',
      );
    } on Object {
      _clearOutgoingPlaceholder(placeholder);
      rethrow;
    }
  }

  void _clearOutgoingPlaceholder(VoipCall placeholder) {
    _knownCalls.remove(placeholder.id);
    if (_activeCall?.id != placeholder.id) {
      return;
    }
    _activeCall = null;
    _publishCallState();
    _stopWindowsCallReconciliationIfIdle();
  }

  @override
  Future<void> syncPbxDndToggle() async {
    if (!_registrationState.isRegistered) {
      _pendingPbxDndToggle = !_pendingPbxDndToggle;
      _sipLog('warn', 'PBX DND toggle queued until SIP is registered');
      return;
    }
    if (_activeCall != null) {
      _pendingPbxDndToggle = !_pendingPbxDndToggle;
      _sipLog('info', 'PBX DND toggle queued until active call ends');
      return;
    }
    if (_featureCodeDialInFlight) {
      _pendingPbxDndToggle = !_pendingPbxDndToggle;
      _sipLog(
        'info',
        'PBX DND toggle queued while feature-code dial is in flight',
      );
      return;
    }
    await _dialPbxDndToggle();
  }

  Future<void> _dialPbxDndToggle() async {
    if (_featureCodeDialInFlight) {
      _pendingPbxDndToggle = !_pendingPbxDndToggle;
      return;
    }
    _featureCodeDialInFlight = true;
    _pendingPbxDndToggle = false;
    try {
      final id = await _platformChannel.dialFeatureCode(_pbxDndToggleCode);
      if (id != null && id.isNotEmpty) {
        _featureCodeCallIds.add(id);
        // Safety net if native never reports an ended event for this dial.
        Future<void>.delayed(const Duration(seconds: 20), () {
          if (!_featureCodeCallIds.contains(id)) {
            return;
          }
          _featureCodeCallIds.remove(id);
          if (_featureCodeCallIds.isEmpty) {
            _featureCodeDialInFlight = false;
            _flushPendingPbxDndToggleIfIdle();
          }
        });
      } else {
        _featureCodeDialInFlight = false;
      }
      _sipLog(
        'info',
        'PBX DND toggle dialed $_pbxDndToggleCode id=${id ?? 'unknown'}',
      );
    } on Object catch (error) {
      _featureCodeDialInFlight = false;
      _sipLog(
        'error',
        'PBX DND toggle dial failed: ${_nativeErrorMessage(error)}',
      );
      AppLogger.warning(
        'PBX DND toggle dial failed: ${_nativeErrorMessage(error)}',
      );
    }
  }

  void _flushPendingPbxDndToggleIfIdle() {
    if (!_pendingPbxDndToggle) {
      return;
    }
    if (!_registrationState.isRegistered ||
        _activeCall != null ||
        _featureCodeDialInFlight) {
      return;
    }
    unawaited(_dialPbxDndToggle());
  }

  @override
  Future<void> acceptCall(String callId) async {
    final call = _knownCalls[callId] ?? _activeCall;
    if (call == null ||
        call.id != callId ||
        call.direction != CallDirection.incoming ||
        call.status != CallStatus.ringing) {
      throw const VoipException(
        message: 'Incoming call is no longer available',
        userMessage: 'This call has already ended.',
      );
    }
    final current = _currentMediaCall(excluding: callId);
    if (current != null) {
      await hold(current.id);
      await _waitForCallStatus(
        current.id,
        (status) => status == CallStatus.held,
        operation: 'hold current call',
      );
    }
    try {
      await _traceCallAction(
        'answer',
        callId,
        () => _platformChannel.acceptCall(callId),
      );
    } catch (_) {
      if (current != null) {
        unawaited(resume(current.id));
      }
      rethrow;
    }
    // An accepted answer that subsequently fails to establish is not a missed
    // call—the user acted on it. Native active state reinforces this marker.
    _answeredIncomingCallIds.add(callId);
  }

  @override
  Future<void> endCurrentAndAcceptCall(String callId) async {
    final waiting = _knownCalls[callId];
    if (waiting == null ||
        waiting.direction != CallDirection.incoming ||
        waiting.status != CallStatus.ringing) {
      throw const VoipException(
        message: 'Incoming call is no longer available',
        userMessage: 'This call has already ended.',
      );
    }
    final current = _currentMediaCall(excluding: callId);
    if (current != null) {
      await endCall(current.id);
      await _waitForCallStatus(
        current.id,
        _isFinished,
        operation: 'end current call',
      );
    }
    await _traceCallAction(
      'answer_after_end',
      callId,
      () => _platformChannel.acceptCall(callId),
    );
    _answeredIncomingCallIds.add(callId);
  }

  @override
  Future<void> rejectCall(String callId) async {
    final call = _knownCalls[callId] ?? _activeCall;
    final isUserDecline =
        call?.id == callId &&
        call?.direction == CallDirection.incoming &&
        isDndEnabled?.call() != true &&
        !_dndRejectedCallIds.contains(callId);
    if (isUserDecline) _declinedIncomingCallIds.add(callId);
    try {
      await _traceCallAction(
        'reject',
        callId,
        () => _platformChannel.rejectCall(callId),
      );
    } catch (_) {
      if (isUserDecline) _declinedIncomingCallIds.remove(callId);
      rethrow;
    }
  }

  @override
  Future<void> endCall(String callId) async {
    await _traceCallAction(
      'end',
      callId,
      () => _platformChannel.endCall(callId),
    );
  }

  @override
  Future<void> mute(bool enabled) async {
    await _traceCallAction(
      enabled ? 'mute' : 'unmute',
      _activeCall?.id,
      () => _platformChannel.mute(enabled),
    );
    _updateActiveCall((call) => call.copyWith(isMuted: enabled));
  }

  @override
  Future<void> hold(String callId) async {
    // Wait for native Pausing/Paused events to update status — do not
    // optimistically mark held (a failed pause previously looked like a hangup).
    await _traceCallAction('hold', callId, () => _platformChannel.hold(callId));
  }

  @override
  Future<void> resume(String callId) async {
    await _traceCallAction(
      'resume',
      callId,
      () => _platformChannel.resume(callId),
    );
  }

  @override
  Future<void> switchToCall(String callId) async {
    final target = _knownCalls[callId];
    if (target == null || target.status != CallStatus.held) {
      throw const VoipException(
        message: 'Held call is no longer available',
        userMessage: 'The held call is no longer available.',
      );
    }
    final current = _currentMediaCall(excluding: callId);
    if (current != null) {
      await hold(current.id);
      await _waitForCallStatus(
        current.id,
        (status) => status == CallStatus.held,
        operation: 'hold current call',
      );
    }
    try {
      await resume(callId);
      await _waitForCallStatus(
        callId,
        (status) => status == CallStatus.active,
        operation: 'resume held call',
      );
    } catch (_) {
      if (current != null) unawaited(resume(current.id));
      rethrow;
    }
  }

  @override
  Future<void> setSpeaker(bool enabled) async {
    await setAudioRoute(
      enabled ? AudioOutputRoute.speaker : AudioOutputRoute.earpiece,
    );
  }

  @override
  Future<void> setBluetooth(bool enabled) async {
    await setAudioRoute(
      enabled ? AudioOutputRoute.bluetooth : AudioOutputRoute.earpiece,
    );
  }

  @override
  Future<bool> ensureBluetoothPermission() async {
    final granted = await _platformChannel.ensureBluetoothPermission();
    return granted == true;
  }

  @override
  Future<List<AudioOutputRouteOption>> getAudioRoutes() async {
    final routes = await _platformChannel.getAudioRoutes();
    return routes.map(AudioOutputRouteOption.fromPlatform).toList();
  }

  @override
  Future<void> setAudioRoute(AudioOutputRoute route, {String? endpointId}) {
    final operation = _audioRouteSerial.then<void>((_) async {
      await _applyAudioRoute(route, endpointId: endpointId);
    });
    // A failed or disconnected endpoint must not poison later selections.
    _audioRouteSerial = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  @override
  Future<void> setAudioInputDevice(String endpointId) {
    final operation = _audioRouteSerial.then<void>((_) async {
      await _platformChannel.setAudioInputDevice(endpointId);
      await _waitForAudioInput(endpointId);
    });
    _audioRouteSerial = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  @override
  Future<AudioVolumeLevels> getAudioVolumeLevels() async {
    final levels = await _platformChannel.getAudioVolumeLevels();
    return AudioVolumeLevels.fromPlatform(levels);
  }

  @override
  Future<void> setAudioVolume(AudioVolumeKind kind, int level) {
    return _platformChannel.setAudioVolume(
      kind.platformValue,
      level.clamp(0, 100),
    );
  }

  @override
  Future<void> playAudioTestSound() => _platformChannel.playAudioTestSound();

  @override
  Future<void> startAudioInputTest() => _platformChannel.startAudioInputTest();

  @override
  Future<double> getAudioInputLevel() => _platformChannel.getAudioInputLevel();

  @override
  Future<void> stopAudioInputTest() => _platformChannel.stopAudioInputTest();

  Future<void> _applyAudioRoute(
    AudioOutputRoute route, {
    String? endpointId,
  }) async {
    final previous = _activeCall;
    // Optimistic UI so the Audio control updates before native SCO settles.
    _updateActiveCall(
      (call) => call.copyWith(
        audioRoute: route,
        isSpeakerEnabled: route == AudioOutputRoute.speaker,
      ),
    );
    final started = Stopwatch()..start();
    _traceCall(
      'audio_route_requested',
      identity: previous?.id,
      detail:
          'route=${route.name} endpoint=${_diagnosticCorrelation(endpointId)}',
    );
    try {
      final routeValue = await _platformChannel.setAudioRoute(
        route.channelValue,
        endpointId: endpointId,
      );
      final activeRoute = AudioOutputRoute.tryParse(routeValue) ?? route;
      await _waitForAudioRoute(activeRoute, endpointId: endpointId);
      _updateActiveCall(
        (call) => call.copyWith(
          audioRoute: activeRoute,
          isSpeakerEnabled: activeRoute == AudioOutputRoute.speaker,
        ),
      );
      _traceCall(
        'audio_route_applied',
        identity: _activeCall?.id,
        detail:
            'route=${activeRoute.name} durationMs=${started.elapsedMilliseconds}',
      );
    } catch (error) {
      _traceCall(
        'audio_route_failed',
        identity: previous?.id,
        detail: 'route=${route.name} durationMs=${started.elapsedMilliseconds}',
        error: error,
      );
      if (previous != null) {
        _activeCall = previous;
        _callController.add(previous);
      }
      rethrow;
    }
  }

  Future<void> _waitForAudioRoute(
    AudioOutputRoute route, {
    String? endpointId,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    do {
      final endpoints = await getAudioRoutes();
      final outputEndpoints = endpoints
          .where((item) => item.direction == AudioDeviceDirection.output)
          .toList(growable: false);
      final reportsSelection = outputEndpoints.any((item) => item.selected);
      if (!reportsSelection) return;
      final confirmed = outputEndpoints.any(
        (item) =>
            item.selected &&
            (endpointId == null
                ? item.route == route
                : item.endpointId == endpointId),
      );
      if (confirmed) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } while (DateTime.now().isBefore(deadline));
    throw StateError(
      'The operating system did not activate the selected audio device.',
    );
  }

  Future<void> _waitForAudioInput(String endpointId) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    do {
      final endpoints = await getAudioRoutes();
      final inputs = endpoints
          .where((item) => item.direction == AudioDeviceDirection.input)
          .toList(growable: false);
      if (inputs.isEmpty || !inputs.any((item) => item.selected)) return;
      if (inputs.any(
        (item) => item.selected && item.endpointId == endpointId,
      )) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } while (DateTime.now().isBefore(deadline));
    throw StateError(
      'The operating system did not activate the selected microphone.',
    );
  }

  @override
  Future<void> sendDtmf(String value) {
    return _platformChannel.sendDtmf(value);
  }

  @override
  Future<CallQualityInfo> getCallQuality({String? callId}) async {
    final raw = await _platformChannel.getCallQuality(
      callId: callId ?? _activeCall?.id,
    );
    return CallQualityInfo.fromMap(raw);
  }

  @override
  Future<void> transferCall({
    required String callId,
    required String destination,
  }) {
    final trimmed = destination.trim();
    if (trimmed.isEmpty) {
      throw const VoipException(
        message: 'Missing transfer destination',
        userMessage: 'Choose a directory extension to transfer to.',
      );
    }
    final call = _activeCall;
    if (call == null || call.id != callId) {
      throw const VoipException(
        message: 'No active call to transfer',
        userMessage: 'There is no active call to transfer.',
      );
    }
    return _platformChannel.transferCall(callId: callId, destination: trimmed);
  }

  @override
  Future<void> sendMessage({
    required String destination,
    required String text,
  }) {
    final trimmedDestination = destination.trim();
    final trimmedText = text.trim();
    if (trimmedDestination.isEmpty || trimmedText.isEmpty) {
      throw const VoipException(
        message: 'Missing message destination or body',
        userMessage: 'Enter a destination and message.',
      );
    }
    return _platformChannel.sendMessage(
      destination: trimmedDestination,
      text: trimmedText,
    );
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _windowsCallReconciliationTimer?.cancel();
    _windowsCallReconciliationTimer = null;
    await _registrationSubscription?.cancel();
    await _callSubscription?.cancel();
    await _messageSubscription?.cancel();
    try {
      // Never stop the native core while a call is live — disposing mid-call
      // (provider rebuild / hot restart) would tear down the media session.
      final keepCoreAlive =
          (_activeCall != null && !_isFinished(_activeCall!.status)) ||
          await _platformChannel.hasActiveCall();
      if (!keepCoreAlive) {
        await _platformChannel.dispose();
      } else {
        AppLogger.warning('Skipping native SIP dispose while a call is active');
      }
    } catch (_) {
      // The native bridge may not exist in widget/unit tests.
    }
    await _registrationController.close();
    await _callController.close();
    await _liveCallsController.close();
    await _messageController.close();
  }

  Future<void> _configureNativeAccount(SipConfig config) {
    return _platformChannel.configureAccount({
      'extension': config.extension,
      'sipUsername': config.sipUsername,
      'authUsername': config.authUsername,
      'password': config.password,
      'ha1': config.ha1,
      'algorithm': config.algorithm,
      'realm': config.realm,
      'authDomain': config.authDomain,
      'domain': config.domain,
      'registrar': config.registrar,
      'outboundProxy': config.outboundProxy,
      'port': config.port,
      'transport': config.transport.name,
      'displayName': config.displayName,
      'stunServer': _stunServer,
      'turnServer': _turnServer,
      'pushProvider': config.pushConfig?.provider,
      'pushToken': config.pushConfig?.token,
      'pushParam': config.pushConfig?.param,
      'pushBundleId': config.pushConfig?.bundleId,
      'pushTeamId': config.pushConfig?.teamId,
    });
  }

  void _bindNativeEvents() {
    _registrationSubscription ??= _platformChannel.registrationEvents().listen(
      (event) {
        final state = _registrationFromEvent(event);
        _sipLog(
          'info',
          'Registration => ${state.status.name}'
              '${state.message == null || state.message!.isEmpty ? '' : ' · ${state.message}'}',
        );
        _emitRegistration(state);
        if (state.isRegistered) {
          _flushPendingPbxDndToggleIfIdle();
        }
      },
      onError: (Object error) {
        _sipLog(
          'error',
          'Registration stream error: ${_nativeErrorMessage(error)}',
        );
        _emitRegistration(
          SipRegistrationState(
            status: SipRegistrationStatus.failed,
            updatedAt: DateTime.now(),
            message: _nativeErrorMessage(error),
          ),
        );
      },
    );
    _callSubscription ??= _platformChannel.callEvents().listen(
      _handleNativeCallEvent,
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.error(
          'SIP call event stream error',
          error: error,
          stackTrace: stackTrace,
        );
        _sipLog('error', 'Call stream error: ${_nativeErrorMessage(error)}');
      },
    );
    _messageSubscription ??= _platformChannel.messageEvents().listen((event) {
      final message = SipMessage.fromPlatformEvent(event);
      _sipLog(
        'info',
        'Message => ${message.direction.name} ${message.status.name} to/from=${message.remoteUri}',
      );
      _messageController.add(message);
    });
  }

  void _handleNativeCallEvent(Map<String, dynamic> event) {
    final eventId = '${event['id'] ?? ''}';
    final stateMessage = _nullableString(event['stateMessage']);
    _traceCall(
      'native_call_event',
      identity: eventId,
      detail:
          'direction=${event['direction']} status=${event['status']} '
          'route=${event['audioRoute']} endpoints=${(event['availableEndpoints'] as Iterable?)?.length ?? 0} '
          'reason=${stateMessage ?? "none"}',
    );
    final nativeStatus = '${event['status']}'.trim().toLowerCase();
    if (nativeStatus == 'none' || nativeStatus == 'cleared') {
      _sipLog('debug', 'Call sync => none');
      _handleNativeCallCleared();
      _stopWindowsCallReconciliationIfIdle();
      return;
    }
    final call = _callFromEvent(event);
    _trackIncomingCallState(call);
    if (call.direction == CallDirection.incoming &&
        _isFinished(call.status) &&
        stateMessage?.toLowerCase().contains('declin') == true &&
        !_dndRejectedCallIds.contains(call.id)) {
      // Native system call UIs (CallKit, Android Telecom) can decline without
      // invoking Dart's rejectCall method. Linphone's terminal reason lets the
      // local history retain that explicit user action.
      _declinedIncomingCallIds.add(call.id);
    }
    _traceCall(
      'call_state_applied',
      identity: call.id,
      detail:
          'direction=${call.direction.name} status=${call.status.name} '
          'remoteCorr=${_diagnosticCorrelation(call.remoteUri)}',
    );
    _sipLog(
      'info',
      'Call => id=${call.id} ${call.direction.name} ${call.status.name} '
          'remote=${call.remoteUri} reason=${stateMessage ?? "none"}',
    );
    final isFeatureCode = _isFeatureCodeCallEvent(event, call);
    if (isFeatureCode) {
      _featureCodeCallIds.add(call.id);
      // Clear any leaked in-call UI if an earlier event slipped through.
      if (_activeCall?.id == call.id) {
        _activeCall = null;
        _callController.add(null);
      }
      if (_isFinished(call.status)) {
        _featureCodeCallIds.remove(call.id);
        _featureCodeDialInFlight = false;
        _flushPendingPbxDndToggleIfIdle();
      }
      // No activeCall emit and no history for PBX feature-code dials.
      _stopWindowsCallReconciliationIfIdle();
      return;
    }
    if (_shouldSuppressIncoming(call)) {
      final isNewReject = _dndRejectedCallIds.add(call.id);
      _knownCalls[call.id] = call;
      if (isNewReject) {
        AppLogger.info(
          'DND enabled => auto-rejecting incoming call id=${call.id}',
        );
        _sipLog('warn', 'DND auto-reject incoming id=${call.id}');
        unawaited(rejectCall(call.id));
      }
      _publishCallState();
      _stopWindowsCallReconciliationIfIdle();
      return;
    }
    _recordCallState(call);
    final previousActive = _activeCall;
    _publishCallState();
    if (_activeCall == null && call.answeredElsewhere) {
      // Let the router/incoming screen present the meaningful completion before
      // publishing the normal idle state.
      _callController.add(call);
      scheduleMicrotask(() {
        if (!_disposed && _activeCall == null) _callController.add(null);
      });
    }
    if (_activeCall == null) {
      _stopWindowsCallReconciliationIfIdle();
    } else {
      _startWindowsCallReconciliation();
    }
    if (previousActive != null && _isFinished(call.status)) {
      final held = _orderedLiveCalls()
          .where((candidate) => candidate.status == CallStatus.held)
          .toList(growable: false);
      final hasMediaCall = _currentMediaCall() != null;
      final hasRinging = _orderedLiveCalls().any(
        (candidate) => candidate.status == CallStatus.ringing,
      );
      if (!hasMediaCall && !hasRinging && held.length == 1) {
        unawaited(_resumeAfterPeerEnded(held.single.id));
      } else if (_activeCall == null) {
        _flushPendingPbxDndToggleIfIdle();
      }
    }
  }

  List<VoipCall> _orderedLiveCalls() {
    final calls = _knownCalls.values
        .where(
          (call) =>
              !_isFinished(call.status) &&
              !_featureCodeCallIds.contains(call.id) &&
              !_dndRejectedCallIds.contains(call.id),
        )
        .toList(growable: false);
    int priority(VoipCall call) => switch (call.status) {
      CallStatus.ringing => 0,
      CallStatus.active => 1,
      CallStatus.connecting || CallStatus.dialing => 2,
      CallStatus.held => 3,
      _ => 4,
    };
    calls.sort((a, b) {
      final byStatus = priority(a).compareTo(priority(b));
      if (byStatus != 0) return byStatus;
      return a.startedAt.compareTo(b.startedAt);
    });
    return List.unmodifiable(calls);
  }

  void _publishCallState() {
    final calls = _orderedLiveCalls();
    _activeCall = calls.isEmpty ? null : calls.first;
    _liveCallsController.add(calls);
    _callController.add(_activeCall);
  }

  VoipCall? _currentMediaCall({String? excluding}) {
    for (final call in _knownCalls.values) {
      if (call.id == excluding || _isFinished(call.status)) continue;
      if (call.status == CallStatus.active ||
          call.status == CallStatus.connecting ||
          call.status == CallStatus.dialing) {
        return call;
      }
    }
    return null;
  }

  Future<void> _waitForCallStatus(
    String callId,
    bool Function(CallStatus status) predicate, {
    required String operation,
  }) async {
    final current = _knownCalls[callId];
    if (current != null && predicate(current.status)) return;
    final completer = Completer<void>();
    late final StreamSubscription<List<VoipCall>> subscription;
    subscription = liveCallsStream.listen((_) {
      final call = _knownCalls[callId];
      if (call != null && predicate(call.status) && !completer.isCompleted) {
        completer.complete();
      }
    });
    try {
      await completer.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw VoipException(
          message: 'Timed out waiting to $operation',
          userMessage: 'The call could not be changed. Please try again.',
        ),
      );
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> _resumeAfterPeerEnded(String callId) async {
    try {
      await resume(callId);
    } catch (error) {
      AppLogger.warning('Unable to resume held call after peer ended: $error');
    }
  }

  bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  void _startWindowsCallReconciliation() {
    if (!_isWindows || _windowsCallReconciliationTimer != null) {
      return;
    }
    _windowsCallReconciliationTimer = Timer.periodic(
      const Duration(milliseconds: 750),
      (_) => unawaited(_reconcileWindowsCall()),
    );
  }

  void _stopWindowsCallReconciliationIfIdle() {
    if (_activeCall != null && !_isFinished(_activeCall!.status)) {
      return;
    }
    _windowsCallReconciliationTimer?.cancel();
    _windowsCallReconciliationTimer = null;
  }

  Future<void> _reconcileWindowsCall() async {
    if (_windowsSyncInFlight) {
      return;
    }
    _windowsSyncInFlight = true;
    try {
      final snapshot = await _platformChannel.syncCurrentCall();
      if (snapshot != null) {
        _handleNativeCallEvent(snapshot);
      }
    } on Object catch (error) {
      _sipLog('debug', 'Windows call reconciliation skipped: $error');
    } finally {
      _windowsSyncInFlight = false;
    }
  }

  void _sipLog(String level, String message) {
    final store = _sipLogStore;
    if (store == null || !store.isEnabled) {
      return;
    }
    store.append(level: level, source: 'sip', message: message);
  }

  SipRegistrationState _registrationFromEvent(Map<String, dynamic> event) {
    final status = _registrationStatus('${event['status']}');
    final message = _nullableString(event['message']);
    AppLogger.debug(
      'SIP registration event => status=$status, message=${message ?? "null"}',
    );
    if (status == SipRegistrationStatus.failed) {
      final config = _config;
      if (config != null) {
        _logConfig('registration-failed', config);
      }
    }
    return SipRegistrationState(
      status: status,
      updatedAt: DateTime.now(),
      message: message,
    );
  }

  VoipCall _callFromEvent(Map<String, dynamic> event) {
    final id = _string(event['id'], fallback: 'native-call');
    final status = _callStatus('${event['status']}');
    final direction = _callDirection('${event['direction']}');
    final eventRemoteUri = _string(event['remoteUri']);
    final eventStartedAt = _date(event['startedAt']);
    final previous =
        _knownCalls[id] ??
        _promotePreviousCallIdentity(
          newId: id,
          direction: direction,
          remoteUri: eventRemoteUri,
          startedAt: eventStartedAt,
        );
    final endedAt = _date(event['endedAt']);
    final parsedRoute = AudioOutputRoute.tryParse(
      _nullableString(event['audioRoute']),
    );
    final hasSpeakerFlag = event.containsKey('isSpeakerEnabled');
    final hasMutedFlag = event.containsKey('isMuted');
    final rawEndpoints = event['availableEndpoints'];
    final availableEndpoints = rawEndpoints is Iterable
        ? rawEndpoints
              .whereType<Map>()
              .map(
                (value) => AudioOutputRouteOption.fromPlatform(
                  Map<String, dynamic>.from(value),
                ),
              )
              .toList(growable: false)
        : (previous?.availableAudioEndpoints ?? const []);
    final audioRoute =
        parsedRoute ??
        (hasSpeakerFlag && event['isSpeakerEnabled'] == true
            ? AudioOutputRoute.speaker
            : null) ??
        previous?.audioRoute ??
        AudioOutputRoute.earpiece;

    return VoipCall(
      id: id,
      remoteUri: _string(
        event['remoteUri'],
        fallback: previous?.remoteUri ?? '',
      ),
      remoteDisplayName:
          _nullableString(event['remoteDisplayName']) ??
          previous?.remoteDisplayName,
      direction: direction,
      status: status,
      startedAt: previous?.startedAt ?? eventStartedAt ?? DateTime.now(),
      endedAt: endedAt ?? (_isFinished(status) ? DateTime.now() : null),
      isMuted: hasMutedFlag
          ? event['isMuted'] == true
          : (previous?.isMuted ?? false),
      isSpeakerEnabled: hasSpeakerFlag
          ? event['isSpeakerEnabled'] == true
          : audioRoute == AudioOutputRoute.speaker,
      audioRoute: audioRoute,
      audioEndpointId:
          _nullableString(event['currentEndpointId']) ??
          previous?.audioEndpointId,
      availableAudioEndpoints: availableEndpoints,
      answeredElsewhere:
          previous?.answeredElsewhere == true ||
          event['answeredElsewhere'] == true ||
          isAnsweredElsewhereReason(_nullableString(event['stateMessage'])),
    );
  }

  /// Linphone can emit an outgoing call with an object-derived temporary ID
  /// before its SIP Call-ID exists, then switch to the authoritative Call-ID
  /// on the next event. Treat that as identity promotion for the same session,
  /// not as a second call. Otherwise the visible Flutter panel remains bound
  /// to stale controls while CallKit owns the promoted call.
  VoipCall? _promotePreviousCallIdentity({
    required String newId,
    required CallDirection direction,
    required String remoteUri,
    required DateTime? startedAt,
  }) {
    final candidate = _activeCall;
    if (candidate == null ||
        candidate.id == newId ||
        _isFinished(candidate.status) ||
        candidate.direction != direction) {
      return null;
    }

    final previousRemote = _displayNumber(candidate.remoteUri).toLowerCase();
    final nextRemote = _displayNumber(remoteUri).toLowerCase();
    if (previousRemote.isEmpty ||
        nextRemote.isEmpty ||
        previousRemote != nextRemote) {
      return null;
    }

    if (startedAt != null &&
        startedAt.difference(candidate.startedAt).abs() >
            const Duration(seconds: 30)) {
      return null;
    }

    _knownCalls.remove(candidate.id);
    if (_featureCodeCallIds.remove(candidate.id)) {
      _featureCodeCallIds.add(newId);
    }
    if (_dndRejectedCallIds.remove(candidate.id)) {
      _dndRejectedCallIds.add(newId);
    }
    if (_ringingIncomingCallIds.remove(candidate.id)) {
      _ringingIncomingCallIds.add(newId);
    }
    if (_answeredIncomingCallIds.remove(candidate.id)) {
      _answeredIncomingCallIds.add(newId);
    }
    if (_declinedIncomingCallIds.remove(candidate.id)) {
      _declinedIncomingCallIds.add(newId);
    }
    AppLogger.info(
      'Promoted active native call identity ${candidate.id} -> $newId',
    );
    return candidate;
  }

  void _updateActiveCall(VoipCall Function(VoipCall call) update) {
    final call = _activeCall;
    if (call == null) {
      return;
    }
    final updated = update(call);
    _knownCalls[updated.id] = updated;
    _activeCall = updated;
    _callController.add(updated);
    _liveCallsController.add(_orderedLiveCalls());
  }

  bool _shouldSuppressIncoming(VoipCall call) {
    if (call.direction != CallDirection.incoming ||
        call.status != CallStatus.ringing) {
      return false;
    }
    return isDndEnabled?.call() == true ||
        _dndRejectedCallIds.contains(call.id);
  }

  void _trackIncomingCallState(VoipCall call) {
    if (call.direction != CallDirection.incoming) {
      return;
    }
    if (call.status == CallStatus.ringing) {
      _ringingIncomingCallIds.add(call.id);
    }
    if (call.status == CallStatus.active || call.status == CallStatus.held) {
      _answeredIncomingCallIds.add(call.id);
    }
  }

  /// Silent PBX feature-code dials (*76 DND, etc.) must never drive in-call UI
  /// or call history. Native may clear its feature-code set before emitting End,
  /// and Call-IDs can change between dialFeatureCode's return value and SIP events.
  bool _isFeatureCodeCallEvent(Map<String, dynamic> event, VoipCall call) {
    if (event['featureCode'] == true) {
      return true;
    }
    if (_featureCodeCallIds.contains(call.id)) {
      return true;
    }
    if (_featureCodeDialInFlight && _looksLikePbxFeatureCode(call)) {
      return true;
    }
    return false;
  }

  bool _looksLikePbxFeatureCode(VoipCall call) {
    if (call.direction != CallDirection.outgoing) {
      return false;
    }
    final display = call.remoteDisplayName?.trim() ?? '';
    if (display.startsWith('*') || display.startsWith('#')) {
      return true;
    }
    final remote = call.remoteUri.trim().toLowerCase();
    final match = RegExp(r'(?:sips?:)?([^@;>\s]+)').firstMatch(remote);
    final user = match?.group(1) ?? '';
    return user.startsWith('*') || user.startsWith('#');
  }

  void _recordCallState(VoipCall call) {
    if (_featureCodeCallIds.contains(call.id) ||
        (_featureCodeDialInFlight && _looksLikePbxFeatureCode(call))) {
      return;
    }
    final previous = _knownCalls[call.id];
    _knownCalls[call.id] = call;
    if (!_isFinished(call.status)) {
      return;
    }
    final upgradesAnsweredElsewhere =
        previous != null &&
        _isFinished(previous.status) &&
        !previous.answeredElsewhere &&
        call.answeredElsewhere;
    if (previous != null &&
        _isFinished(previous.status) &&
        !upgradesAnsweredElsewhere) {
      return;
    }
    final repository = _callHistoryRepository;
    if (repository == null) {
      return;
    }
    final wasDndReject = _dndRejectedCallIds.remove(call.id);
    final wasDeclined = _declinedIncomingCallIds.remove(call.id);
    final classification = classifyCompletedCall(
      direction: call.direction,
      status: call.status,
      wasRinging: _ringingIncomingCallIds.remove(call.id),
      wasAnswered: _answeredIncomingCallIds.remove(call.id),
      wasDndRejected: wasDndReject,
      wasDeclined: wasDeclined,
      wasAnsweredElsewhere: call.answeredElsewhere,
    );
    unawaited(
      repository
          .syncCallLog(
            remoteNumber: _displayNumber(call.remoteUri),
            remoteDisplayName: call.remoteDisplayName,
            direction: classification.direction,
            status: classification.status,
            disposition: classification.disposition,
            startedAt: call.startedAt,
            endedAt: call.endedAt ?? DateTime.now(),
            sipCallId: call.id,
          )
          .whenComplete(() {
            if (!_disposed) _onCallHistoryChanged?.call();
          }),
    );
  }

  void _emitRegistration(SipRegistrationState state) {
    _registrationState = state;
    _registrationController.add(state);
  }

  Future<void> _traceCallAction(
    String action,
    String? callId,
    Future<void> Function() operation,
  ) async {
    final started = Stopwatch()..start();
    _traceCall(
      '${action}_requested',
      identity: callId,
      detail: 'state=${_activeCall?.status.name ?? 'none'}',
    );
    try {
      await operation();
      _traceCall(
        '${action}_native_accepted',
        identity: callId,
        detail:
            'durationMs=${started.elapsedMilliseconds} '
            'state=${_activeCall?.status.name ?? 'none'}',
      );
    } catch (error) {
      _traceCall(
        '${action}_failed',
        identity: callId,
        detail: 'durationMs=${started.elapsedMilliseconds}',
        error: error,
      );
      rethrow;
    }
  }

  void _traceCall(
    String event, {
    String? identity,
    String? detail,
    Object? error,
  }) {
    final sequence = ++_callTraceSequence;
    final message =
        'CallTrace/flutter seq=$sequence '
        't=${_callTraceClock.elapsedMilliseconds}ms event=$event '
        'corr=${_diagnosticCorrelation(identity)}'
        '${detail == null || detail.isEmpty ? '' : ' $detail'}';
    if (error == null) {
      AppLogger.info(message);
    } else {
      AppLogger.error(message, error: error);
    }
  }

  void _logConfig(String phase, SipConfig config) {
    AppLogger.debug(
      'SIP config [$phase] => identity=${config.sipIdentity}, '
      'domain=${config.domain}, registrar=${config.registrar}, '
      'transport=${config.transport.name}, '
      'pushProvider=${config.pushConfig?.provider ?? "none"}, '
      'pushConfigured=${config.pushConfig?.token.isNotEmpty == true}',
    );
  }
}

String _diagnosticCorrelation(String? value) {
  final normalized = value?.trim().toLowerCase() ?? '';
  if (normalized.isEmpty) return 'none';
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(normalized)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

bool _isFinished(CallStatus status) {
  return switch (status) {
    CallStatus.ended || CallStatus.missed || CallStatus.failed => true,
    _ => false,
  };
}

String _displayNumber(String value) {
  var text = value.trim();
  final lower = text.toLowerCase();
  final sipsIndex = lower.indexOf('sips:');
  final sipIndex = lower.indexOf('sip:');
  if (sipsIndex >= 0) {
    text = text.substring(sipsIndex + 5);
  } else if (sipIndex >= 0) {
    text = text.substring(sipIndex + 4);
  }

  text = text
      .replaceAll('<', '')
      .replaceAll('>', '')
      .replaceAll('"', '')
      .split(';')
      .first
      .split('?')
      .first
      .trim();
  if (text.contains('@')) {
    text = text.split('@').first.trim();
  }

  try {
    text = Uri.decodeComponent(text);
  } on ArgumentError {
    // Preserve malformed SIP user parts best-effort.
  } on FormatException {
    // Preserve malformed SIP user parts best-effort.
  }

  final compact = text.replaceAll(RegExp(r'\s+'), '');
  if (_prefixedRemoteIdentifier.hasMatch(compact)) {
    return compact;
  }

  final allowed = RegExp(r'[0-9+*#,]');
  final number = compact
      .split('')
      .where((char) => allowed.hasMatch(char))
      .join();
  return number.isEmpty ? compact : number;
}

final _prefixedRemoteIdentifier = RegExp(
  r'^[A-Za-z][A-Za-z0-9._-]*:[+*#0-9][A-Za-z0-9+*#,._-]*$',
);

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

String _nativeErrorMessage(Object error) {
  final text = '$error';
  if (text.contains('MissingPluginException')) {
    return 'Linphone native bridge is not installed for this platform.';
  }
  if (text.contains('LINPHONE_NOT_LINKED')) {
    return 'Linphone iOS SDK is not linked in this build.';
  }
  if (text.contains('PlatformException')) {
    final match = RegExp(
      r'PlatformException\([^,]+,\s*([^,]+)',
    ).firstMatch(text);
    return match?.group(1)?.trim() ?? 'Linphone native operation failed.';
  }
  return 'Linphone operation failed.';
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
  if (value is num) {
    final raw = value.toInt();
    final millis = raw < 10000000000 ? raw * 1000 : raw;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }
  final text = '$value'.trim();
  final numeric = int.tryParse(text);
  if (numeric != null) {
    final millis = numeric < 10000000000 ? numeric * 1000 : numeric;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }
  return DateTime.tryParse(text);
}
