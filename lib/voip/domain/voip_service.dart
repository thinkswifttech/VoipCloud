import '../../features/calls/domain/voip_call.dart';
import 'sip_account.dart';
import 'sip_registration_state.dart';

abstract class VoipService {
  Future<void> initialize();

  Future<void> configureAccount(SipAccount account);

  Future<void> register();

  Future<void> unregister();

  Future<void> makeCall(String destination);

  Future<void> acceptCall(String callId);

  Future<void> declineCall(String callId);

  Future<void> endCall(String callId);

  Future<void> mute(bool enabled);

  Future<void> setSpeaker(bool enabled);

  SipRegistrationState get currentRegistrationState;

  VoipCall? get activeCall;

  Stream<SipRegistrationState> get registrationStateStream;

  Stream<VoipCall?> get callStateStream;

  Future<void> dispose();
}
