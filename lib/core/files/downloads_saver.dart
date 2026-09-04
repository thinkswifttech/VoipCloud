import 'dart:convert';
import 'package:flutter/services.dart';

class AppFiles {
  AppFiles({MethodChannel channel = const MethodChannel('voipcloud/files')})
    : _channel = channel;

  final MethodChannel _channel;

  /// Saves [bytes] as [fileName] into Downloads (Android) or Files (iOS).
  Future<String> saveBytes({
    required String fileName,
    required Uint8List bytes,
    String mimeType = 'application/octet-stream',
  }) async {
    final result = await _channel.invokeMethod<dynamic>(
      'saveToDownloads',
      <String, dynamic>{
        'fileName': fileName,
        'bytes': bytes,
        'mimeType': mimeType,
      },
    );
    if (result is String && result.trim().isNotEmpty) {
      return result.trim();
    }
    return fileName;
  }

  Future<String> saveText({
    required String fileName,
    required String content,
    String mimeType = 'text/csv',
  }) {
    return saveBytes(
      fileName: fileName,
      bytes: Uint8List.fromList(utf8.encode(content)),
      mimeType: mimeType,
    );
  }

  /// Opens a system file picker for a CSV/text file.
  /// Returns file contents, or null if the user cancels.
  Future<String?> pickCsvText() async {
    final result = await _channel.invokeMethod<dynamic>('pickCsv');
    if (result == null) {
      return null;
    }
    if (result is String) {
      return result;
    }
    if (result is Uint8List) {
      return utf8.decode(result, allowMalformed: true);
    }
    if (result is List<int>) {
      return utf8.decode(result, allowMalformed: true);
    }
    return result.toString();
  }
}

@Deprecated('Use AppFiles')
typedef DownloadsSaver = AppFiles;
