import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('kitchen workspace exposes a read-only operational attention layer', () {
    final screen = readRepoFile('lib/features/kitchen/kitchen_screen.dart');
    final provider = readRepoFile('lib/features/kitchen/kitchen_provider.dart');

    expect(
      screen,
      contains("import '../../core/i18n/locale_extensions.dart';"),
    );
    expect(screen, contains('context.l10n'));
    expect(screen, contains('l10n.kitchenAttentionTitle'));
    expect(screen, contains('l10n.kitchenAttentionSubtitle'));
    expect(screen, contains('l10n.kitchenAttentionFollowUpNow'));
    expect(screen, contains('l10n.kitchenAttentionPendingItems'));
    expect(screen, contains('l10n.kitchenAttentionReadyItems'));
    expect(screen, contains('l10n.kitchenAttentionOldestWait'));
    expect(screen, contains('l10n.kitchenAttentionLongWaits'));
    expect(screen, contains('l10n.kitchenAttentionReadyTables'));
    expect(screen, contains('l10n.kitchenAttentionFollowUpFocus'));
    expect(screen, contains('l10n.kitchenAttentionHandoffReadiness'));
    expect(screen, contains('l10n.kitchenAttentionBoundary'));
    expect(screen, contains('l10n.kitchenSecondsAgo'));
    expect(screen, contains('l10n.kitchenMinutesAgo'));
    expect(screen, contains('l10n.kitchenHoursAgo'));

    expect(
      provider,
      contains(".inFilter('status', ['pending', 'confirmed', 'serving'])"),
    );
    expect(
      provider,
      contains("LiveSyncScope.storeChannel('kitchen_orders', storeId)"),
    );
    expect(provider, contains('LiveSyncScope.storeFilter(storeId)'));
    expect(provider, contains('table: \'orders\''));
    expect(provider, contains('table: \'order_items\''));
    expect(provider, contains('PostgresChangeEvent.insert'));
    expect(provider, contains('PostgresChangeEvent.update'));
    expect(provider, contains('PostgresChangeEvent.delete'));
    expect(provider, contains('_refreshKitchenOrdersFromRealtime(storeId)'));
    expect(provider, contains('Duration(seconds: 2)'));
    expect(provider, contains('_ensureAutoRefresh(storeId)'));
    expect(provider, contains('showLoading: false'));

    expect(screen, isNot(contains("path: '/kitchen/attention'")));
    expect(screen, isNot(contains('Navigator.push(')));
    expect(screen, isNot(contains('createKitchenFollowup')));
  });

  test('kitchen alerts when waiter sends new items without manual refresh', () {
    final screen = readRepoFile('lib/features/kitchen/kitchen_screen.dart');

    expect(screen, contains('_hasObservedKitchenSnapshot'));
    expect(screen, contains('previousItemIds'));
    expect(screen, contains("item.status == 'pending'"));
    expect(screen, contains('_triggerKitchenNewOrderAlert(order)'));
    expect(screen, contains('showSuccessToast(context, message)'));
    expect(screen, contains('SystemSound.play(SystemSoundType.alert)'));
  });

  test('kitchen tickets expose menu-line-only item actions', () {
    final screen = readRepoFile('lib/features/kitchen/kitchen_screen.dart');

    expect(screen, contains('class _KitchenCommandHeader'));
    expect(screen, contains('ToastMetricStrip('));
    expect(screen, isNot(contains('PosPageHeader(')));
    expect(screen, isNot(contains('PosStatCard(')));
    expect(screen, contains('class _KitchenTicketPreview'));
    expect(screen, contains('_handleItemAction'));
    expect(screen, contains('required this.visibleStatuses'));
    expect(screen, contains('required this.processingItemIds'));
    expect(screen, contains('_processingItemIds.contains(item.itemId)'));
    expect(screen, contains("visibleStatuses: const {'pending'}"));
    expect(screen, contains("visibleStatuses: const {'preparing'}"));
    expect(screen, contains("visibleStatuses: const {'ready'}"));
    expect(screen, contains('(item) => visibleStatuses.contains(item.status)'));
    expect(screen, contains('processingItemIds.contains(item.itemId)'));
    expect(screen, contains('class _KitchenTicketItemRow'));
    expect(screen, contains('onItemAction: () => onItemAction(item)'));
    expect(screen, contains('onPressed: isProcessing ? null : onItemAction'));
    expect(screen, contains('CircularProgressIndicator(strokeWidth: 2)'));
    expect(screen, contains("return item.status == 'pending' ||"));
    expect(screen, contains("item.status == 'preparing' ||"));
    expect(screen, contains("item.status == 'ready';"));
    expect(screen, contains("'pending' => context.l10n.kitchenStartCooking"));
    expect(
      screen,
      contains("current.itemId == item.itemId || current.status == 'served'"),
    );
    expect(screen, contains(".where((item) => item.status == 'pending')"));
    expect(screen, contains('OutlinedButton.icon('));
    expect(screen, isNot(contains('_handleOrderPrimaryAction')));
    expect(screen, isNot(contains('_primaryKitchenActionItems')));
    expect(screen, isNot(contains('onPrimaryAction')));
    expect(
      screen,
      isNot(contains("const Key('kitchen_start_cooking_button')")),
    );
    expect(screen, isNot(contains('PosPrimaryButton(')));
    expect(screen, isNot(contains('ToastPrimaryActionZone(')));
    expect(screen, isNot(contains('for (final item in actionableItems)')));
    expect(screen, isNot(contains('class _KitchenExecutionItemRow')));
    expect(screen, isNot(contains('_executionOpen')));
    expect(screen, isNot(contains('티켓 실행')));
    expect(screen, isNot(contains('티켓 접기')));
  });

  test(
    'kitchen item status changes force a silent refresh after rpc success',
    () {
      final provider = readRepoFile(
        'lib/features/kitchen/kitchen_provider.dart',
      );

      expect(provider, contains('await orderService.updateOrderItemStatus('));
      expect(
        provider,
        contains('await loadOrders(storeId, showLoading: false);'),
      );
      expect(provider, isNot(contains("if (newStatus == 'served')")));
    },
  );

  test(
    'kitchen ticket header clamps table and status labels on narrow cards',
    () {
      final screen = readRepoFile('lib/features/kitchen/kitchen_screen.dart');

      expect(
        screen,
        contains('context.l10n.kitchenTableLabel(order.tableNumber)'),
      );
      expect(screen, contains('overflow: TextOverflow.ellipsis'));
      expect(screen, contains('Flexible('));
      expect(screen, contains('fit: FlexFit.loose'));
      expect(screen, contains('FittedBox('));
      expect(screen, contains('BoxFit.scaleDown'));
      expect(screen, contains('ToastStatusBadge.kitchen('));
    },
  );

  test(
    'kitchen stacked lanes use one vertical scroll owner on compact widths',
    () {
      final screen = readRepoFile('lib/features/kitchen/kitchen_screen.dart');

      expect(screen, contains('this.scrollable = true'));
      expect(screen, contains('scrollable: false'));
      expect(screen, contains('shrinkWrap: !scrollable'));
      expect(screen, contains(': const NeverScrollableScrollPhysics()'));
      expect(screen, isNot(contains('height: 420')));
    },
  );
}
