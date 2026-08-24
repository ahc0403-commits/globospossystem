import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_qr_export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'external-order QR export keeps the canonical store URL and filename',
    () async {
      String? renderedUrl;
      String? savedName;
      Uint8List? savedBytes;
      final service = DirectOrderQrExportService(
        renderer: (url) async {
          renderedUrl = url;
          return Uint8List.fromList([137, 80, 78, 71]);
        },
        saver: (name, bytes) async {
          savedName = name;
          savedBytes = bytes;
        },
      );
      const url = 'https://globospossystem.vercel.app/order/bunsikclub-sample';

      await service.savePng(slug: 'bunsikclub-sample', url: url);

      expect(renderedUrl, url);
      expect(savedName, 'external_order_qr_bunsikclub-sample');
      expect(savedBytes, [137, 80, 78, 71]);
    },
  );

  test('external-order QR export rejects non-HTTPS and unrelated routes', () {
    const service = DirectOrderQrExportService();
    expect(
      () => service.buildPng('http://example.com/#/order/sample'),
      throwsFormatException,
    );
    expect(
      () => service.buildPng('https://example.com/#/qr/sample'),
      throwsFormatException,
    );
    expect(
      () => service.buildPng('https://example.com/order/x'),
      throwsFormatException,
    );
  });

  test('legacy hash order QR remains valid during link migration', () async {
    const service = DirectOrderQrExportService(renderer: _legacyRenderer);
    final bytes = await service.buildPng(
      'https://example.com/#/order/sample-store',
    );
    expect(bytes, [137, 80, 78, 71]);
  });

  test(
    'external-order QR print receives the canonical URL and image',
    () async {
      String? printedName;
      String? printedUrl;
      Uint8List? printedBytes;
      final service = DirectOrderQrExportService(
        renderer: (_) async => Uint8List.fromList([137, 80, 78, 71]),
        printer: (name, bytes, url) async {
          printedName = name;
          printedBytes = bytes;
          printedUrl = url;
        },
      );
      const url = 'https://example.com/order/sample-store';

      await service.printQr(slug: 'sample-store', url: url);

      expect(printedName, 'external_order_qr_sample-store');
      expect(printedBytes, [137, 80, 78, 71]);
      expect(printedUrl, url);
    },
  );
}

Future<Uint8List> _legacyRenderer(String _) async =>
    Uint8List.fromList([137, 80, 78, 71]);
