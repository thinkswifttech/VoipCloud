import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
