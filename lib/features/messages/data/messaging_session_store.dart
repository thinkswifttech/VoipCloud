import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../domain/messaging_session.dart';

class MessagingSessionStore {
  const MessagingSessionStore(this._storage);

  final SecureStorageService _storage;

  Future<MessagingSessionCredentials?> read() async {
    final access = await _storage.read(StorageKeys.messagingAccessToken);
    final refresh = await _storage.read(StorageKeys.messagingRefreshToken);
    final accessExpiry = DateTime.tryParse(
      await _storage.read(StorageKeys.messagingAccessExpiresAt) ?? '',
    );
    final refreshExpiry = DateTime.tryParse(
      await _storage.read(StorageKeys.messagingRefreshExpiresAt) ?? '',
    );
    final sessionId = await _storage.read(StorageKeys.messagingSessionId);
    final inboxId = await _storage.read(StorageKeys.messagingInboxId);

    if (access == null ||
        refresh == null ||
        accessExpiry == null ||
        refreshExpiry == null ||
        sessionId == null ||
        inboxId == null) {
      return null;
    }

    return MessagingSessionCredentials(
      accessToken: access,
      refreshToken: refresh,
      accessExpiresAt: accessExpiry.toUtc(),
      refreshExpiresAt: refreshExpiry.toUtc(),
      sessionId: sessionId,
      inboxId: inboxId,
    );
  }

  Future<void> write(MessagingSessionCredentials session) async {
    await _storage.write(StorageKeys.messagingAccessToken, session.accessToken);
    await _storage.write(
      StorageKeys.messagingRefreshToken,
      session.refreshToken,
    );
    await _storage.write(
      StorageKeys.messagingAccessExpiresAt,
      session.accessExpiresAt.toIso8601String(),
    );
    await _storage.write(
      StorageKeys.messagingRefreshExpiresAt,
      session.refreshExpiresAt.toIso8601String(),
    );
    await _storage.write(StorageKeys.messagingSessionId, session.sessionId);
    await _storage.write(StorageKeys.messagingInboxId, session.inboxId);
  }

  Future<int> readLastSequence() async {
    return int.tryParse(
          await _storage.read(StorageKeys.messagingLastSequence) ?? '',
        ) ??
        0;
  }

  Future<void> writeLastSequence(int sequence) {
    return _storage.write(StorageKeys.messagingLastSequence, '$sequence');
  }

  Future<void> clear() async {
    await _storage.delete(StorageKeys.messagingAccessToken);
    await _storage.delete(StorageKeys.messagingRefreshToken);
    await _storage.delete(StorageKeys.messagingAccessExpiresAt);
    await _storage.delete(StorageKeys.messagingRefreshExpiresAt);
    await _storage.delete(StorageKeys.messagingSessionId);
    await _storage.delete(StorageKeys.messagingInboxId);
    await _storage.delete(StorageKeys.messagingLastSequence);
  }
}
