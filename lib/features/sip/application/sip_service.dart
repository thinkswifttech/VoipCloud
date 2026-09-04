import '../../calls/domain/audio_output_route.dart';
import '../../calls/domain/call_quality_info.dart';
import '../../calls/domain/voip_call.dart';
import '../domain/sip_message.dart';
import '../domain/sip_config.dart';
import '../domain/sip_registration_state.dart';

abstract class SipService {
  Future<void> initialize(SipConfig config);

  Future<void> register();

  Future<void> syncCurrentCall();

  Future<bool> hasActiveCall();

  Future<void> unregister();

  /// Permanently removes the native SIP identity after an account logout.
  ///
  /// This is intentionally separate from [unregister], which is also used for
  /// temporary registration changes and diagnostics.
  Future<void> purgeAccount();

  Future<void> refreshConfig(SipConfig config);

  SipConfig? get currentConfig;

  SipRegistrationState getRegistrationState();

  Stream<SipRegistrationState> get registrationStateStream;

  VoipCall? get activeCall;

  Stream<VoipCall?> get callStateStream;

  Stream<SipMessage> get messageStream;

  Future<void> makeCall(String destination);

  /// Silently dial a PBX feature code (*76 DND toggle). No in-call UI / history.
  Future<void> syncPbxDndToggle();

  Future<void> endCall(String callId);

  Future<void> acceptCall(String callId);

  Future<void> rejectCall(String callId);

  Future<void> mute(bool enabled);

  Future<void> hold(String callId);

  Future<void> resume(String callId);

  Future<void> setSpeaker(bool enabled);

  Future<bool> ensureBluetoothPermission();

  Future<List<AudioOutputRouteOption>> getAudioRoutes();

  Future<void> setAudioRoute(AudioOutputRoute route, {String? endpointId});

  Future<void> setBluetooth(bool enabled);

  Future<void> sendDtmf(String value);

  Future<CallQualityInfo> getCallQuality({String? callId});

  Future<void> transferCall({
    required String callId,
    required String destination,
  });

  Future<void> sendMessage({required String destination, required String text});

  Future<void> dispose();
}
