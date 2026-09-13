import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:globos_pos_system/features/procurement/procurement_workspace.dart';

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
}
