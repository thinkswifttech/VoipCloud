import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/features/messages/data/messaging_session_store.dart';
import 'package:phone_app/features/messages/domain/messaging_session.dart';

void main() {
  test(
    'persists, restores, and clears messaging credentials and replay state',
    () async {
      final storage = InMemorySecureStorageService();
      final store = MessagingSessionStore(storage);
      final session = MessagingSessionCredentials(
        accessToken: 'access-secret',
        refreshToken: 'refresh-secret',
        accessExpiresAt: DateTime.utc(2026, 8, 10, 19),
        refreshExpiresAt: DateTime.utc(2026, 9, 9, 19),
        sessionId: 'session-1',
        inboxId: 'inbox-1',
      );

      await store.write(session);
      await store.writeLastSequence(42);

      final restored = await store.read();
      expect(restored?.accessToken, 'access-secret');
      expect(restored?.refreshToken, 'refresh-secret');
      expect(restored?.sessionId, 'session-1');
      expect(restored?.inboxId, 'inbox-1');
      expect(await store.readLastSequence(), 42);

      await store.clear();
      expect(await store.read(), isNull);
      expect(await store.readLastSequence(), 0);
    },
  );

  test('rejects incomplete session responses', () {
    expect(
      () => MessagingSessionCredentials.fromJson({
        'access_token': 'access',
        'refresh_token': 'refresh',
        'access_expires_at': '2026-08-10T19:00:00Z',
        'refresh_expires_at': '2026-09-09T19:00:00Z',
        'session_id': 'session-1',
      }),
      throwsFormatException,
    );
  });
}
