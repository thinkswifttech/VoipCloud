import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/messages/presentation/message_text_presentation.dart';

void main() {
  test('keeps ordinary and mixed text at the standard size', () {
    expect(messageTextPresentation('Hello').fontSize, 14);
    expect(messageTextPresentation('Hello 👋').fontSize, 14);
  });

  test('enlarges short emoji-only messages', () {
    expect(messageTextPresentation('😀').fontSize, 30);
    expect(messageTextPresentation('❤️').fontSize, 30);
    expect(messageTextPresentation('👍🏽 👍🏽').fontSize, 30);
  });

  test('scales longer emoji-only messages without oversized wrapping', () {
    expect(messageTextPresentation('😀😀😀😀').fontSize, 25);
    expect(messageTextPresentation('😀😀😀😀😀😀😀').fontSize, 20);
  });
}
