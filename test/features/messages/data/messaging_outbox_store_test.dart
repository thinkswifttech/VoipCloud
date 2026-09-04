import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/features/messages/data/messaging_outbox_store.dart';
import 'package:phone_app/features/messages/domain/messaging_repository.dart';

void main() {
  late Directory directory;
  late InMemorySecureStorageService secureStorage;
  late MessagingOutboxStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('messaging-outbox-test-');
    secureStorage = InMemorySecureStorageService();
    store = MessagingOutboxStore(
      secureStorage: secureStorage,
      supportDirectory: () async => directory,
    );
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('encrypts, restores, and removes queued SMS and MMS', () async {
    final createdAt = DateTime.utc(2026, 8, 13, 18);
    await store.enqueue(
      MessagingOutboxItem(
        clientId: 'queued-sms',
        destination: '+14165550123',
        text: 'Private queued body',
        createdAt: createdAt,
      ),
    );
    await store.enqueue(
      MessagingOutboxItem(
        clientId: 'queued-mms',
        destination: '+14165550124',
        text: 'Photo',
        createdAt: createdAt.add(const Duration(seconds: 1)),
        attachment: OutboundMessageAttachment(
          bytes: Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]),
          fileName: 'photo.jpg',
          contentType: 'image/jpeg',
        ),
      ),
    );

    final encrypted = await File(
      '${directory.path}${Platform.pathSeparator}messaging'
      '${Platform.pathSeparator}outbox.v1',
    ).readAsString();
    expect(encrypted, isNot(contains('Private queued body')));
    expect(encrypted, isNot(contains('+14165550123')));

    final restored = await store.readAll();
    expect(restored.map((item) => item.clientId), ['queued-sms', 'queued-mms']);
    expect(restored.last.attachment?.bytes, [0xff, 0xd8, 0xff, 0xd9]);

    await store.remove('queued-sms');
    expect((await store.readAll()).single.clientId, 'queued-mms');
    await store.clear();
    expect(await store.readAll(), isEmpty);
  });

  test('replaces an item with the same idempotency key', () async {
    final createdAt = DateTime.utc(2026, 8, 13, 18);
    for (final text in ['first', 'updated']) {
      await store.enqueue(
        MessagingOutboxItem(
          clientId: 'same-client-id',
          destination: '+14165550123',
          text: text,
          createdAt: createdAt,
        ),
      );
    }

    final restored = await store.readAll();
    expect(restored, hasLength(1));
    expect(restored.single.text, 'updated');
  });
}
