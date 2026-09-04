import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/dio_provider.dart';
import '../domain/sip_account.dart';
import '../domain/sip_provisioning_repository.dart';
import '../domain/sip_registration_state.dart';
import '../domain/voip_service.dart';
import '../linphone/linphone_voip_service.dart';
import 'api_sip_provisioning_repository.dart';

final sipProvisioningRepositoryProvider = Provider<SipProvisioningRepository>((
  ref,
) {
  return ApiSipProvisioningRepository(ref.watch(appClientProvider));
});

final sipAccountProvider = FutureProvider<SipAccount?>((ref) {
  return ref.watch(sipProvisioningRepositoryProvider).getSipAccount();
});

final voipServiceProvider = Provider<VoipService>((ref) {
  final service = LinphoneVoipService();
  ref.onDispose(() {
    unawaited(service.dispose());
  });
  return service;
});

final registrationStateProvider = StreamProvider<SipRegistrationState>((ref) {
  final service = ref.watch(voipServiceProvider);
  return service.registrationStateStream;
});

final activeCallProvider = StreamProvider((ref) {
  final service = ref.watch(voipServiceProvider);
  return service.callStateStream;
});
