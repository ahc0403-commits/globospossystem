import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/procurement/procurement_product_picker.dart';

void main() {
  testWidgets(
    'search stays above scrolling results and returns the selected code',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final products = List.generate(
        200,
        (i) => <String, dynamic>{
          'id': '$i',
          'name': 'Material $i',
          'product_code': 'RAW-$i',
          'base_unit': 'g',
        },
      );
      Map<String, dynamic>? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  selected = await showDialog<Map<String, dynamic>>(
                    context: context,
                    builder: (_) =>
                        ProcurementProductPicker(products: products),
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
      final field = find.byKey(const Key('procurement_product_search'));
      final top = tester.getTopLeft(field).dy;
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(field).dy, top);
      await tester.enterText(field, 'RAW-199');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(find.text('Material 199'), findsOneWidget);
      await tester.tap(find.text('Material 199'));
      await tester.pumpAndSettle();
      expect(selected?['product']['product_code'], 'RAW-199');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'only one request runs and a late response cannot replace the latest search',
    (tester) async {
      final first = Completer<Map<String, dynamic>>();
      final second = Completer<Map<String, dynamic>>();
      final queries = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ProcurementProductPicker(
            products: const [],
            loadCatalog: (query) {
              queries.add(query);
              return queries.length == 1 ? first.future : second.future;
            },
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('procurement_product_search')),
        'RAW-new',
      );
      await tester.pump(const Duration(milliseconds: 301));
      expect(queries, hasLength(1));
      first.complete({
        'products': [
          {'id': 'old', 'name': 'Stale result'},
        ],
      });
      await tester.pump();
      await tester.pump();
      expect(queries, hasLength(2));
      expect(queries.last['catalog_only'], true);
      expect(queries.last['catalog_search'], 'RAW-new');
      expect(find.text('Stale result'), findsNothing);
      second.complete({
        'products': [
          {'id': 'new', 'name': 'Latest result', 'product_code': 'RAW-new'},
        ],
      });
      await tester.pumpAndSettle();
      expect(find.text('Latest result'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
