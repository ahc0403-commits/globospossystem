import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_cart_draft.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_menu_search.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_support.dart';
import 'package:globos_pos_system/features/inventory_purchase/inventory_workflow_state.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const item = DirectOrderMenuItem(
    id: 'menu',
    categoryId: 'food',
    nameKo: '당근 김밥',
    nameVi: 'Kimbap cà rốt',
    nameEn: 'Carrot kimbap',
    description: '',
    price: 10000,
    imageUrl: null,
    vatCategory: 'food',
    sortOrder: 1,
  );
  test('menu search matches all names and Vietnamese without accents', () {
    for (final query in ['당근', '김밥', 'CA ROT', 'cà rốt', 'CARROT KIMBAP', '']) {
      expect(directOrderMenuMatches(item, query), isTrue, reason: query);
    }
    expect(directOrderMenuMatches(item, 'missing'), isFalse);
  });
  test(
    'cart recovery stays scoped by store and retains submission identity',
    () async {
      SharedPreferences.setMockInitialValues({});
      const service = DirectOrderService();
      final draft = DirectOrderCartDraft(
        id: '11111111-1111-4111-8111-111111111111',
        savedAt: DateTime.now().toUtc(),
        cart: {'menu': 2},
        itemNotes: {'menu': 'No onion'},
        comboChoices: {},
        pickup: true,
        dinerCount: 2,
        utensilsRequested: false,
      );
      await service.saveCartDraft('store-a', draft);
      final restored = (await service.loadCartDraft('store-a'))!;
      expect(restored.id, draft.id);
      expect(restored.cart, {'menu': 2});
      expect(restored.itemNotes, {'menu': 'No onion'});
      expect(restored.pickup, isTrue);
      expect(await service.loadCartDraft('store-b'), isNull);
      await service.saveCartDraft('store-a', null);
      expect(await service.loadCartDraft('store-a'), isNull);
    },
  );
  test('expired and invalid drafts never replace a fresh cart', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'direct_order_cart_v1_store',
      jsonEncode({
        'id': '11111111-1111-4111-8111-111111111111',
        'saved_at': DateTime.now()
            .subtract(const Duration(days: 2))
            .toIso8601String(),
        'cart': {'menu': 2},
        'item_notes': {},
        'combo_choices': {},
        'pickup': false,
        'diner_count': 1,
        'utensils_requested': true,
      }),
    );
    const service = DirectOrderService();
    expect(await service.loadCartDraft('store'), isNull);
    await prefs.setString('direct_order_cart_v1_store', '{bad');
    expect(await service.loadCartDraft('store'), isNull);
    expect(prefs.containsKey('direct_order_cart_v1_store'), isFalse);
  });
  test('receiving uses localized names and exact display precision', () {
    expect(
      receivingProductName({
        'product': {'name': 'Cà rốt (당근)'},
      }, 'ko'),
      '당근 (Cà rốt)',
    );
    expect(receivingQuantityDifference(1, .8, 'KG', 'ko'), '발주 대비 0.2 KG 부족');
    expect(
      receivingQuantityDifference(1, 1.2, 'KG', 'en'),
      '0.2 KG over ordered quantity',
    );
    expect(receivingQuantityDifference(1, 1, 'KG', 'ko'), '');
  });

  for (final failRefresh in [false, true]) {
    testWidgets(
      'multiple chat images remain available after refresh failure=$failRefresh',
      (tester) async {
        final paths = <String>[];
        var picked = 0, refreshed = 0;
        final png = Uint8List.fromList(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z1ZcAAAAASUVORK5CYII=',
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.build(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: DirectOrderAttachmentButton(
                storeId: 'store',
                requestId: 'request',
                pickFile: () async => XFile.fromData(
                  png,
                  path: 'image-${++picked}.png',
                  name: 'image-$picked.png',
                ),
                upload: (path, filename, mime, bytes) async {
                  paths.add(path);
                },
                onSent: () async {
                  if (++refreshed == 1 && failRefresh) {
                    throw StateError('Refresh unavailable');
                  }
                },
              ),
            ),
          ),
        );
        for (var i = 0; i < 2; i++) {
          await tester.tap(find.text('Attach image or PDF'));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, 'Send'));
          await tester.pumpAndSettle();
          expect(find.text('Attach image or PDF'), findsOneWidget);
        }
        expect(picked, 2);
        expect(paths.toSet(), hasLength(2));
        expect(refreshed, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
