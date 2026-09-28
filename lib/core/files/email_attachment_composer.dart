import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

typedef SystemFileShare = Future<ShareResult> Function(ShareParams params);

class EmailAttachmentComposer {
  EmailAttachmentComposer({
    MethodChannel channel = const MethodChannel('voipcloud/windows_email'),
    bool? isSupported,
    bool? useWindowsEmailComposer,
    Future<Directory> Function()? temporaryDirectory,
    SystemFileShare? systemShare,
  }) : _channel = channel,
       isSupported =
           isSupported ??
           (Platform.isAndroid ||
               Platform.isIOS ||
               Platform.isMacOS ||
               Platform.isWindows),
       _useWindowsEmailComposer = useWindowsEmailComposer ?? Platform.isWindows,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _systemShare = systemShare ?? SharePlus.instance.share;

  final MethodChannel _channel;
  final bool isSupported;
  final bool _useWindowsEmailComposer;
  final Future<Directory> Function() _temporaryDirectory;
  final SystemFileShare _systemShare;

  Future<void> composeLog({
    required String fileName,
    required String content,
    Rect? sharePositionOrigin,
  }) async {
    if (!isSupported) {
      throw UnsupportedError('Email attachment sharing is unavailable.');
    }
    if (fileName.isEmpty ||
        fileName != File(fileName).uri.pathSegments.last ||
        fileName.contains('/') ||
        fileName.contains('\\')) {
      throw ArgumentError.value(fileName, 'fileName', 'Invalid file name');
    }
    final root = await _temporaryDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}ThinkSwift'
      '${Platform.pathSeparator}VoipCloud${Platform.pathSeparator}logs',
    );
    await directory.create(recursive: true);
    await _removeExpiredLogs(directory);
    final file = File('${directory.path}${Platform.pathSeparator}$fileName');
    await file.writeAsString(content, flush: true);

    if (_useWindowsEmailComposer) {
      try {
        await _channel.invokeMethod<void>('compose', <String, String>{
          'path': file.path,
          'subject': 'VoipCloud SIP logs',
          'body': 'VoipCloud SIP diagnostic logs are attached.',
        });
        return;
      } on PlatformException {
        // Some Windows email clients do not expose Simple MAPI. The modern
        // system share panel can still pass the attachment to those clients.
      }
    }

    await _systemShare(
      ShareParams(
        title: 'Share VoipCloud SIP logs',
        subject: 'VoipCloud SIP logs',
        text: 'VoipCloud SIP diagnostic logs are attached.',
        files: [XFile(file.path, mimeType: 'text/plain')],
        fileNameOverrides: [fileName],
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }

  Future<void> _removeExpiredLogs(Directory directory) async {
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    try {
      await for (final entity in directory.list()) {
        if (entity is! File) continue;
        final modified = await entity.lastModified();
        if (modified.isBefore(cutoff)) {
          await entity.delete();
        }
      }
    } on FileSystemException {
      // Temporary-file cleanup must never prevent the current export.
    }
  }
}
