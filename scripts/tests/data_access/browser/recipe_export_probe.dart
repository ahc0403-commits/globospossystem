// Standalone AOT encoder workload. Rows are synthetic; no DB/network timings.
import 'dart:convert';
import 'dart:io';
import 'package:globos_pos_system/features/inventory/recipe_excel_import.dart';

Map<String, dynamic> row(int i) => {
  'name': 'Name & <$i>',
  'inventory_item_id': 'I$i',
  'is_active': true,
  'base_unit': 'g',
  'menu_item_name': 'Menu & <$i>',
  'ingredient_name': 'Ingredient & <$i>',
  'quantity_g': 12.5,
};

Future<void> main(List<String> args) async {
  final count = int.parse(args.first), mode = args[1];
  final timer = Stopwatch()..start();
  var batches = 0;
  Stream<List<Map<String, dynamic>>> source() async* {
    for (var start = 0; start < count; start += 500) {
      batches++;
      yield List.generate(
        count - start < 500 ? count - start : 500,
        (i) => row(start + i),
      );
    }
  }

  final bytes = mode == 'before'
      ? buildRecipeImportTemplate(
          menuItems: List.generate(count, row),
          products: List.generate(count, row),
          recipes: List.generate(count, row),
        )
      : await buildRecipeTemplateFromBatches(
          recipes: source(),
          menuItems: source(),
          ingredients: source(),
        );
  timer.stop();
  if (args.length > 2) File(args[2]).writeAsBytesSync(bytes);
  stdout.writeln(
    jsonEncode({
      'rows_per_sheet': count,
      'mode': mode,
      'batches': batches,
      'output_bytes': bytes.length,
      'elapsed_ms': timer.elapsedMicroseconds / 1000,
      'max_rss_bytes': ProcessInfo.maxRss,
    }),
  );
}
