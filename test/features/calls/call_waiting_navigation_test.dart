import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:phone_app/app/router/call_route_listener.dart';
import 'package:phone_app/features/calls/domain/call_direction.dart';
import 'package:phone_app/features/calls/domain/call_quality_info.dart';
import 'package:phone_app/features/calls/domain/call_status.dart';
import 'package:phone_app/features/calls/domain/voip_call.dart';
import 'package:phone_app/features/calls/presentation/call_waiting_banner.dart';
import 'package:phone_app/features/calls/presentation/call_waiting_presentation.dart';
import 'package:phone_app/features/calls/presentation/in_call_panel.dart';
import 'package:phone_app/features/calls/presentation/incoming_call_screen.dart';
import 'package:phone_app/features/contacts/domain/contact.dart';
import 'package:phone_app/features/contacts/presentation/contacts_providers.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';
import 'package:phone_app/features/directory/presentation/directory_providers.dart';
import 'package:phone_app/features/session/presentation/session_controller.dart';
import 'package:phone_app/features/settings/presentation/settings_controller.dart';
import 'package:phone_app/features/sip/application/sip_service.dart';

VoipCall fixture(String id, CallStatus status, {String? name}) => VoipCall(
  id: id,
  remoteUri: 'sip:$id@example.test',
  remoteDisplayName: name ?? id,
  direction: CallDirection.incoming,
  status: status,
  startedAt: DateTime.utc(2026, 10, 6, 14),
);

class TestContacts extends ContactsController {
  @override
  Future<List<Contact>> build() async => [];
}

class TestDirectory extends DirectoryController {
  @override
  Future<List<DirectoryEntry>> build() async => [];
}

class TestSettings extends SettingsController {
  @override
  SettingsState build() => const SettingsState();
}

class RecordingSipService extends Fake implements SipService {
  final unexpectedActions = <Symbol>[];
  @override
  Future<CallQualityInfo> getCallQuality({String? callId}) async =>
      CallQualityInfo(callId: callId ?? '', capturedAt: DateTime.now());
  @override
  Future<void> syncCurrentCall() async {}
  @override
  Future<bool> hasActiveCall() async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedActions.add(invocation.memberName);
    return super.noSuchMethod(invocation);
  }
}

void main() {
  final original = fixture(
    'original',
    CallStatus.active,
    name: 'Original caller',
  );
  final waiting = fixture(
    'waiting',
    CallStatus.ringing,
    name: 'Waiting caller with a long name for responsive layout',
  );

  test('ringing priority does not change the displayed control target', () {
    expect(selectDisplayedCall(waiting, [waiting, original])?.id, original.id);
    expect(
      selectDisplayedCall(waiting, [
        waiting,
        original.copyWith(status: CallStatus.held),
      ])?.id,
      original.id,
    );
    expect(selectDisplayedCall(waiting, [waiting]), isNull);
    expect(selectDisplayedCall(original, []), isNull);
    expect(selectWaitingCall([original, waiting])?.id, waiting.id);
    expect(
      selectWaitingCall([original, waiting.copyWith(status: CallStatus.ended)]),
      isNull,
    );
  });

  test('dismissal is per ringing episode and explicit View clears it', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(callWaitingPresentationProvider.notifier);
    controller.returnToCall('waiting');
    controller.reconcile([waiting, original]);
    expect(
      container.read(callWaitingPresentationProvider),
      contains('waiting'),
    );
    controller.showWaiting('waiting');
    expect(container.read(callWaitingPresentationProvider), isEmpty);
    controller.returnToCall('waiting');
    controller.reconcile([original]);
    expect(container.read(callWaitingPresentationProvider), isEmpty);
    controller.reconcile([waiting, original]);
    expect(container.read(callWaitingPresentationProvider), isEmpty);
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  ]) {
    for (final size in [
      const Size(320, 360),
      const Size(390, 844),
      const Size(760, 360),
      const Size(1000, 700),
    ]) {
      testWidgets('$platform $size: back and View do not control either call', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final primaryEvents = StreamController<VoipCall?>.broadcast();
        final callEvents = StreamController<List<VoipCall>>.broadcast();
        addTearDown(primaryEvents.close);
        addTearDown(callEvents.close);
        final service = RecordingSipService();
        final router = GoRouter(
          initialLocation: '/dialer',
          routes: [
            GoRoute(
              path: '/dialer',
              builder: (_, _) => Consumer(
                builder: (context, ref, _) {
                  final call = ref.watch(displayedInCallProvider);
                  return Scaffold(
                    body: call == null
                        ? const Text('No active call')
                        : InCallPanel(call: call, enableProximity: false),
                  );
                },
              ),
            ),
            GoRoute(
              path: '/calls/incoming/:callId',
              builder: (_, state) =>
                  IncomingCallScreen(callId: state.pathParameters['callId']!),
            ),
          ],
        );
        addTearDown(router.dispose);
        final container = ProviderContainer(
          overrides: [
            sipServiceProvider.overrideWithValue(service),
            activeCallProvider.overrideWith((_) async* {
              yield waiting;
              yield* primaryEvents.stream;
            }),
            liveCallsProvider.overrideWith((_) async* {
              yield [waiting, original];
              yield* callEvents.stream;
            }),
            postDialPromptProvider.overrideWith((_) => Stream.value(null)),
            contactsProvider.overrideWith(TestContacts.new),
            directoryProvider.overrideWith(TestDirectory.new),
            settingsControllerProvider.overrideWith(TestSettings.new),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: CallRouteListener(
              router: router,
              child: MaterialApp.router(
                routerConfig: router,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(size.width == 320 ? 2 : 1),
                  ),
                  child: child!,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Back to active call'), findsOneWidget);
        expect(tester.takeException(), isNull);
        for (final action in [
          'Hold & answer',
          'End current & answer',
          'Decline new call',
        ]) {
          await tester.ensureVisible(find.text(action));
          expect(
            tester.getRect(find.text(action)).center.dy,
            lessThan(size.height),
          );
        }
        await tester.ensureVisible(find.text('Back to active call'));
        await tester.tap(find.text('Back to active call'));
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/dialer');
        expect(find.text('Original caller'), findsOneWidget);
        expect(find.byType(CallWaitingBanner), findsOneWidget);
        // Repeated native ringing and layout rebuilds must not force it open.
        primaryEvents.add(waiting.copyWith(isMuted: true));
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/dialer');
        expect(tester.takeException(), isNull);
        // If the original call ends, the same ringing call becomes the normal
        // incoming screen even without a new primary-call event.
        callEvents.add([waiting]);
        // The ordinary mobile incoming slider has a repeating ring animation.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(router.state.uri.path, '/calls/incoming/waiting');
        expect(find.text('Back to active call'), findsNothing);
        callEvents.add([waiting, original]);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Back to active call'));
        await tester.tap(find.text('Back to active call'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('View'));
        await tester.tap(find.text('View'));
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/calls/incoming/waiting');
        if (platform == TargetPlatform.android) {
          await router.routerDelegate.popRoute();
        } else {
          await tester.tap(find.text('Back to active call'));
        }
        await tester.pumpAndSettle();
        // Cancellation removes the banner without affecting the original call.
        callEvents.add([original]);
        primaryEvents.add(original);
        await tester.pumpAndSettle();
        expect(find.byType(CallWaitingBanner), findsNothing);
        expect(find.text('Original caller'), findsOneWidget);
        // A new ringing episode is not suppressed by the previous dismissal.
        callEvents.add([waiting, original]);
        primaryEvents.add(waiting);
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/calls/incoming/waiting');
        // Native acceptance/hold events restore the correct control target.
        final answered = waiting.copyWith(status: CallStatus.active);
        callEvents.add([answered, original.copyWith(status: CallStatus.held)]);
        primaryEvents.add(answered);
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/dialer');
        expect(container.read(displayedInCallProvider)?.id, waiting.id);
        expect(find.byType(CallWaitingBanner), findsNothing);
        expect(service.unexpectedActions, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
}
