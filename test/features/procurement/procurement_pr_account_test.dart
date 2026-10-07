import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:globos_pos_system/features/procurement/procurement_workspace.dart';
import 'package:globos_pos_system/features/procurement/procurement_presentation.dart';

void main() {
  test('recent month uses Vietnam dates and clamps the previous month', () {
    expect(procurementRecentMonth(nowUtc: DateTime.utc(2026, 3, 31)), {
      'created_from': '2026-02-28',
      'created_to': '2026-03-31',
    });
    expect(procurementRecentMonth(nowUtc: DateTime.utc(2028, 3, 31)), {
      'created_from': '2028-02-29',
      'created_to': '2028-03-31',
    });
    expect(procurementRecentMonth(nowUtc: DateTime.utc(2026, 12, 31, 17)), {
      'created_from': '2026-12-01',
      'created_to': '2027-01-01',
    });
    expect(procurementDate('2026-10-06T17:00:00Z'), '2026-10-07');
    expect(procurementNumber(1234567.89), '1,234,567.89');
    expect(procurementNumber(1.125, decimals: 3), '1.125');
    expect(procurementNumber(double.nan), '—');
  });
  test(
    'automatic estimate requires one best source and preserves explicit supplier',
    () {
      final items = <Map<String, dynamic>>[
        {
          'id': 'a',
          'product_id': 'p',
          'supplier_id': 's1',
          'is_preferred': true,
        },
        {
          'id': 'b',
          'product_id': 'p',
          'supplier_id': 's2',
          'is_preferred': false,
        },
      ];
      expect(procurementEstimateItem(items, 'p', null)?['id'], 'a');
      items[1]['is_preferred'] = true;
      expect(procurementEstimateItem(items, 'p', null), isNull);
      expect(procurementEstimateItem(items, 'p', 's2')?['id'], 'b');
      expect(procurementEstimateItem(items, 'missing', null), isNull);
    },
  );
  testWidgets('creating a PR selects the saved record on the first page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final queries = <Map<String, dynamic>>[];
    final requests = <Map<String, dynamic>>[
      {
        'id': 'old-pr',
        'request_no': 'PR-OLD',
        'status': 'draft',
        'created_at': '2026-09-08',
        'allowed_actions': [],
      },
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: ProcurementWorkspacePage(
          load: () async => {},
          loadPage: (query) async {
            queries.add({...query});
            return {
              'contract_version': 2,
              'enabled': true,
              'store_id': 'store',
              'actor': {
                'system': 'pos',
                'subject_id': 'requester',
                'can_create': true,
              },
              'requests': requests,
              'request_has_more': requests.length == 1,
              'orders': [],
              'events': [],
              'products': [
                {
                  'id': 'item',
                  'name': 'Eggs',
                  'stock_unit': 'box',
                  'base_unit': 'box',
                  'conversion': 1,
                },
              ],
              'supplier_items': [],
              if (query['request_id'] != null)
                'request_detail': requests.firstWhere(
                  (r) => r['id'] == query['request_id'],
                ),
            };
          },
          execute: (action, id, version, key, payload) async {
            final saved = <String, dynamic>{
              'id': 'saved-pr',
              'request_no': 'PR-SAVED',
              'status': 'draft',
              'row_version': 1,
              'reason': payload['reason'],
              'lines': [],
              'allowed_actions': [],
            };
            requests.insert(0, saved);
            return saved;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String>, 'Purchase category'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beverages').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Search PR'),
      'PR-OTHER',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(queries.last['purchase_category'], 'beverage');
    expect(queries.last['search'], 'PR-OTHER');
    await tester.tap(find.text('Next requests'));
    await tester.pumpAndSettle();
    expect(queries.last['request_before_id'], 'old-pr');
    final readsBeforeSave = queries.length;
    await tester.tap(find.byKey(const Key('procurement_create_request')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Reason *'),
      'Weekly replenishment',
    );
    final item = find.widgetWithText(DropdownButtonFormField<String>, 'Item');
    await tester.ensureVisible(item);
    await tester.tap(item);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Eggs').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(queries.last['request_id'], 'saved-pr');
    expect(queries.last.containsKey('request_before'), isFalse);
    expect(queries.last.containsKey('purchase_category'), isFalse);
    expect(queries.last.containsKey('search'), isFalse);
    await tester.scrollUntilVisible(
      find.text('PR-SAVED · Draft'),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('PR-SAVED · Draft'), findsOneWidget);
    expect(
      queries.length,
      readsBeforeSave + 1,
      reason: 'one bounded reload after the command',
    );
    expect(queries.last['request_sort'], 'created');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'response loss can be retried in the editor with the exact saved command',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final firstResponse = Completer<Map<String, dynamic>>();
      final calls = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ProcurementWorkspacePage(
            load: () async => _requesterWorkspace(),
            execute: (action, id, version, key, payload) async {
              calls.add({
                'action': action,
                'id': id,
                'version': version,
                'key': key,
                'payload': jsonDecode(jsonEncode(payload)),
              });
              if (calls.length == 1) return firstResponse.future;
              return {
                'id': 'saved-pr',
                'request_no': 'PR-SAVED',
                'status': 'draft',
                'row_version': 1,
              };
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _fillNewRequest(tester);
      // Two pointer events can share the callback before the next frame rebuilds.
      final save = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed!;
      save();
      save();
      await tester.pump();
      expect(calls, hasLength(1));
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull,
      );
      firstResponse.completeError(StateError('Connection closed after commit'));
      await tester.pumpAndSettle();
      final dialog = find.byType(ProcurementRequestDialog);
      expect(dialog, findsOneWidget);
      final retry = find.descendant(
        of: dialog,
        matching: find.text('Retry saved request'),
      );
      expect(retry, findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Reason *'),
            )
            .controller!
            .text,
        'Weekly replenishment',
      );
      final locked = find.descendant(
        of: dialog,
        matching: find.byType(AbsorbPointer),
      );
      expect(tester.widget<AbsorbPointer>(locked.first).absorbing, isTrue);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(calls, hasLength(2));
      expect(calls.last, calls.first);
      expect(dialog, findsNothing);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'procurement.command.pos.requester.store',
        ),
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'transactional rejection keeps the editor editable and starts a new command',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final calls = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ProcurementWorkspacePage(
            load: () async => _requesterWorkspace(),
            execute: (action, id, version, key, payload) async {
              calls.add({'key': key, 'reason': payload['reason']});
              if (calls.length == 1) {
                throw StateError('PROCUREMENT_INPUT_INVALID');
              }
              return {
                'id': 'saved-pr',
                'request_no': 'PR-SAVED',
                'status': 'draft',
              };
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _fillNewRequest(tester);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.byType(ProcurementRequestDialog), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'procurement.command.pos.requester.store',
        ),
        isNull,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Reason *'),
        'Corrected reason',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(calls, hasLength(2));
      expect(calls.last['key'], isNot(calls.first['key']));
      expect(calls.last['reason'], 'Corrected reason');
      expect(find.byType(ProcurementRequestDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'successful save with failed refresh closes the editor without replaying creation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final refresh = ChangeNotifier();
      addTearDown(refresh.dispose);
      final queries = <Map<String, dynamic>>[];
      var commands = 0;
      final saved = {
        'id': 'saved-pr',
        'request_no': 'PR-SAVED',
        'status': 'draft',
        'allowed_actions': [],
      };
      await tester.pumpWidget(
        MaterialApp(
          home: ProcurementWorkspacePage(
            load: () async => {},
            refreshListenable: refresh,
            loadPage: (query) async {
              queries.add({...query});
              if (queries.length == 2) throw StateError('Network unavailable');
              return {
                ..._requesterWorkspace(),
                if (commands > 0) 'requests': [saved],
                if (query['request_id'] != null) 'request_detail': saved,
              };
            },
            execute: (action, id, version, key, payload) async {
              commands++;
              return saved;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _fillNewRequest(tester);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.byType(ProcurementRequestDialog), findsNothing);
      expect(
        find.text('Saved, but the list could not refresh. Refresh to confirm.'),
        findsOneWidget,
      );
      expect(commands, 1);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'procurement.command.pos.requester.store',
        ),
        isNull,
      );
      refresh.notifyListeners();
      await tester.pumpAndSettle();
      expect(queries, hasLength(3));
      expect(queries.last['request_id'], 'saved-pr');
      expect(commands, 1);
      expect(
        find.text('Saved, but the list could not refresh. Refresh to confirm.'),
        findsNothing,
      );
      expect(find.text('PR-SAVED · Saved · Draft'), findsOneWidget);
      await tester.ensureVisible(find.text('PR-SAVED · Draft'));
      expect(find.text('PR-SAVED · Draft'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'request editor hides channel and supplier while retaining automatic estimates',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProcurementRequestDialog(
              products: const [
                {
                  'id': 'item',
                  'name': 'Eggs',
                  'stock_unit': 'box',
                  'base_unit': 'ea',
                  'conversion': 10,
                },
              ],
              supplierItems: const [
                {
                  'id': 'price',
                  'product_id': 'item',
                  'supplier_id': 'supplier',
                  'is_preferred': true,
                  'unit_price': 85000,
                  'tax_rate': 0,
                  'order_unit_quantity_base': 10,
                  'order_unit': 'box',
                },
              ],
              initial: const {
                'purchase_channel': 'shopee',
                'purchase_category': 'stationery',
                'reason': 'Restock',
                'lines': [
                  {
                    'product_id': 'item',
                    'requested_quantity': 2,
                    'requested_unit': 'box',
                  },
                ],
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Purchase channel'), findsNothing);
      expect(find.text('Suggested supplier (optional)'), findsNothing);
      expect(find.textContaining('170,000'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed save preserves edited values and hidden historical fields',
    (tester) async {
      final pending = Completer<String?>();
      final payloads = <Map<String, dynamic>>[];
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await showDialog<Map<String, dynamic>>(
                    context: context,
                    builder: (_) => ProcurementRequestDialog(
                      products: const [
                        {
                          'id': 'p',
                          'name': 'Eggs',
                          'stock_unit': 'box',
                          'base_unit': 'ea',
                          'conversion': 10,
                        },
                      ],
                      supplierItems: const [],
                      initial: const {
                        'purchase_category': 'stationery',
                        'purchase_channel': 'shopee',
                        'reason': 'Original',
                        'requested_delivery_date': '2026-10-09',
                        'lines': [
                          {
                            'product_id': 'p',
                            'requested_quantity': 2,
                            'requested_unit': 'box',
                            'preferred_supplier_id': 'original-supplier',
                          },
                        ],
                      },
                      saveRequest: (payload) async {
                        payloads.add(payload);
                        return payloads.length == 1 ? pending.future : null;
                      },
                    ),
                  );
                },
                child: const Text('Open editor'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Reason *'),
        'Edited request',
      );
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull,
      );
      pending.complete('Version changed; review again.');
      await tester.pumpAndSettle();
      expect(find.text('Version changed; review again.'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Reason *'),
            )
            .controller!
            .text,
        'Edited request',
      );
      expect(saved, isNull);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved!['reason'], 'Edited request');
      expect(saved!['purchase_category'], 'stationery');
      expect(saved!['purchase_channel'], 'shopee');
      expect(
        (saved!['lines'] as List).single['preferred_supplier_id'],
        'original-supplier',
      );
      expect(payloads.length, 2);
      expect(tester.takeException(), isNull);
    },
  );
}

Map<String, dynamic> _requesterWorkspace() => {
  'contract_version': 2,
  'enabled': true,
  'store_id': 'store',
  'actor': {'system': 'pos', 'subject_id': 'requester', 'can_create': true},
  'requests': [],
  'orders': [],
  'events': [],
  'products': [
    {
      'id': 'item',
      'name': 'Eggs',
      'stock_unit': 'box',
      'base_unit': 'box',
      'conversion': 1,
    },
  ],
  'supplier_items': [],
};

Future<void> _fillNewRequest(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('procurement_create_request')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Reason *'),
    'Weekly replenishment',
  );
  final item = find.widgetWithText(DropdownButtonFormField<String>, 'Item');
  await tester.ensureVisible(item);
  await tester.tap(item);
  await tester.pumpAndSettle();
  await tester.tap(find.textContaining('Eggs').last);
  await tester.pumpAndSettle();
}
