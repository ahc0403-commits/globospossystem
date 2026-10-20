import 'package:globos_pos_system/features/kitchen/kitchen_provider.dart';
import 'package:globos_pos_system/core/services/qr_order_service.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_cart_draft.dart';
import 'dart:typed_data';
import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/menu/menu_options.dart';
import 'package:globos_pos_system/features/admin/menu_import/menu_excel_import.dart';
import 'package:globos_pos_system/features/admin/menu_import/menu_excel_roundtrip.dart';
import 'package:globos_pos_system/features/order/order_model.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';

void main() {
  test('registered sellable S and L cannot merge in a POS cart', () {
    const s = CartItem(
      menuItemId: 'registered-s',
      name: 'Noodles · S',
      price: 10000,
      quantity: 1,
    );
    const m = CartItem(
      menuItemId: 'registered-l',
      name: 'Noodles · L',
      price: 18000,
      quantity: 1,
    );
    expect(s.lineKey, isNot(m.lineKey));
    expect(s.price * s.quantity + m.price * m.quantity, 28000);
    expect(s.copyWith(quantity: 2).menuItemId, s.menuItemId);
  });
  test('QR and restored customer drafts retain the registered option key', () {
    const key = '["S","spicy","Mild",10000]';
    final item = QrMenuItem.fromJson({
      'id': 'registered-s',
      'name': 'S · Mild · Noodles',
      'price': 10000,
      'menu_option_key': key,
    });
    expect(
      QrOrderLine(
        menuItemId: item.id,
        quantity: 1,
        menuOptionKey: item.menuOptionKey,
      ).toJson()['menu_option_key'],
      key,
    );
    final draft = DirectOrderCartDraft(
      id: '10000000-0000-4000-8000-000000000001',
      savedAt: DateTime.utc(2026),
      cart: {item.id: 1},
      itemNotes: const {},
      comboChoices: const {},
      menuOptionKeys: {item.id: key},
      pickup: true,
      dinerCount: 1,
      utensilsRequested: false,
    );
    expect(
      DirectOrderCartDraft.fromJson(draft.toJson()).menuOptionKeys[item.id],
      key,
    );
    const old = CartItem(
      menuItemId: 'registered-s',
      name: 'old',
      price: 10000,
      quantity: 1,
      menuOptionKey: 'old',
    );
    const changed = CartItem(
      menuItemId: 'registered-s',
      name: 'new',
      price: 10000,
      quantity: 1,
      menuOptionKey: 'new',
    );
    expect(old.lineKey, isNot(changed.lineKey));
    expect(old.copyWith(isTakeout: true).menuOptionKey, 'old');
  });
  test(
    'new import accepts S/L rows and flags duplicate choices with row numbers',
    () {
      final excel = Excel.createExcel();
      final sheet = excel[menuImportSheetName];
      final headers = [
        '매장코드',
        '카테고리명',
        '카테고리순서',
        '메뉴명',
        '설명',
        '가격(VND)',
        '판매가능',
        'QR메뉴노출',
        '메뉴순서',
        '메뉴명(VI)',
        ...menuOptionsExcelHeaders,
      ];
      sheet.appendRow(headers.map(TextCellValue.new).toList());
      for (final portion in ['S', 'L']) {
        sheet.appendRow([
          TextCellValue('JGBT'),
          TextCellValue('면'),
          IntCellValue(0),
          TextCellValue('국수'),
          TextCellValue(''),
          DoubleCellValue(portion == 'S' ? 10000 : 18000),
          BoolCellValue(true),
          BoolCellValue(true),
          IntCellValue(0),
          TextCellValue('Mì'),
          TextCellValue(portion),
          TextCellValue('spicy'),
          TextCellValue(''),
        ]);
      }
      expect(
        parseMenuImportWorkbook(
          Uint8List.fromList(excel.encode()!),
        ).rows.map((r) => r.menuOptions?['portion_code']),
        ['S', 'L'],
      );
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: 10, rowIndex: 2))
          .value = TextCellValue(
        'S',
      );
      expect(
        () => parseMenuImportWorkbook(Uint8List.fromList(excel.encode()!)),
        throwsA(isA<MenuImportValidationException>()),
      );
    },
  );
  test('old menus remain unconfirmed and editing uses original base names', () {
    expect(MenuOptions.fromJson({}).spice, 'unknown');
    expect(
      menuBaseName({
        'name_ko': '국수 · S · 🌶 매운 메뉴',
        'option_base_names': {'name_ko': '국수'},
      }, 'name_ko'),
      '국수',
    );
  });
  test(
    'reconnected orders use immutable translations ahead of current menu',
    () {
      final item = OrderItem.fromJson({
        'id': 'old-order',
        'label': '국수 · S · 🌶 매운 메뉴',
        'unit_price': 10000,
        'quantity': 1,
        'menu_items': {
          'name_ko': '새 메뉴 · L',
          'name_vi': 'Món mới',
          'name_en': 'New',
        },
        'menu_option_snapshot': {
          'portion_code': 'S',
          'spice_level': 'spicy',
          'name_ko': '국수 · S · 🌶 매운 메뉴',
          'name_vi': 'Mì · S · 🌶 Món cay',
          'name_en': 'Noodles · S · 🌶 Spicy dish',
        },
      });
      expect(item.localizedName('en'), 'Noodles · S · 🌶 Spicy dish');
      expect(item.unitPrice, 10000);
      final kitchen = KitchenItem.fromJson({
        'id': 'line',
        'quantity': 1,
        'menu_items': {'name_vi': 'New live name'},
        'menu_option_snapshot': {'name_vi': 'S · 🌶 Món cay · Original'},
      });
      expect(kitchen.localizedName('vi'), 'S · 🌶 Món cay · Original');
    },
  );
  test('KDS separates structural choices even when translated names match', () {
    EmergencyFulfillmentItem item(String portion, String choice) =>
        EmergencyFulfillmentItem.fromJson({
          'id': 'line',
          'order_item_id': 'source',
          'name_ko': '같은 이름',
          'name_vi': 'Món',
          'name_en': 'Dish',
          'menu_option_snapshot': {
            'portion_code': portion,
            'spice_level': 'spicy',
            'spice_choice': choice,
          },
        });
    final s = item('S', '');
    final m = item('L', '');
    final mild = item('S', 'Mild');
    expect(kitchenChecketGroupKey(s), isNot(kitchenChecketGroupKey(m)));
    expect(kitchenChecketGroupKey(s), isNot(kitchenChecketGroupKey(mild)));
    expect(s.withStage('kitchen_done', 1).menuOptionKey, s.menuOptionKey);
  });
  test(
    'Excel options round trip without suffix duplication; old columns preserve options',
    () {
      final bytes = buildMenuRoundTripWorkbook(
        storeId: '10000000-0000-4000-8000-000000000001',
        categories: [
          {
            'id': '20000000-0000-4000-8000-000000000001',
            'name_ko': '면',
            'name_vi': 'Mì',
            'name_en': 'Noodles',
            'sort_order': 0,
          },
        ],
        items: [
          {
            'id': '30000000-0000-4000-8000-000000000001',
            'category_id': '20000000-0000-4000-8000-000000000001',
            'name_ko': '국수 · S',
            'name_vi': 'Mì · S',
            'name_en': 'Noodles · S',
            'option_base_names': {
              'name_ko': '국수',
              'name_vi': 'Mì',
              'name_en': 'Noodles',
            },
            'price': 10000,
            'is_available': true,
            'is_visible_public': true,
            'portion_code': 'S',
            'spice_level': 'spicy',
            'spice_choice': 'Mild',
          },
        ],
      );
      final row = tryParseMenuRoundTripWorkbook(
        Uint8List.fromList(bytes),
      )!.items.single;
      expect(row.nameKo, '국수');
      expect(row.toJson()['portion_code'], 'S');
      expect(row.toJson()['spice_level'], 'spicy');
      final old = Excel.decodeBytes(bytes);
      final sheet = old.tables[menuImportSheetName]!;
      for (final header in menuOptionsExcelHeaders.reversed) {
        final index = sheet.rows.first.indexWhere(
          (cell) => cell?.value.toString() == header,
        );
        sheet.removeColumn(index);
      }
      expect(
        tryParseMenuRoundTripWorkbook(
          Uint8List.fromList(old.encode()!),
        )!.items.single.menuOptions,
        isNull,
      );
      final issues = <String>[];
      parseMenuOptionsExcelRow({'양(S/L)': 0}, (_) => 'M', 42, issues);
      expect(issues.single, contains('42행'));
    },
  );
  testWidgets(
    'menu editor exposes S/L and explicit unconfirmed/spicy choices',
    (tester) async {
      var value = const MenuOptions();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, setState) => MenuOptionsEditor(
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
      expect(find.text('Unconfirmed'), findsOneWidget);
      await tester.tap(find.byKey(const Key('admin_menu_portion')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('L').last);
      await tester.pumpAndSettle();
      expect(value.portion, 'L');
      await tester.tap(find.byKey(const Key('admin_menu_spice')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('🌶 Spicy dish').last);
      await tester.pumpAndSettle();
      expect(value.spice, 'spicy');
      expect(tester.takeException(), isNull);
    },
  );
}
