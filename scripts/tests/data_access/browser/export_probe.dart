// Standalone AOT workload; real encoder, synthetic rows, no database or UI.
import 'dart:convert';
import 'dart:io';
import 'package:globos_pos_system/features/inventory/ingredient_excel_import.dart';

Map<String, dynamic> product(int i) => {
  'id': 'P$i',
  'product_code': 'C$i',
  'name': 'Ingredient & <$i>',
  'stock_unit': 'kg',
  'base_unit': 'g',
  'base_unit_factor': 1000,
  'is_orderable': true,
  'export_supplier': {'supplier_name': 'Fixture supplier', 'unit_price': 12.5},
};
Future<void> main(List<String> args) async {
  final count = int.parse(args.first), mode = args[1];
  final timer = Stopwatch()..start();
  final suppliers = [
    {'id': 'S1', 'supplier_name': 'Fixture supplier', 'status': 'active'},
  ];
  List<int> bytes;
  var batches = 0;
  if (mode == 'before') {
    final products = List.generate(count, product);
    final links = List.generate(
      count,
      (i) => {
        'product_id': 'P$i',
        'supplier_id': 'S1',
        'unit_price': 12.5,
        'is_active': true,
      },
    );
    bytes = buildIngredientImportTemplate(
      products: products,
      suppliers: suppliers,
      supplierItems: links,
    );
  } else {
    Stream<List<Map<String, dynamic>>> source() async* {
      for (var start = 0; start < count; start += 500) {
        batches++;
        yield List.generate(
          count - start < 500 ? count - start : 500,
          (i) => product(start + i),
        );
      }
    }

    bytes = await buildIngredientTemplateFromBatches(
      batches: source(),
      suppliers: suppliers,
    );
  }
  timer.stop();
  if (args.length > 2) File(args[2]).writeAsBytesSync(bytes);
  stdout.writeln(
    jsonEncode({
      'rows': count,
      'mode': mode,
      'batches': batches,
      'output_bytes': bytes.length,
      'elapsed_ms': timer.elapsedMicroseconds / 1000,
      'max_rss_bytes': ProcessInfo.maxRss,
    }),
  );
}
