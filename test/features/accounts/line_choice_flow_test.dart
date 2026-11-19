import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/config/sip_transport.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/core/storage/storage_providers.dart';
import 'package:phone_app/features/accounts/domain/account_models.dart';
import 'package:phone_app/features/accounts/presentation/accounts_controller.dart';
import 'package:phone_app/features/call_history/domain/call_history_item.dart';
import 'package:phone_app/features/call_history/presentation/call_history_providers.dart';
import 'package:phone_app/features/dialer/presentation/dialer_controller.dart';
import 'package:phone_app/features/dialer/presentation/dialer_line.dart';
import 'package:phone_app/features/session/domain/app_session.dart';
import 'package:phone_app/features/session/domain/device_status.dart';
import 'package:phone_app/features/session/presentation/session_controller.dart';
import 'package:phone_app/features/sip/application/sip_service.dart';
import 'package:phone_app/features/sip/domain/sip_config.dart';

class _MemoryStorage implements SecureStorageService {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<void> deleteAll() async => values.clear();
}

class _Sip extends Fake implements SipService {}

SipConfig _config(String extension, String domain) => SipConfig(
  extension: extension,
  sipUsername: extension,
  authUsername: extension,
  password: 'pw',
  domain: domain,
  registrar: domain,
  outboundProxy: domain,
  port: 5060,
  transport: SipTransport.udp,
);

AppSession _session(SipConfig config) => AppSession.localSip(
  sipConfig: config,
  device: const DeviceStatus(
    provisioningStatus: DeviceProvisioningStatus.provisioned,
    sessionStatus: DeviceSessionStatus.active,
    revoked: false,
  ),
);

class _Primary extends SessionController {
  @override
  Future<AppSession?> build() async =>
      _session(_config('210', 'swift.example.test'));
}

class _NoHistory extends CallHistoryController {
  @override
  Future<List<CallHistoryItem>> build() async => const [];
}

/// Calls [chooseLineForCall] from a button and shows what it returned.
class _Harness extends ConsumerStatefulWidget {
  const _Harness();

  @override
  ConsumerState<_Harness> createState() => _HarnessState();
}

class _HarnessState extends ConsumerState<_Harness> {
  String result = 'none';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          TextButton(
            onPressed: () async {
              final line = await chooseLineForCall(context, ref);
              setState(() => result = line?.name ?? 'cancelled');
            },
            child: const Text('call'),
          ),
          Text('result: $result'),
        ],
      ),
    );
  }
}

void main() {
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, {bool withSecond = true}) async {
    container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(_MemoryStorage()),
        sipServiceProvider.overrideWithValue(_Sip()),
        sessionControllerProvider.overrideWith(_Primary.new),
        callHistoryProvider.overrideWith(_NoHistory.new),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionControllerProvider.future);
    await container.read(accountsControllerProvider.future);
    if (withSecond) {
      await container
          .read(accountsControllerProvider.notifier)
          .addSecondary(_session(_config('305', 'other.example.test')));
    }
    container
        .read(dialerControllerProvider.notifier)
        .setDestination('4165550100');
    await container.read(callHistoryProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: _Harness()),
      ),
    );
  }

  testWidgets('asks which account, and remembers it when ticked', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.text('call'));
    await tester.pumpAndSettle();
    expect(find.text('Call from which account?'), findsOneWidget);
    expect(find.text('305 · other'), findsOneWidget);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('305 · other'));
    await tester.pumpAndSettle();

    expect(find.text('result: secondary'), findsOneWidget);
    expect(
      container.read(accountsControllerProvider).value?.prefs.defaultOutgoing,
      DefaultOutgoingLine.secondary,
    );

    // With a default saved, the next call does not ask.
    await tester.tap(find.text('call'));
    await tester.pumpAndSettle();
    expect(find.text('Call from which account?'), findsNothing);
    expect(find.text('result: secondary'), findsOneWidget);
  });

  testWidgets('picking without the tick asks again next time', (tester) async {
    await pump(tester);
    await tester.tap(find.text('call'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('210 · swift'));
    await tester.pumpAndSettle();
    expect(find.text('result: primary'), findsOneWidget);
    expect(
      container.read(accountsControllerProvider).value?.prefs.defaultOutgoing,
      DefaultOutgoingLine.ask,
    );
  });

  testWidgets('dismissing the question cancels the call', (tester) async {
    await pump(tester);
    await tester.tap(find.text('call'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('result: cancelled'), findsOneWidget);
  });

  testWidgets('a line you came from decides without asking', (tester) async {
    await pump(tester);
    container
        .read(dialerLineHintProvider.notifier)
        .set('4165550100', AccountLine.secondary);
    await tester.tap(find.text('call'));
    await tester.pumpAndSettle();
    expect(find.text('Call from which account?'), findsNothing);
    expect(find.text('result: secondary'), findsOneWidget);
  });

  testWidgets('with one account there is never a question', (tester) async {
    await pump(tester, withSecond: false);
    await tester.tap(find.text('call'));
    await tester.pumpAndSettle();
    expect(find.text('Call from which account?'), findsNothing);
    expect(find.text('result: primary'), findsOneWidget);
  });
}
