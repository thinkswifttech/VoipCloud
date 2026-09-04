import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/constants/storage_keys.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/features/messages/data/messaging_attachment_cache.dart';
import 'package:phone_app/features/messages/domain/carrier_message.dart';

void main() {
  late Directory directory;
  late InMemorySecureStorageService secureStorage;

  final attachment = MessageAttachment(
    id: 'attachment-1',
    contentType: 'image/jpeg',
    state: MessageAttachmentState.ready,
    downloadUri: Uri(path: '/api/v1/messaging/media/attachment-1'),
  );
  final image = Uint8List.fromList([0xff, 0xd8, 1, 2, 3, 0xff, 0xd9]);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'messaging-attachment-cache-test-',
    );
    secureStorage = InMemorySecureStorageService();
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  MessagingAttachmentCache createCache() => MessagingAttachmentCache(
    secureStorage: secureStorage,
    supportDirectory: () async => directory,
  );

  test(
    'deduplicates downloads and restores encrypted content from disk',
    () async {
      var downloads = 0;
      final first = createCache();
      Future<MessageAttachmentContent> download() async {
        downloads++;
        return MessageAttachmentContent(
          bytes: image,
          contentType: 'image/jpeg',
        );
      }

      final loaded = await Future.wait([
        first.getOrLoad(
          inboxId: 'inbox-1',
          attachment: attachment,
          loader: download,
        ),
        first.getOrLoad(
          inboxId: 'inbox-1',
          attachment: attachment,
          loader: download,
        ),
      ]);
      expect(downloads, 1);
      expect(loaded.last.bytes, image);
      await first.flush();

      final cacheDirectory = Directory(
        '${directory.path}${Platform.pathSeparator}messaging'
        '${Platform.pathSeparator}attachment-cache-v1',
      );
      final files = await cacheDirectory
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.v1'))
          .cast<File>()
          .toList();
      expect(files, hasLength(1));
      final encrypted = await files.single.readAsString();
      expect(encrypted, isNot(contains('image/jpeg')));
      expect(encrypted, isNot(contains('/9gBAgP/2Q==')));

      final restored = await createCache().getOrLoad(
        inboxId: 'inbox-1',
        attachment: attachment,
        loader: () => throw StateError('network should not be used'),
      );
      expect(restored.bytes, image);
      expect(restored.contentType, 'image/jpeg');
    },
  );

  test('isolates inbox keys and securely clears files and key', () async {
    var downloads = 0;
    final cache = createCache();
    Future<MessageAttachmentContent> download() async {
      downloads++;
      return MessageAttachmentContent(bytes: image, contentType: 'image/jpeg');
    }

    await cache.getOrLoad(
      inboxId: 'inbox-1',
      attachment: attachment,
      loader: download,
    );
    await cache.getOrLoad(
      inboxId: 'inbox-2',
      attachment: attachment,
      loader: download,
    );
    expect(downloads, 2);
    await cache.flush();

    await cache.clear();
    expect(
      await secureStorage.read(StorageKeys.messagingAttachmentCacheKey),
      isNull,
    );
    expect(
      await Directory(
        '${directory.path}${Platform.pathSeparator}messaging'
        '${Platform.pathSeparator}attachment-cache-v1',
      ).exists(),
      isFalse,
    );
  });
}
