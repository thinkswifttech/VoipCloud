import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/config/sip_transport.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/core/storage/storage_providers.dart';
import 'package:phone_app/features/accounts/presentation/accounts_controller.dart';
import 'package:phone_app/features/directory/data/directory_repository.dart';
import 'package:phone_app/features/directory/domain/directory_access.dart';
import 'package:phone_app/features/directory/domain/directory_entry.dart';
import 'package:phone_app/features/directory/presentation/directory_providers.dart';
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

/// Records which directory each request was for.
class _Repository extends DirectoryRepository {
  final fetchedHosts = <String?>[];

  @override
  Future<List<DirectoryEntry>> fetchDirectory(DirectoryAccess? access) async {
    fetchedHosts.add(access?.endpoint.host);
    return [
      DirectoryEntry(
        id: '102',
        displayName: 'From ${access?.endpoint.host}',
        numbers: const ['102'],
        telephoneKind: DirectoryTelephoneKind.internal,
        presence: DirectoryPresence.unknown,
      ),
    ];
  }
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

AppSession _session(SipConfig config, {DirectoryAccess? directory}) =>
    AppSession.localSip(
      sipConfig: config,
      device: const DeviceStatus(
        provisioningStatus: DeviceProvisioningStatus.provisioned,
        sessionStatus: DeviceSessionStatus.active,
        revoked: false,
      ),
      directoryAccess: directory,
    );

class _Primary extends SessionController {
  @override
  Future<AppSession?> build() async => _session(
    _config('210', 'swift.example.test'),
    directory: DirectoryAccess(
      endpoint: Uri.parse('https://swift-dir.example.test/directory'),
      token: 'primary-token',
    ),
  );
}

void main() {
  late ProviderContainer container;
  late _Repository repository;

  setUp(() {
    repository = _Repository();
    container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(_MemoryStorage()),
        sipServiceProvider.overrideWithValue(_Sip()),
        sessionControllerProvider.overrideWith(_Primary.new),
        directoryRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
  });

  test(
    'without a second account (or a directory for it) it is empty',
    () async {
      await container.read(sessionControllerProvider.future);
      await container.read(accountsControllerProvider.future);
      expect(await container.read(secondaryDirectoryProvider.future), isEmpty);
      expect(repository.fetchedHosts, isEmpty);

      // A second account that has no directory simply has none.
      await container
          .read(accountsControllerProvider.notifier)
          .addSecondary(_session(_config('305', 'other.example.test')));
      container.invalidate(secondaryDirectoryProvider);
      expect(await container.read(secondaryDirectoryProvider.future), isEmpty);
    },
  );

  test('each account loads its own phone system\'s directory', () async {
    await container.read(sessionControllerProvider.future);
    await container.read(accountsControllerProvider.future);
    await container
        .read(accountsControllerProvider.notifier)
        .addSecondary(
          _session(
            _config('305', 'other.example.test'),
            directory: DirectoryAccess(
              endpoint: Uri.parse('https://other-dir.example.test/directory'),
              token: 'second-token',
            ),
          ),
        );
    container.invalidate(secondaryDirectoryProvider);

    final primary = await container.read(directoryProvider.future);
    final second = await container.read(secondaryDirectoryProvider.future);

    // The same extension number, each from its own directory.
    expect(primary.single.displayName, 'From swift-dir.example.test');
    expect(second.single.displayName, 'From other-dir.example.test');
    expect(
      repository.fetchedHosts,
      containsAll(['swift-dir.example.test', 'other-dir.example.test']),
    );
  });
}
