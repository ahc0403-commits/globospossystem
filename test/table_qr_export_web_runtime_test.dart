import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/table_qr_export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('production-sized PDF export renders in a browser runtime', (
    tester,
  ) async {
    const service = TableQrExportService();
    final rows = List<Map<String, dynamic>>.generate(22, (index) {
      final tableNumber = index < 11 ? '${201 + index}' : '${290 + index}';
      return {
        'token_id':
            '20000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
        'table_id':
            '30000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
        'table_number': tableNumber,
        'floor_label': index < 11 ? '2F' : '3F',
        'layout_sort_order': index,
        'store_name': 'BunsikClub Binh Thanh',
        'token': 'stable-token-${index.toString().padLeft(2, '0')}',
      };
    });
    final cards = service.cardsFromRpcRows(rows);

    final pdf = await tester.runAsync(
      () => service.buildPdf(cards).timeout(const Duration(seconds: 10)),
    );
    expect(pdf, isA<Uint8List>());
    expect(pdf, isNotEmpty);
  });

  testWidgets('a PNG export renders in a browser runtime', (tester) async {
    const service = TableQrExportService();
    final cards = service.cardsFromRpcRows([
      {
        'token_id': '20000000-0000-4000-8000-000000000001',
        'table_id': '30000000-0000-4000-8000-000000000001',
        'table_number': '201',
        'floor_label': '2F',
        'layout_sort_order': 0,
        'store_name': 'BunsikClub Binh Thanh',
        'token': 'stable-token-01',
      },
    ]);
    final png = await tester.runAsync(() => service.buildPng(cards.single));
    expect(png, isNotEmpty);
  });
}
