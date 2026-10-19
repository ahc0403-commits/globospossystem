import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:globos_pos_system/features/procurement/procurement_workspace.dart';

void main() {
  for (final count in [20, 100]) {
    for (final lines in [1, 20, 200]) {
      testWidgets(
        '$count summaries / $lines selected lines use one read per interaction',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final queries = <Map<String, dynamic>>[];
          Future<Map<String, dynamic>> page(Map<String, dynamic> query) async {
            queries.add({...query});
            return {
              'contract_version': 2,
              'read_contract': 'paged',
              'store_id': 'store-a',
              'enabled': true,
              'actor': {
                'system': 'pos',
                'subject_id': 'user-a',
                'can_create': true,
              },
              'products': [],
              'supplier_items': [],
              'requests': List.generate(
                count,
                (i) => {
                  'id': 'pr-$i',
                  'request_no': 'PR-$i',
                  'status': 'draft',
                  'reason': 'Test',
                  'updated_at': '2026-10-05',
                  'lines': [],
                  'quotes': [],
                  'allowed_actions': [],
                },
              ),
              'orders': [],
              'events': [],
              if (query['request_id'] != null)
                'request_detail': {
                  'id': 'pr-0',
                  'request_no': 'PR-0',
                  'status': 'draft',
                  'reason': 'Test',
                  'allowed_actions': [],
                  'lines': List.generate(
                    lines,
                    (i) => {
                      'id': 'line-$i',
                      'product_name': 'Test line $i',
                      'requested_quantity': 1,
                      'requested_unit': 'box',
                    },
                  ),
                  'quotes': [],
                },
            };
          }

          await tester.pumpWidget(
            MaterialApp(
              home: ProcurementWorkspacePage(
                load: () async => throw StateError('Unpaged read'),
                loadPage: page,
                execute: (a, b, c, d, e) async => {},
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(queries.length, 1);
          final first = find.text('PR-0 · Draft');
          await tester.ensureVisible(first);
          await tester.tap(first);
          await tester.pumpAndSettle();
          expect(queries.length, 2);
          expect(queries.last['request_id'], 'pr-0');
          await tester.scrollUntilVisible(
            find.textContaining('Test line ${lines - 1}'),
            1000,
            scrollable: find.byType(Scrollable).first,
            maxScrolls: 200,
          );
          expect(find.textContaining('Test line ${lines - 1}'), findsOneWidget);
          expect(queries.length, 2);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('paused creation leaves existing records readable', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        home: ProcurementWorkspacePage(
          load: () async => {
            'contract_version': 2,
            'store_id': 's',
            'enabled': true,
            'policy': {'new_requests_enabled': false},
            'actor': {'system': 'pos', 'subject_id': 'u', 'can_create': true},
            'requests': [],
            'orders': [],
          },
          execute: (a, b, c, d, e) async => {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('procurement_create_request')),
          )
          .onPressed,
      isNull,
    );
  });
  testWidgets('custom period validates dates before a bounded page read', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final queries = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ProcurementWorkspacePage(
          load: () async => {},
          loadPage: (q) async {
            queries.add({...q});
            return {
              'contract_version': 2,
              'store_id': 's',
              'enabled': true,
              'actor': {'system': 'pos', 'subject_id': 'u'},
              'requests': [],
              'orders': [],
            };
          },
          execute: (a, b, c, d, e) async => {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final period = find.byWidgetPredicate(
      (w) =>
          w is DropdownButtonFormField<String> &&
          w.key.toString().contains('procurement_period'),
    );
    await tester.tap(period);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom period').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Switch to input'));
    await tester.pumpAndSettle();
    final start = find.widgetWithText(TextField, 'Start Date');
    final end = find.widgetWithText(TextField, 'End Date');
    await tester.enterText(start, '02/31/2026');
    await tester.enterText(end, '10/07/2026');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(queries.length, 1);
    expect(find.text('Invalid format.'), findsOneWidget);
    await tester.enterText(start, '10/01/2026');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(queries.length, 2);
    expect(queries.last['created_from'], '2026-10-01');
    expect(queries.last['created_to'], '2026-10-07');
    expect(queries.last.containsKey('request_before'), isFalse);
    expect(tester.takeException(), isNull);
  });
}
