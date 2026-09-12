import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/updates/desktop_update.dart';
import '../features/settings/presentation/settings_controller.dart';
import '../shared/platform/windows_taskbar_pin_offer.dart';
import 'router/app_router.dart';
import 'router/call_route_listener.dart';
import 'router/external_communication_intent_listener.dart';
import 'router/messaging_notification_listener.dart';
import 'sip_lifecycle_listener.dart';
import 'theme/app_theme.dart';

class SoftphoneApp extends ConsumerStatefulWidget {
  const SoftphoneApp({this.commandLineArguments = const [], super.key});

  final List<String> commandLineArguments;

  @override
  ConsumerState<SoftphoneApp> createState() => _SoftphoneAppState();
}

class _SoftphoneAppState extends ConsumerState<SoftphoneApp> {
  MessagingNotificationListener? _messagingNotifications;
  Object? _routerIdentity;

  @override
  void dispose() {
    _messagingNotifications?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep a single application-wide desktop update check alive from startup.
    // Its result drives the Settings badge and the About panel.
    ref.watch(desktopUpdateProvider);
    final router = ref.watch(appRouterProvider);
    final settings = ref.watch(settingsControllerProvider);
    if (!identical(_routerIdentity, router)) {
      _messagingNotifications?.dispose();
      _routerIdentity = router;
      _messagingNotifications = MessagingNotificationListener(router);
      unawaited(_messagingNotifications!.start());
    }

    return MaterialApp.router(
      title: 'VoipCloud',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: settings.materialThemeMode,
      builder: (context, child) {
        return WindowsTaskbarPinOffer(
          commandLineArguments: widget.commandLineArguments,
          child: SipLifecycleListener(
            child: ExternalCommunicationIntentListener(
              router: router,
              child: CallRouteListener(
                router: router,
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          ),
        );
      },
    );
  }
}
