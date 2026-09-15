import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../shared/widgets/startup_brand_intro.dart';
import '../../calls/domain/call_direction.dart';
import '../../calls/domain/call_status.dart';
import '../../calls/domain/voip_call.dart';
import '../../legal/data/terms_acceptance_repository.dart';
import '../../session/domain/service_account.dart';
import '../../session/presentation/session_controller.dart';
import 'app_startup_controller.dart';

class StartupScreen extends ConsumerStatefulWidget {
  const StartupScreen({super.key});

  @override
  ConsumerState<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends ConsumerState<StartupScreen> {
  var _isRouting = false;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_restore);
  }

  Future<void> _restore() async {
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
    } catch (_) {
      if (mounted && !_isRouting) {
        _go(RoutePaths.provisioning);
      }
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

    return const Scaffold(body: StartupBrandIntro());
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
