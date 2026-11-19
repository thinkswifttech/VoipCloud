import '../../../core/storage/secure_storage_service.dart';

/// Gives the second account's messaging its own keys in secure storage, so its
/// tokens, outbox key and deletion markers never mix with the primary's.
class LineScopedStorage implements SecureStorageService {
  const LineScopedStorage(this._inner, this._prefix);

  final SecureStorageService _inner;
  final String _prefix;

  @override
  Future<String?> read(String key) => _inner.read('$_prefix$key');

  @override
  Future<void> write(String key, String value) =>
      _inner.write('$_prefix$key', value);

  @override
  Future<void> delete(String key) => _inner.delete('$_prefix$key');

  @override
  Future<void> deleteAll() => throw UnsupportedError(
    'A scoped store cannot clear the whole secure storage.',
  );
}
