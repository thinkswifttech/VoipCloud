import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../data/blf_feed_client.dart';
import '../domain/directory_access.dart';

/// Phones close the feed while backgrounded; desktop stays connected.
bool get isMobileBlfPlatform =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Null unless the build enables the feed, so nothing else needs to check.
final blfFeedClientProvider = Provider<BlfFeedClient?>((ref) {
  if (!blfFeedEnabled) return null;
  final client = BlfFeedClient(fetchCapabilities: dioBlfCapabilitiesFetcher());
  if (isMobileBlfPlatform) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    client.setForeground(
      lifecycle == null ||
          lifecycle == AppLifecycleState.resumed ||
          lifecycle == AppLifecycleState.inactive,
    );
  }
  ref.onDispose(() => unawaited(client.dispose()));
  return client;
});

Future<void> configureBlfFeedCredentials(
  BlfFeedClient feed,
  SecureStorageService storage,
  DirectoryAccess? access,
) async {
  final deviceId = (await storage.read(StorageKeys.appDeviceId))?.trim();
  final override = Uri.tryParse(blfFeedBaseUrl.trim());
  final baseUri =
      override != null && override.scheme == 'https' && override.host.isNotEmpty
      ? override
      : access?.endpoint;
  feed.setCredentials(
    access == null || baseUri == null || deviceId == null || deviceId.isEmpty
        ? null
        : BlfFeedCredentials(
            baseUri: baseUri,
            token: access.token,
            deviceId: deviceId,
          ),
  );
}
