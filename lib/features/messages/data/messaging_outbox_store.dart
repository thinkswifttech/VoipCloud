import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/constants/storage_keys.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../domain/messaging_repository.dart';

class MessagingOutboxItem {
  const MessagingOutboxItem({
    required this.clientId,
    required this.destination,
    required this.text,
    required this.createdAt,
    this.attachment,
  });

  factory MessagingOutboxItem.fromJson(Map<String, dynamic> json) {
    final rawAttachment = json['attachment'];
    return MessagingOutboxItem(
      clientId: '${json['client_id'] ?? ''}'.trim(),
      destination: '${json['destination'] ?? ''}'.trim(),
      text: '${json['text'] ?? ''}',
      createdAt:
          DateTime.tryParse('${json['created_at'] ?? ''}') ?? DateTime.now(),
      attachment: rawAttachment is Map
          ? OutboundMessageAttachment(
              bytes: Uint8List.fromList(
                base64Decode('${rawAttachment['bytes'] ?? ''}'),
              ),
              fileName: '${rawAttachment['file_name'] ?? ''}',
              contentType: '${rawAttachment['content_type'] ?? ''}',
            )
          : null,
    );
  }

  final String clientId;
  final String destination;
  final String text;
  final DateTime createdAt;
  final OutboundMessageAttachment? attachment;

  int get storedBytes =>
      utf8.encode(text).length + (attachment?.bytes.length ?? 0);

  Map<String, dynamic> toJson() => {
    'client_id': clientId,
    'destination': destination,
    'text': text,
    'created_at': createdAt.toUtc().toIso8601String(),
    if (attachment case final value?)
      'attachment': {
        'bytes': base64Encode(value.bytes),
        'file_name': value.fileName,
        'content_type': value.contentType,
      },
  };
}

class MessagingOutboxStore {
  MessagingOutboxStore({
    required SecureStorageService secureStorage,
    Future<Directory> Function()? supportDirectory,
    AesGcm? cipher,
  }) : _secureStorage = secureStorage,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _cipher = cipher ?? AesGcm.with256bits();

  static const maxItems = 100;
  static const maxStoredBytes = 25 * 1024 * 1024;

  final SecureStorageService _secureStorage;
  final Future<Directory> Function() _supportDirectory;
  final AesGcm _cipher;
  Future<void> _tail = Future.value();

  Future<List<MessagingOutboxItem>> readAll() =>
      _locked(() async => _readUnlocked());

  Future<void> enqueue(MessagingOutboxItem item) => _locked(() async {
    final items = await _readUnlocked();
    final existing = items.indexWhere(
      (value) => value.clientId == item.clientId,
    );
    if (existing >= 0) {
      items[existing] = item;
    } else {
      items.add(item);
    }
    items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final totalBytes = items.fold<int>(
      0,
      (sum, value) => sum + value.storedBytes,
    );
    if (items.length > maxItems || totalBytes > maxStoredBytes) {
      throw const StorageException(
        message: 'Messaging outbox capacity exceeded.',
        userMessage: 'Too many messages are waiting to send.',
      );
    }
    await _writeUnlocked(items);
  });

  Future<void> remove(String clientId) => _locked(() async {
    final items = await _readUnlocked();
    items.removeWhere((item) => item.clientId == clientId);
    await _writeUnlocked(items);
  });

  Future<void> clear() => _locked(() async {
    final paths = await _paths();
    for (final file in [paths.main, paths.backup, paths.temporary]) {
      if (await file.exists()) await file.delete();
    }
    await _secureStorage.delete(StorageKeys.messagingOutboxKey);
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

  Future<List<MessagingOutboxItem>> _readUnlocked() async {
    final paths = await _paths();
    for (final file in [paths.main, paths.backup]) {
      if (!await file.exists()) continue;
      try {
        final encrypted = await file.readAsString();
        final clear = await _decrypt(encrypted);
        final decoded = jsonDecode(clear);
        if (decoded is! List) throw const FormatException('Invalid outbox.');
        return decoded
            .whereType<Map>()
            .map(
              (row) =>
                  MessagingOutboxItem.fromJson(Map<String, dynamic>.from(row)),
            )
            .where(
              (item) => item.clientId.isNotEmpty && item.destination.isNotEmpty,
            )
            .toList(growable: true);
      } catch (_) {
        // Try the atomic backup. If neither decrypts, fail closed below.
      }
    }
    if (await paths.main.exists() || await paths.backup.exists()) {
      throw const StorageException(
        message: 'Encrypted messaging outbox could not be read.',
        userMessage: 'Messages waiting to send could not be restored.',
      );
    }
    return [];
  }

  Future<void> _writeUnlocked(List<MessagingOutboxItem> items) async {
    final paths = await _paths();
    if (items.isEmpty) {
      for (final file in [paths.main, paths.backup, paths.temporary]) {
        if (await file.exists()) await file.delete();
      }
      return;
    }
    final clear = jsonEncode(items.map((item) => item.toJson()).toList());
    final encrypted = await _encrypt(clear);
    await paths.temporary.writeAsString(encrypted, flush: true);
    if (await paths.backup.exists()) await paths.backup.delete();
    if (await paths.main.exists()) await paths.main.rename(paths.backup.path);
    await paths.temporary.rename(paths.main.path);
    if (await paths.backup.exists()) await paths.backup.delete();
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
      throw const FormatException('Unsupported outbox format.');
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
    var encoded = await _secureStorage.read(StorageKeys.messagingOutboxKey);
    if ((encoded == null || encoded.isEmpty) && create) {
      final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      encoded = base64Encode(bytes);
      await _secureStorage.write(StorageKeys.messagingOutboxKey, encoded);
    }
    if (encoded == null || encoded.isEmpty) {
      throw const StorageException(
        message: 'Messaging outbox encryption key is unavailable.',
      );
    }
    return SecretKey(base64Decode(encoded));
  }

  Future<({File main, File backup, File temporary})> _paths() async {
    final root = await _supportDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}messaging',
    );
    if (!await directory.exists()) await directory.create(recursive: true);
    return (
      main: File('${directory.path}${Platform.pathSeparator}outbox.v1'),
      backup: File('${directory.path}${Platform.pathSeparator}outbox.v1.bak'),
      temporary: File(
        '${directory.path}${Platform.pathSeparator}outbox.v1.tmp',
      ),
    );
  }
}
