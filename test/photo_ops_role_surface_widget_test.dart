import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/photo_ops/photo_ops_screen.dart';

void main() {
  testWidgets('store operator does not render management-only surfaces', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: PhotoOpsManagementSurfaceGate(
          role: 'photo_objet_store_operator',
          child: Column(
            children: [
              Text('sales'),
              Text('payroll'),
              Text('export'),
              Text('store scope'),
            ],
          ),
        ),
      ),
    );

    expect(find.text('sales'), findsNothing);
    expect(find.text('payroll'), findsNothing);
    expect(find.text('export'), findsNothing);
    expect(find.text('store scope'), findsNothing);
  });

  testWidgets('Photo master retains management-only surfaces', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: PhotoOpsManagementSurfaceGate(
          role: 'photo_objet_master',
          child: Text('management surface'),
        ),
      ),
    );

    expect(find.text('management surface'), findsOneWidget);
  });
}
