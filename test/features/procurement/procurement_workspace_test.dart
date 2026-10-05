import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:globos_pos_system/features/procurement/procurement_workspace.dart';
import 'package:globos_pos_system/features/procurement/procurement_catalog_dialog.dart';

void main() {
  Map<String, dynamic> workspace({bool enabled = true}) => {
    'contract_version': 2,
    'store_id': 'store-a',
    'enabled': enabled,
    'actor': {'system': 'pos', 'subject_id': 'user-a', 'can_create': true},
    'requests': [],
    'orders': [],
    'events': [],
    'products': [],
    'supplier_items': [],
  };
  testWidgets('disabled store cannot create requests', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        home: ProcurementWorkspacePage(
          load: () async => workspace(enabled: false),
          execute: (a, b, c, d, e) async => {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('procurement_create_request')),
    );
    expect(button.onPressed, isNull);
  });
  testWidgets(
    'uncertain command survives reopen and retry preserves its exact identity',
    (tester) async {
      const key = 'procurement.command.pos.user-a.store-a';
      final pending = {
        'action': 'create_request',
        'record_id': null,
        'version': 0,
        'key': 'stable-key',
        'payload': {'reason': 'Gloves'},
      };
      SharedPreferences.setMockInitialValues({key: jsonEncode(pending)});
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ProcurementWorkspacePage(
            load: () async => workspace(),
            execute: (a, b, c, d, e) async {
              calls.add(d);
              expect(e, {'reason': 'Gloves'});
              if (calls.length == 1) throw Exception('Network unavailable');
              return {};
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry saved request'));
      await tester.pumpAndSettle();
      expect((await SharedPreferences.getInstance()).getString(key), isNotNull);
      await tester.tap(find.text('Retry saved request'));
      await tester.pumpAndSettle();
      expect(calls, ['stable-key', 'stable-key']);
      expect((await SharedPreferences.getInstance()).getString(key), isNull);
    },
  );
  testWidgets('another store never replays the saved command', (tester) async {
    SharedPreferences.setMockInitialValues({
      'procurement.command.pos.user-a.store-b': jsonEncode({'key': 'foreign'}),
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ProcurementWorkspacePage(
          load: () async => workspace(),
          execute: (a, b, c, d, e) async => {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Retry saved request'), findsNothing);
  });
  testWidgets('request dialog rejects impossible calendar date', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcurementRequestDialog(
            products: const [],
            supplierItems: const [],
          ),
        ),
      ),
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Required date (YYYY-MM-DD)'),
      '2026-02-31',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Check the date'), findsOneWidget);
  });
  testWidgets('opens request editor and cancellation creates no request', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ProcurementWorkspacePage(
          load: () async => workspace(),
          execute: (a, b, c, d, e) async {
            calls++;
            return {};
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('procurement_create_request')));
    await tester.pumpAndSettle();
    expect(find.byType(ProcurementRequestDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(ProcurementRequestDialog), findsNothing);
    expect(calls, 0);
  });
  testWidgets('purchase item dialog validates fields before saving', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final data = workspace();
    data['actor']['can_office_approve'] = true;
    data['supplier_items'] = [
      {'supplier_id': 'supplier-a', 'supplier_name': 'Supplier A'},
    ];
    final calls = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ProcurementWorkspacePage(
          load: () async => data,
          execute: (a, b, c, d, e) async {
            calls.add({'action': a, 'record_id': b, 'payload': e});
            return {};
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final open = find.widgetWithText(TextButton, 'Set up purchase item');
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(find.byType(ProcurementCatalogDialog), findsOneWidget);
    await tester.tap(find.widgetWithIcon(TextButton, Icons.close));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    await tester.tap(open);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithIcon(FilledButton, Icons.check));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(find.byType(ProcurementCatalogDialog), findsOneWidget);
    for (final entry in {
      'Item': 'Cleaning gloves',
      'Item code': 'GLOVE-01',
      'Specification': 'Size M',
      'Estimated unit price': '25000',
      'VAT (%)': '8',
    }.entries) {
      await tester.enterText(
        find.widgetWithText(TextFormField, entry.key),
        entry.value,
      );
    }
    await tester.tap(
      find
          .widgetWithText(DropdownButtonFormField<String>, 'Supplier PO PDF')
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supplier A').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithIcon(FilledButton, Icons.check));
    await tester.pumpAndSettle();
    expect(calls, [
      {
        'action': 'save_product',
        'record_id': null,
        'payload': {
          'name': 'Cleaning gloves',
          'product_code': 'GLOVE-01',
          'specification': 'Size M',
          'base_unit': 'ea',
          'stock_unit': 'ea',
          'base_unit_factor': '1',
          'unit_price': '25000',
          'tax_rate': '8',
          'supplier_id': 'supplier-a',
          'receipt_classification': 'nonstock',
        },
      },
    ]);
  });
  testWidgets('policy activation dialog requires explicit confirmation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final data = workspace(enabled: false);
    data['actor']['can_manage'] = true;
    data['policy'] = {
      'id': 'policy-a',
      'row_version': 7,
      'high_value_amount': 2000000,
      'quantity_review_multiplier': 2,
      'max_price_increase_percent': 10,
      'stock_freshness_hours': 12,
    };
    final calls = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ProcurementWorkspacePage(
          load: () async => data,
          execute: (a, b, c, d, e) async {
            calls.add({
              'action': a,
              'record_id': b,
              'version': c,
              'payload': e,
            });
            return {};
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final confirm in [false, true]) {
      await tester.tap(find.widgetWithText(OutlinedButton, 'Purchase policy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'New PRs will require store adjustment, brand agreement and purchase approval. Existing requests retain their policy.',
        ),
        findsOneWidget,
      );
      expect(calls, isEmpty);
      await tester.tap(
        confirm
            ? find.widgetWithIcon(FilledButton, Icons.check)
            : find.widgetWithIcon(TextButton, Icons.close),
      );
      await tester.pumpAndSettle();
      if (!confirm) expect(calls, isEmpty);
    }
    expect(calls, [
      {
        'action': 'configure',
        'record_id': 'policy-a',
        'version': 7,
        'payload': {
          'enabled': true,
          'three_stage_required': true,
          'high_value_amount': 2000000.0,
          'quantity_review_multiplier': 2.0,
          'max_price_increase_percent': 10.0,
          'stock_freshness_hours': 12,
        },
      },
    ]);
  });
  for (final action in ['return_request', 'submit_request']) {
    testWidgets(
      action == 'return_request'
          ? 'return reason dialog requires a reason'
          : 'request submit confirmation precedes command',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final data = workspace();
        data['requests'] = [
          {
            'id': 'pr-1',
            'request_no': 'PR-1',
            'status': 'submitted',
            'reason': 'Gloves',
            'row_version': 2,
            'allowed_actions': [action],
          },
        ];
        final calls = <Map<String, dynamic>>[];
        await tester.pumpWidget(
          MaterialApp(
            home: ProcurementWorkspacePage(
              load: () async => data,
              execute: (a, b, c, d, e) async {
                calls.add({'action': a, 'payload': e});
                return {};
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('PR-1 · Store review'));
        await tester.pumpAndSettle();
        final label = action == 'return_request' ? 'Return' : 'Submit';
        await tester.tap(find.widgetWithText(OutlinedButton, label));
        await tester.pumpAndSettle();
        expect(calls, isEmpty);
        if (action == 'return_request') {
          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();
          expect(calls, isEmpty);
          await tester.enterText(
            find.widgetWithText(TextFormField, 'Reason'),
            'Check quantity',
          );
          await tester.tap(find.text('OK'));
        } else {
          await tester.tap(find.widgetWithText(FilledButton, label));
        }
        await tester.pumpAndSettle();
        expect(calls.single['action'], action);
        if (action == 'return_request') {
          expect(calls.single['payload'], {'reason': 'Check quantity'});
        }
      },
    );
  }
}
