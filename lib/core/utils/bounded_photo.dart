import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

const photoInputBytesLimit = 5 * 1024 * 1024;
const photoInputPixelsLimit = 4 * 1024 * 1024;
const photoOutputBytesLimit = 1024 * 1024;
const photoPickerDimension = 1600.0;

class PhotoProcessingException implements Exception {
  const PhotoProcessingException(this.code);
  final String code;
  @override
  String toString() => code;
}

/// Limits compressed bytes and header dimensions before allocating decoded
/// pixels. Previews and upload processing use the same admission check.
Future<Uint8List> readBoundedPhoto(XFile file) async {
  const budget = Duration(seconds: 10);
  final clock = Stopwatch()..start();
  final length = await file.length().timeout(budget);
  if (length <= 0 || length > photoInputBytesLimit) {
    throw const PhotoProcessingException('PHOTO_INPUT_TOO_LARGE');
  }
  // XFile's memory implementation requires end <= length. This fixed end also
  // prevents a native file that grows after stat from allocating without bound.
  final chunks = StreamIterator(file.openRead(0, length));
  final bytes = BytesBuilder(copy: false);
  try {
    while (true) {
      final remaining = budget - clock.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('Photo read deadline');
      }
      if (!await chunks.moveNext().timeout(remaining)) break;
      if (bytes.length + chunks.current.length > photoInputBytesLimit) {
        throw const PhotoProcessingException('PHOTO_INPUT_TOO_LARGE');
      }
      bytes.add(chunks.current);
    }
  } finally {
    await chunks.cancel().timeout(const Duration(seconds: 1));
  }
  final result = bytes.takeBytes();
  return _photoDecoder(result).$2;
}

(img.Decoder, Uint8List) _photoDecoder(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > photoInputBytesLimit) {
    throw const PhotoProcessingException('PHOTO_INPUT_TOO_LARGE');
  }
  try {
    return _headerDecoder(bytes);
  } on PhotoProcessingException {
    rethrow;
  } catch (_) {
    throw const PhotoProcessingException('PHOTO_INVALID');
  }
}

void _dimensions(int width, int height) {
  if (width < 1 ||
      height < 1 ||
      width > 8192 ||
      height > 8192 ||
      width * height > photoInputPixelsLimit) {
    throw const PhotoProcessingException('PHOTO_INPUT_TOO_LARGE');
  }
}

// image's JPEG startDecode calls JpegFrame.prepare(), allocating DCT blocks.
// Never call that API before validating every frame header ourselves. Parsing
// only the first SOF would let a later malformed SOF allocate a larger frame.
(img.Decoder, Uint8List) _headerDecoder(Uint8List bytes) {
  if (bytes.length >= 4 && bytes[0] == 0xff && bytes[1] == 0xd8) {
    var offset = 2, frames = 0;
    var scan = false;
    while (offset < bytes.length) {
      if (bytes[offset++] != 0xff) continue;
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.length) break;
      final marker = bytes[offset++];
      if (marker == 0 || marker == 1 || marker >= 0xd0 && marker <= 0xd7) {
        continue;
      }
      if (marker == 0xd9) break;
      if (marker == 0xd8 || offset + 2 > bytes.length) {
        throw const PhotoProcessingException('PHOTO_INVALID');
      }
      final length = (bytes[offset] << 8) | bytes[offset + 1];
      if (length < 2 || offset + length > bytes.length) {
        throw const PhotoProcessingException('PHOTO_INVALID');
      }
      if (marker >= 0xc0 &&
          marker <= 0xcf &&
          !const {0xc4, 0xc8, 0xcc}.contains(marker)) {
        if (!const {0xc0, 0xc1, 0xc2}.contains(marker) ||
            ++frames != 1 ||
            length < 8) {
          throw const PhotoProcessingException('PHOTO_INVALID');
        }
        _dimensions(
          (bytes[offset + 5] << 8) | bytes[offset + 6],
          (bytes[offset + 3] << 8) | bytes[offset + 4],
        );
        final components = bytes[offset + 7];
        if (!const {1, 3, 4}.contains(components) ||
            length != 8 + 3 * components) {
          throw const PhotoProcessingException('PHOTO_INVALID');
        }
        var blocks = 0;
        for (var i = 0; i < components; i++) {
          final sampling = bytes[offset + 9 + i * 3],
              h = sampling >> 4,
              v = sampling & 15;
          if (h < 1 || h > 4 || v < 1 || v > 4) {
            throw const PhotoProcessingException('PHOTO_INVALID');
          }
          blocks += h * v;
        }
        if (blocks > 10) throw const PhotoProcessingException('PHOTO_INVALID');
      }
      if (marker == 0xda) scan = true;
      offset += length;
    }
    if (frames != 1 || !scan) {
      throw const PhotoProcessingException('PHOTO_INVALID');
    }
    return (img.JpegDecoder(), bytes);
  }
  final data = ByteData.sublistView(bytes);
  if (bytes.length >= 33 &&
      data.getUint32(0) == 0x89504e47 &&
      data.getUint32(4) == 0x0d0a1a0a &&
      data.getUint32(8) == 13 &&
      data.getUint32(12) == 0x49484452) {
    _dimensions(data.getUint32(16), data.getUint32(20));
    // Remove compressed ancillary text/profile from the decoding copy: these
    // are not pixels and can inflate independently of the canvas dimensions.
    // The image decoder does not apply ICC color conversion to pixel samples.
    final normalized = BytesBuilder(copy: false)
      ..add(Uint8List.sublistView(bytes, 0, 8));
    var offset = 8;
    while (offset + 12 <= bytes.length) {
      final length = data.getUint32(offset), type = data.getUint32(offset + 4);
      if (offset + 12 + length > bytes.length) {
        throw const PhotoProcessingException('PHOTO_INVALID');
      }
      if (type == 0x6163544c) {
        throw const PhotoProcessingException('PHOTO_INVALID');
      }
      if (!const {0x69434350, 0x7a545874, 0x69545874}.contains(type)) {
        normalized.add(
          Uint8List.sublistView(bytes, offset, offset + 12 + length),
        );
      }
      offset += 12 + length;
      if (type == 0x49454e44) break;
    }
    return (img.PngDecoder(), normalized.takeBytes());
  }
  if (bytes.length >= 30 &&
      data.getUint32(0) == 0x52494646 &&
      data.getUint32(8) == 0x57454250) {
    var offset = 12, frames = 0;
    while (offset + 8 <= bytes.length) {
      final type = data.getUint32(offset),
          length = data.getUint32(offset + 4, Endian.little),
          p = offset + 8;
      if (p + length > bytes.length) {
        throw const PhotoProcessingException('PHOTO_INVALID');
      }
      if (type == 0x56503858 && length >= 10) {
        if (bytes[p] & 2 != 0) {
          throw const PhotoProcessingException('PHOTO_INVALID');
        }
        _dimensions(
          1 + bytes[p + 4] + (bytes[p + 5] << 8) + (bytes[p + 6] << 16),
          1 + bytes[p + 7] + (bytes[p + 8] << 8) + (bytes[p + 9] << 16),
        );
      } else if (type == 0x5650384c && length >= 5 && bytes[p] == 0x2f) {
        final bits = data.getUint32(p + 1, Endian.little);
        _dimensions(1 + (bits & 0x3fff), 1 + ((bits >> 14) & 0x3fff));
        frames++;
      } else if (type == 0x56503820 &&
          length >= 10 &&
          bytes[p + 3] == 0x9d &&
          bytes[p + 4] == 1 &&
          bytes[p + 5] == 0x2a) {
        _dimensions(
          data.getUint16(p + 6, Endian.little) & 0x3fff,
          data.getUint16(p + 8, Endian.little) & 0x3fff,
        );
        frames++;
      } else if (type == 0x414e4d46) {
        throw const PhotoProcessingException('PHOTO_INVALID');
      }
      offset = p + length + (length & 1);
    }
    if (frames != 1) throw const PhotoProcessingException('PHOTO_INVALID');
    return (img.WebPDecoder(), bytes);
  }
  throw const PhotoProcessingException('PHOTO_INVALID');
}

bool _processingPhoto = false;

/// At most one codec worker per app; no accumulating queue of image buffers.
/// Native uses a worker isolate. Web compute stays on the UI event loop, so its
/// finite pixel bound is still required and is not claimed to be background work.
Future<Uint8List> compressBoundedPhoto(
  XFile file, {
  required int maxDimension,
  required int quality,
}) async {
  if (_processingPhoto) {
    throw const PhotoProcessingException('PHOTO_PROCESSOR_BUSY');
  }
  if (maxDimension < 1 || maxDimension > 1600 || quality < 1 || quality > 100) {
    throw ArgumentError('PHOTO_OUTPUT_POLICY_INVALID');
  }
  _processingPhoto = true;
  try {
    final bytes = await readBoundedPhoto(file);
    return await compute(_compressPhoto, (
      bytes,
      maxDimension,
      quality,
    ), debugLabel: 'bounded-photo');
  } finally {
    // Never release the slot on a timeout while a codec worker is still alive.
    _processingPhoto = false;
  }
}

Uint8List _compressPhoto((Uint8List, int, int) input) {
  final (bytes, maxDimension, quality) = input;
  final (decoder, normalized) = _photoDecoder(bytes);
  img.Image? decoded;
  try {
    decoded = decoder.decode(normalized, frame: 0);
  } catch (_) {
    throw const PhotoProcessingException('PHOTO_INVALID');
  }
  if (decoded == null) throw const PhotoProcessingException('PHOTO_INVALID');
  final original = img.bakeOrientation(decoded);
  final longest = math.max(original.width, original.height);
  final resized = longest <= maxDimension
      ? original
      : img.copyResize(
          original,
          width: original.width >= original.height ? maxDimension : null,
          height: original.height > original.width ? maxDimension : null,
        );
  final compressed = Uint8List.fromList(
    img.encodeJpg(resized, quality: quality),
  );
  if (compressed.length > photoOutputBytesLimit) {
    throw const PhotoProcessingException('PHOTO_OUTPUT_TOO_LARGE');
  }
  return compressed;
}
