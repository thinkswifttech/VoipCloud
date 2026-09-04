import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:phone_app/features/provisioning/domain/provisioning_qr_image_decoder.dart';
import 'package:zxing2/qrcode.dart';

void main() {
  test('decodes a provisioning link from a PNG QR image', () {
    const payload =
        'https://provision.example.test/activate?token=desktop-test';

    expect(decodeProvisioningQrImageSync(_qrPng(payload)), payload);
  });

  test('returns null when the image does not contain a QR code', () {
    final image = image_lib.Image(width: 240, height: 180);
    image_lib.fill(image, color: image_lib.ColorRgb8(255, 255, 255));

    expect(
      decodeProvisioningQrImageSync(
        Uint8List.fromList(image_lib.encodePng(image)),
      ),
      isNull,
    );
  });

  test('rejects files over the import size limit', () {
    expect(
      decodeProvisioningQrImageSync(
        Uint8List(maximumProvisioningQrFileBytes + 1),
      ),
      isNull,
    );
  });
}

Uint8List _qrPng(String value) {
  final matrix = Encoder.encode(value, ErrorCorrectionLevel.m).matrix!;
  const scale = 8;
  const quietZone = 4;
  final size = (matrix.width + quietZone * 2) * scale;
  final image = image_lib.Image(width: size, height: size);
  image_lib.fill(image, color: image_lib.ColorRgb8(255, 255, 255));

  for (var x = 0; x < matrix.width; x++) {
    for (var y = 0; y < matrix.height; y++) {
      if (matrix.get(x, y) != 1) continue;
      final left = (x + quietZone) * scale;
      final top = (y + quietZone) * scale;
      image_lib.fillRect(
        image,
        x1: left,
        y1: top,
        x2: left + scale - 1,
        y2: top + scale - 1,
        color: image_lib.ColorRgb8(0, 0, 0),
      );
    }
  }

  return Uint8List.fromList(image_lib.encodePng(image));
}
