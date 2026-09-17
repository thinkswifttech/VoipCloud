import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../errors/app_exception.dart';

abstract class SecureStorageService {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  Future<void> deleteAll();
}

/// Device-bound iOS Keychain policy used for provisioned application data.
///
/// VoIP pushes can cold-launch the process while the phone is locked. After
/// the first unlock following a reboot, these values therefore need to remain
/// readable while the device is locked. `this_device` also prevents SIP and
/// API credentials from migrating to another phone through a backup.
const voipCloudIosSecureStorageOptions = IOSOptions(
  accountName: 'voipcloud_secure_storage_v2',
  accessibility: KeychainAccessibility.first_unlock_this_device,
  synchronizable: false,
);

/// Compatibility policy used by releases that stored values in the package's
/// default Keychain namespace with `whenUnlocked` accessibility.
const _legacyIosSecureStorageOptions = IOSOptions(
  accessibility: KeychainAccessibility.unlocked,
  synchronizable: false,
);

class FlutterSecureStorageService implements SecureStorageService {
  FlutterSecureStorageService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage(),
      _usesManagedIosPolicy = storage == null;

  final FlutterSecureStorage _storage;
  final bool _usesManagedIosPolicy;

  bool get _shouldUseManagedIosPolicy =>
      _usesManagedIosPolicy &&
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Future<String?> read(String key) async {
    try {
      if (!_shouldUseManagedIosPolicy) {
        return await _storage.read(key: key);
      }

      final current = await _storage.read(
        key: key,
        iOptions: voipCloudIosSecureStorageOptions,
      );
      if (current != null) return current;

      // Existing installations used the plugin's default Keychain service and
      // when-unlocked accessibility. Read it only as a migration fallback,
      // then copy it into the hardened, device-bound namespace. Keeping the
      // legacy item until an explicit reset makes this migration interruption
      // safe if iOS suspends the process between the read and write.
      final legacy = await _storage.read(
        key: key,
        iOptions: _legacyIosSecureStorageOptions,
      );
      if (legacy != null) {
        await _storage.write(
          key: key,
          value: legacy,
          iOptions: voipCloudIosSecureStorageOptions,
        );
      }
      return legacy;
    } catch (error) {
      throw StorageException(message: 'Failed to read secure key "$key"');
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(
        key: key,
        value: value,
        iOptions: _shouldUseManagedIosPolicy
            ? voipCloudIosSecureStorageOptions
            : null,
      );
    } catch (error) {
      throw StorageException(message: 'Failed to write secure key "$key"');
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      if (!_shouldUseManagedIosPolicy) {
        await _storage.delete(key: key);
        return;
      }
      // Remove the fallback first so an interruption can leave the current
      // value intact, but can never resurrect an obsolete legacy value after
      // the current value has been removed.
      await _storage.delete(
        key: key,
        iOptions: _legacyIosSecureStorageOptions,
      );
      await _storage.delete(
        key: key,
        iOptions: voipCloudIosSecureStorageOptions,
      );
    } catch (error) {
      throw StorageException(message: 'Failed to delete secure key "$key"');
    }
  }

  @override
  Future<void> deleteAll() async {
    try {
      if (!_shouldUseManagedIosPolicy) {
        await _storage.deleteAll();
        return;
      }
      await _storage.deleteAll(iOptions: _legacyIosSecureStorageOptions);
      await _storage.deleteAll(iOptions: voipCloudIosSecureStorageOptions);
    } catch (error) {
      throw const StorageException(message: 'Failed to clear secure storage');
    }
  }
}

class InMemorySecureStorageService implements SecureStorageService {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<void> deleteAll() async {
    _values.clear();
  }
}
