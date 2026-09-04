import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/features/messages/data/messaging_deletion_store.dart';

void main() {
  late InMemorySecureStorageService storage;

  setUp(() {
    storage = InMemorySecureStorageService();
  });

  test('deleted conversation markers survive controller recreation', () async {
    final deletedAt = DateTime.utc(2026, 9, 1, 13, 30);
    await MessagingDeletionStore(storage).mark(
      inboxId: 'inbox-a',
      remoteNumber: '+14165550123',
      deletedAt: deletedAt,
    );

    final restored = await MessagingDeletionStore(storage).read('inbox-a');

    expect(restored, {'+14165550123': deletedAt});
  });

  test('markers are isolated by inbox and can be removed', () async {
    final store = MessagingDeletionStore(storage);
    await Future.wait([
      store.mark(
        inboxId: 'inbox-a',
        remoteNumber: '+14165550123',
        deletedAt: DateTime.utc(2026, 9, 1, 13, 30),
      ),
      store.mark(
        inboxId: 'inbox-b',
        remoteNumber: '+14165550124',
        deletedAt: DateTime.utc(2026, 9, 1, 13, 31),
      ),
    ]);

    expect((await store.read('inbox-a')).keys, ['+14165550123']);
    expect((await store.read('inbox-b')).keys, ['+14165550124']);

    await store.remove(inboxId: 'inbox-a', remoteNumber: '+14165550123');

    expect(await store.read('inbox-a'), isEmpty);
    expect((await store.read('inbox-b')).keys, ['+14165550124']);
  });
}
