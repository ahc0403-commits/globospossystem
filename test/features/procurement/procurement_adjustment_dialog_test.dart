import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/procurement/procurement_adjustment_dialog.dart';
import 'package:globos_pos_system/features/procurement/procurement_process_labels.dart';

void main() {
  final original = <String, dynamic>{
    'id': 'line-original',
    'product_id': 'original',
    'product_name': 'Original material',
    'requested_quantity': 10,
    'requested_unit': 'g',
  };
  final added = <String, dynamic>{
    'id': 'added',
    'name': 'Added material',
    'product_code': 'ADD-001',
    'base_unit': 'g',
    'stock_unit': 'kg',
    'conversion': 1000,
  };
  test('adjustment action labels retain the same key in three languages', () {
    expect(procurementProcessLabel('adjust_request', 'ko'), '조정');
    expect(procurementProcessLabel('adjust_request', 'en'), 'Adjust');
    expect(procurementProcessLabel('adjust_request', 'vi'), 'Điều chỉnh');
  });

  for (final locale in ['ko', 'en', 'vi']) {
    testWidgets(
      '$locale manager can add a registered item without replacing old IDs',
      (tester) async {
        Map<String, dynamic>? saved;
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            supportedLocales: const [Locale('ko'), Locale('en'), Locale('vi')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Scaffold(
              body: ProcurementAdjustmentDialog(
                lines: [original],
                products: [added],
                allowAdditions: true,
                saveAdjustment: (payload) async {
                  saved = payload;
                  return null;
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('procurement_adjustment_reason')),
          'Add needed material',
        );
        await tester.enterText(
          find.byKey(const ValueKey('adjustment_quantity_line-original')),
          '12',
        );
        await tester.tap(find.byKey(const Key('procurement_adjustment_add')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Added material'));
        await tester.pumpAndSettle();
        final quantity = find.byKey(
          const ValueKey('adjustment_quantity_added'),
        );
        await tester.ensureVisible(quantity);
        await tester.enterText(quantity, '2');
        await tester.tap(find.byKey(const Key('procurement_adjustment_save')));
        await tester.pumpAndSettle();
        expect(saved?['reason'], 'Add needed material');
        expect(saved?['lines'], [
          {'request_line_id': 'line-original', 'quantity': '12'},
        ]);
        expect(saved?['new_lines'], [
          {'product_id': 'added', 'quantity': '2', 'unit': 'kg'},
        ]);
        expect(original['requested_quantity'], 10);
      },
    );
  }

  testWidgets(
    'duplicate selection and invalid quantity cannot create a batch',
    (tester) async {
      var writes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProcurementAdjustmentDialog(
              lines: [original],
              allowAdditions: true,
              products: [
                {...added, 'id': 'original'},
              ],
              saveAdjustment: (_) async {
                writes++;
                return null;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('procurement_adjustment_add')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Added material'));
      await tester.pumpAndSettle();
      expect(find.textContaining('already included'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('procurement_adjustment_reason')),
        'Review',
      );
      await tester.enterText(
        find.byKey(const ValueKey('adjustment_quantity_line-original')),
        '0',
      );
      await tester.tap(find.byKey(const Key('procurement_adjustment_save')));
      await tester.pumpAndSettle();
      expect(writes, 0);
      expect(find.text('Check quantity'), findsOneWidget);
    },
  );

  testWidgets('older servers keep quantity-only payloads and hide additions', (
    tester,
  ) async {
    Map<String, dynamic>? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcurementAdjustmentDialog(
            lines: [original],
            products: [added],
            saveAdjustment: (payload) async {
              saved = payload;
              return null;
            },
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('procurement_adjustment_add')), findsNothing);
    await tester.enterText(
      find.byKey(const Key('procurement_adjustment_reason')),
      'Review',
    );
    await tester.tap(find.byKey(const Key('procurement_adjustment_save')));
    await tester.pumpAndSettle();
    expect(saved?.containsKey('new_lines'), false);
    expect(saved?['lines'], [
      {'request_line_id': 'line-original', 'quantity': '10'},
    ]);
  });

  testWidgets(
    'uncertain save confirms the saved command without another payload',
    (tester) async {
      var writes = 0, confirmations = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProcurementAdjustmentDialog(
              lines: [original],
              products: [added],
              allowAdditions: true,
              saveAdjustment: (_) async {
                writes++;
                return 'Response lost';
              },
              needsConfirmation: () => true,
              retrySavedAdjustment: () async {
                confirmations++;
                return null;
              },
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('procurement_adjustment_reason')),
        'Review',
      );
      await tester.tap(find.byKey(const Key('procurement_adjustment_save')));
      await tester.pumpAndSettle();
      expect(find.text('Response lost'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const Key('procurement_adjustment_reason')),
            )
            .enabled,
        false,
      );
      await tester.tap(find.text('Confirm saved adjustment'));
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(confirmations, 1);
    },
  );
}
