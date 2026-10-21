import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/store_setup/widgets/store_lifecycle_card.dart';

class _Service extends StoreLifecycleService {
  bool ready = false;
  final writes = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> load(String store) async => {
    'lifecycle': {'state': 'preparing', 'revision': 3},
    'source_hash': 'reviewed-hash',
    'business_ready': ready,
    'checks': {
      'accounts': true,
      'employees': true,
      'field_verification': ready,
    },
    'employees': [
      {'id': 'employee', 'name': 'Manager'},
    ],
  };
  @override
  Future<void> write(String rpc, Map<String, dynamic> params) async {
    expect(rpc, 'admin_transition_store_lifecycle_v1');
    writes.add(params);
  }
}

void main() {
  testWidgets(
    'readiness blocks opening and uses the inspected revision after explicit action',
    (tester) async {
      final service = _Service();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StoreLifecycleCard(storeId: 'store', service: service),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const Key('store_open_for_business'));
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      service.ready = true;
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(service.writes, isEmpty);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.enterText(
        find.byType(TextField),
        'Opening checks completed',
      );
      await tester.pump();
      await tester.tap(find.text('Record').last);
      await tester.pumpAndSettle();
      expect(service.writes.single, {
        'p_store_id': 'store',
        'p_expected_revision': 3,
        'p_state': 'active',
        'p_source_hash': 'reviewed-hash',
        'p_reason': 'Opening checks completed',
      });
    },
  );
}
