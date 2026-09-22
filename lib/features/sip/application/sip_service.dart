import '../../calls/domain/audio_output_route.dart';
import '../../calls/domain/audio_volume_levels.dart';
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

  /// All non-terminal SIP calls known to this device. At most one call may be
  /// active; another may be ringing or held.
  List<VoipCall> get liveCalls;

  Stream<List<VoipCall>> get liveCallsStream;

  Stream<SipMessage> get messageStream;

  Future<void> makeCall(String destination);

  /// Silently dial the PBX-wide DND feature toggle. No in-call UI or history.
  Future<void> syncPbxDndToggle();

  Future<void> endCall(String callId);

  Future<void> acceptCall(String callId);

  /// Ends any other active call before accepting [callId].
  Future<void> endCurrentAndAcceptCall(String callId);

  Future<void> rejectCall(String callId);

  Future<void> mute(bool enabled);

  Future<void> hold(String callId);

  Future<void> resume(String callId);

  /// Atomically holds the current media call and resumes [callId].
  Future<void> switchToCall(String callId);

  Future<void> setSpeaker(bool enabled);

  Future<bool> ensureBluetoothPermission();

  Future<List<AudioOutputRouteOption>> getAudioRoutes();

  Future<void> setAudioRoute(AudioOutputRoute route, {String? endpointId});

  Future<void> setAudioInputDevice(String endpointId);

  /// Returns VoipCloud's app-local desktop audio levels (0...100).
  Future<AudioVolumeLevels> getAudioVolumeLevels();

  /// Changes one app-local desktop audio level without changing system volume.
  Future<void> setAudioVolume(AudioVolumeKind kind, int level);

  /// Plays a short, local sound through the configured desktop output.
  Future<void> playAudioTestSound();

  /// Starts a temporary desktop microphone meter without retaining audio.
  Future<void> startAudioInputTest();

  /// Returns the current normalized microphone activity in the range 0...1.
  Future<double> getAudioInputLevel();

  /// Releases all resources used by the temporary microphone meter.
  Future<void> stopAudioInputTest();

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
