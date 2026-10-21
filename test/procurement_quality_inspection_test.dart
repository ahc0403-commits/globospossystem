import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/procurement/procurement_inspection_dialog.dart';

void main() {
  testWidgets(
    'frozen quality version requires a real employee, sample and measured temperature',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      List<Map<String, dynamic>>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  saved = await showDialog<List<Map<String, dynamic>>>(
                    context: context,
                    builder: (_) => ProcurementInspectionDialog(
                      employees: const [
                        {'id': 'person-a', 'name': 'Receiving employee'},
                      ],
                      lines: const [
                        {
                          'id': 'line-a',
                          'product_name': 'Cold ingredient',
                          'quality': {
                            'profile_id': 'profile-v2',
                            'revision': 2,
                            'criteria': {
                              'temperature_required': true,
                              'temperature_min_c': 0,
                              'temperature_max_c': 5,
                              'expiry_required': true,
                              'min_remaining_days': 7,
                              'photo_required': false,
                              'min_sample_count': 2,
                            },
                          },
                        },
                      ],
                      payload: const [
                        {
                          'purchase_order_line_id': 'line-a',
                          'received_quantity_base': 10,
                        },
                      ],
                      uploadPhoto: (_) async =>
                          throw StateError('No upload expected'),
                    ),
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
      expect(find.text('0–5 °C'), findsOneWidget);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Expiry not applicable'),
            )
            .onChanged,
        isNull,
      );
      await tester.tap(find.text('Save inspection'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      await tester.tap(find.byKey(const Key('quality_inspector_employee')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Receiving employee').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('quality_samples_line-a')),
        '2',
      );
      final expiry = find.widgetWithText(TextFormField, 'Expiry (YYYY-MM-DD)');
      final temperature = find.widgetWithText(
        TextFormField,
        'Measured cold-chain temperature °C',
      );
      await tester.enterText(expiry, '2027-01-01');
      await tester.enterText(temperature, '8');
      await tester.tap(find.text('Save inspection'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.text('Check approved temperature range'), findsOneWidget);
      await tester.enterText(temperature, '3');
      await tester.tap(find.text('Save inspection'));
      await tester.pumpAndSettle();
      expect(
        saved!.single['inspection'],
        containsPair('quality_profile_id', 'profile-v2'),
      );
      expect(
        saved!.single['inspection'],
        containsPair('employee_id', 'person-a'),
      );
      expect(saved!.single['inspection'], containsPair('sample_count', '2'));
      expect(tester.takeException(), isNull);
    },
  );
}
