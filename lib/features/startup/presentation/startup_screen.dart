import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../core/logging/app_logger.dart';
import '../../../shared/widgets/startup_brand_intro.dart';
import '../../calls/domain/call_direction.dart';
import '../../calls/domain/call_status.dart';
import '../../calls/domain/voip_call.dart';
import '../../legal/data/terms_acceptance_repository.dart';
import '../../session/domain/service_account.dart';
import '../../session/presentation/session_controller.dart';
import '../../sip/presentation/sip_log_providers.dart';
import 'app_startup_controller.dart';

class StartupScreen extends ConsumerStatefulWidget {
  const StartupScreen({super.key});

  @override
  ConsumerState<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends ConsumerState<StartupScreen>
    with WidgetsBindingObserver {
  var _isRouting = false;
  var _isRestoring = false;
  Object? _restoreError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future<void>.microtask(_restore);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _restoreError != null) {
      unawaited(_restore());
    }
  }

  Future<void> _restore() async {
    if (_isRouting || _isRestoring) return;
    setState(() {
      _isRestoring = true;
      _restoreError = null;
    });
    try {
      final session = await ref
          .read(appStartupControllerProvider.notifier)
          .restore();
      if (!mounted || _isRouting) {
        return;
      }
      final termsPending = await ref
          .read(termsAcceptanceRepositoryProvider)
          .isPending();
      if (!mounted || _isRouting) {
        return;
      }
      if (session != null && termsPending) {
        _go(RoutePaths.termsAgreement);
      } else if (session == null ||
          session.provisioning.requiresProvisioning ||
          session.sipConfig == null) {
        _go(RoutePaths.provisioning);
      } else if (session.service.serviceStatus == ServiceStatus.active &&
          session.device.isUsable &&
          session.sipConfig != null) {
        _go(_currentCallRoute(ref) ?? RoutePaths.dialer);
      } else {
        _go(RoutePaths.accountStatus);
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'Startup session restoration failed without clearing provisioning',
        error: error,
        stackTrace: stackTrace,
      );
      ref
          .read(sipLogStoreProvider)
          .diagnostic(
            level: 'error',
            source: 'startup',
            message:
                'Startup restore unavailable; setup preserved '
                '(${error.runtimeType})',
          );
      if (mounted && !_isRouting) setState(() => _restoreError = error);
    } finally {
      if (mounted) setState(() => _isRestoring = false);
    }
  }

  void _go(String location) {
    if (!mounted || _isRouting) {
      return;
    }
    _isRouting = true;
    context.go(location);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<VoipCall?>>(activeCallProvider, (_, next) {
      final route = _routeForCall(next);
      if (route != null) {
        _go(route);
      }
    });

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const StartupBrandIntro(),
          if (_restoreError != null)
            _StartupRestoreRecovery(onRetry: () => unawaited(_restore())),
        ],
      ),
    );
  }

  String? _currentCallRoute(WidgetRef ref) {
    return _routeForCall(ref.read(activeCallProvider));
  }

  String? _routeForCall(AsyncValue<VoipCall?> value) {
    return value.when(
      loading: () => null,
      error: (_, _) => null,
      data: (call) {
        if (call == null || _isFinished(call.status)) {
          return null;
        }
        if (call.direction == CallDirection.incoming &&
            call.status == CallStatus.ringing) {
          if (defaultTargetPlatform == TargetPlatform.iOS) {
            return RoutePaths.dialer;
          }
          return RoutePaths.incomingCallPath(call.id);
        }
        return RoutePaths.activeCallPath(call.id);
      },
    );
  }

  bool _isFinished(CallStatus status) {
    return switch (status) {
      CallStatus.ended || CallStatus.missed || CallStatus.failed => true,
      _ => false,
    };
  }
}

class _StartupRestoreRecovery extends StatelessWidget {
  const _StartupRestoreRecovery({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Your saved account is temporarily unavailable',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Your setup has not been erased. Unlock the device and '
                      'try again.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 14),
                    FilledButton(
                      onPressed: onRetry,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
