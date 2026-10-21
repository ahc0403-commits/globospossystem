import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/store_procurement/store_procurement_setup_card.dart';

class SetupFixture extends StoreProcurementSetupService {
  final calls = <(String, Map<String, dynamic>)>[];
  @override
  Future<dynamic> call(String name, Map<String, dynamic> params) async {
    calls.add((name, params));
    if (name == 'admin_get_procurement_setup_v1') {
      return {
        'readiness': {
          'ready': false,
          'revision': null,
          'enforced': false,
          'checks': {'policy': false, 'catalog': false, 'buyer': false},
        },
        'products': [],
        'templates': [],
        'specs': [],
      };
    }
    return {'id': params['p_id']};
  }
}

void main() {
  testWidgets(
    'procurement setup reads on demand and requires reviewed policy values',
    (tester) async {
      final fixture = SetupFixture();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StoreProcurementSetupCard(
                storeId: 'store-a',
                service: fixture,
              ),
            ),
          ),
        ),
      );
      expect(fixture.calls, isEmpty);
      await tester.tap(find.text('Check procurement readiness'));
      await tester.pumpAndSettle();
      expect(fixture.calls.single.$2, {
        'p_store': 'store-a',
        'p_after': null,
        'p_limit': 100,
      });
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Activate verified criteria'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Approve policy version'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Approve reviewed values'),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'Approved opening policy',
      );
      await tester.enterText(find.byType(TextFormField).at(1), '24');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Approve reviewed values'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Approve reviewed values'));
      await tester.pumpAndSettle();
      final published = fixture.calls
          .where((c) => c.$1 == 'admin_publish_procurement_template_v1')
          .single
          .$2;
      expect(published['p_policy'], {'stock_freshness_hours': 24});
      expect(published['p_name'], 'Approved opening policy');
      expect(
        fixture.calls.any((c) => c.$1 == 'admin_apply_procurement_template_v1'),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
