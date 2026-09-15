import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/call_history/presentation/call_history_screen.dart';
import '../../features/calls/presentation/active_call_screen.dart';
import '../../features/calls/presentation/call_ended_screen.dart';
import '../../features/calls/presentation/incoming_call_screen.dart';
import '../../features/contacts/presentation/device_contacts_screen.dart';
import '../../features/dialer/presentation/dialer_screen.dart';
import '../../features/directory/presentation/directory_screen.dart';
import '../../features/messages/presentation/messages_screen.dart';
import '../../features/messages/domain/messaging_platform.dart';
import '../../features/legal/presentation/terms_agreement_screen.dart';
import '../../features/session/presentation/session_controller.dart';
import '../../features/provisioning/presentation/provisioning_screen.dart';
import '../../features/provisioning/presentation/provisioning_scanner_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/settings/presentation/sip_diagnostics_screen.dart';
import '../../features/settings/presentation/sip_logs_screen.dart';
import '../../features/session/presentation/account_status_screen.dart';
import '../../features/startup/presentation/startup_screen.dart';
import 'home_shell.dart';
import 'route_names.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _shellNavigatorKey = GlobalKey<NavigatorState>();

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: RoutePaths.splash,
    redirect: (_, state) {
      // Older Android incoming-call PendingIntents used this URI only to make
      // each native notification intent unique. It was never an application
      // deep link. Recover safely if Android/OEM task restoration replays one;
      // CallRouteListener will navigate to the synchronized active call.
      if (state.uri.scheme == 'voipcloud' &&
          state.uri.host == 'incoming-call') {
        return RoutePaths.splash;
      }
      if (state.uri.path.startsWith(RoutePaths.messages) &&
          !isCarrierMessagingEnabled(
            ref.read(sessionControllerProvider).value?.carrierMessaging,
          )) {
        return RoutePaths.dialer;
      }
      if (state.uri.path.startsWith(RoutePaths.directory) &&
          ref.read(sessionControllerProvider).value?.directoryAccess == null) {
        return RoutePaths.dialer;
      }
      return null;
    },
    routes: [
      GoRoute(
        path: RoutePaths.splash,
        name: RouteNames.splash,
        builder: (context, state) => const StartupScreen(),
      ),
      GoRoute(
        path: RoutePaths.provisioning,
        name: RouteNames.provisioning,
        builder: (context, state) => const ProvisioningScreen(),
      ),
      GoRoute(
        path: RoutePaths.provisioningScanner,
        name: RouteNames.provisioningScanner,
        builder: (context, state) => const ProvisioningScannerScreen(),
      ),
      GoRoute(
        path: RoutePaths.termsAgreement,
        name: RouteNames.termsAgreement,
        builder: (context, state) => const TermsAgreementScreen(),
      ),
      GoRoute(
        path: RoutePaths.accountStatus,
        name: RouteNames.accountStatus,
        builder: (context, state) => const AccountStatusScreen(),
      ),
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) {
          return HomeShell(location: state.uri.path, child: child);
        },
        routes: [
          GoRoute(
            path: RoutePaths.home,
            name: RouteNames.home,
            redirect: (_, _) => RoutePaths.dialer,
          ),
          GoRoute(
            path: RoutePaths.dialer,
            name: RouteNames.dialer,
            pageBuilder: (context, state) => _shellPage(
              context,
              state,
              DialerScreen(initialDestination: state.uri.queryParameters['to']),
            ),
          ),
          GoRoute(
            path: RoutePaths.directory,
            name: RouteNames.directory,
            pageBuilder: (context, state) =>
                _shellPage(context, state, const DirectoryScreen()),
          ),
          GoRoute(
            path: RoutePaths.callHistory,
            name: RouteNames.callHistory,
            pageBuilder: (context, state) =>
                _shellPage(context, state, const CallHistoryScreen()),
          ),
          GoRoute(
            path: RoutePaths.contacts,
            name: RouteNames.contacts,
            pageBuilder: (context, state) =>
                _shellPage(context, state, const DeviceContactsScreen()),
          ),
          if (isCarrierMessagingSupported())
            GoRoute(
              path: RoutePaths.messages,
              name: RouteNames.messages,
              pageBuilder: (context, state) => _shellPage(
                context,
                state,
                MessagesScreen(
                  initialDestination: state.uri.queryParameters['to'],
                  initialMessageId: state.uri.queryParameters['message'],
                ),
              ),
            ),
          GoRoute(
            path: RoutePaths.settings,
            name: RouteNames.settings,
            pageBuilder: (context, state) =>
                _shellPage(context, state, const SettingsScreen()),
          ),
        ],
      ),
      GoRoute(
        path: RoutePaths.sipDiagnostics,
        name: RouteNames.sipDiagnostics,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const SipDiagnosticsScreen(),
      ),
      GoRoute(
        path: RoutePaths.sipLogs,
        name: RouteNames.sipLogs,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const SipLogsScreen(),
      ),
      GoRoute(
        path: RoutePaths.callEnded,
        name: RouteNames.callEnded,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) {
          final status = state.uri.queryParameters['status'] ?? 'Call ended';
          final caller = state.uri.queryParameters['caller'];
          return CallEndedScreen(statusLabel: status, caller: caller);
        },
      ),
      GoRoute(
        path: RoutePaths.incomingCall,
        name: RouteNames.incomingCall,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) {
          return IncomingCallScreen(
            callId: Uri.decodeComponent(state.pathParameters['callId']!),
          );
        },
      ),
      GoRoute(
        path: RoutePaths.activeCall,
        name: RouteNames.activeCall,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) {
          return ActiveCallScreen(
            callId: Uri.decodeComponent(state.pathParameters['callId']!),
          );
        },
      ),
    ],
  );
});

Page<void> _shellPage(BuildContext context, GoRouterState state, Widget child) {
  return NoTransitionPage<void>(
    key: state.pageKey,
    child: ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: child,
    ),
  );
}
