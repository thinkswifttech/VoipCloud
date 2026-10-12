import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/constants/storage_keys.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/features/directory/data/blf_feed_client.dart';
import 'package:phone_app/features/directory/domain/directory_access.dart';
import 'package:phone_app/features/directory/presentation/blf_feed_providers.dart';

void main() {
  test('the feed is off unless the build enables it', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(blfFeedClientProvider), isNull);
  });

  test(
    'credentials use the directory token and the stored device id',
    () async {
      final storage = InMemorySecureStorageService();
      await storage.write(StorageKeys.appDeviceId, 'device-1');
      final fetched = <BlfFeedCredentials>[];
      final feed = BlfFeedClient(
        fetchCapabilities: (credentials) async {
          fetched.add(credentials);
          return const BlfCapabilities(enabled: false);
        },
      );
      feed.setTargets({'103'});
      await configureBlfFeedCredentials(
        feed,
        storage,
        DirectoryAccess(
          endpoint: Uri.parse('https://dir.example.test/api/directory'),
          token: 'secret',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(fetched.single.token, 'secret');
      expect(fetched.single.deviceId, 'device-1');
      expect(fetched.single.baseUri.host, 'dir.example.test');
      await feed.dispose();
    },
  );

  test('no device id or no directory access means no connection', () async {
    var fetches = 0;
    final feed = BlfFeedClient(
      fetchCapabilities: (_) async {
        fetches += 1;
        return const BlfCapabilities(enabled: false);
      },
    );
    feed.setTargets({'103'});
    final access = DirectoryAccess(
      endpoint: Uri.parse('https://dir.example.test/api/directory'),
      token: 'secret',
    );
    await configureBlfFeedCredentials(
      feed,
      InMemorySecureStorageService(),
      access,
    );
    final storage = InMemorySecureStorageService();
    await storage.write(StorageKeys.appDeviceId, 'device-1');
    await configureBlfFeedCredentials(feed, storage, null);
    await Future<void>.delayed(Duration.zero);
    expect(fetches, 0);
    await feed.dispose();
  });
}
