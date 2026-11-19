import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/messages/presentation/shared_content.dart';

void main() {
  test('parses a shared link with photos', () {
    final content = SharedContent.fromPayload({
      'id': 'a1',
      'text': ' https://a.co/d/xyz ',
      'files': [
        {'path': '/cache/p.jpg', 'mimeType': 'IMAGE/JPEG', 'name': 'p.jpg'},
        {'path': '', 'mimeType': 'image/jpeg', 'name': 'skipped'},
      ],
    });
    expect(content!.text, 'https://a.co/d/xyz');
    expect(content.files, hasLength(1));
    expect(content.files.single.mimeType, 'image/jpeg');
  });

  test('ignores payloads with no id or nothing to send', () {
    expect(SharedContent.fromPayload(null), isNull);
    expect(SharedContent.fromPayload({'id': 'a', 'text': ' '}), isNull);
    expect(SharedContent.fromPayload({'text': 'hi'}), isNull);
  });
}
