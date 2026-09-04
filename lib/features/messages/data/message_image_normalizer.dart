import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;

/// Bakes JPEG EXIF orientation into pixels and removes metadata that carriers
/// commonly discard. Other formats are returned byte-for-byte so animated GIF
/// and WebP content is never flattened accidentally.
Future<Uint8List> normalizeMessageImage({
  required Uint8List bytes,
  required String contentType,
  int? maximumBytes,
  bool stripMetadata = false,
}) async {
  if (contentType.toLowerCase() != 'image/jpeg' || bytes.isEmpty) return bytes;
  try {
    return await compute(_normalizeJpeg, (
      bytes: bytes,
      maximumBytes: maximumBytes,
      stripMetadata: stripMetadata,
    ));
  } catch (_) {
    // A download must remain available when a carrier supplies a JPEG variant
    // the normalizer cannot decode. Outbound uploads remain fail-closed.
    if (!stripMetadata) return bytes;
    rethrow;
  }
}

Uint8List _normalizeJpeg(
  ({Uint8List bytes, int? maximumBytes, bool stripMetadata}) request,
) {
  final decoded = image.decodeJpg(request.bytes);
  if (decoded == null) {
    throw const FormatException('The JPEG image could not be decoded.');
  }
  final hasOrientation = decoded.exif.imageIfd.hasOrientation;
  final orientation = hasOrientation ? decoded.exif.imageIfd.orientation : 1;
  if (!request.stripMetadata && (orientation == null || orientation == 1)) {
    return request.bytes;
  }

  final normalized = image.bakeOrientation(decoded);
  normalized.exif = image.ExifData();
  final maximum = request.maximumBytes;
  for (final quality in const [82, 74, 66, 58, 50, 42]) {
    final encoded = image.encodeJpg(normalized, quality: quality);
    if (maximum == null || encoded.length <= maximum || quality == 42) {
      return encoded;
    }
  }
  throw StateError('JPEG normalization did not produce output.');
}
