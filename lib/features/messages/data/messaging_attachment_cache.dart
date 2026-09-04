import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../domain/carrier_message.dart';

/// A private, bounded cache for normalized messaging attachments.
///
/// Files are encrypted individually with AES-256-GCM. Cache keys include the
/// inbox so content can never be reused across provisioned accounts. The
/// seven-day device lifetime limits stale local copies; longer-lived media is
/// downloaded again when needed.
class MessagingAttachmentCache {
  MessagingAttachmentCache({
    required SecureStorageService secureStorage,
    Future<Directory> Function()? supportDirectory,
    AesGcm? cipher,
    this.maxDiskBytes = 100 * 1024 * 1024,
    this.maxDiskItems = 200,
    this.maxMemoryBytes = 24 * 1024 * 1024,
    this.maxAge = const Duration(days: 7),
  }) : _secureStorage = secureStorage,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _cipher = cipher ?? AesGcm.with256bits();

  final SecureStorageService _secureStorage;
  final Future<Directory> Function() _supportDirectory;
  final AesGcm _cipher;
  final int maxDiskBytes;
  final int maxDiskItems;
  final int maxMemoryBytes;
  final Duration maxAge;

  final LinkedHashMap<String, MessageAttachmentContent> _memory =
      LinkedHashMap();
  final Map<String, Future<MessageAttachmentContent>> _inFlight = {};
  Future<void> _maintenanceTail = Future.value();
  int _memoryBytes = 0;
  int _generation = 0;

  Future<MessageAttachmentContent> getOrLoad({
    required String inboxId,
    required MessageAttachment attachment,
    required Future<MessageAttachmentContent> Function() loader,
  }) async {
    final key = _logicalKey(inboxId, attachment);
    final memory = _memory.remove(key);
    if (memory != null) {
      _memory[key] = memory;
      return memory;
    }
    final pending = _inFlight[key];
    if (pending != null) return pending;

    final generation = _generation;
    late final Future<MessageAttachmentContent> operation;
    operation = _restoreOrLoad(key, generation, loader).whenComplete(() {
      if (identical(_inFlight[key], operation)) _inFlight.remove(key);
    });
    _inFlight[key] = operation;
    return operation;
  }

  Future<void> clear({bool deleteKey = true}) async {
    _generation++;
    _memory.clear();
    _memoryBytes = 0;
    await _maintain(() async {
      final directory = await _directory(create: false);
      if (directory != null && await directory.exists()) {
        await directory.delete(recursive: true);
      }
      if (deleteKey) {
        await _secureStorage.delete(StorageKeys.messagingAttachmentCacheKey);
      }
    });
  }

  /// Completes after queued cache writes and pruning finish.
  Future<void> flush() => _maintenanceTail;

  Future<MessageAttachmentContent> _restoreOrLoad(
    String key,
    int generation,
    Future<MessageAttachmentContent> Function() loader,
  ) async {
    final restored = await _read(key);
    if (restored != null) {
      if (generation == _generation) _remember(key, restored);
      return restored;
    }
    final downloaded = await loader();
    if (generation == _generation) {
      _remember(key, downloaded);
      unawaited(_write(key, downloaded, generation).catchError((_) {}));
    }
    return downloaded;
  }

  Future<MessageAttachmentContent?> _read(String key) async {
    final file = await _fileFor(key, createDirectory: false);
    if (file == null || !await file.exists()) return null;
    try {
      final modified = await file.lastModified();
      if (DateTime.now().difference(modified) > maxAge) {
        await file.delete();
        return null;
      }
      final clear = await _decrypt(await file.readAsString());
      final value = jsonDecode(clear);
      if (value is! Map || value['v'] != 1) return null;
      final cachedAt = DateTime.tryParse('${value['cached_at'] ?? ''}');
      if (cachedAt == null || DateTime.now().difference(cachedAt) > maxAge) {
        await file.delete();
        return null;
      }
      final bytes = base64Decode('${value['bytes'] ?? ''}');
      final contentType = '${value['content_type'] ?? ''}'.trim();
      if (bytes.isEmpty || contentType.isEmpty) return null;
      await file.setLastModified(DateTime.now());
      return MessageAttachmentContent(
        bytes: Uint8List.fromList(bytes),
        contentType: contentType,
      );
    } catch (_) {
      if (await file.exists()) await file.delete();
      return null;
    }
  }

  Future<void> _write(
    String key,
    MessageAttachmentContent content,
    int generation,
  ) => _maintain(() async {
    if (generation != _generation) return;
    final file = await _fileFor(key, createDirectory: true);
    if (file == null) return;
    final temporary = File('${file.path}.tmp');
    final clear = jsonEncode({
      'v': 1,
      'cached_at': DateTime.now().toUtc().toIso8601String(),
      'content_type': content.contentType,
      'bytes': base64Encode(content.bytes),
    });
    await temporary.writeAsString(await _encrypt(clear), flush: true);
    if (generation != _generation) {
      if (await temporary.exists()) await temporary.delete();
      return;
    }
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
    await _prune();
  });

  void _remember(String key, MessageAttachmentContent content) {
    final previous = _memory.remove(key);
    if (previous != null) _memoryBytes -= previous.bytes.length;
    _memory[key] = content;
    _memoryBytes += content.bytes.length;
    while (_memoryBytes > maxMemoryBytes && _memory.isNotEmpty) {
      final oldestKey = _memory.keys.first;
      final removed = _memory.remove(oldestKey);
      if (removed != null) _memoryBytes -= removed.bytes.length;
    }
  }

  Future<void> _prune() async {
    final directory = await _directory(create: false);
    if (directory == null || !await directory.exists()) return;
    final records = <({File file, DateTime modified, int bytes})>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.v1')) continue;
      final stat = await entity.stat();
      records.add((file: entity, modified: stat.modified, bytes: stat.size));
    }
    records.sort((a, b) => b.modified.compareTo(a.modified));
    var retainedBytes = 0;
    for (var index = 0; index < records.length; index++) {
      final record = records[index];
      final expired = DateTime.now().difference(record.modified) > maxAge;
      final overItems = index >= maxDiskItems;
      final overBytes = retainedBytes + record.bytes > maxDiskBytes;
      if (expired || overItems || overBytes) {
        if (await record.file.exists()) await record.file.delete();
      } else {
        retainedBytes += record.bytes;
      }
    }
  }

  Future<String> _encrypt(String clear) async {
    final nonce = _cipher.newNonce();
    final box = await _cipher.encrypt(
      utf8.encode(clear),
      secretKey: await _key(),
      nonce: nonce,
    );
    return jsonEncode({
      'v': 1,
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    });
  }

  Future<String> _decrypt(String encrypted) async {
    final envelope = jsonDecode(encrypted);
    if (envelope is! Map || envelope['v'] != 1) {
      throw const FormatException('Unsupported attachment cache format.');
    }
    final clear = await _cipher.decrypt(
      SecretBox(
        base64Decode('${envelope['ciphertext'] ?? ''}'),
        nonce: base64Decode('${envelope['nonce'] ?? ''}'),
        mac: Mac(base64Decode('${envelope['mac'] ?? ''}')),
      ),
      secretKey: await _key(create: false),
    );
    return utf8.decode(clear);
  }

  Future<SecretKey> _key({bool create = true}) async {
    var encoded = await _secureStorage.read(
      StorageKeys.messagingAttachmentCacheKey,
    );
    if ((encoded == null || encoded.isEmpty) && create) {
      final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      encoded = base64Encode(bytes);
      await _secureStorage.write(
        StorageKeys.messagingAttachmentCacheKey,
        encoded,
      );
    }
    if (encoded == null || encoded.isEmpty) {
      throw const FormatException('Attachment cache key is unavailable.');
    }
    return SecretKey(base64Decode(encoded));
  }

  Future<File?> _fileFor(String key, {required bool createDirectory}) async {
    final directory = await _directory(create: createDirectory);
    if (directory == null) return null;
    final digest = await Sha256().hash(utf8.encode(key));
    final name = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return File('${directory.path}${Platform.pathSeparator}$name.v1');
  }

  Future<Directory?> _directory({required bool create}) async {
    final root = await _supportDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}messaging'
      '${Platform.pathSeparator}attachment-cache-v1',
    );
    if (create && !await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  String _logicalKey(String inboxId, MessageAttachment attachment) =>
      '$inboxId\u0000${attachment.id}\u0000${attachment.contentType}';

  Future<T> _maintain<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _maintenanceTail = _maintenanceTail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
