import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/config/config_providers.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/errors/failure.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/dio_provider.dart';
import '../../../core/storage/storage_providers.dart';
import '../../call_history/presentation/call_history_providers.dart';
import '../../calls/domain/voip_call.dart';
import '../../contacts/presentation/quick_dial_providers.dart';
import '../../settings/presentation/settings_controller.dart';
import '../../messages/data/messaging_providers.dart';
import '../../messages/domain/carrier_messaging_config.dart';
import '../../sip/application/sip_service.dart';
import '../../directory/data/directory_repository.dart';
import '../../sip/application/linphone_sip_service.dart';
import '../../sip/application/sip_push_token_service.dart';
import '../../sip/domain/sip_routing.dart';
import '../../sip/domain/sip_config.dart';
import '../../sip/domain/sip_registration_state.dart';
import '../../sip/presentation/sip_log_providers.dart';
import '../data/app_config_repository.dart';
import '../data/device_info_repository.dart';
import '../data/device_credential_repository.dart';
import '../data/secure_session_storage.dart';
import '../domain/app_session.dart';

final secureSessionStorageProvider = Provider<SecureSessionStorage>((ref) {
  return SecureSessionStorage(ref.watch(secureStorageProvider));
});

final appConfigRepositoryProvider = Provider<AppConfigRepository>((ref) {
  return AppConfigRepository(ref.watch(appClientProvider));
});

final deviceInfoRepositoryProvider = Provider<DeviceInfoRepository>((ref) {
  return DeviceInfoRepository(
    storage: ref.watch(secureStorageProvider),
    client: ref.watch(appClientProvider),
  );
});

final sipServiceProvider = Provider<SipService>((ref) {
  final config = ref.watch(appConfigProvider);
  // Read (don't watch) stable dependencies so incidental provider churn never
  // disposes the SIP service mid-call (native dispose stops the Linphone core).
  final service = LinphoneSipService(
    callHistoryRepository: ref.read(callHistoryRepositoryProvider),
    stunServer: config.stunServer,
    turnServer: config.turnServer,
    isDndEnabled: () => ref.read(settingsControllerProvider).dndEnabled,
    sipLogStore: ref.read(sipLogStoreProvider),
  );
  ref.onDispose(() {
    unawaited(service.dispose());
  });
  AppLogger.debug('SipServiceProvider initialized');
  return service;
});

final sipPushTokenServiceProvider = Provider<SipPushTokenService>((ref) {
  return const SipPushTokenService();
});

final sipRegistrationStateProvider = StreamProvider((ref) {
  final service = ref.watch(sipServiceProvider);
  return Stream<SipRegistrationState>.multi((controller) {
    controller.add(service.getRegistrationState());
    final subscription = service.registrationStateStream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = subscription.cancel;
  });
});

final activeCallProvider = StreamProvider((ref) {
  final service = ref.watch(sipServiceProvider);
  return Stream<VoipCall?>.multi((controller) {
    final currentCall = service.activeCall;
    AppLogger.info(
      'Active call provider subscribed initial=${_callLogSummary(currentCall)}',
    );
    controller.add(currentCall);
    final subscription = service.callStateStream.listen(
      (call) {
        AppLogger.info('Active call provider event=${_callLogSummary(call)}');
        controller.add(call);
      },
      onError: controller.addError,
      onDone: controller.close,
    );
    unawaited(service.syncCurrentCall());
    controller.onCancel = () {
      AppLogger.info('Active call provider cancelled');
      return subscription.cancel();
    };
  });
});

final sipMessagesProvider = StreamProvider((ref) {
  return ref.watch(sipServiceProvider).messageStream;
});

final sessionControllerProvider =
    AsyncNotifierProvider<SessionController, AppSession?>(
      SessionController.new,
    );

class SessionController extends AsyncNotifier<AppSession?> {
  Timer? _registrationRetryTimer;

  @override
  Future<AppSession?> build() {
    ref.onDispose(() => _registrationRetryTimer?.cancel());
    return ref.watch(secureSessionStorageProvider).readSession();
  }

  Future<AppSession?> restoreAndRefresh() async {
    state = const AsyncLoading();
    final storage = ref.read(secureSessionStorageProvider);
    final stored = await storage.readSession();
    if (stored == null) {
      state = const AsyncData(null);
      return null;
    }

    // Bring SIP up from the cached session before any backend round-trip so an
    // already-ringing native call can route while config refresh continues.
    await _syncSip(stored);
    state = AsyncData(stored);
    if (await ref.read(sipServiceProvider).hasActiveCall()) {
      AppLogger.info(
        'Startup fast-path: active call present after local SIP sync; '
        'deferring config refresh',
      );
      unawaited(_refreshConfigInBackground(stored));
      return stored;
    }

    try {
      if (!stored.hasBackendSession) {
        return stored;
      }
      final snapshot = await ref.read(appConfigRepositoryProvider).getConfig();
      final refreshed = stored.copyWith(
        user: snapshot.user,
        service: snapshot.service,
        device: snapshot.device,
        provisioning: snapshot.provisioning,
        sipConfig: snapshot.sipConfig ?? stored.sipConfig,
        carrierMessaging: snapshot.carrierMessaging ?? stored.carrierMessaging,
        clearSipConfig:
            snapshot.service.blocksSip ||
            snapshot.device.revoked ||
            snapshot.device.requiresProvisioning ||
            snapshot.provisioning.requiresProvisioning,
      );
      await storage.writeSession(refreshed);
      if (_sipIdentityChanged(stored, refreshed)) {
        await _syncSip(refreshed);
      }
      state = AsyncData(refreshed);
      return refreshed;
    } on ApiException catch (error, stackTrace) {
      if (error.statusCode == 401) {
        await resetLocal();
        return null;
      }
      // Keep the local session usable if refresh fails after SIP is already up.
      AppLogger.error(
        'Config refresh failed after local SIP restore',
        error: error,
        stackTrace: stackTrace,
      );
      return stored;
    } catch (error, stackTrace) {
      AppLogger.error(
        'Config refresh failed after local SIP restore',
        error: error,
        stackTrace: stackTrace,
      );
      return stored;
    }
  }

  Future<void> _refreshConfigInBackground(AppSession stored) async {
    if (!stored.hasBackendSession) {
      return;
    }
    try {
      final snapshot = await ref.read(appConfigRepositoryProvider).getConfig();
      final refreshed = stored.copyWith(
        user: snapshot.user,
        service: snapshot.service,
        device: snapshot.device,
        provisioning: snapshot.provisioning,
        sipConfig: snapshot.sipConfig ?? stored.sipConfig,
        clearSipConfig:
            snapshot.service.blocksSip ||
            snapshot.device.revoked ||
            snapshot.device.requiresProvisioning ||
            snapshot.provisioning.requiresProvisioning,
      );
      await ref.read(secureSessionStorageProvider).writeSession(refreshed);
      if (!await ref.read(sipServiceProvider).hasActiveCall() &&
          _sipIdentityChanged(stored, refreshed)) {
        await _syncSip(refreshed);
      }
      state = AsyncData(refreshed);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Background config refresh after call wake failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  bool _sipIdentityChanged(AppSession previous, AppSession next) {
    final previousSip = previous.sipConfig;
    final nextSip = next.sipConfig;
    if (previousSip == null || nextSip == null) {
      return previousSip != nextSip;
    }
    return previousSip.sipIdentity != nextSip.sipIdentity ||
        previousSip.password != nextSip.password ||
        previousSip.domain != nextSip.domain ||
        previousSip.outboundProxy != nextSip.outboundProxy;
  }

  Future<void> setProvisionedSession(AppSession session) async {
    await ref.read(secureSessionStorageProvider).writeSession(session);
    await _syncSip(session);
    state = AsyncData(session);
  }

  Future<void> setCarrierMessagingConfig(CarrierMessagingConfig config) async {
    final current = state.value;
    if (current == null) return;
    final updated = current.copyWith(carrierMessaging: config);
    await ref.read(secureSessionStorageProvider).writeSession(updated);
    state = AsyncData(updated);
  }

  Future<Failure?> refreshConfig() async {
    final current = state.value;
    if (current == null) {
      return const Failure(userMessage: 'No active app session.');
    }
    if (!current.hasBackendSession) {
      await _syncSip(current);
      return null;
    }

    final result = await AsyncValue.guard(() async {
      final snapshot = await ref.read(appConfigRepositoryProvider).getConfig();
      final refreshed = current.copyWith(
        user: snapshot.user,
        service: snapshot.service,
        device: snapshot.device,
        provisioning: snapshot.provisioning,
        sipConfig: snapshot.sipConfig ?? current.sipConfig,
        carrierMessaging: snapshot.carrierMessaging ?? current.carrierMessaging,
        clearSipConfig:
            snapshot.service.blocksSip ||
            snapshot.device.revoked ||
            snapshot.device.requiresProvisioning ||
            snapshot.provisioning.requiresProvisioning,
      );
      await ref.read(secureSessionStorageProvider).writeSession(refreshed);
      await _syncSip(refreshed);
      return refreshed;
    });

    state = result;
    return result.hasError
        ? Failure.fromException(result.error!, result.stackTrace)
        : null;
  }

  Future<void> logout() async {
    try {
      await ref.read(appClientProvider).post<void>(ApiEndpoints.appLogout);
    } catch (_) {
      // The local reset still needs to complete if the backend session is gone.
    } finally {
      await resetLocal();
    }
  }

  Future<void> revokeDeviceAndReset() async {
    // Flexisip-only provisioning has no app-device revocation endpoint. Avoid
    // delaying SIP unregistration with a guaranteed 404 in that mode.
    if (state.value?.hasBackendSession == true) {
      try {
        await ref.read(deviceInfoRepositoryProvider).revokeDevice();
      } catch (_) {
        // Local reset must still complete if revoke is unavailable.
      }
    }
    await resetLocal();
  }

  Future<void> resetLocal() async {
    _registrationRetryTimer?.cancel();
    // Revoke messaging while its access token and the control-plane directory
    // token are still available. Clearing either first would leave the server
    // session and its push endpoint active even though the device logged out.
    try {
      await ref.read(messagingRepositoryProvider).clearLocalData();
    } catch (error, stackTrace) {
      // Local logout must still finish when the messaging edge is unavailable.
      AppLogger.error(
        'Messaging session could not be revoked during local reset',
        error: error,
        stackTrace: stackTrace,
      );
    }
    final deviceCredential = state.value?.deviceCredential;
    final directoryAccess = state.value?.directoryAccess;
    if (deviceCredential != null) {
      try {
        await ref
            .read(deviceCredentialRepositoryProvider)
            .revoke(deviceCredential);
      } catch (error, stackTrace) {
        AppLogger.error(
          'Device credential could not be revoked during local reset',
          error: error,
          stackTrace: stackTrace,
        );
      }
    } else if (directoryAccess != null) {
      try {
        await ref.read(directoryRepositoryProvider).revoke(directoryAccess);
      } catch (error, stackTrace) {
        // The device must still discard its SIP identity while offline or when
        // the directory control plane is temporarily unavailable.
        AppLogger.error(
          'Directory token could not be revoked during local reset',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    final sipService = ref.read(sipServiceProvider);
    await sipService.unregister();
    // A disabled native account can be restored by a later FCM/APNs wake.
    // Purge it only for a real local reset, after the unregister transaction.
    await sipService.purgeAccount();
    await ref.read(secureSessionStorageProvider).clearSession();
    await ref.read(callHistoryRepositoryProvider).clearCallHistory();
    await ref.read(quickDialRepositoryProvider).clear();
    ref.invalidate(callHistoryProvider);
    ref.invalidate(quickDialProvider);
    state = const AsyncData(null);
  }

  Future<void> _syncSip(AppSession session) async {
    _registrationRetryTimer?.cancel();
    final sip = session.sipConfig;
    final service = ref.read(sipServiceProvider);
    if (!session.canRegisterSip) {
      await service.unregister();
      return;
    }

    try {
      final config = ref.read(appConfigProvider);
      final alignedSip = alignSipRouting(sip!, config.sipProxyHost);

      // A normal foreground start must not publish a temporary SIP contact
      // without pn-provider/pn-prid. The native iOS core is already restored
      // before Flutter for true PushKit cold wakes, so waiting for the platform
      // token here does not delay CallKit's mandatory incoming-call report.
      final pushConfig = await ref
          .read(sipPushTokenServiceProvider)
          .getPushConfig();
      final sipWithPush = pushConfig == null
          ? alignedSip
          : alignedSip.copyWith(pushConfig: pushConfig);
      await service.initialize(sipWithPush);
      if (await service.hasActiveCall()) {
        AppLogger.info(
          'SIP sync deferred push/device setup due to active call',
        );
        unawaited(_completeDeferredSipSetup(session, sipWithPush));
        return;
      }

      if (session.hasBackendSession) {
        await ref
            .read(deviceInfoRepositoryProvider)
            .registerDevice(sipIdentity: sipWithPush.sipIdentity);
      }
      await service.register();
      _registrationRetryTimer = Timer(
        const Duration(seconds: 6),
        () => unawaited(_retryStartupRegistration(service)),
      );
    } catch (error, stackTrace) {
      AppLogger.error(
        'Automatic SIP registration failed during session restore',
        error: error,
        stackTrace: stackTrace,
      );
      // Registration diagnostics carry the SIP failure; app session restore
      // should still complete so the user can inspect and reprovision.
    }
  }

  Future<void> _completeDeferredSipSetup(
    AppSession session,
    SipConfig alignedSip,
  ) async {
    try {
      final pushConfig = await ref
          .read(sipPushTokenServiceProvider)
          .getPushConfig();
      if (pushConfig != null &&
          !await ref.read(sipServiceProvider).hasActiveCall()) {
        await ref
            .read(sipServiceProvider)
            .refreshConfig(alignedSip.copyWith(pushConfig: pushConfig));
      }
      if (session.hasBackendSession) {
        await ref
            .read(deviceInfoRepositoryProvider)
            .registerDevice(sipIdentity: alignedSip.sipIdentity);
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'Deferred SIP setup after call wake failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _retryStartupRegistration(SipService service) async {
    try {
      if (state.value?.canRegisterSip != true ||
          await service.hasActiveCall() ||
          service.getRegistrationState().status ==
              SipRegistrationStatus.registered) {
        return;
      }
      AppLogger.warning(
        'SIP was not registered after startup; retrying registration',
      );
      await service.register();
    } catch (error, stackTrace) {
      AppLogger.error(
        'Automatic SIP registration retry failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

String _callLogSummary(VoipCall? call) {
  if (call == null) {
    return 'none';
  }
  return 'id=${call.id}, direction=${call.direction}, status=${call.status}';
}
