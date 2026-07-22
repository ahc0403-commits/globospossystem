import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/menu_import/menu_excel_import.dart';
import 'package:globos_pos_system/features/admin/menu_import/menu_excel_roundtrip.dart';

const storeId = '10000000-0000-4000-8000-000000000001';
const foodCategoryId = '20000000-0000-4000-8000-000000000001';
const emptyCategoryId = '20000000-0000-4000-8000-000000000002';
const firstItemId = '30000000-0000-4000-8000-000000000001';
const secondItemId = '30000000-0000-4000-8000-000000000002';

void main() {
  test(
    'exports every category and menu with KO, VI, EN names and stable IDs',
    () {
      final bytes = buildMenuRoundTripWorkbook(
        storeId: storeId,
        categories: _categories,
        items: _items,
      );
      final excel = Excel.decodeBytes(bytes);
      final sheet = excel.tables[menuImportSheetName]!;

      expect(
        sheet.rows.first.map((cell) => cell?.value.toString()),
        menuRoundTripHeaders,
      );
      expect(sheet.rows.length, 4);
      expect(sheet.rows[1][0]?.value.toString(), storeId);
      expect(sheet.rows[1][1]?.value.toString(), foodCategoryId);
      expect(sheet.rows[1][2]?.value.toString(), '분식');
      expect(sheet.rows[1][3]?.value.toString(), 'Món ăn vặt Hàn Quốc');
      expect(sheet.rows[1][4]?.value.toString(), 'Korean snacks');
      expect(sheet.rows[1][6]?.value.toString(), firstItemId);
      expect(sheet.rows[3][1]?.value.toString(), emptyCategoryId);
      expect(sheet.rows[3][6]?.value.toString(), '');
    },
  );

  test(
    'round-trip parser reads edited multilingual category and menu names',
    () {
      final excel = Excel.decodeBytes(
        buildMenuRoundTripWorkbook(
          storeId: storeId,
          categories: _categories,
          items: _items,
        ),
      );
      final sheet = excel[menuImportSheetName];
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: 1))
          .value = TextCellValue(
        'Đồ ăn đường phố',
      );
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: 8, rowIndex: 1))
          .value = TextCellValue(
        'Bánh gạo cay',
      );

      final parsed = tryParseMenuRoundTripWorkbook(
        Uint8List.fromList(excel.encode()!),
      )!;
      expect(parsed.categoryCount, 2);
      expect(parsed.itemCount, 2);
      expect(parsed.storeIds, {storeId});
      expect(parsed.categories.first.nameVi, 'Đồ ăn đường phố');
      expect(parsed.items.first.nameVi, 'Bánh gạo cay');
      expect(parsed.items.first.itemId, firstItemId);
    },
  );

  test('round-trip parser rejects missing translations', () {
    final excel = Excel.decodeBytes(
      buildMenuRoundTripWorkbook(
        storeId: storeId,
        categories: _categories,
        items: _items,
      ),
    );
    excel[menuImportSheetName]
        .cell(CellIndex.indexByColumnRow(columnIndex: 9, rowIndex: 1))
        .value = TextCellValue(
      '',
    );

    expect(
      () => tryParseMenuRoundTripWorkbook(Uint8List.fromList(excel.encode()!)),
      throwsA(
        isA<MenuImportValidationException>().having(
          (error) => error.issues.join('\n'),
          'issues',
          contains('메뉴명(EN)'),
        ),
      ),
    );
  });

  test('legacy one-language import workbook remains distinguishable', () {
    final excel = Excel.createExcel();
    final sheet = excel[menuImportSheetName];
    sheet.appendRow(
      const [
        '매장코드',
        '카테고리명',
        '카테고리순서',
        '메뉴명',
        '설명',
        '가격(VND)',
        '판매가능',
        'QR메뉴노출',
        '메뉴순서',
      ].map(TextCellValue.new).toList(),
    );
    sheet.appendRow([
      TextCellValue('BT'),
      TextCellValue('분식'),
      IntCellValue(0),
      TextCellValue('떡볶이'),
      TextCellValue(''),
      IntCellValue(50000),
      BoolCellValue(true),
      BoolCellValue(true),
      IntCellValue(0),
    ]);
    final bytes = Uint8List.fromList(excel.encode()!);

    expect(tryParseMenuRoundTripWorkbook(bytes), isNull);
    expect(parseMenuImportWorkbook(bytes).itemCount, 1);
  });

  test(
    'database update is atomic, tenant-scoped, and preserves item identity',
    () {
      final migration = File(
        'supabase/migrations/20260722070000_menu_excel_roundtrip_i18n.sql',
      ).readAsStringSync();

      expect(migration, contains('require_admin_actor_for_restaurant'));
      expect(migration, contains('FOR UPDATE'));
      expect(migration, contains('MENU_WORKBOOK_STORE_MISMATCH'));
      expect(migration, contains('MENU_WORKBOOK_ITEM_CATEGORY_MISMATCH'));
      expect(migration, contains('name_vi = v_name_vi'));
      expect(migration, isNot(contains('image_url =')));
      expect(migration, isNot(contains('DELETE FROM public.menu_items')));

      final deploy = File(
        'scripts/deploy_pos_production.sh',
      ).readAsStringSync();
      expect(deploy, contains('20260722070000_menu_excel_roundtrip_i18n.sql'));
      expect(deploy, contains('preflight_menu_excel_roundtrip_i18n.sql'));
      expect(deploy, contains('verify_menu_excel_roundtrip_i18n.sql'));
    },
  );
}

final _categories = <Map<String, dynamic>>[
  {
    'id': foodCategoryId,
    'name': '분식',
    'name_ko': '분식',
    'name_vi': 'Món ăn vặt Hàn Quốc',
    'name_en': 'Korean snacks',
    'sort_order': 0,
  },
  {
    'id': emptyCategoryId,
    'name': '기타',
    'name_ko': '기타',
    'name_vi': 'Khác',
    'name_en': 'Other',
    'sort_order': 1,
  },
];

final _items = <Map<String, dynamic>>[
  {
    'id': firstItemId,
    'category_id': foodCategoryId,
    'name': '떡볶이',
    'name_ko': '떡볶이',
    'name_vi': 'Tokbokki',
    'name_en': 'Spicy rice cakes',
    'description': '매운맛',
    'price': 50000,
    'is_available': true,
    'is_visible_public': true,
    'sort_order': 0,
    'image_url': 'https://example.test/image.jpg',
  },
  {
    'id': secondItemId,
    'category_id': foodCategoryId,
    'name': '김밥',
    'name_ko': '김밥',
    'name_vi': 'Cơm cuộn',
    'name_en': 'Gimbap',
    'description': null,
    'price': 45000,
    'is_available': true,
    'is_visible_public': false,
    'sort_order': 1,
  },
];
