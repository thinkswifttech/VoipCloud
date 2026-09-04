import 'dart:convert';
import 'dart:typed_data';

import 'quick_dial_entry.dart';

class QuickDialCsvCodec {
  const QuickDialCsvCodec._();

  static const header = 'displayName,number,source,sourceId,photoBase64';

  static String encode(List<QuickDialEntry> entries) {
    final buffer = StringBuffer(header)..writeln();
    for (final entry in entries) {
      final photo = entry.photoBytes;
      buffer.writeln(
        [
          _escape(entry.displayName),
          _escape(entry.number),
          _escape(entry.source.name),
          _escape(entry.sourceId ?? ''),
          _escape(photo == null || photo.isEmpty ? '' : base64Encode(photo)),
        ].join(','),
      );
    }
    return buffer.toString();
  }

  static List<QuickDialEntry> decode(String raw) {
    final lines = raw
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) {
      return const [];
    }

    var start = 0;
    if (_looksLikeHeader(lines.first)) {
      start = 1;
    }

    final now = DateTime.now();
    final entries = <QuickDialEntry>[];
    for (var i = start; i < lines.length; i++) {
      final fields = _parseLine(lines[i]);
      if (fields.isEmpty) {
        continue;
      }
      final displayName = fields.isNotEmpty ? fields[0].trim() : '';
      final number = fields.length > 1 ? fields[1].trim() : '';
      if (displayName.isEmpty || number.isEmpty) {
        continue;
      }
      final sourceName = fields.length > 2 ? fields[2].trim() : '';
      final source = QuickDialSource.values.firstWhere(
        (value) => value.name == sourceName,
        orElse: () => QuickDialSource.custom,
      );
      final sourceId = fields.length > 3 ? fields[3].trim() : '';
      final photoRaw = fields.length > 4 ? fields[4].trim() : '';
      Uint8List? photo;
      if (photoRaw.isNotEmpty) {
        try {
          photo = base64Decode(photoRaw);
        } catch (_) {
          photo = null;
        }
      }
      entries.add(
        QuickDialEntry(
          id: 'qd-import-${now.microsecondsSinceEpoch}-$i',
          displayName: displayName,
          number: number.replaceAll(RegExp(r'\s+'), ''),
          source: source,
          sourceId: sourceId.isEmpty ? null : sourceId,
          photoBytes: photo,
          createdAt: now.add(Duration(microseconds: i)),
        ),
      );
    }
    return entries;
  }

  static bool _looksLikeHeader(String line) {
    final lower = line.toLowerCase();
    return lower.contains('displayname') || lower.contains('display_name');
  }

  static String _escape(String value) {
    if (value.contains(',') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  static List<String> _parseLine(String line) {
    final fields = <String>[];
    final buffer = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final char = line[i];
      if (inQuotes) {
        if (char == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            buffer.write('"');
            i += 1;
          } else {
            inQuotes = false;
          }
        } else {
          buffer.write(char);
        }
        continue;
      }
      if (char == '"') {
        inQuotes = true;
        continue;
      }
      if (char == ',') {
        fields.add(buffer.toString());
        buffer.clear();
        continue;
      }
      buffer.write(char);
    }
    fields.add(buffer.toString());
    return fields;
  }
}
