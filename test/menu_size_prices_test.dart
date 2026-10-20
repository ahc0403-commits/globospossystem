import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/menu/menu_options.dart';
import 'package:globos_pos_system/core/menu/menu_sizes.dart';
import 'package:globos_pos_system/features/admin/menu_import/menu_excel_roundtrip.dart';

void main() {
  test(
    'one catalog dish owns both sizes and exports one row with both prices',
    () {
      final rows = [
        for (final size in ['S', 'L'])
          {
            'id': size == 'S'
                ? '30000000-0000-4000-8000-000000000001'
                : 'large',
            'size_parent_id': size == 'S'
                ? null
                : '30000000-0000-4000-8000-000000000001',
            'category_id': '20000000-0000-4000-8000-000000000001',
            'name': '$size · 탕수육',
            'name_ko': '$size · 탕수육',
            'name_vi': '$size · Thịt',
            'name_en': '$size · Pork',
            'option_base_names': {
              'name_ko': '탕수육',
              'name_vi': 'Thịt',
              'name_en': 'Pork',
            },
            'size_prices': size == 'S' ? {'S': 190000, 'L': 370000} : {},
            'portion_code': size,
            'price': size == 'S' ? 190000 : 370000,
            'is_available': true,
            'is_visible_public': true,
            'menu_option_key': jsonEncode([
              size,
              'unknown',
              '',
              size == 'S' ? 190000 : 370000,
              {
                'menu_id': '30000000-0000-4000-8000-000000000001',
                'names': {
                  'name': '탕수육',
                  'name_ko': '탕수육',
                  'name_vi': 'Thịt',
                  'name_en': 'Pork',
                },
              },
            ]),
          },
      ];
      final catalog = menuCatalogRows(rows);
      expect(catalog, hasLength(1));
      expect(catalog.single['name_ko'], '탕수육');
      expect(catalog.single['size_options'], hasLength(2));
      final bytes = buildMenuRoundTripWorkbook(
        storeId: '10000000-0000-4000-8000-000000000001',
        categories: [
          {
            'id': '20000000-0000-4000-8000-000000000001',
            'name_ko': '요리',
            'name_vi': 'Món',
            'name_en': 'Main',
            'sort_order': 0,
          },
        ],
        items: catalog,
      );
      final imported = tryParseMenuRoundTripWorkbook(
        Uint8List.fromList(bytes),
      )!;
      expect(imported.items, hasLength(1));
      expect(imported.items.single.nameKo, '탕수육');
      expect(imported.items.single.toJson()['size_prices'], {
        'S': 190000,
        'L': 370000,
      });
      expect(
        menuCatalogRows([
          {'id': 'old', 'name': 'Other store', 'price': 10},
        ]).single['name'],
        'Other store',
      );
    },
  );

  testWidgets(
    'register one menu with S/L prices instead of a portion per menu',
    (tester) async {
      var value = const MenuOptions();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, setState) => MenuOptionsEditor(
                  allowSizes: true,
                  value: value,
                  onChanged: (v) => setState(() => value = v),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('admin_menu_options_expansion')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin_menu_has_sizes')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin_menu_size_price_S')),
        '190000',
      );
      await tester.enterText(
        find.byKey(const Key('admin_menu_size_price_L')),
        '370000',
      );
      await tester.pump();
      expect(find.byKey(const Key('admin_menu_portion')), findsNothing);
      expect(value.validSizePrices, isTrue);
      expect(value.toJson()['size_prices'], {'S': 190000, 'L': 370000});
      expect(tester.takeException(), isNull);
    },
  );
}
