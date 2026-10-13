import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/calls/domain/call_direction.dart';
import 'package:phone_app/features/calls/domain/call_status.dart';
import 'package:phone_app/features/calls/domain/voip_call.dart';
import 'package:phone_app/features/calls/presentation/call_session_providers.dart';
import 'package:phone_app/features/directory/data/directory_presence_monitor.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';
import 'package:phone_app/features/directory/presentation/directory_presence_providers.dart';
import 'package:phone_app/features/directory/presentation/directory_providers.dart';
import 'package:phone_app/features/directory/presentation/directory_screen.dart';
import 'package:phone_app/features/session/presentation/session_controller.dart';
import 'package:phone_app/features/sip/application/sip_service.dart';

class _Directory extends DirectoryController {
  @override
  Future<List<DirectoryEntry>> build() async => [
    DirectoryEntry(
      id: '1',
      displayName: 'Mayra Grosso',
      numbers: ['108'],
      telephoneKind: DirectoryTelephoneKind.internal,
      presence: DirectoryPresence.unknown,
    ),
  ];
}

class _Sip extends Fake implements SipService {
  final transfers = <String>[];

  @override
  Future<void> blindTransfer({
    required String callId,
    required String destination,
  }) async => transfers.add('$callId->$destination');
}

/// Tearing the directory down schedules a short timer in the presence monitor.
Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  final original = VoipCall(
    id: 'orig',
    remoteUri: 'sip:caller@example.test',
    remoteDisplayName: 'Dave Allan',
    direction: CallDirection.incoming,
    status: CallStatus.active,
    startedAt: DateTime.utc(2026, 10, 13, 12),
  );

  Future<(ProviderContainer, _Sip)> pump(WidgetTester tester) async {
    final sip = _Sip();
    final monitor = DirectoryPresenceMonitor(
      events: const Stream.empty(),
      reconcile: (_, _, _) async {},
      stop: () async {},
    );
    final container = ProviderContainer(
      overrides: [
        directoryProvider.overrideWith(_Directory.new),
        directoryPresenceMonitorProvider.overrideWithValue(monitor),
        sipServiceProvider.overrideWithValue(sip),
        liveCallsProvider.overrideWith((_) => Stream.value([original])),
      ],
    );
    addTearDown(container.dispose);
    // The app's call listener keeps this provider alive; do the same here.
    container.listen(liveCallsProvider, (_, _) {});
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: DirectoryScreen())),
      ),
    );
    await tester.pumpAndSettle();
    return (container, sip);
  }

  testWidgets('the transfer card is not shown outside transfer mode', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Transfer to a number or extension'), findsNothing);
    await _finish(tester);
  });

  testWidgets('transfer mode asks for any number below the search bar', (
    tester,
  ) async {
    final (container, sip) = await pump(tester);
    container
        .read(callTransferModeProvider.notifier)
        .begin(kind: CallTransferKind.blind, originalCallId: 'orig');
    await tester.pumpAndSettle();

    expect(find.text('Transfer to a number or extension'), findsOneWidget);
    await tester.tap(find.text('Transfer to a number or extension'));
    await tester.pumpAndSettle();

    final continueButton = find.widgetWithText(FilledButton, 'Continue');
    expect(tester.widget<FilledButton>(continueButton).onPressed, isNull);
    await tester.enterText(find.byType(TextField).last, '960');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(continueButton).onPressed, isNotNull);
    await tester.tap(continueButton);
    await tester.pumpAndSettle();

    expect(find.text('Transfer call to 960.'), findsOneWidget);
    await tester.tap(find.text('Transfer now'));
    await tester.pumpAndSettle();

    expect(sip.transfers, ['orig->960']);
    await _finish(tester);
  });

  testWidgets('letters are not accepted as a number', (tester) async {
    final (container, _) = await pump(tester);
    container
        .read(callTransferModeProvider.notifier)
        .begin(kind: CallTransferKind.blind, originalCallId: 'orig');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transfer to a number or extension'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'sales');
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue'))
          .onPressed,
      isNull,
    );
    await _finish(tester);
  });
}
