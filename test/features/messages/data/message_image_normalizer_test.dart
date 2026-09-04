import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:phone_app/features/messages/data/message_image_normalizer.dart';

void main() {
  test('bakes JPEG EXIF orientation into the pixel dimensions', () async {
    final source = image.Image(width: 8, height: 4)
      ..exif.imageIfd.orientation = 6;
    final encoded = Uint8List.fromList(image.encodeJpg(source));

    final normalized = await normalizeMessageImage(
      bytes: encoded,
      contentType: 'image/jpeg',
      stripMetadata: true,
    );
    final decoded = image.decodeJpg(normalized);

    expect(decoded, isNotNull);
    expect(decoded!.width, 4);
    expect(decoded.height, 8);
    expect(decoded.exif.imageIfd.hasOrientation, isFalse);
  });

  test('leaves non-JPEG formats byte-for-byte unchanged', () async {
    final bytes = Uint8List.fromList(const [1, 2, 3, 4]);

    final normalized = await normalizeMessageImage(
      bytes: bytes,
      contentType: 'image/png',
      stripMetadata: true,
    );

    expect(normalized, same(bytes));
  });

  test('fails open for an inbound JPEG variant it cannot decode', () async {
    final bytes = Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xD9]);

    final normalized = await normalizeMessageImage(
      bytes: bytes,
      contentType: 'image/jpeg',
    );

    expect(normalized, same(bytes));
  });
}
