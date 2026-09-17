import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../../../core/storage/storage_providers.dart';

final termsAcceptanceRepositoryProvider = Provider<TermsAcceptanceRepository>(
  (ref) => TermsAcceptanceRepository(ref.watch(secureStorageProvider)),
);

class TermsAcceptanceRepository {
  const TermsAcceptanceRepository(this._storage);

  static const _pending = 'pending';
  static const _accepted = 'accepted';

  final SecureStorageService _storage;

  Future<bool> isPending() async {
    final value = await _storage.read(StorageKeys.appTermsAcceptance);
    return value == _pending || value?.startsWith('$_pending:') == true;
  }

  Future<void> markPending() {
    return _storage.write(StorageKeys.appTermsAcceptance, _pending);
  }

  Future<void> accept({required String version, required String sha256}) {
    return _storage.write(
      StorageKeys.appTermsAcceptance,
      '$_accepted:$version:$sha256',
    );
  }

  Future<void> clear() {
    return _storage.delete(StorageKeys.appTermsAcceptance);
  }
}
