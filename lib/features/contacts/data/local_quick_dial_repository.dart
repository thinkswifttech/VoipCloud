import 'dart:convert';

import '../../../core/constants/storage_keys.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../domain/quick_dial_entry.dart';

class LocalQuickDialRepository {
  const LocalQuickDialRepository(this._storage);

  final SecureStorageService _storage;

  Future<List<QuickDialEntry>> getEntries() async {
    final raw = await _storage.read(StorageKeys.appQuickDial);
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const [];
      }
      final entries =
          decoded
              .whereType<Map>()
              .map(
                (item) =>
                    QuickDialEntry.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList()
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return entries;
    } catch (error) {
      AppLogger.warning('Quick dial read skipped', data: error);
      return const [];
    }
  }

  Future<List<QuickDialEntry>> saveEntries(List<QuickDialEntry> entries) async {
    final limited = entries.take(100).toList(growable: false);
    try {
      await _storage.write(
        StorageKeys.appQuickDial,
        jsonEncode(limited.map((entry) => entry.toJson()).toList()),
      );
    } catch (error) {
      AppLogger.warning('Quick dial write skipped', data: error);
    }
    return limited;
  }

  Future<void> clear() async {
    try {
      await _storage.delete(StorageKeys.appQuickDial);
    } catch (error) {
      AppLogger.warning('Quick dial clear skipped', data: error);
    }
  }
}
