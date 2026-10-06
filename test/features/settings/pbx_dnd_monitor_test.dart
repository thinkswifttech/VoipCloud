import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/settings/application/pbx_dnd_monitor.dart';

String xml(int version, bool enabled) =>
    '<dialog-info xmlns="urn:ietf:params:xml:ns:dialog-info" version="$version" state="full" '
    'entity="sip:*76210@swift.voipcloud.ca"><dialog id="*76210"><state>'
    '${enabled ? 'confirmed' : 'terminated'}</state></dialog></dialog-info>';

class Harness {
  Harness() {
    monitor = PbxDndMonitor(
      events: events.stream,
      start: (extension, id) async {
        starts.add((extension, id));
        if (failStart) throw StateError('failed');
      },
      stop: () async {
        stops++;
      },
      toggle: () async {
        toggles++;
        if (failToggle) throw StateError('failed');
      },
      canToggle: () => idle,
    );
  }
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  late final PbxDndMonitor monitor;
  final starts = <(String, String)>[];
  int toggles = 0, stops = 0;
  bool idle = true, failStart = false, failToggle = false;
  String get id => starts.last.$2;
  void configure({String extension = '210', bool registered = true}) =>
      monitor.configure(
        identity: '$extension@swift.voipcloud.ca',
        extension: extension,
        domain: 'swift.voipcloud.ca',
        registered: registered,
      );
  void notify(int version, bool enabled, {String? epoch, String? body}) =>
      events.add({
        'kind': 'notify',
        'extension': '*76210',
        'event': 'dialog',
        'contentType': 'application/dialog-info+xml',
        'subscriptionId': epoch ?? id,
        'body': body ?? xml(version, enabled),
      });
  void error() => events.add({
    'kind': 'subscription',
    'extension': '*76210',
    'event': 'dialog',
    'subscriptionId': id,
    'state': 'error',
  });
}

class _Owner extends StatefulWidget {
  const _Owner(this.h);
  final Harness h;
  @override
  State<_Owner> createState() => _OwnerState();
}

class _OwnerState extends State<_Owner> {
  @override
  Widget build(BuildContext context) => const SizedBox();
  @override
  void dispose() {
    widget.h.monitor.dispose();
    super.dispose();
  }
}

void main() {
  test('real PBX off/on mapping', () {
    expect(
      parseDndDialog(xml(0, false), '*76210', 'swift.voipcloud.ca')!.enabled,
      isFalse,
    );
    expect(
      parseDndDialog(xml(1, true), '*76210', 'swift.voipcloud.ca')!.enabled,
      isTrue,
    );
  });
  for (final body in [
    '',
    '<broken>',
    xml(0, true).replaceAll('*76210', '*76211'),
    xml(0, true).replaceAll('swift.voipcloud.ca', 'other.example'),
    xml(0, true).replaceAll('confirmed', 'early'),
    xml(0, true).replaceAll('version="0"', 'version="-1"'),
    xml(0, true).replaceAll('urn:ietf:params:xml:ns:dialog-info', 'wrong'),
    '<!DOCTYPE x>${xml(0, true)}',
  ]) {
    test(
      'rejects invalid document $body',
      () =>
          expect(parseDndDialog(body, '*76210', 'swift.voipcloud.ca'), isNull),
    );
  }
  Future<Harness> setup(WidgetTester tester, {bool failStart = false}) async {
    final h = Harness()..failStart = failStart;
    addTearDown(() async {
      h.monitor.dispose();
      await tester.pump();
      await h.events.close();
    });
    await tester.pumpWidget(_Owner(h));
    h.configure();
    await tester.pump();
    return h;
  }

  testWidgets('remote off/on/off never dials', (tester) async {
    final h = await setup(tester);
    expect(h.monitor.state.enabled, isNull);
    h.notify(0, false);
    h.notify(1, true);
    h.notify(2, false);
    expect(h.monitor.state.enabled, isFalse);
    expect(h.toggles, 0);
  });
  testWidgets('duplicate and older versions ignored', (tester) async {
    final h = await setup(tester);
    h.notify(2, true);
    h.notify(2, false);
    h.notify(1, false);
    expect(h.monitor.state.enabled, isTrue);
  });

  testWidgets(
    'partial document invalidates state and requests a full snapshot',
    (tester) async {
      final h = await setup(tester);
      h.notify(0, true);
      h.notify(
        1,
        false,
        body: xml(1, false).replaceAll('state="full"', 'state="partial"'),
      );
      expect(h.monitor.state.enabled, isNull);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(h.starts, hasLength(2));
      expect(h.toggles, 0);
    },
  );

  test('namespace-prefixed PBX documents are supported', () {
    final prefixed = xml(0, true)
        .replaceAll('xmlns=', 'xmlns:d=')
        .replaceAll('<dialog-info', '<d:dialog-info')
        .replaceAll('</dialog-info', '</d:dialog-info')
        .replaceAll('<dialog ', '<d:dialog ')
        .replaceAll('</dialog>', '</d:dialog>')
        .replaceAll('<state>', '<d:state>')
        .replaceAll('</state>', '</d:state>');
    expect(
      parseDndDialog(prefixed, '*76210', 'swift.voipcloud.ca')!.enabled,
      isTrue,
    );
  });
  testWidgets('new epoch accepts zero, ignores old callbacks', (tester) async {
    final h = await setup(tester);
    final old = h.id;
    h.notify(10, true);
    h.monitor.refresh();
    await tester.pump();
    h.notify(11, true, epoch: old);
    expect(h.monitor.state.enabled, isNull);
    h.notify(0, false);
    expect(h.monitor.state.enabled, isFalse);
  });
  testWidgets('unknown cannot toggle; switch awaits confirmation', (
    tester,
  ) async {
    final h = await setup(tester);
    await h.monitor.setEnabled(true);
    expect(h.toggles, 0);
    h.notify(0, false);
    await h.monitor.setEnabled(true);
    expect(h.toggles, 1);
    expect(h.monitor.state.enabled, isFalse);
    expect(h.monitor.state.pending, isTrue);
    await h.monitor.setEnabled(true);
    expect(h.toggles, 1);
    h.notify(1, true);
    expect(h.monitor.state.enabled, isTrue);
    expect(h.monitor.state.pending, isFalse);
  });
  testWidgets('timeout resubscribes, never repeats toggle', (tester) async {
    final h = await setup(tester);
    h.notify(0, false);
    await h.monitor.setEnabled(true);
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(h.toggles, 1);
    expect(h.starts, hasLength(2));
    expect(h.monitor.state.enabled, isNull);
    expect(h.monitor.state.message, contains('not confirmed'));
    h.notify(0, true);
    expect(h.monitor.state.enabled, isTrue);
  });
  testWidgets('busy call refuses toggle without queuing', (tester) async {
    final h = await setup(tester);
    h.notify(0, false);
    h.idle = false;
    await h.monitor.setEnabled(true);
    h.idle = true;
    await tester.pump(const Duration(seconds: 20));
    expect(h.toggles, 0);
    expect(h.monitor.state.message, contains('End the current call'));
  });
  testWidgets('errors invalidate state and retry with backoff', (tester) async {
    final h = await setup(tester);
    h.notify(0, true);
    h.error();
    expect(h.monitor.state.enabled, isNull);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(h.starts, hasLength(2));
    h.error();
    await tester.pump(const Duration(seconds: 2));
    expect(h.starts, hasLength(2));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(h.starts, hasLength(3));
  });
  testWidgets('no notify times out instead of claiming off', (tester) async {
    final h = await setup(tester);
    await tester.pump(const Duration(seconds: 15));
    expect(h.monitor.state.enabled, isNull);
    expect(h.monitor.state.message, contains('did not respond'));
  });
  testWidgets('logout clears state and stops retries', (tester) async {
    final h = await setup(tester);
    final old = h.id;
    h.notify(0, true);
    h.configure(registered: false);
    await tester.pump();
    h.notify(1, true, epoch: old);
    expect(h.monitor.state.enabled, isNull);
    await tester.pump(const Duration(minutes: 5));
    expect(h.starts, hasLength(1));
  });
  testWidgets('another extension cannot inherit state', (tester) async {
    final h = await setup(tester);
    final old = h.id;
    h.notify(0, true);
    h.configure(extension: '211');
    await tester.pump();
    h.notify(1, true, epoch: old);
    expect(h.monitor.state.enabled, isNull);
  });
  testWidgets('healthy subscription renews without dialing', (tester) async {
    final h = await setup(tester);
    h.notify(0, false);
    await tester.pump(const Duration(minutes: 4));
    await tester.pump();
    expect(h.starts, hasLength(2));
    expect(h.toggles, 0);
  });
  testWidgets('identical snapshots do not duplicate subscriptions', (
    tester,
  ) async {
    final h = await setup(tester);
    h.configure();
    h.configure();
    await tester.pump();
    expect(h.starts, hasLength(1));
  });
  testWidgets('native toggle errors are visible and not retried', (
    tester,
  ) async {
    final h = await setup(tester);
    h.notify(0, false);
    h.failToggle = true;
    await h.monitor.setEnabled(true);
    expect(h.monitor.state.pending, isFalse);
    expect(h.monitor.state.message, contains('Unable'));
    expect(h.toggles, 1);
  });
  testWidgets('native start failure is recoverable', (tester) async {
    final h = await setup(tester, failStart: true);
    expect(h.monitor.state.enabled, isNull);
    h.failStart = false;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    h.notify(0, false);
    expect(h.monitor.state.enabled, isFalse);
  });
}
