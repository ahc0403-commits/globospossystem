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
    expect(screen, contains('l10n.kitchenAttentionOldestWait'));
    expect(screen, contains('l10n.kitchenAttentionLongWaits'));
    expect(screen, contains('l10n.kitchenAttentionFollowUpFocus'));
    expect(screen, contains('l10n.kitchenAttentionBoundary'));
    expect(screen, contains('l10n.kitchenSecondsAgo'));
    expect(screen, contains('l10n.kitchenMinutesAgo'));
    expect(screen, contains('l10n.kitchenHoursAgo'));

    expect(
      provider,
      contains(
        ".inFilter('status', ['pending', 'confirmed', 'serving', 'completed'])",
      ),
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
    expect(provider, contains('completedOrders'));
    expect(screen, contains("Key('kitchen_completed_history_panel')"));

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

  test('kitchen tickets expose item and whole-ticket completion actions', () {
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
    expect(screen, contains("'preparing',"));
    expect(screen, contains("'ready',"));
    expect(screen, contains('(item) => visibleStatuses.contains(item.status)'));
    expect(screen, contains('processingItemIds.contains(item.itemId)'));
    expect(screen, contains('class _KitchenTicketItemRow'));
    expect(screen, contains('onItemAction: () => onItemAction(item)'));
    expect(screen, contains('onPressed: isProcessing ? null : onItemAction'));
    expect(screen, contains('CircularProgressIndicator(strokeWidth: 2)'));
    expect(screen, contains('PosDensity.touchTargetMin'));
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
    expect(screen, contains('kitchenCompleteAllItems'));
    expect(screen, contains("Key('kitchen_complete_order_\${order.orderId}')"));
    expect(screen, contains('_handleOrderComplete'));
    expect(screen, contains('notifier.completeOrder(order.orderId)'));
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
    'kitchen v2 uses bright ticket-rail tokens without dark board creep',
    () {
      final screen = readRepoFile('lib/features/kitchen/kitchen_screen.dart');

      expect(screen, contains('PosNumericText.tableId'));
      expect(screen, contains('PosNumericText.elapsedPrimary'));
      expect(screen, contains('PosNumericText.elapsedOverdue'));
      expect(screen, contains('PosNumericText.qtyUnit'));
      expect(screen, contains('PosSurfaceRole.background'));
      expect(screen, contains('PosSurfaceRole.operating'));
      expect(screen, contains('PosSurfaceRole.action'));
      expect(screen, contains('PosStatusPalette.delayed'));
      expect(screen, contains('PosStatusPalette.newOrder'));
      expect(screen, contains('PosStatusPalette.preparing'));
      expect(screen, contains('PosStatusPalette.handoffReady'));
      expect(screen, contains('_KitchenStatusCue'));
      expect(screen, contains('_kitchenStatusIcon'));
      expect(screen, contains('icon: _kitchenStatusIcon(normalized)'));
      expect(screen, contains("Key('kitchen_empty_lane_slim_rail')"));
      expect(
        screen,
        contains('constraints: const BoxConstraints(minHeight: 72)'),
      );
      expect(screen, isNot(contains('PosKdsDark')));
      expect(screen, isNot(contains('dark mode')));
      expect(screen, isNot(contains('darkMode')));
      expect(screen, isNot(contains('brightness: Brightness.dark')));
    },
  );

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
      expect(screen, contains('Expanded('));
      expect(
        screen,
        contains('_KitchenStatusCue(status: orderSummary.status)'),
      );
      expect(screen, contains('Wrap('));
      expect(screen, contains('ToastStatusBadge.kitchen('));
    },
  );

  test(
    'kitchen stacked lanes use one vertical scroll owner on compact widths',
    () {
      final screen = readRepoFile('lib/features/kitchen/kitchen_screen.dart');

      expect(screen, contains('this.scrollable = true'));
      expect(screen, contains('scrollable: false'));
      expect(screen, contains('ToastResponsiveScrollBody('));
      expect(screen, contains('shrinkWrap: !scrollable'));
      expect(screen, contains(': const NeverScrollableScrollPhysics()'));
      expect(screen, isNot(contains('height: 420')));
    },
  );

  test('kitchen exposes failed print jobs and reprint action in place', () {
    final screen = readRepoFile('lib/features/kitchen/kitchen_screen.dart');
    final provider = readRepoFile('lib/features/kitchen/kitchen_provider.dart');

    expect(provider, contains('class FailedPrintJob'));
    expect(provider, contains('failedPrintJobsProvider'));
    expect(provider, contains('printStationJobsProvider'));
    expect(provider, contains(".from('print_jobs')"));
    expect(provider, contains(".eq('status', 'failed')"));
    expect(
      provider,
      contains(".inFilter('status', ['pending', 'printing', 'failed'])"),
    );
    expect(provider, contains("'reprint_print_job'"));
    expect(screen, contains('class _KitchenFailedPrintJobsButton'));
    expect(screen, contains("Key('kitchen_failed_print_jobs_button')"));
    expect(screen, contains("Key('kitchen_failed_print_jobs_badge')"));
    expect(screen, contains("Key('kitchen_failed_print_jobs_dialog')"));
    expect(screen, contains("Key('kitchen_reprint_print_job_button')"));
    expect(screen, contains("Key('kitchen_print_station_entry')"));
    expect(screen, contains('PlatformInfo.isPrinterSupported'));
    expect(screen, contains("context.go('/print-station')"));
    expect(screen, contains('context.l10n.kitchenFailedPrintJobs'));
    expect(screen, contains('context.l10n.kitchenPrintQueueUnavailable'));
    expect(screen, contains('context.l10n.kitchenReprintQueued'));
    expect(
      screen,
      contains('ref.invalidate(failedPrintJobsProvider(storeId))'),
    );
    expect(screen, isNot(contains("path: '/kitchen/print-jobs'")));
    expect(screen, isNot(contains('Navigator.push(')));
  });
}
