import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A file another app shared with VoipCloud, already copied into app storage
/// by the native side (Android intent / iOS share extension).
class SharedFile {
  const SharedFile({
    required this.path,
    required this.mimeType,
    required this.name,
  });

  final String path;
  final String mimeType;
  final String name;
}

/// What another app shared: some text (often a link) and/or photos.
class SharedContent {
  const SharedContent({
    required this.id,
    this.text = '',
    this.files = const [],
  });

  /// Null unless the payload has an id and something to send.
  static SharedContent? fromPayload(Map<dynamic, dynamic>? payload) {
    final id = '${payload?['id'] ?? ''}'.trim();
    final text = '${payload?['text'] ?? ''}'.trim();
    final files = <SharedFile>[
      for (final raw in (payload?['files'] as List?) ?? const [])
        if (raw is Map && '${raw['path'] ?? ''}'.isNotEmpty)
          SharedFile(
            path: '${raw['path']}',
            mimeType: '${raw['mimeType'] ?? ''}'.toLowerCase(),
            name: '${raw['name'] ?? ''}',
          ),
    ];
    if (id.isEmpty || (text.isEmpty && files.isEmpty)) return null;
    return SharedContent(id: id, text: text, files: files);
  }

  final String id;
  final String text;
  final List<SharedFile> files;
}

final sharedContentProvider =
    NotifierProvider<SharedContentNotifier, SharedContent?>(
      SharedContentNotifier.new,
    );

class SharedContentNotifier extends Notifier<SharedContent?> {
  @override
  SharedContent? build() => null;

  void set(SharedContent? content) => state = content;
}
