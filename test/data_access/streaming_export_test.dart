import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/inventory/ingredient_excel_import.dart';
import 'package:globos_pos_system/core/utils/excel_workbook_decoder.dart';
import 'package:globos_pos_system/features/inventory/recipe_excel_import.dart';

void main() {
  test(
    'recipe export streams three sources without overlapping page reads',
    () async {
      final phases = <String>[];
      Stream<List<Map<String, dynamic>>> source(String name) async* {
        phases.add('$name:start');
        for (var b = 0; b < 3; b++) {
          yield List.generate(
            500,
            (i) => {
              'menu_item_name': 'Menu & <${b * 500 + i}>',
              'ingredient_name': 'Ingredient ${b * 500 + i}',
              'quantity_g': 12.5,
              'name': '$name ${b * 500 + i}',
              'base_unit': 'g',
            },
          );
        }
        phases.add('$name:end');
      }

      final bytes = await buildRecipeTemplateFromBatches(
        recipes: source('recipes'),
        menuItems: source('menus'),
        ingredients: source('ingredients'),
      );
      expect(phases, [
        'recipes:start',
        'recipes:end',
        'menus:start',
        'menus:end',
        'ingredients:start',
        'ingredients:end',
      ]);
      final book = decodeExcelWorkbook(bytes);
      expect(book.tables.keys, [
        recipeImportSheetName,
        recipeMenuReferenceSheetName,
        recipeIngredientReferenceSheetName,
      ]);
      for (final sheet in book.tables.values) {
        expect(sheet.rows.length, 1501);
      }
      expect(
        book.tables[recipeImportSheetName]!.rows[501][0]?.value.toString(),
        'Menu & <500>',
      );
      expect(
        book.tables[recipeImportSheetName]!.rows.last[2]?.value.toString(),
        '12.5',
      );
      expect(
        book.tables[recipeIngredientReferenceSheetName]!.rows.last[1]?.value
            .toString(),
        'g',
      );
    },
  );

  test(
    'empty streamed recipe template preserves the editable sample',
    () async {
      final bytes = await buildRecipeTemplateFromBatches(
        recipes: const Stream.empty(),
        menuItems: const Stream.empty(),
        ingredients: const Stream.empty(),
      );
      final rows = decodeExcelWorkbook(
        bytes,
      ).tables[recipeImportSheetName]!.rows;
      expect(rows.length, 2);
      expect(rows[1][0]?.value.toString(), '메뉴목록 시트에서 복사');
    },
  );

  test(
    'streamed ingredient workbook preserves values across 500-row boundaries',
    () async {
      var requested = 0;
      Stream<List<Map<String, dynamic>>> batches() async* {
        for (var b = 0; b < 3; b++) {
          requested++;
          yield List.generate(
            500,
            (i) => {
              'id': 'P${b * 500 + i}',
              'product_code': 'C${b * 500 + i}',
              'name': 'Name & <${b * 500 + i}>',
              'stock_unit': 'kg',
              'base_unit': 'g',
              'base_unit_factor': 1000,
              'is_orderable': true,
              'export_supplier': {
                'supplier_name': 'S & <1>',
                'unit_price': 12.5,
              },
            },
          );
        }
      }

      final bytes = await buildIngredientTemplateFromBatches(
        batches: batches(),
        suppliers: [
          {'supplier_name': 'S & <1>', 'status': 'active'},
        ],
      );
      expect(requested, 3);
      final excel = decodeExcelWorkbook(bytes);
      final rows = excel.tables[ingredientImportSheetName]!.rows;
      expect(rows.length, 1501);
      expect(rows[501][0]?.value.toString(), 'P500');
      expect(rows.last[2]?.value.toString(), 'Name & <1499>');
      expect(rows.last[11]?.value.toString(), '12.5');
    },
  );
}
