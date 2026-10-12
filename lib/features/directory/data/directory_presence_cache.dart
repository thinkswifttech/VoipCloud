import 'dart:convert';

import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../domain/directory_entry.dart';

// Restart continuity only; this is not a refresh/polling interval.
const directoryPresenceCacheLifetime = Duration(minutes: 1);
const cachedRingingLifetime = Duration(seconds: 15);

class CachedPresenceValue {
  const CachedPresenceValue({required this.presence, required this.observedAt});

  final DirectoryPresence presence;
  final DateTime observedAt;

  Map<String, Object> toJson() => {
    'presence': presence.name,
    'observed_at': observedAt.toUtc().toIso8601String(),
  };

  static CachedPresenceValue? fromJson(Object? value) {
    if (value is! Map) return null;
    final observedAt = DateTime.tryParse('${value['observed_at'] ?? ''}');
    if (observedAt == null) return null;
    return CachedPresenceValue(
      presence: directoryPresenceFromValue(value['presence']),
      observedAt: observedAt.toUtc(),
    );
  }
}

class CachedExtensionPresence {
  const CachedExtensionPresence({this.dialog, this.availability});

  final CachedPresenceValue? dialog;
  final CachedPresenceValue? availability;

  Map<String, Object> toJson() => {
    if (dialog != null) 'dialog': dialog!.toJson(),
    if (availability != null) 'availability': availability!.toJson(),
  };

  static CachedExtensionPresence? fromJson(Object? value) {
    if (value is! Map) return null;
    final dialog = CachedPresenceValue.fromJson(value['dialog']);
    final availability = CachedPresenceValue.fromJson(value['availability']);
    if (dialog == null && availability == null) return null;
    return CachedExtensionPresence(dialog: dialog, availability: availability);
  }
}

class DirectoryPresenceCacheSnapshot {
  const DirectoryPresenceCacheSnapshot({
    required this.identityKey,
    required this.savedAt,
    required this.extensions,
  });

  final String identityKey;
  final DateTime savedAt;
  final Map<String, CachedExtensionPresence> extensions;
}

class DirectoryPresenceCache {
  const DirectoryPresenceCache(this._storage);

  final SecureStorageService _storage;

  Future<DirectoryPresenceCacheSnapshot?> read({
    required String identityKey,
    required DateTime now,
  }) async {
    final raw = await _storage.read(StorageKeys.appDirectoryPresenceCache);
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['version'] != 1) return null;
      if ('${decoded['identity_key'] ?? ''}' != identityKey) return null;
      final savedAt = DateTime.tryParse(
        '${decoded['saved_at'] ?? ''}',
      )?.toUtc();
      if (savedAt == null ||
          now.toUtc().difference(savedAt) >= directoryPresenceCacheLifetime ||
          savedAt.isAfter(now.toUtc().add(const Duration(minutes: 1)))) {
        return null;
      }
      final rawExtensions = decoded['extensions'];
      if (rawExtensions is! Map) return null;
      final extensions = <String, CachedExtensionPresence>{};
      CachedPresenceValue? recent(CachedPresenceValue? value) {
        if (value == null ||
            now.toUtc().difference(value.observedAt) >=
                directoryPresenceCacheLifetime ||
            value.observedAt.isAfter(now.toUtc())) {
          return null;
        }
        return value;
      }

      for (final entry in rawExtensions.entries) {
        final extension = '${entry.key}'.trim();
        final presence = CachedExtensionPresence.fromJson(entry.value);
        if (extension.isNotEmpty && presence != null) {
          // A write caused by another extension must not extend an old value.
          final dialog = recent(presence.dialog);
          final availability = recent(presence.availability);
          if (dialog != null || availability != null) {
            extensions[extension] = CachedExtensionPresence(
              dialog: dialog,
              availability: availability,
            );
          }
        }
      }
      return DirectoryPresenceCacheSnapshot(
        identityKey: identityKey,
        savedAt: savedAt,
        extensions: extensions,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write(DirectoryPresenceCacheSnapshot snapshot) => _storage.write(
    StorageKeys.appDirectoryPresenceCache,
    jsonEncode({
      'version': 1,
      'identity_key': snapshot.identityKey,
      'saved_at': snapshot.savedAt.toUtc().toIso8601String(),
      'extensions': {
        for (final entry in snapshot.extensions.entries)
          entry.key: entry.value.toJson(),
      },
    }),
  );

  Future<void> clear() =>
      _storage.delete(StorageKeys.appDirectoryPresenceCache);
}
