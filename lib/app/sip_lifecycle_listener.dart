import 'dart:async';
import 'dart:io' show Platform;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_logger.dart';
import '../../core/updates/desktop_update.dart';
import '../../features/calls/domain/call_status.dart';
import '../../features/calls/domain/voip_call.dart';
import '../../features/call_history/presentation/call_history_providers.dart';
import '../../features/directory/presentation/blf_feed_providers.dart';
import '../../features/directory/presentation/directory_presence_providers.dart';
import '../../features/session/presentation/session_controller.dart';
import '../../features/settings/presentation/settings_controller.dart';
import '../../features/settings/presentation/pbx_dnd_providers.dart';
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
  DateTime? _lastHistoryRefresh;

  void _refreshHistoryIfNeeded({bool force = false}) {
    if (!mounted ||
        ref.read(sessionControllerProvider).value?.directoryAccess == null) {
      return;
    }
    final now = DateTime.now();
    if (!force &&
        _lastHistoryRefresh != null &&
        now.difference(_lastHistoryRefresh!) < const Duration(seconds: 30)) {
      return;
    }
    _lastHistoryRefresh = now;
    ref.invalidate(callHistoryProvider);
  }

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
        // Mobile only: no BLF socket (or polling) while backgrounded.
        if (isMobileBlfPlatform) {
          ref.read(blfFeedClientProvider)?.setForeground(false);
        }
        if (!_backgroundTransitionSent) {
          _backgroundTransitionSent = true;
          await _platformChannel.enterBackground();
          await _maybePromptForBackgroundPermission();
        }
      case AppLifecycleState.resumed:
        if (isMobileBlfPlatform) {
          ref.read(blfFeedClientProvider)?.setForeground(true);
        }
        final wasBackgrounded = _backgroundTransitionSent;
        _backgroundTransitionSent = false;
        // The desktop app lives in the tray; look for a new release whenever
        // the window comes back (throttled, and quiet on failure).
        unawaited(ref.read(desktopUpdateProvider.notifier).refreshIfStale());
        // A device silenced at the edge receives no call event to refresh history.
        // Reconcile completed server calls (and badge) independently of SIP refresh.
        _refreshHistoryIfNeeded(force: wasBackgrounded);
        await _platformChannel.enterForeground();
        ref.read(pbxDndMonitorProvider).refresh();
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
    _configurePbxDnd();
    _connectivitySubscription = connectivity.onConnectivityChanged.listen((
      results,
    ) {
      final hasNetwork = _hasNetwork(results);
      final restored = _hadNetwork == false && hasNetwork;
      _hadNetwork = hasNetwork;
      _configurePbxDnd();
      if (!restored ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      _refreshHistoryIfNeeded();
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
  Widget build(BuildContext context) {
    ref.watch(sessionControllerProvider);
    ref.watch(sipRegistrationStateProvider);
    ref.watch(directoryPresenceSessionProvider);
    // Configure after the frame to avoid changing other provider state while
    // widgets are building; reread current values to discard stale frames.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _configurePbxDnd();
    });
    return widget.child;
  }

  void _configurePbxDnd() {
    if (!mounted) return;
    final current = ref.read(sipServiceProvider).currentConfig;
    ref
        .read(pbxDndMonitorProvider)
        .configure(
          identity: current?.sipIdentity,
          extension: current?.extension,
          domain: current?.domain,
          registered:
              _hadNetwork != false &&
              ref
                      .read(sessionControllerProvider)
                      .asData
                      ?.value
                      ?.canRegisterSip ==
                  true &&
              (ref
                      .read(sipRegistrationStateProvider)
                      .asData
                      ?.value
                      .isRegistered ??
                  false),
        );
  }
}
