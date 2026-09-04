import 'dart:convert';
import 'dart:typed_data';

enum QuickDialSource { contact, directory, custom }

class QuickDialEntry {
  const QuickDialEntry({
    required this.id,
    required this.displayName,
    required this.number,
    required this.source,
    required this.createdAt,
    this.sourceId,
    this.photoBytes,
  });

  final String id;
  final String displayName;
  final String number;
  final QuickDialSource source;
  final String? sourceId;
  final Uint8List? photoBytes;
  final DateTime createdAt;

  QuickDialEntry copyWith({
    String? displayName,
    String? number,
    Uint8List? photoBytes,
    bool clearPhoto = false,
  }) {
    return QuickDialEntry(
      id: id,
      displayName: displayName ?? this.displayName,
      number: number ?? this.number,
      source: source,
      sourceId: sourceId,
      photoBytes: clearPhoto ? null : photoBytes ?? this.photoBytes,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'displayName': displayName,
      'number': number,
      'source': source.name,
      'sourceId': sourceId,
      'photoBase64': photoBytes == null ? null : base64Encode(photoBytes!),
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory QuickDialEntry.fromJson(Map<String, dynamic> json) {
    final photoRaw = json['photoBase64']?.toString();
    Uint8List? photo;
    if (photoRaw != null && photoRaw.isNotEmpty) {
      try {
        photo = base64Decode(photoRaw);
      } catch (_) {
        photo = null;
      }
    }

    return QuickDialEntry(
      id: _string(
        json['id'],
        fallback: 'qd-${DateTime.now().microsecondsSinceEpoch}',
      ),
      displayName: _string(json['displayName']),
      number: _string(json['number']),
      source: QuickDialSource.values.firstWhere(
        (value) => value.name == _string(json['source']),
        orElse: () => QuickDialSource.custom,
      ),
      sourceId: _nullableString(json['sourceId']),
      photoBytes: photo,
      createdAt:
          DateTime.tryParse(_string(json['createdAt'])) ?? DateTime.now(),
    );
  }
}

String _string(Object? value, {String fallback = ''}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

String? _nullableString(Object? value) {
  final text = _string(value);
  return text.isEmpty ? null : text;
}
