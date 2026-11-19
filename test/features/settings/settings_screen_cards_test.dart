import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/config/sip_transport.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/core/storage/storage_providers.dart';
import 'package:phone_app/features/session/domain/app_session.dart';
import 'package:phone_app/features/session/domain/device_status.dart';
import 'package:phone_app/features/session/presentation/session_controller.dart';
import 'package:phone_app/features/settings/presentation/settings_screen.dart';
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
  @override
  SipRegistrationState getRegistrationState() => SipRegistrationState(
    status: SipRegistrationStatus.registered,
    updatedAt: DateTime(2026),
  );

  @override
  Stream<SipRegistrationState> get registrationStateStream =>
      const Stream.empty();

  @override
  SipConfig? get currentConfig => null;
}

class _Primary extends SessionController {
  @override
  Future<AppSession?> build() async => AppSession.localSip(
    sipConfig: const SipConfig(
      extension: '210',
      sipUsername: '210',
      authUsername: '210',
      password: 'pw',
      domain: 'swift.example.test',
      registrar: 'swift.example.test',
      outboundProxy: 'swift.example.test',
      port: 5060,
      transport: SipTransport.udp,
    ),
    device: const DeviceStatus(
      provisioningStatus: DeviceProvisioningStatus.provisioned,
      sessionStatus: DeviceSessionStatus.active,
      revoked: false,
    ),
  );
}

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required bool accounts,
    required bool callingNetwork,
  }) async {
    await tester.binding.setSurfaceSize(const Size(390, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(_MemoryStorage()),
          sipServiceProvider.overrideWithValue(_Sip()),
          sessionControllerProvider.overrideWith(_Primary.new),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SettingsScreen(
              showAccountsCard: accounts,
              showCallingNetworkCard: callingNetwork,
            ),
          ),
        ),
      ),
    );
    // The screen shows a progress indicator while loading, so settle by hand.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  // Appearance (the theme choice) and About used to disappear when optional
  // cards were enabled, because the layout placed cards by fixed position.
  for (final accounts in [false, true]) {
    for (final callingNetwork in [false, true]) {
      testWidgets(
        'theme choice and About stay (accounts: $accounts, calling network: $callingNetwork)',
        (tester) async {
          await pump(
            tester,
            accounts: accounts,
            callingNetwork: callingNetwork,
          );
          expect(find.text('Appearance'), findsOneWidget);
          expect(find.text('System'), findsOneWidget);
          expect(find.text('Light'), findsOneWidget);
          expect(find.text('Dark'), findsOneWidget);
          expect(find.text('About'), findsOneWidget);
          expect(
            find.text('Accounts'),
            accounts ? findsOneWidget : findsNothing,
          );
          expect(
            find.text('Calling network'),
            callingNetwork ? findsOneWidget : findsNothing,
          );
        },
      );
    }
  }
}
