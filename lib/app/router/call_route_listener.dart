import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/logging/app_logger.dart';
import '../../features/calls/domain/call_direction.dart';
import '../../features/calls/domain/call_status.dart';
import '../../features/calls/domain/voip_call.dart';
import '../../features/calls/presentation/call_session_providers.dart';
import '../../features/call_history/presentation/call_history_providers.dart';
import '../../features/session/presentation/session_controller.dart';
import '../../features/settings/presentation/settings_controller.dart';
import 'route_names.dart';

/// Routes incoming ringing to a full-screen answer UI; connected calls stay in
/// the shell (Dial hosts the in-call panel).
class CallRouteListener extends ConsumerWidget {
  const CallRouteListener({
    required this.child,
    required this.router,
    super.key,
  });

  final Widget child;
  final GoRouter router;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentCall = ref.watch(activeCallProvider);

    ref.listen<AsyncValue<VoipCall?>>(activeCallProvider, (_, next) {
      _routeForCall(context, ref, next, invalidateHistory: true);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _routeForCall(context, ref, currentCall);
    });

    return child;
  }

  void _routeForCall(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<VoipCall?> value, {
    bool invalidateHistory = false,
  }) {
    value.when(
      loading: () {},
      error: (_, _) {},
      data: (call) {
        if (!context.mounted) {
          return;
        }
        final path = router.state.uri.path;
        final location = router.state.uri.toString();

        if (call == null) {
          AppLogger.info(
            'Call route decision => no active call, path=$path, invalidateHistory=$invalidateHistory',
          );
          // Tab switches can race a native `none` sync during registration
          // refresh. If the native core still has a live call, restore it.
          unawaited(_resyncActiveCallIfNeeded(ref));
          if (invalidateHistory) {
            ref.invalidate(callHistoryProvider);
          }
          // Leaving transfer mode must never end the SIP call — only clear UI mode.
          if (ref.read(callTransferModeProvider)) {
            ref.read(callTransferModeProvider.notifier).clear();
          }
          if (path.startsWith('/calls/') && path != RoutePaths.callEnded) {
            router.go(RoutePaths.dialer);
          }
          return;
        }

        if (_isFinished(call.status)) {
          ref.read(callTransferModeProvider.notifier).clear();
          final target = RoutePaths.callEndedPath(
            status: _statusLabel(call.status),
            caller: call.remoteDisplayName ?? call.remoteUri,
          );
          AppLogger.info(
            'Call route decision => call finished id=${call.id}, current=$path, target=$target',
          );
          if (location != target) {
            router.go(target);
          }
          return;
        }

        if (call.direction == CallDirection.incoming &&
            call.status == CallStatus.ringing) {
          if (ref.read(settingsControllerProvider).dndEnabled) {
            AppLogger.info(
              'Call route decision => DND on, skip incoming UI id=${call.id}',
            );
            unawaited(ref.read(sipServiceProvider).rejectCall(call.id));
            return;
          }
          // PushKit calls must always be reported to CallKit, but a call that
          // arrives while our app is already foregrounded should also navigate
          // to the app's richer incoming-call screen. `inactive` still counts
          // as foreground here because presenting CallKit's banner temporarily
          // resigns the app without moving it to the background.
          final lifecycle = WidgetsBinding.instance.lifecycleState;
          final appIsForeground = lifecycle == AppLifecycleState.resumed ||
              lifecycle == AppLifecycleState.inactive;
          if (defaultTargetPlatform == TargetPlatform.iOS &&
              !appIsForeground) {
            AppLogger.info(
              'Call route decision => background iOS CallKit UI id=${call.id}',
            );
            if (path.startsWith('/calls/incoming/')) {
              router.go(RoutePaths.dialer);
            }
            return;
          }
          final target = RoutePaths.incomingCallPath(call.id);
          AppLogger.info(
            'Call route decision => incoming ringing id=${call.id}, current=$path, target=$target',
          );
          if (path != target) {
            router.go(target);
          }
          return;
        }

        // Connected / dialing / held: stay in the shell. Only leave root call
        // routes (incoming answer → Dial, stale /calls/:id → Dial).
        AppLogger.info(
          'Call route decision => in-shell call id=${call.id}, status=${call.status}, path=$path',
        );
        if (path.startsWith('/calls/') && path != RoutePaths.callEnded) {
          router.go(RoutePaths.dialer);
        }
      },
    );
  }

  Future<void> _resyncActiveCallIfNeeded(WidgetRef ref) async {
    try {
      final service = ref.read(sipServiceProvider);
      if (await service.hasActiveCall()) {
        AppLogger.info(
          'Call route: Flutter idle but native still has a call; syncing',
        );
        await service.syncCurrentCall();
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'Call route native resync failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  bool _isFinished(CallStatus status) {
    return switch (status) {
      CallStatus.ended || CallStatus.missed || CallStatus.failed => true,
      _ => false,
    };
  }

  String _statusLabel(CallStatus status) {
    return switch (status) {
      CallStatus.ended => 'Call ended',
      CallStatus.missed => 'Missed call',
      CallStatus.failed => 'Call failed',
      _ => 'Call ended',
    };
  }
}
