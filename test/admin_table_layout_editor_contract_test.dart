import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'admin tables tab exposes floor layout editor and saves table positions',
    () {
      final adminTables = readRepoFile(
        'lib/features/admin/tabs/tables_tab.dart',
      );
      final provider = readRepoFile(
        'lib/features/admin/providers/tables_provider.dart',
      );
      final audit = readRepoFile(
        'lib/features/admin/widgets/admin_audit_trace_panel.dart',
      );

      expect(adminTables, contains('FloorLayoutView('));
      expect(adminTables, contains('_layoutEditMode'));
      expect(adminTables, contains('_buildTableCommandHeader'));
      expect(adminTables, contains('ToastMetricStrip('));
      expect(adminTables, contains('ToastFilterChip('));
      expect(
        adminTables,
        contains("Key('admin_tables_audit_secondary_detail')"),
      );
      expect(
        adminTables,
        contains("Key('admin_table_order_secondary_detail')"),
      );
      expect(adminTables, contains('initiallyExpanded: false'));
      expect(adminTables, contains('onTableMoved:'));
      expect(adminTables, contains('updateTableLayout('));
      expect(adminTables, isNot(contains('PosPageHeader(')));
      expect(adminTables, isNot(contains('PosToolbar(')));
      expect(adminTables, isNot(contains('PosStatCard(')));
      expect(adminTables, isNot(contains('ChoiceChip(')));
      expect(provider, contains('Future<bool> updateTableLayout'));
      expect(audit, contains("'layout_x' => 'Layout X'"));
      expect(audit, contains("'layout_y' => 'Layout Y'"));
    },
  );
}
