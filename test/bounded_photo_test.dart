import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/bounded_photo.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

class _File extends XFile {
  _File(this.reportedLength, this.chunks, {this.gate})
    : super('synthetic-photo');
  final int reportedLength;
  final List<Uint8List> chunks;
  final Completer<void>? gate;
  int reads = 0;
  @override
  Future<int> length() async {
    await gate?.future;
    return reportedLength;
  }

  @override
  Stream<Uint8List> openRead([int? start, int? end]) {
    reads++;
    return Stream.fromIterable(chunks);
  }

  @override
  Future<Uint8List> readAsBytes() =>
      throw StateError('Unbounded file read forbidden');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Uint8List jpeg(int width, int height) => Uint8List.fromList(
    img.encodeJpg(img.Image(width: width, height: height)),
  );
  Matcher error(String code) =>
      isA<PhotoProcessingException>().having((e) => e.code, 'code', code);

  test('file byte limit rejects before opening the content stream', () async {
    final file = _File(photoInputBytesLimit + 1, []);
    await expectLater(
      readBoundedPhoto(file),
      throwsA(error('PHOTO_INPUT_TOO_LARGE')),
    );
    expect(file.reads, 0);
  });
  test(
    'bounded stream still rejects content that grows after length lookup',
    () async {
      final file = _File(1, [Uint8List(photoInputBytesLimit), Uint8List(1)]);
      await expectLater(
        readBoundedPhoto(file),
        throwsA(error('PHOTO_INPUT_TOO_LARGE')),
      );
      expect(file.reads, 1);
    },
  );
  test(
    'oversized JPEG header is rejected before allocating decoded pixels',
    () async {
      final bytes = jpeg(8, 8);
      final marker = List.generate(
        bytes.length - 1,
        (i) => i,
      ).firstWhere((i) => bytes[i] == 0xff && bytes[i + 1] == 0xc0);
      bytes[marker + 5] = 0xff;
      bytes[marker + 6] = 0xff;
      bytes[marker + 7] = 0xff;
      bytes[marker + 8] = 0xff;
      await expectLater(
        readBoundedPhoto(XFile.fromData(bytes)),
        throwsA(error('PHOTO_INPUT_TOO_LARGE')),
      );
    },
  );
  test('invalid and animated inputs are refused', () async {
    await expectLater(
      readBoundedPhoto(XFile.fromData(Uint8List.fromList([1, 2, 3]))),
      throwsA(error('PHOTO_INVALID')),
    );
    final frames = img.Image(width: 2, height: 2)
      ..addFrame(img.Image(width: 2, height: 2));
    await expectLater(
      readBoundedPhoto(
        XFile.fromData(Uint8List.fromList(img.encodeGif(frames))),
      ),
      throwsA(error('PHOTO_INVALID')),
    );
  });
  test('PNG and lossy WebP keep photographic compatibility', () async {
    final inputs = [
      Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 6))),
      base64Decode(
        'UklGRjAAAABXRUJQVlA4ICQAAABwAQCdASoIAAYAAUAmJYwCdAFAAAD+82mNaTSLz1VT19+gAAA=',
      ),
    ];
    for (final bytes in inputs) {
      final output = await compressBoundedPhoto(
        XFile.fromData(bytes),
        maxDimension: 800,
        quality: 70,
      );
      final decoded = img.decodeJpg(output)!;
      expect((decoded.width, decoded.height), (8, 6));
    }
  });
  test(
    'existing lossless WebP codec failure exposes a readable photo error',
    () async {
      // Unmodified image 4.8.0 also throws IndexError for this valid palette WebP.
      // Preserve the diagnostic; do not count its decoding as a compatibility PASS.
      final bytes = base64Decode(
        'UklGRiIAAABXRUJQVlA4TBYAAAAvB0ABAAdQqPJUq/8BgCD8b5uI6H8I',
      );
      expect(() => img.decodeWebP(bytes), throwsRangeError);
      await expectLater(
        compressBoundedPhoto(
          XFile.fromData(bytes),
          maxDimension: 800,
          quality: 70,
        ),
        throwsA(error('PHOTO_INVALID')),
      );
    },
  );
  test(
    'a second JPEG frame or excessive sampling cannot bypass admission',
    () async {
      final original = jpeg(8, 8);
      final marker = List.generate(
        original.length - 1,
        (i) => i,
      ).firstWhere((i) => original[i] == 0xff && original[i + 1] == 0xc0);
      final length = (original[marker + 2] << 8) | original[marker + 3];
      final second = Uint8List.fromList([
        ...original.take(original.length - 2),
        ...original.skip(marker).take(length + 2),
        0xff,
        0xd9,
      ]);
      await expectLater(
        readBoundedPhoto(XFile.fromData(second)),
        throwsA(error('PHOTO_INVALID')),
      );
      original[marker + 11] = 0xff;
      await expectLater(
        readBoundedPhoto(XFile.fromData(original)),
        throwsA(error('PHOTO_INVALID')),
      );
    },
  );
  test(
    'PNG huge dimensions are rejected before the PNG decoder runs',
    () async {
      final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 8, height: 6)),
      );
      ByteData.sublistView(bytes).setUint32(16, 0xffffffff);
      await expectLater(
        readBoundedPhoto(XFile.fromData(bytes)),
        throwsA(error('PHOTO_INPUT_TOO_LARGE')),
      );
    },
  );
  test('small valid photo is not enlarged', () async {
    final output = await compressBoundedPhoto(
      XFile.fromData(jpeg(96, 72)),
      maxDimension: 800,
      quality: 70,
    );
    final decoded = img.decodeJpg(output)!;
    expect((decoded.width, decoded.height), (96, 72));
    expect(output.length, lessThanOrEqualTo(photoOutputBytesLimit));
  });
  test(
    'landscape and portrait preserve aspect ratio and maximum dimension',
    () async {
      for (final dimensions in [(1200, 600), (600, 1200)]) {
        final output = await compressBoundedPhoto(
          XFile.fromData(jpeg(dimensions.$1, dimensions.$2)),
          maxDimension: 800,
          quality: 70,
        );
        final decoded = img.decodeJpg(output)!;
        expect((
          decoded.width,
          decoded.height,
        ), dimensions.$1 > dimensions.$2 ? (800, 400) : (400, 800));
      }
    },
  );
  test(
    'one active codec admission rejects a second buffer and recovers on failure',
    () async {
      final gate = Completer<void>();
      final first = compressBoundedPhoto(
        _File(1, [Uint8List(1)], gate: gate),
        maxDimension: 800,
        quality: 70,
      );
      await expectLater(
        compressBoundedPhoto(
          XFile.fromData(jpeg(8, 8)),
          maxDimension: 800,
          quality: 70,
        ),
        throwsA(error('PHOTO_PROCESSOR_BUSY')),
      );
      gate.complete();
      await expectLater(first, throwsA(error('PHOTO_INVALID')));
      expect(
        await compressBoundedPhoto(
          XFile.fromData(jpeg(8, 8)),
          maxDimension: 800,
          quality: 70,
        ),
        isNotEmpty,
      );
    },
  );
}
