import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/config/sip_transport.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/core/storage/storage_providers.dart';
import 'package:phone_app/features/accounts/domain/account_models.dart';
import 'package:phone_app/features/accounts/presentation/accounts_controller.dart';
import 'package:phone_app/features/messages/domain/carrier_messaging_config.dart';
import 'package:phone_app/features/messages/presentation/messaging_lines.dart';
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
  @override
  Future<void> configureSecondary(SipConfig config) async {}
  @override
  Future<void> register() async {}
}

const _ready = CarrierMessagingConfig(
  enabled: true,
  did: '+15550100001',
  inboxId: 'inbox-1',
);
const _off = CarrierMessagingConfig(enabled: false, did: '', inboxId: '');

SipConfig _sip(String extension) => SipConfig(
  extension: extension,
  sipUsername: extension,
  authUsername: extension,
  password: 'pw',
  domain: 'example.test',
  registrar: 'example.test',
  outboundProxy: 'example.test',
  port: 5060,
  transport: SipTransport.udp,
);

AppSession _session(String extension, CarrierMessagingConfig? messaging) =>
    AppSession.localSip(
      sipConfig: _sip(extension),
      carrierMessaging: messaging,
      device: const DeviceStatus(
        provisioningStatus: DeviceProvisioningStatus.provisioned,
        sessionStatus: DeviceSessionStatus.active,
        revoked: false,
      ),
    );

void main() {
  Future<List<AccountLine>> lines({
    CarrierMessagingConfig? primary,
    bool hasSecond = false,
    CarrierMessagingConfig? second,
  }) async {
    final container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(_MemoryStorage()),
        sipServiceProvider.overrideWithValue(_Sip()),
        sessionControllerProvider.overrideWith(
          () => _FixedSession(_session('210', primary)),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionControllerProvider.future);
    await container.read(accountsControllerProvider.future);
    if (hasSecond) {
      await container
          .read(accountsControllerProvider.notifier)
          .addSecondary(_session('305', second));
    }
    return container.read(messagingLinesProvider);
  }

  test('one account with messaging: only that account', () async {
    expect(await lines(primary: _ready), [AccountLine.primary]);
  });

  test('one account without messaging: none', () async {
    expect(await lines(primary: _off), isEmpty);
    expect(await lines(), isEmpty);
  });

  test('only the primary can message', () async {
    expect(await lines(primary: _ready, hasSecond: true, second: _off), [
      AccountLine.primary,
    ]);
  });

  test('only the second account can message', () async {
    expect(await lines(primary: _off, hasSecond: true, second: _ready), [
      AccountLine.secondary,
    ]);
  });

  test('both can message', () async {
    expect(await lines(primary: _ready, hasSecond: true, second: _ready), [
      AccountLine.primary,
      AccountLine.secondary,
    ]);
  });

  test('neither can message', () async {
    expect(await lines(primary: _off, hasSecond: true, second: null), isEmpty);
  });
}

class _FixedSession extends SessionController {
  _FixedSession(this._session);
  final AppSession _session;
  @override
  Future<AppSession?> build() async => _session;
}
