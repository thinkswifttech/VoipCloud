import 'dart:convert';

import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../domain/account_models.dart';

/// Secure storage for the second line and the pair's settings. The primary
/// account keeps its original session storage untouched.
class AccountsRepository {
  const AccountsRepository(this._storage);

  final SecureStorageService _storage;

  Future<SecondaryAccount?> readSecondary() async {
    final raw = await _storage.read(StorageKeys.appSecondaryAccount);
    if (raw == null || raw.isEmpty) return null;
    try {
      return SecondaryAccount.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } on Object {
      // A damaged record must never block the primary account.
      return null;
    }
  }

  Future<void> writeSecondary(SecondaryAccount account) => _storage.write(
    StorageKeys.appSecondaryAccount,
    jsonEncode(account.toJson()),
  );

  Future<AccountsPrefs> readPrefs() async {
    final raw = await _storage.read(StorageKeys.appAccountsPrefs);
    if (raw == null || raw.isEmpty) return const AccountsPrefs();
    try {
      return AccountsPrefs.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } on Object {
      return const AccountsPrefs();
    }
  }

  Future<void> writePrefs(AccountsPrefs prefs) =>
      _storage.write(StorageKeys.appAccountsPrefs, jsonEncode(prefs.toJson()));

  Future<void> clearSecondary() async {
    await _storage.delete(StorageKeys.appSecondaryAccount);
  }

  /// App reset: forget the second line and the pair's settings.
  Future<void> clearAll() async {
    await _storage.delete(StorageKeys.appSecondaryAccount);
    await _storage.delete(StorageKeys.appAccountsPrefs);
  }
}
