import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/messages/presentation/linkified_text.dart';

void main() {
  test('splitLinks finds links and trims trailing punctuation', () {
    final parts = splitLinks(
      'Buy this https://amzn.eu/d/abc123. Or www.example.com/x!',
    );
    expect(parts.map((p) => p.$1), [
      'Buy this ',
      'https://amzn.eu/d/abc123',
      '. Or ',
      'www.example.com/x',
      '!',
    ]);
    expect(parts[1].$2, Uri.parse('https://amzn.eu/d/abc123'));
    expect(parts[3].$2, Uri.parse('https://www.example.com/x'));
    expect(parts[0].$2, isNull);
  });

  testWidgets('tapping a link opens it', (tester) async {
    Uri? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LinkifiedText(
            'see https://amzn.eu/d/abc123',
            style: const TextStyle(fontSize: 14),
            openLink: (uri) async {
              opened = uri;
              return true;
            },
          ),
        ),
      ),
    );
    final finder = find.byType(RichText).last;
    final box = tester.getRect(finder);
    await tester.tapAt(Offset(box.right - 10, box.center.dy));
    expect(opened, Uri.parse('https://amzn.eu/d/abc123'));
  });
}
