import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/constants/storage_keys.dart';
import 'package:phone_app/core/errors/app_exception.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/features/session/data/secure_session_storage.dart';

void main() {
  test('iOS session storage remains device-bound after first unlock', () {
    expect(
      voipCloudIosSecureStorageOptions.accessibility,
      KeychainAccessibility.first_unlock_this_device,
    );
    expect(
      voipCloudIosSecureStorageOptions.accountName,
      'voipcloud_secure_storage_v2',
    );
    expect(voipCloudIosSecureStorageOptions.synchronizable, isFalse);
  });

  test(
    'retries a transient secure-storage read without losing session',
    () async {
      final backing = InMemorySecureStorageService();
      await backing.write(
        StorageKeys.appSipConfig,
        jsonEncode({
          'extension': '211',
          'sipUsername': '211',
          'authUsername': '211',
          'password': 'secret',
          'domain': 'swift.voipcloud.ca',
          'registrar': 'swift.voipcloud.ca',
          'outboundProxy': '',
          'port': 5061,
          'transport': 'TLS',
        }),
      );
      final storage = _FlakyStorage(backing, failuresRemaining: 1);

      final session = await SecureSessionStorage(
        storage,
      ).readSessionResilient(retryDelay: Duration.zero);

      expect(session?.sipConfig?.sipIdentity, '211@swift.voipcloud.ca');
      expect(storage.readAttempts, greaterThan(1));
      expect(await backing.read(StorageKeys.appSipConfig), isNotNull);
    },
  );

  test('exhausted secure-storage retries surface an error, not null', () async {
    final backing = InMemorySecureStorageService();
    await backing.write(StorageKeys.appSipConfig, '{"still":"present"}');
    final storage = _FlakyStorage(backing, failuresRemaining: 10);

    await expectLater(
      SecureSessionStorage(
        storage,
      ).readSessionResilient(maxAttempts: 3, retryDelay: Duration.zero),
      throwsA(isA<StorageException>()),
    );

    expect(await backing.read(StorageKeys.appSipConfig), isNotNull);
  });
}

class _FlakyStorage implements SecureStorageService {
  _FlakyStorage(this._delegate, {required this.failuresRemaining});

  final SecureStorageService _delegate;
  int failuresRemaining;
  int readAttempts = 0;

  @override
  Future<String?> read(String key) {
    readAttempts++;
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw const StorageException(message: 'Keychain temporarily locked');
    }
    return _delegate.read(key);
  }

  @override
  Future<void> write(String key, String value) => _delegate.write(key, value);

  @override
  Future<void> delete(String key) => _delegate.delete(key);

  @override
  Future<void> deleteAll() => _delegate.deleteAll();
}
