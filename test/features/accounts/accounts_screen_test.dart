import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/config/sip_transport.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/core/storage/storage_providers.dart';
import 'package:phone_app/features/accounts/domain/account_models.dart';
import 'package:phone_app/features/accounts/presentation/accounts_controller.dart';
import 'package:phone_app/features/accounts/presentation/accounts_screen.dart';
import 'package:phone_app/features/accounts/presentation/line_widgets.dart';
import 'package:phone_app/features/session/domain/app_session.dart';
import 'package:phone_app/features/session/domain/device_status.dart';
import 'package:phone_app/features/session/presentation/session_controller.dart';
import 'package:phone_app/features/sip/application/sip_service.dart';
import 'package:phone_app/features/sip/domain/sip_config.dart';
import 'package:phone_app/features/sip/domain/sip_registration_state.dart';

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

class _Sip extends Fake implements SipService {
  int removals = 0;

  @override
  SipRegistrationState getRegistrationState() => SipRegistrationState(
    status: SipRegistrationStatus.registered,
    updatedAt: DateTime(2026),
  );

  @override
  Stream<SipRegistrationState> get registrationStateStream =>
      const Stream.empty();

  @override
  SipRegistrationState getSecondaryRegistrationState() => SipRegistrationState(
    status: SipRegistrationStatus.registering,
    updatedAt: DateTime(2026),
  );

  @override
  Stream<SipRegistrationState> get secondaryRegistrationStateStream =>
      const Stream.empty();

  @override
  Future<void> removeSecondary() async => removals++;
}

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

void main() {
  late ProviderContainer container;
  late _Sip sip;

  Future<void> pump(WidgetTester tester, {required bool withSecond}) async {
    sip = _Sip();
    container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(_MemoryStorage()),
        sipServiceProvider.overrideWithValue(sip),
        sessionControllerProvider.overrideWith(_Primary.new),
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
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AccountsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('one account: offers to add a second, no dual features', (
    tester,
  ) async {
    await pump(tester, withSecond: false);
    expect(find.text('210 · swift'), findsOneWidget);
    expect(find.text('Primary'), findsOneWidget);
    expect(find.text('Add a second account'), findsOneWidget);
    expect(find.text('Add account'), findsOneWidget);
    expect(find.text('Call from'), findsNothing);
    expect(find.text('Remove second account'), findsNothing);
  });

  testWidgets('two accounts: shows both lines, the default choice and remove', (
    tester,
  ) async {
    await pump(tester, withSecond: true);
    expect(find.text('210 · swift'), findsWidgets);
    expect(find.text('305 · other'), findsWidgets);
    expect(find.text('Add account'), findsNothing);
    expect(find.text('Call from'), findsOneWidget);
    expect(find.text('Ask me'), findsOneWidget);
    expect(find.text('Remove second account'), findsOneWidget);
  });

  testWidgets('changing the default line is kept', (tester) async {
    await pump(tester, withSecond: true);
    final selector = find.byType(LineSegmented);
    await tester.ensureVisible(selector);
    await tester.tap(
      find.descendant(of: selector, matching: find.text('305 · other')),
    );
    await tester.pumpAndSettle();
    expect(
      container.read(accountsControllerProvider).value?.prefs.defaultOutgoing,
      DefaultOutgoingLine.secondary,
    );
  });

  testWidgets('removing the second account asks first, then removes it', (
    tester,
  ) async {
    await pump(tester, withSecond: true);
    await tester.ensureVisible(find.text('Remove second account'));
    await tester.tap(find.text('Remove second account'));
    await tester.pumpAndSettle();
    expect(find.text('Remove this account?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(sip.removals, 0);

    await tester.tap(find.text('Remove second account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(sip.removals, 1);
    expect(container.read(hasSecondaryAccountProvider), isFalse);
    expect(find.text('Add a second account'), findsOneWidget);
  });
}
