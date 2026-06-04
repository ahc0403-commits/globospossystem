import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'waiter uses shared floor layout instead of fixed grid table rendering',
    () {
      final floorLayout = readRepoFile('lib/features/table/floor_layout.dart');
      final waiter = readRepoFile('lib/features/waiter/waiter_screen.dart');

      expect(floorLayout, contains('class FloorLayoutView'));
      expect(floorLayout, contains('Positioned('));
      expect(floorLayout, contains('onTableMoved'));
      expect(waiter, contains('FloorLayoutView('));
      expect(waiter, contains('_buildWaiterCommandHeader'));
      expect(waiter, contains('ToastMetricStrip('));
      expect(waiter, contains("Key('waiter_mobile_command_header')"));
      expect(waiter, contains("Key('waiter_mobile_order_header')"));
      expect(waiter, isNot(contains('PosPageHeader(')));
      expect(waiter, isNot(contains('PosStatCard(')));
      expect(
        waiter,
        isNot(contains('SliverGridDelegateWithFixedCrossAxisCount')),
      );
    },
  );

  test('waiter top navigation returns from order workspace to floor', () {
    final waiter = readRepoFile('lib/features/waiter/waiter_screen.dart');
    final navBar = readRepoFile('lib/widgets/app_nav_bar.dart');

    expect(waiter, contains('showOrderWorkspace: showOrderWorkspace'));
    expect(waiter, contains('onReturnToFloor: _onCancelOrderPanel'));
    expect(waiter, contains('forceBackEnabled: showOrderWorkspace'));
    expect(waiter, contains('forceHomeEnabled: showOrderWorkspace'));
    expect(navBar, contains('final bool forceBackEnabled;'));
    expect(navBar, contains('final bool forceHomeEnabled;'));
    expect(navBar, contains('forceBackEnabled || nav.canGoBack'));
    expect(navBar, contains('forceHomeEnabled || !isHome'));
  });

  test('waiter floor table cards show active order menu previews', () {
    final waiter = readRepoFile('lib/features/waiter/waiter_screen.dart');
    final floorLayout = readRepoFile('lib/features/table/floor_layout.dart');
    final tableProvider = readRepoFile(
      'lib/features/table/table_provider.dart',
    );
    final previewModel = readRepoFile(
      'lib/features/table/table_order_preview.dart',
    );

    expect(
      waiter,
      contains('orderPreviewByTableId: state.orderPreviewByTableId'),
    );
    expect(waiter, contains('loadTables(storeId);'));
    expect(floorLayout, contains('orderPreviewByTableId'));
    expect(floorLayout, contains('_TableOrderPreviewChip'));
    expect(floorLayout, contains('Icons.restaurant_menu'));
    expect(tableProvider, contains('orderPreviewByTableId'));
    expect(tableProvider, contains('static const _autoRefreshInterval'));
    expect(tableProvider, contains('_ensureAutoRefresh(storeId)'));
    expect(tableProvider, contains('Timer.periodic(_autoRefreshInterval'));
    expect(tableProvider, contains('loadTables(storeId, showLoading: false)'));
    expect(tableProvider, contains('_refreshTablesFromRealtime(storeId)'));
    expect(
      tableProvider,
      contains('status == RealtimeSubscribeStatus.subscribed'),
    );
    expect(
      tableProvider,
      contains(
        'order_items(id, created_at, label, quantity, status, menu_items(name))',
      ),
    );
    expect(
      tableProvider,
      contains('itemRows.sort(_compareOrderItemRowsByCreatedAt);'),
    );
    expect(previewModel, contains('class TableOrderPreview'));
    expect(
      previewModel,
      contains('lines.fold<int>(0, (sum, line) => sum + line.quantity)'),
    );
  });

  test('waiter table switching clears the unsent order cart', () {
    final waiter = readRepoFile('lib/features/waiter/waiter_screen.dart');

    expect(waiter, contains('final selectingDifferentTable'));
    expect(
      waiter,
      contains('ref.read(orderProvider.notifier).clearSession();'),
    );
    expect(
      waiter,
      contains('await ref.read(orderProvider.notifier).loadActiveOrder'),
    );
  });

  test('waiter phone portrait uses non-overlapping compact floor cards', () {
    final floorLayout = readRepoFile('lib/features/table/floor_layout.dart');
    final workspace = readRepoFile('lib/widgets/order_workspace.dart');

    expect(floorLayout, contains('constraints.maxWidth < 560'));
    expect(floorLayout, contains('class _CompactFloorTableGrid'));
    expect(floorLayout, contains("key: const Key('floor_compact_table_grid')"));
    expect(floorLayout, contains('SliverGridDelegateWithFixedCrossAxisCount'));
    expect(workspace, contains('final useSingleColumn'));
    expect(workspace, contains('gridConstraints.maxWidth < 420'));
  });

  test('waiter smoke table target prefers the first available table', () {
    final floorLayout = readRepoFile('lib/features/table/floor_layout.dart');

    expect(floorLayout, contains('int _firstActionableTableIndex'));
    expect(
      floorLayout,
      contains('tables.indexWhere((table) => table.isAvailable)'),
    );
    expect(floorLayout, contains('availableIndex == -1 ? 0 : availableIndex'));
    expect(floorLayout, contains('final firstActionableTableIndex'));
    expect(
      floorLayout,
      contains('firstActionableTableIndex: firstActionableTableIndex'),
    );
    expect(floorLayout, contains('index == firstActionableTableIndex'));
  });
}
