import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/settings/presentation/dnd_subscription_diagnostic.dart';
import 'package:phone_app/voip/platform/voip_platform_channel.dart';

class _Platform extends VoipPlatformChannel {
  final events = StreamController<Map<String, dynamic>>.broadcast();
  final operations = <String>[];
  Completer<void>? startup;
  bool fail = false;
  @override
  Stream<Map<String, dynamic>> presenceEvents() => events.stream;
  @override
  Future<void> startDndDiagnostic(String extension) async {
    operations.add('start:$extension');
    if (fail) throw StateError('failed');
    await startup?.future;
  }

  @override
  Future<void> stopDndDiagnostic() async {
    operations.add('stop');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('diagnostic uses a scoped SUBSCRIBE bridge, never a call', () async {
    const channel = MethodChannel('test/dnd-contract');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    const platform = VoipPlatformChannel(channel: channel);
    await platform.startDndDiagnostic('210');
    await platform.stopDndDiagnostic();
    expect(calls.map((e) => e.method), [
      'startPresenceSubscriptions',
      'stopPresenceSubscriptions',
    ]);
    expect(calls.first.arguments, {
      'extensions': ['*76210'],
      'diagnostic': true,
    });
    expect(calls.last.arguments, {'diagnostic': true});
    expect(() => platform.startDndDiagnostic('210@other'), throwsArgumentError);
  });

  test('presence listeners share the same stream', () {
    const platform = VoipPlatformChannel();
    expect(
      identical(platform.presenceEvents(), platform.presenceEvents()),
      isTrue,
    );
  });
  test('persistent DND carries a native epoch without replacing BLF', () async {
    const channel = MethodChannel('test/dnd-persistent');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    const platform = VoipPlatformChannel(channel: channel);
    await platform.startPbxDndSubscription('210', 'epoch-1');
    await platform.startPresenceSubscriptions(['211']);
    expect(calls.first.arguments, {
      'extensions': ['*76210'],
      'diagnostic': true,
      'subscriptionId': 'epoch-1',
    });
    expect(calls.last.arguments, {
      'extensions': ['211'],
    });
  });

  Future<void> show(
    WidgetTester tester,
    _Platform platform, {
    bool registered = true,
    String identity = '210@swift.voipcloud.ca',
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: DndSubscriptionDiagnostic(
            extension: '210',
            registered: registered,
            accountIdentity: identity,
            platform: platform,
            duration: const Duration(seconds: 5),
          ),
        ),
      ),
    ),
  );

  testWidgets('captures only own DND events and automatically stops', (
    tester,
  ) async {
    final platform = _Platform();
    addTearDown(platform.events.close);
    await show(tester, platform);
    await tester.tap(find.text('Start DND test'));
    await tester.pump();
    expect(platform.operations, ['start:210']);
    platform.events.add({
      'kind': 'notify',
      'extension': '211',
      'body': 'unrelated-pbx-notification',
    });
    platform.events.add({
      'kind': 'subscription',
      'extension': '*76210',
      'event': 'dialog',
      'state': 'active',
    });
    platform.events.add({
      'kind': 'notify',
      'extension': '*76210',
      'event': 'dialog',
      'contentType': 'application/dialog-info+xml',
      'body': '<state>confirmed</state>',
    });
    await tester.pump();
    expect(find.textContaining('<state>confirmed</state>'), findsOneWidget);
    expect(
      find.textContaining('SUBSCRIPTION event=dialog state=active'),
      findsOneWidget,
    );
    expect(find.textContaining('unrelated-pbx-notification'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(platform.operations, ['start:210', 'stop']);
    expect(find.text('Test stopped'), findsOneWidget);
  });

  testWidgets('unregistered account cannot start', (tester) async {
    final platform = _Platform();
    addTearDown(platform.events.close);
    await show(tester, platform, registered: false);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Start DND test'),
          )
          .onPressed,
      isNull,
    );
    expect(platform.operations, isEmpty);
  });

  testWidgets('account replacement stops the probe', (tester) async {
    final platform = _Platform();
    addTearDown(platform.events.close);
    await show(tester, platform);
    await tester.tap(find.text('Start DND test'));
    await tester.pump();
    await show(tester, platform, identity: '210@another.example');
    await tester.pump();
    expect(platform.operations, ['start:210', 'stop']);
  });

  testWidgets('dispose during startup cleans up after late completion', (
    tester,
  ) async {
    final platform = _Platform()..startup = Completer<void>();
    addTearDown(platform.events.close);
    await show(tester, platform);
    await tester.tap(find.text('Start DND test'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    platform.startup!.complete();
    await tester.pump();
    expect(platform.operations, ['start:210', 'stop']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native failure is visible and cleaned up', (tester) async {
    final platform = _Platform()..fail = true;
    addTearDown(platform.events.close);
    await show(tester, platform);
    await tester.tap(find.text('Start DND test'));
    await tester.pump();
    await tester.pump();
    expect(
      find.textContaining('Unable to start subscription test.'),
      findsOneWidget,
    );
    expect(platform.operations, ['start:210', 'stop']);
    expect(find.text('Test stopped'), findsOneWidget);
  });
}
