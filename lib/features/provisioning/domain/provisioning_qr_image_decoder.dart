import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as image_lib;
import 'package:zxing2/qrcode.dart';

const int maximumProvisioningQrFileBytes = 12 * 1024 * 1024;
const int _maximumImageDimension = 8192;
const int _maximumImagePixels = 32 * 1024 * 1024;
const int _maximumDecodeDimension = 3072;

/// Decodes a QR image away from the UI isolate.
///
/// The image is bounded before its pixels are decoded to avoid an accidentally
/// huge or malicious image consuming unbounded desktop memory.
Future<String?> decodeProvisioningQrImage(Uint8List bytes) {
  return Isolate.run(() => decodeProvisioningQrImageSync(bytes));
}

String? decodeProvisioningQrImageSync(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > maximumProvisioningQrFileBytes) {
    return null;
  }

  try {
    final decoder = image_lib.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (decoder == null ||
        info == null ||
        info.width <= 0 ||
        info.height <= 0) {
      return null;
    }

    final pixels = info.width * info.height;
    if (info.width > _maximumImageDimension ||
        info.height > _maximumImageDimension ||
        pixels > _maximumImagePixels) {
      return null;
    }

    var image = decoder.decodeFrame(0);
    if (image == null) {
      return null;
    }

    final longestSide = image.width > image.height ? image.width : image.height;
    if (longestSide > _maximumDecodeDimension) {
      final scale = _maximumDecodeDimension / longestSide;
      image = image_lib.copyResize(
        image,
        width: (image.width * scale).round(),
        height: (image.height * scale).round(),
        interpolation: image_lib.Interpolation.average,
      );
    }

    final pixels32 = image
        .convert(numChannels: 4)
        .getBytes(order: image_lib.ChannelOrder.abgr)
        .buffer
        .asInt32List();
    final source = RGBLuminanceSource(image.width, image.height, pixels32);
    final bitmap = BinaryBitmap(HybridBinarizer(source));
    final hints = DecodeHints()..put(DecodeHintType.tryHarder);
    final value = QRCodeReader().decode(bitmap, hints: hints).text.trim();
    return value.isEmpty ? null : value;
  } catch (_) {
    return null;
  }
}
