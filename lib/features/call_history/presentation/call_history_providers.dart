import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../data/local_call_history_repository.dart';
import '../domain/call_history_item.dart';
import '../domain/call_history_repository.dart';

final callHistoryStorageProvider = Provider<SecureStorageService>((ref) {
  return FlutterSecureStorageService(
    storage: const FlutterSecureStorage(
      iOptions: IOSOptions(
        accountName: 'voipcloud_call_history',
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    ),
  );
});

final callHistoryRepositoryProvider = Provider<CallHistoryRepository>((ref) {
  return LocalCallHistoryRepository(ref.watch(callHistoryStorageProvider));
});

final callHistoryProvider =
    AsyncNotifierProvider<CallHistoryController, List<CallHistoryItem>>(
      CallHistoryController.new,
    );

final missedCallCountProvider =
    AsyncNotifierProvider<MissedCallCountController, int>(
      MissedCallCountController.new,
    );

class MissedCallCountController extends AsyncNotifier<int> {
  var _viewGeneration = 0;

  @override
  Future<int> build() async {
    final viewGeneration = _viewGeneration;
    final items = await ref.watch(callHistoryProvider.future);
    final rawLastViewed = await ref
        .watch(callHistoryStorageProvider)
        .read(StorageKeys.appCallHistoryLastViewedAt);
    final count = unreadMissedCallCount(
      items,
      lastViewedAt: DateTime.tryParse(rawLastViewed ?? ''),
    );
    return viewGeneration == _viewGeneration ? count : 0;
  }

  Future<void> markViewed() async {
    _viewGeneration += 1;
    state = const AsyncData(0);
    try {
      await ref
          .read(callHistoryStorageProvider)
          .write(
            StorageKeys.appCallHistoryLastViewedAt,
            DateTime.now().toUtc().toIso8601String(),
          );
    } catch (_) {
      // Keep the badge cleared for this session even if secure storage is
      // temporarily unavailable. A later provider rebuild can retry it.
    }
  }
}

int unreadMissedCallCount(
  Iterable<CallHistoryItem> items, {
  required DateTime? lastViewedAt,
}) {
  final viewedAt = lastViewedAt?.toUtc();
  return items.where((item) {
    final isMissed = item.effectiveDisposition == CallHistoryDisposition.missed;
    if (!isMissed) return false;
    final completedAt = (item.endedAt ?? item.startedAt).toUtc();
    return viewedAt == null || completedAt.isAfter(viewedAt);
  }).length;
}

class CallHistoryController extends AsyncNotifier<List<CallHistoryItem>> {
  @override
  Future<List<CallHistoryItem>> build() async {
    try {
      return await ref
          .watch(callHistoryRepositoryProvider)
          .getCallHistory()
          .timeout(const Duration(seconds: 25));
    } on TimeoutException {
      return const [];
    } catch (_) {
      return const [];
    }
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
  }
}
