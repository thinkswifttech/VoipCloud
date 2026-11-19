import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/accounts/domain/account_line.dart';
import 'package:phone_app/features/calls/domain/call_direction.dart';
import 'package:phone_app/features/calls/domain/call_quality_info.dart';
import 'package:phone_app/features/calls/domain/call_status.dart';
import 'package:phone_app/features/calls/domain/voip_call.dart';
import 'package:phone_app/features/calls/presentation/call_waiting_presentation.dart';
import 'package:phone_app/features/calls/presentation/in_call_panel.dart';
import 'package:phone_app/features/contacts/domain/contact.dart';
import 'package:phone_app/features/contacts/presentation/contacts_providers.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';
import 'package:phone_app/features/directory/presentation/directory_providers.dart';
import 'package:phone_app/features/session/presentation/session_controller.dart';
import 'package:phone_app/features/settings/presentation/settings_controller.dart';
import 'package:phone_app/features/sip/application/sip_service.dart';

VoipCall call(String id, CallStatus status) => VoipCall(
  id: id,
  remoteUri: 'sip:$id@example.test',
  remoteDisplayName: id,
  direction: CallDirection.outgoing,
  status: status,
  startedAt: DateTime.utc(2026, 11, 19, 12),
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

class FakeSip extends Fake implements SipService {
  FakeSip(this.liveCalls);
  @override
  final List<VoipCall> liveCalls;
  final actions = <String>[];
  @override
  Future<CallQualityInfo> getCallQuality({String? callId}) async =>
      CallQualityInfo(callId: callId ?? '', capturedAt: DateTime.now());
  @override
  Future<void> syncCurrentCall() async {}
  @override
  Future<void> prepareAttendedTransfer(String originalCallId) async =>
      actions.add('hold $originalCallId');
  @override
  Future<void> makeCall(
    String destination, {
    AccountLine line = AccountLine.primary,
  }) async => actions.add('call $destination');
}

Future<FakeSip> pumpPanel(WidgetTester tester, List<VoipCall> calls) async {
  await tester.binding.setSurfaceSize(const Size(1000, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final service = FakeSip(calls);
  final container = ProviderContainer(
    overrides: [
      sipServiceProvider.overrideWithValue(service),
      activeCallProvider.overrideWith((_) => Stream.value(calls.first)),
      liveCallsProvider.overrideWith((_) => Stream.value(calls)),
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
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              final shown = ref.watch(displayedInCallProvider);
              return shown == null
                  ? const SizedBox()
                  : InCallPanel(call: shown, enableProximity: false);
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return service;
}

void main() {
  testWidgets('a call on hold can have a second call added', (tester) async {
    final service = await pumpPanel(tester, [call('a', CallStatus.held)]);
    expect(find.text('Add call'), findsOneWidget);
    await tester.tap(find.byTooltip('Add call'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '5551234');
    await tester.tap(find.text('Call'));
    await tester.pumpAndSettle();
    expect(service.actions, ['hold a', 'call 5551234']);
  });

  testWidgets('an active call is put on hold before the new call starts', (
    tester,
  ) async {
    final service = await pumpPanel(tester, [call('a', CallStatus.active)]);
    await tester.tap(find.byTooltip('Add call'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '555 1234');
    await tester.tap(find.text('Call'));
    await tester.pumpAndSettle();
    expect(service.actions, ['hold a', 'call 5551234']);
  });

  testWidgets('no Add call when two calls are already live', (tester) async {
    await pumpPanel(tester, [
      call('a', CallStatus.active),
      call('b', CallStatus.held),
    ]);
    expect(find.text('Add call'), findsNothing);
  });
}
