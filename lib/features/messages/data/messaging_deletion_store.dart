import 'dart:async';
import 'dart:convert';

import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/secure_storage_service.dart';

/// Encrypted, inbox-scoped suppression markers prevent an eventually
/// consistent conversation index from briefly resurrecting locally deleted
/// history after an app restart. A genuinely newer message reopens the thread.
class MessagingDeletionStore {
  MessagingDeletionStore(this._storage);

  static const _retention = Duration(days: 30);
  static const _maximumPerInbox = 500;

  final SecureStorageService _storage;
  Future<void> _tail = Future<void>.value();

  Future<Map<String, DateTime>> read(String inboxId) => _locked(() async {
    final all = await _readAll();
    return _parseInbox(all, inboxId);
  });

  Map<String, DateTime> _parseInbox(Map<String, dynamic> all, String inboxId) {
    final rows = all[inboxId];
    if (rows is! Map) return {};
    final cutoff = DateTime.now().toUtc().subtract(_retention);
    final result = <String, DateTime>{};
    for (final entry in rows.entries) {
      final deletedAt = DateTime.tryParse('${entry.value}')?.toUtc();
      if (deletedAt != null && !deletedAt.isBefore(cutoff)) {
        result['${entry.key}'] = deletedAt;
      }
    }
    return result;
  }

  Future<void> mark({
    required String inboxId,
    required String remoteNumber,
    required DateTime deletedAt,
  }) => _locked(() async {
    final all = await _readAll();
    final current = _parseInbox(all, inboxId);
    current[remoteNumber] = deletedAt.toUtc();
    final ordered = current.entries.toList()
      ..sort((left, right) => right.value.compareTo(left.value));
    all[inboxId] = {
      for (final entry in ordered.take(_maximumPerInbox))
        entry.key: entry.value.toIso8601String(),
    };
    await _writeAll(all);
  });

  Future<void> remove({
    required String inboxId,
    required String remoteNumber,
  }) => _locked(() async {
    final all = await _readAll();
    final rows = all[inboxId];
    if (rows is! Map || !rows.containsKey(remoteNumber)) return;
    final updated = Map<String, dynamic>.from(rows)..remove(remoteNumber);
    if (updated.isEmpty) {
      all.remove(inboxId);
    } else {
      all[inboxId] = updated;
    }
    await _writeAll(all);
  });

  Future<T> _locked<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<Map<String, dynamic>> _readAll() async {
    final encoded = await _storage.read(
      StorageKeys.messagingDeletedConversations,
    );
    if (encoded == null || encoded.isEmpty) return {};
    try {
      final decoded = jsonDecode(encoded);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeAll(Map<String, dynamic> value) async {
    if (value.isEmpty) {
      await _storage.delete(StorageKeys.messagingDeletedConversations);
      return;
    }
    await _storage.write(
      StorageKeys.messagingDeletedConversations,
      jsonEncode(value),
    );
  }
}
