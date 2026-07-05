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
      final floorLayout = readRepoFile('lib/features/table/floor_layout.dart');

      expect(adminTables, contains('FloorLayoutView('));
      expect(adminTables, contains('_layoutEditMode'));
      expect(adminTables, contains('_buildTableCommandHeader'));
      expect(adminTables, contains('PosFloorMapSurface('));
      expect(adminTables, contains('editMode: _layoutEditMode'));
      expect(adminTables, contains('class _AdminFloorOverviewInspector'));
      expect(adminTables, contains('class _AdminOccupiedTableShortcut'));
      expect(adminTables, contains("Key('admin_tables_save_layout_action')"));
      expect(
        adminTables,
        contains("Key('admin_table_layout_adjust_controls')"),
      );
      expect(
        adminTables,
        contains("keyName: 'admin_table_layout_width_decrease'"),
      );
      expect(
        adminTables,
        contains("keyName: 'admin_table_layout_width_increase'"),
      );
      expect(
        adminTables,
        contains("keyName: 'admin_table_layout_height_decrease'"),
      );
      expect(
        adminTables,
        contains("keyName: 'admin_table_layout_height_increase'"),
      );
      expect(
        adminTables,
        contains("keyName: 'admin_table_layout_rotate_left'"),
      );
      expect(
        adminTables,
        contains("keyName: 'admin_table_layout_rotate_right'"),
      );
      expect(adminTables, contains('_draftRotationByTableId'));
      expect(adminTables, contains('PosTable.normalizeLayoutRotation'));
      expect(adminTables, contains('PosActionTile('));
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
      expect(floorLayout, contains('class _FloorStatusBadge'));
      expect(floorLayout, contains('PosNumericText.tableId'));
      expect(provider, contains('Future<bool> updateTableLayout'));
      expect(audit, contains("'layout_x' => 'Layout X'"));
      expect(audit, contains("'layout_y' => 'Layout Y'"));
    },
  );
}
