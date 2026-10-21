import 'fixtures/menu_choice_data.dart';
import 'package:globos_pos_system/core/menu/menu_choice_editor.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/menu/menu_choices.dart';
import 'package:globos_pos_system/core/menu/menu_options.dart';
import 'package:globos_pos_system/core/menu/menu_sizes.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_cart_draft.dart';

void main() {
  testWidgets(
    'definition editor cancels without changing the registered menu',
    (tester) async {
      var changed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MenuChoiceEditor(
              definition: definition(),
              storeId: 'store',
              onChanged: (_) => changed = true,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Customer choices'));
      await tester.pumpAndSettle();
      expect(find.text('Apply to menu'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(changed, isFalse);
    },
  );
  testWidgets(
    'ingredient chooser opens locally and closing preserves the definition',
    (tester) async {
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MenuChoiceEditor(
              definition: definition(),
              storeId: 'store',
              onChanged: (value) => saved = value,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Customer choices'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Mild').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mild').last);
      await tester.pumpAndSettle();
      final button = find.text('Add ingredient').first;
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Ingredient'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Search'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply to menu'));
      await tester.pumpAndSettle();
      expect(saved?['groups'], isNotEmpty);
      expect(
        (saved!['groups'] as List)
            .expand((g) => g['values'] as List)
            .every((v) => (v['recipe_additions'] as List).isEmpty),
        isTrue,
      );
    },
  );

  test(
    'choice validation, server revision, stable separate line identity and old key',
    () {
      final catalog = MenuChoiceCatalog.fromKey(catalogKey())!;
      expect(catalog.defaults('qr'), {'mild': 1});
      expect(catalog.valid({'mild': 1}, 'qr'), false);
      expect(catalog.valid({'hot': 1, 'less': 1}, 'qr'), false);
      expect(catalog.valid({'hot': 2, 'normal': 1}, 'qr'), false);
      expect(catalog.valid({'gone': 1, 'normal': 1}, 'qr'), false);
      final hot = catalog.select({'normal': 1, 'hot': 1}, 'qr');
      final same = catalog.select({'hot': 1, 'normal': 1}, 'qr');
      final mild = catalog.select({'mild': 1, 'less': 1}, 'qr');
      expect(hot.key, same.key);
      expect(hot.price, 12000);
      expect(hot.name('탕수육', 'ko'), '탕수육 [맵게 · 중간]');
      expect(hot.lineId('menu'), isNot(mild.lineId('menu')));
      expect(menuChoiceBaseId(hot.lineId('menu')), 'menu');
      expect(menuChoiceKeyMatches(hot.key, catalog.key), true);
      expect(menuChoiceKeyMatches(hot.key, catalogKey(price: 11000)), false);
      expect(menuChoiceKeyMatches(null, null), true);
      expect(menuChoiceKeyMatches('old', 'old'), true);
    },
  );
  test('legacy S/L metadata survives both catalog and selected keys', () {
    final legacy = jsonEncode([
      'S',
      'unknown',
      '',
      10000,
      {
        'menu_id': 'parent',
        'names': {'name_ko': '탕수육'},
      },
    ]);
    final catalog = MenuChoiceCatalog.fromKey(catalogKey(legacy: legacy))!;
    final selection = catalog.select({'hot': 1, 'normal': 1}, 'direct');
    expect(MenuSizeMetadata.fromKey(catalog.key)!.menuId, 'parent');
    expect(MenuSizeMetadata.fromKey(selection.key)!.size, 'S');
  });
  test(
    'new and legacy drafts preserve selection keys and registered choices',
    () {
      final catalog = MenuChoiceCatalog.fromKey(catalogKey())!;
      final selection = catalog.select({'hot': 1, 'normal': 1}, 'direct');
      final id = selection.lineId('a0000000-0000-4000-8000-000000000001');
      final draft = DirectOrderCartDraft(
        id: 'a0000000-0000-4000-8000-000000000002',
        savedAt: DateTime.utc(2026),
        cart: {id: 2},
        itemNotes: {id: 'note'},
        menuOptionKeys: {id: selection.key},
        comboChoices: {},
        pickup: true,
        dinerCount: 1,
        utensilsRequested: false,
      );
      final restored = DirectOrderCartDraft.fromJson(
        jsonDecode(jsonEncode(draft.toJson())),
      );
      expect(restored.cart, {id: 2});
      expect(restored.menuOptionKeys[id], selection.key);
      expect(
        MenuOptions.fromJson({
          'choice_definition': definition(),
        }).copyWith(spice: 'mild').toJson()['choice_definition'],
        definition(),
      );
      expect(
        const MenuOptions().toJson().containsKey('choice_definition'),
        false,
      );
    },
  );
  testWidgets(
    'picker requires complete valid selections and keeps choices separate',
    (tester) async {
      MenuChoiceSelection? result;
      final catalog = MenuChoiceCatalog.fromKey(catalogKey())!;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showMenuChoicePicker(
                    context,
                    title: 'Dish',
                    catalog: catalog,
                    channel: 'qr',
                    language: 'en',
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('menu_choice_confirm')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.widgetWithText(ListTile, 'Normal'));
      await tester.pumpAndSettle();
      // Selection controls are explicit, tapping a row label does not commit it.
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Normal'),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu_choice_confirm')));
      await tester.pumpAndSettle();
      expect(result!.selected, {'mild': 1, 'normal': 1});
    },
  );
}
