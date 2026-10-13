import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:phone_app/app/router/call_route_listener.dart';
import 'package:phone_app/features/calls/domain/call_direction.dart';
import 'package:phone_app/features/calls/domain/call_status.dart';
import 'package:phone_app/features/calls/domain/voip_call.dart';
import 'package:phone_app/features/session/presentation/session_controller.dart';
import 'package:phone_app/features/settings/presentation/settings_controller.dart';
import 'package:phone_app/features/sip/application/sip_service.dart';

class _Settings extends SettingsController {
  @override
  SettingsState build() => const SettingsState();
}

class _Sip extends Fake implements SipService {
  @override
  Future<void> syncCurrentCall() async {}
  @override
  Future<bool> hasActiveCall() async => false;
}

VoipCall _call(
  CallStatus status, {
  bool answeredElsewhere = false,
  DateTime? endedAt,
}) => VoipCall(
  id: 'queue-call',
  remoteUri: 'sip:caller@example.test',
  remoteDisplayName: 'Caller',
  direction: CallDirection.incoming,
  status: status,
  startedAt: DateTime.utc(2026, 10, 12, 14),
  answeredElsewhere: answeredElsewhere,
  endedAt: endedAt,
);

void main() {
  Future<GoRouter> pump(
    WidgetTester tester,
    StreamController<VoipCall?> events,
  ) async {
    final router = GoRouter(
      initialLocation: '/dialer',
      routes: [
        GoRoute(path: '/dialer', builder: (_, _) => const Text('Dialer')),
        GoRoute(
          path: '/calls/incoming/:callId',
          builder: (_, _) => const Text('Incoming'),
        ),
        GoRoute(path: '/calls/ended', builder: (_, _) => const Text('Ended')),
      ],
    );
    addTearDown(router.dispose);
    final container = ProviderContainer(
      overrides: [
        sipServiceProvider.overrideWithValue(_Sip()),
        activeCallProvider.overrideWith((_) async* {
          yield _call(CallStatus.ringing);
          yield* events.stream;
        }),
        liveCallsProvider.overrideWith((_) => Stream.value(const [])),
        postDialPromptProvider.overrideWith((_) => Stream.value(null)),
        settingsControllerProvider.overrideWith(_Settings.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CallRouteListener(
          router: router,
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets(
    'answered elsewhere while in the background skips the ended page',
    (tester) async {
      final events = StreamController<VoipCall?>.broadcast();
      addTearDown(events.close);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final router = await pump(tester, events);
      expect(router.state.uri.path, startsWith('/calls/incoming/'));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      events.add(_call(CallStatus.ended, answeredElsewhere: true));
      await tester.pumpAndSettle();

      expect(router.state.uri.path, '/dialer');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/dialer');
      expect(find.text('Ended'), findsNothing);
    },
  );

  testWidgets(
    'answered elsewhere in the foreground still shows the ended page',
    (tester) async {
      final events = StreamController<VoipCall?>.broadcast();
      addTearDown(events.close);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final router = await pump(tester, events);

      events.add(_call(CallStatus.ended, answeredElsewhere: true));
      await tester.pump();
      await tester.pump();

      expect(router.state.uri.path, '/calls/ended');
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets('a late report about an old finished call is not presented', (
    tester,
  ) async {
    final events = StreamController<VoipCall?>.broadcast();
    addTearDown(events.close);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final router = await pump(tester, events);

    events.add(
      _call(
        CallStatus.ended,
        answeredElsewhere: true,
        endedAt: DateTime.now().subtract(const Duration(minutes: 5)),
      ),
    );
    await tester.pumpAndSettle();

    expect(router.state.uri.path, isNot('/calls/ended'));
  });
}
