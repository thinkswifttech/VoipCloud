import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/config/sip_transport.dart';
import 'package:phone_app/core/errors/app_exception.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/core/storage/storage_providers.dart';
import 'package:phone_app/features/accounts/domain/account_models.dart';
import 'package:phone_app/features/accounts/presentation/accounts_controller.dart';
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

class _Sip extends Fake implements SipService {
  int removals = 0;

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

class _PrimarySession extends SessionController {
  @override
  Future<AppSession?> build() async =>
      _session(_config('210', 'swift.example.test'));
}

void main() {
  late _MemoryStorage storage;
  late _Sip sip;
  late ProviderContainer container;

  setUp(() {
    storage = _MemoryStorage();
    sip = _Sip();
    container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(storage),
        sipServiceProvider.overrideWithValue(sip),
        sessionControllerProvider.overrideWith(_PrimarySession.new),
      ],
    );
    addTearDown(container.dispose);
  });

  AccountsController controller() =>
      container.read(accountsControllerProvider.notifier);

  test('starts with one line and no dual-account features', () async {
    final state = await container.read(accountsControllerProvider.future);
    expect(state.hasSecondary, isFalse);
    expect(container.read(hasSecondaryAccountProvider), isFalse);
    await container.read(sessionControllerProvider.future);
    final lines = container.read(accountLinesProvider);
    expect(lines.map((line) => line.line), [AccountLine.primary]);
    expect(lines.single.label, '210 · swift');
  });

  test('adding a second account keeps it and lists both lines', () async {
    await container.read(accountsControllerProvider.future);
    await container.read(sessionControllerProvider.future);
    await controller().addSecondary(
      _session(_config('305', 'other.example.test')),
    );

    expect(container.read(hasSecondaryAccountProvider), isTrue);
    final lines = container.read(accountLinesProvider);
    expect(lines.map((line) => line.label), ['210 · swift', '305 · other']);
    // It survives a restart.
    final reread = await container
        .read(accountsRepositoryProvider)
        .readSecondary();
    expect(reread?.sipConfig.sipIdentity, '305@other.example.test');
  });

  test('the same account cannot be added twice or as a second line', () async {
    await container.read(accountsControllerProvider.future);
    await container.read(sessionControllerProvider.future);
    await expectLater(
      controller().addSecondary(_session(_config('210', 'swift.example.test'))),
      throwsA(isA<AppException>()),
    );
    await controller().addSecondary(
      _session(_config('305', 'other.example.test')),
    );
    await expectLater(
      controller().addSecondary(_session(_config('306', 'other.example.test'))),
      throwsA(isA<AppException>()),
    );
  });

  test('an account that cannot register is refused', () async {
    await container.read(accountsControllerProvider.future);
    await container.read(sessionControllerProvider.future);
    final blocked = AppSession.localSip(
      sipConfig: _config('305', 'other.example.test'),
      device: const DeviceStatus(
        provisioningStatus: DeviceProvisioningStatus.provisioned,
        sessionStatus: DeviceSessionStatus.active,
        revoked: true,
      ),
    );
    await expectLater(
      controller().addSecondary(blocked),
      throwsA(isA<AppException>()),
    );
    expect(container.read(hasSecondaryAccountProvider), isFalse);
  });

  test('settings: default line, names and colours are kept', () async {
    await container.read(accountsControllerProvider.future);
    await controller().setDefaultOutgoing(DefaultOutgoingLine.secondary);
    await controller().setAppearance(
      AccountLine.primary,
      label: 'Office',
      colorValue: 0xFF22A06B,
    );
    final prefs = (await container
        .read(accountsRepositoryProvider)
        .readPrefs());
    expect(prefs.defaultOutgoing, DefaultOutgoingLine.secondary);
    expect(prefs.primary.label, 'Office');
    expect(prefs.colorValue(AccountLine.primary), 0xFF22A06B);
  });

  test(
    'removing the second account resets the default and tells native',
    () async {
      await container.read(accountsControllerProvider.future);
      await container.read(sessionControllerProvider.future);
      await controller().addSecondary(
        _session(_config('305', 'other.example.test')),
      );
      await controller().setDefaultOutgoing(DefaultOutgoingLine.secondary);
      await controller().removeSecondary();

      expect(sip.removals, 1);
      expect(container.read(hasSecondaryAccountProvider), isFalse);
      final prefs = await container
          .read(accountsRepositoryProvider)
          .readPrefs();
      expect(prefs.defaultOutgoing, DefaultOutgoingLine.ask);
      expect(
        await container.read(accountsRepositoryProvider).readSecondary(),
        isNull,
      );
    },
  );

  test('an app reset forgets the second account and the settings', () async {
    await container.read(accountsControllerProvider.future);
    await container.read(sessionControllerProvider.future);
    await controller().addSecondary(
      _session(_config('305', 'other.example.test')),
    );
    await controller().resetForAppReset();
    expect(storage.values, isEmpty);
    expect(container.read(hasSecondaryAccountProvider), isFalse);
  });
}
