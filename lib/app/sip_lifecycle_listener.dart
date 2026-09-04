import 'dart:async';
import 'dart:io' show Platform;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_logger.dart';
import '../../features/calls/domain/call_status.dart';
import '../../features/calls/domain/voip_call.dart';
import '../../features/session/presentation/session_controller.dart';
import '../../features/settings/presentation/settings_controller.dart';
import '../../features/sip/application/registration_refresh_coordinator.dart';
import '../../features/sip/domain/sip_registration_state.dart';
import '../../features/sip/presentation/sip_log_providers.dart';
import '../../voip/platform/android_background_permissions.dart';
import '../../voip/platform/voip_platform_channel.dart';

/// Keeps the native SIP stack aligned with Flutter app lifecycle transitions.
class SipLifecycleListener extends ConsumerStatefulWidget {
  const SipLifecycleListener({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<SipLifecycleListener> createState() =>
      _SipLifecycleListenerState();
}

class _SipLifecycleListenerState extends ConsumerState<SipLifecycleListener>
    with WidgetsBindingObserver {
  static const _platformChannel = VoipPlatformChannel();
  bool _backgroundPromptShownThisSession = false;
  bool _backgroundTransitionSent = false;
  late final RegistrationRefreshCoordinator _registrationRefresh;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  StreamSubscription<VoipCall?>? _callSubscription;
  bool? _hadNetwork;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final sipService = ref.read(sipServiceProvider);
    _registrationRefresh = RegistrationRefreshCoordinator(
      canRegister: () =>
          ref.read(sessionControllerProvider).value?.canRegisterSip == true,
      hasActiveCall: sipService.hasActiveCall,
      refresh: sipService.register,
    );
    _callSubscription = sipService.callStateStream.listen((call) {
      if (call == null ||
          call.status == CallStatus.ended ||
          call.status == CallStatus.failed ||
          call.status == CallStatus.missed) {
        unawaited(_registrationRefresh.retryAfterCallEnded());
      }
    });
    unawaited(_observeConnectivity());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_connectivitySubscription?.cancel());
    unawaited(_callSubscription?.cancel());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_handleLifecycle(state));
  }

  Future<void> _handleLifecycle(AppLifecycleState state) async {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        if (!_backgroundTransitionSent) {
          _backgroundTransitionSent = true;
          await _platformChannel.enterBackground();
          await _maybePromptForBackgroundPermission();
        }
      case AppLifecycleState.resumed:
        _backgroundTransitionSent = false;
        await _platformChannel.enterForeground();
        if (ref.read(settingsControllerProvider).voipDebugLogsEnabled) {
          unawaited(ref.read(sipLogStoreProvider).refreshFromNativeFile());
        }
        if (await _platformChannel.hasActiveCall()) {
          await ref.read(sipServiceProvider).syncCurrentCall();
          return;
        }
        try {
          // Refresh even when the local state says registered. The upstream
          // proxy/PBX route may have changed while this process was suspended.
          await _registrationRefresh.request(
            RegistrationRefreshReason.foregroundResume,
          );
        } catch (error, stackTrace) {
          AppLogger.error(
            'Foreground SIP registration refresh failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
        await ref.read(sipServiceProvider).syncCurrentCall();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _observeConnectivity() async {
    final connectivity = Connectivity();
    try {
      _hadNetwork = _hasNetwork(await connectivity.checkConnectivity());
    } catch (_) {
      _hadNetwork = null;
    }
    if (!mounted) return;
    _connectivitySubscription = connectivity.onConnectivityChanged.listen((
      results,
    ) {
      final hasNetwork = _hasNetwork(results);
      final restored = _hadNetwork == false && hasNetwork;
      _hadNetwork = hasNetwork;
      if (!restored ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      unawaited(
        _registrationRefresh
            .request(RegistrationRefreshReason.connectivityRestored)
            .catchError((Object error, StackTrace stackTrace) {
              AppLogger.error(
                'Connectivity SIP registration refresh failed',
                error: error,
                stackTrace: stackTrace,
              );
            }),
      );
    });
  }

  bool _hasNetwork(List<ConnectivityResult> results) =>
      results.any((result) => result != ConnectivityResult.none);

  Future<void> _maybePromptForBackgroundPermission() async {
    if (!Platform.isAndroid || _backgroundPromptShownThisSession) {
      return;
    }

    final registration = ref.read(sipServiceProvider).getRegistrationState();
    if (registration.status != SipRegistrationStatus.registered) {
      return;
    }

    final ignored = await _platformChannel.isBatteryOptimizationIgnored();
    if (!mounted || ignored) {
      return;
    }

    _backgroundPromptShownThisSession = true;
    await showAndroidBackgroundPermissionDialog(
      context,
      platformChannel: _platformChannel,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
