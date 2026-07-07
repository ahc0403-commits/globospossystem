import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('cashier screen routes key operational copy through localization', () {
    final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');

    expect(cashier, contains('context.l10n'));
    expect(cashier, contains('l10n.cashierTitle'));
    expect(cashier, contains('l10n.cashierSubtitle'));
    expect(cashier, contains('l10n.cashierNoPayableOrdersTitle'));
    expect(cashier, contains('l10n.cashierSelectTableTitle'));
    expect(cashier, contains('l10n.cashierCancelOrderTitle'));
    expect(cashier, contains('l10n.cashierServiceProvisionTitle'));
    expect(cashier, contains('l10n.cashierPaymentDue'));
    expect(cashier, contains('l10n.cashierCompletedStatus'));
    expect(cashier, contains('l10n.logout'));
  });

  test(
    'cashier checkout does not expose daily settlement as a default payment job',
    () {
      final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');

      expect(cashier, contains('PaymentProofModal('));
      expect(cashier, contains('RedInvoiceModal('));
      expect(cashier, isNot(contains('_CashierTodaySummaryDialog')));
      expect(cashier, isNot(contains('_showTodaySummaryDialog')));
      expect(cashier, isNot(contains('cashierTodaySummaryProvider')));
      expect(cashier, isNot(contains('l10n.cashierTodaySettlement')));
    },
  );

  test('cashier payment execution uses a primary-job command header', () {
    final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');

    expect(cashier, contains('_buildCashierCommandHeader'));
    expect(cashier, contains('ToastMetricStrip('));
    expect(cashier, contains("key: const Key('cashier_payment_surface')"));
    expect(cashier, contains('PosAmountAnchor('));
    expect(cashier, contains('PosNumericText.amountHero'));
    expect(cashier, contains('PosActionTile('));
    expect(cashier, contains('PosActionTileState.processing'));
    expect(cashier, contains('PosActionTileState.offlineBlocked'));
    expect(cashier, contains('class _CashierNoPayableOrdersPanel'));
    expect(
      cashier,
      contains("Key('cashier_no_payable_orders_operational_empty')"),
    );
    expect(cashier, contains('notifier.loadOrders(storeId)'));
    expect(cashier, contains('l10n.cashierTerminalOnline'));
    expect(cashier, contains('l10n.cashierTerminalOffline'));
    expect(cashier, isNot(contains('PosMoneyBlock(')));
    expect(cashier, isNot(contains('PosPageHeader(')));
    expect(cashier, isNot(contains('PosStatCard(')));
    expect(cashier, contains('PaymentProofModal('));
    expect(cashier, contains('RedInvoiceModal('));
  });

  test('cashier pay button separates method selection from final payment', () {
    final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');

    expect(cashier, contains("key: const Key('payment_submit_button')"));
    expect(cashier, contains('showDialog<String>('));
    expect(cashier, contains('final method = await showDialog<String>('));
    expect(cashier, contains('_CashierPaymentMethodDialog'));
    expect(cashier, contains("Key('cashier_method_dialog_"));
    expect(cashier, contains("l10n.cashierCashMethod"));
    expect(cashier, contains("l10n.cashierQrPaymentMethod"));
    expect(cashier, contains("l10n.cashierCardMethod"));
    expect(cashier, contains('paymentMethodCash'));
    expect(cashier, contains('paymentMethodOther'));
    expect(cashier, contains('paymentMethodCreditCard'));
    expect(cashier, contains('requiresPaymentProof(method)'));
    expect(cashier, contains('isServicePaymentMethod(method)'));
    expect(cashier, contains('paymentMethodDisplayLabel('));
    expect(cashier, contains("onSelectMethod(method);"));
    expect(cashier, contains('if (selectedMethod == null)'));
    expect(cashier, contains('await onProcess(selectedMethod!)'));
    expect(cashier, isNot(contains('await onProcess(method)')));
    expect(cashier, isNot(contains('var method = selectedMethod')));
    expect(cashier, contains('? l10n.cashierPaymentMethod'));
    expect(cashier, contains(': l10n.cashierCompletedStatus'));

    final ko = readRepoFile('lib/l10n/app_ko.arb');
    expect(ko, contains('"cashierCashMethod": "현금"'));
    expect(ko, contains('"cashierQrPaymentMethod": "페이"'));
    expect(ko, contains('"cashierCardMethod": "카드"'));
    expect(ko, contains('"cashierCompletedStatus": "결제 완료"'));
  });

  test(
    'cashier lookup, table selection, and method choice do not complete payment',
    () {
      final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');
      final provider = readRepoFile(
        'lib/features/payment/payment_provider.dart',
      );

      expect(cashier, contains('notifier.selectOrder(order);'));
      expect(
        cashier,
        contains('onTap: () => _showCashierOrderItemsSheet(context, order)'),
      );
      expect(cashier, contains('onTap: () => onSelectMethod(method.value)'));
      expect(provider, contains('void selectOrder(CashierOrder order)'));
      expect(
        provider,
        contains('Future<Map<String, dynamic>?> processPayment('),
      );

      final selectOrderBody = RegExp(
        r'void selectOrder\(CashierOrder order\) \{(?<body>[\s\S]*?)\n  \}',
      ).firstMatch(provider)?.namedGroup('body');
      expect(selectOrderBody, isNotNull);
      expect(selectOrderBody, isNot(contains('processPayment')));
      expect(selectOrderBody, isNot(contains('paymentService')));
      expect(selectOrderBody, isNot(contains('paymentSuccess: true')));
    },
  );

  test(
    'cashier compact payment flow exposes queue, order items, pay, and scroll',
    () {
      final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');

      expect(
        cashier,
        contains("key: const Key('cashier_pending_payment_list')"),
      );
      expect(cashier, contains("key: const Key('cashier_compact_show_queue')"));
      expect(
        cashier,
        contains("key: const Key('cashier_compact_show_selected')"),
      );
      expect(
        cashier,
        contains("key: const Key('cashier_selected_order_scroll')"),
      );
      expect(cashier, contains('_showPaymentQueueOnCompact = false'));
      expect(cashier, contains('Expanded('));
      expect(cashier, contains('showCompactQueue'));
      expect(cashier, contains('? queueWithHistory'));
      expect(cashier, contains(': detailPane'));
      expect(cashier, contains('final useCompactChrome = !useWideLayout'));
      expect(cashier, contains('compact: useCompactChrome'));
      expect(
        cashier,
        contains("key: const Key('cashier_compact_command_bar')"),
      );
      expect(cashier, contains('if (compact)'));
      expect(
        cashier,
        contains('_CashierCompactCommandBar(isOnline: isOnline)'),
      );
      expect(cashier, contains('SizedBox(height: useCompactChrome ? 8 : 12)'));
      expect(cashier, contains('_CashierOrderSummarySurface('));
      expect(cashier, contains('compact: true'));
      expect(cashier, contains('_CashierOrderItemsPanel('));
      expect(cashier, contains('scrollable: !compact'));
      expect(cashier, contains('NeverScrollableScrollPhysics'));
      expect(cashier, contains('expandMethodSection: false'));
      expect(
        cashier,
        contains("key: const Key('cashier_selected_amount_button')"),
      );
      expect(cashier, contains('_showCashierOrderItemsSheet(context, order)'));
      expect(cashier, contains("key: const Key('cashier_order_items_sheet')"));
      expect(
        cashier,
        contains("key: Key('cashier_method_tile_\${method.value}')"),
      );
      expect(cashier, contains('paymentMethodOther'));
      expect(cashier, contains('l10n.cashierQrPaymentMethod'));
      expect(cashier, isNot(contains('height: isAdmin ? 408 : 372')));
    },
  );

  test(
    'cashier payment queue follows kitchen ready handoff and short landscape scroll',
    () {
      final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');
      final provider = readRepoFile(
        'lib/features/payment/payment_provider.dart',
      );
      final readyHandoffMigration = readRepoFile(
        'supabase/migrations/20260703000000_cashier_ready_items_open_payment.sql',
      );

      // ORDER_LIFECYCLE_STATE_CONTRACT_2026_07_03: payability is the
      // server-derived order status (serving), not a client-side item scan.
      expect(provider, contains(".eq('status', 'serving')"));
      expect(provider, isNot(contains('_isCashierPayableItemRows')));
      expect(provider, contains("status: 'serving'"));
      expect(provider, contains("table: 'order_items'"));
      expect(provider, contains('PostgresChangeEvent.update'));
      expect(provider, contains('PostgresChangeEvent.insert'));
      expect(provider, contains('PostgresChangeEvent.delete'));
      expect(provider, contains('static const _autoRefreshInterval'));
      expect(provider, contains('_ensureAutoRefresh(storeId)'));
      expect(provider, contains('Timer.periodic(_fallbackPollInterval'));
      expect(provider, contains('_refreshPaymentOrdersFromRealtime(storeId)'));
      expect(
        provider,
        contains('status == RealtimeSubscribeStatus.subscribed'),
      );

      expect(cashier, contains('forceScrollableCompact'));
      expect(cashier, contains('viewport.height < 720'));
      expect(
        cashier,
        contains('constraints.maxWidth >= 1180 && !forceScrollableCompact'),
      );
      expect(
        cashier,
        contains(
          'minHeight:\n                  MediaQuery.sizeOf(context).width >',
        ),
      );
      expect(cashier, contains('? 820'));
      expect(
        cashier,
        contains(
          'keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag',
        ),
      );
      expect(cashier, contains("'serving' => l10n.cashierPendingStatus"));

      expect(
        readyHandoffMigration,
        contains('CREATE OR REPLACE FUNCTION public.update_order_item_status'),
      );
      expect(
        readyHandoffMigration,
        contains("v_next_order_status := 'serving'"),
      );
      expect(
        readyHandoffMigration,
        contains("AND oi.status NOT IN ('ready', 'served')"),
      );
      expect(readyHandoffMigration, contains('UPDATE orders o'));
    },
  );

  test(
    'waiter screen routes guest, table transfer, and dining floor copy through localization',
    () {
      final waiter = readRepoFile('lib/features/waiter/waiter_screen.dart');

      expect(waiter, contains('context.l10n'));
      expect(waiter, contains('l10n.waiterGuestCountTitle'));
      expect(waiter, contains('l10n.waiterGuestCountField'));
      expect(waiter, contains('l10n.waiterCancelOrderTitle'));
      expect(waiter, contains('l10n.waiterMoveTableTitle'));
      expect(waiter, contains('l10n.waiterOrderCancelled'));
      expect(waiter, contains('l10n.waiterDiningFloor'));
      expect(waiter, contains('l10n.waiterTapTableToStart'));
    },
  );

  test(
    'order workspace routes menu, sent, payment, and ticket copy through localization',
    () {
      final workspace = readRepoFile('lib/widgets/order_workspace.dart');

      expect(workspace, contains('context.l10n'));
      expect(workspace, contains('l10n.orderWorkspaceMenus'));
      expect(workspace, contains('l10n.orderWorkspaceMenuOfflineTitle'));
      expect(workspace, contains('l10n.orderWorkspaceSentToKitchen'));
      expect(workspace, contains('l10n.orderWorkspaceNewItems'));
      expect(workspace, contains('l10n.orderWorkspaceSendToKitchen'));
      expect(workspace, contains('l10n.orderWorkspacePay'));
      expect(workspace, contains('l10n.orderWorkspacePaymentDue'));
      expect(workspace, contains('l10n.orderWorkspaceCurrentCheck'));
      expect(workspace, contains('l10n.orderWorkspaceKitchenTicketSent'));
    },
  );

  test('order workspace keeps sent kitchen items visible by default', () {
    final workspace = readRepoFile('lib/widgets/order_workspace.dart');

    expect(workspace, contains('order_sent_items_always_visible_detail'));
    expect(workspace, contains('initiallyExpanded: true'));
    expect(workspace, contains('l10n.orderWorkspaceSentToKitchen'));
  });

  test(
    'order workspace keeps kitchen send action visible before payment total',
    () {
      final workspace = readRepoFile('lib/widgets/order_workspace.dart');
      final actionIndex = workspace.indexOf('final orderSubmissionActions');
      final placementIndex = workspace.indexOf('orderSubmissionActions,');
      final paymentIndex = workspace.indexOf('l10n.orderWorkspacePaymentDue');

      expect(actionIndex, isNonNegative);
      expect(placementIndex, isNonNegative);
      expect(paymentIndex, isNonNegative);
      expect(placementIndex, lessThan(paymentIndex));
      expect(
        workspace,
        contains('final orderSubmissionActions = _OrderSendFooter('),
      );
      expect(
        workspace,
        contains("key: const Key('cart_submit_order_sticky_footer')"),
      );
      expect(workspace, contains("key: const Key('cart_submit_order')"));
      expect(workspace, contains('PosActionTile('));
      expect(workspace, contains('PosActionTileState.processing'));
      expect(workspace, contains('PosActionTileState.offlineBlocked'));
      expect(workspace, contains('allowOfflineBlockedTap: canSendOrder'));
      expect(workspace, contains('unawaited(onSendOrder())'));
      expect(workspace, contains('l10n.orderWorkspaceTapItemToAdd'));
      expect(
        workspace,
        isNot(contains("key: const Key('cart_submit_order_header')")),
      );
    },
  );

  test(
    'order workspace accumulates selected menu items before kitchen send',
    () {
      final workspace = readRepoFile('lib/widgets/order_workspace.dart');
      final menuCardIndex = workspace.indexOf(
        "Key('menu_first_item_add_card')",
      );
      final selectedListIndex = workspace.indexOf('_SelectedMenuList(');
      final reviewIndex = workspace.indexOf("Key('pending_order_review')");
      final sendIndex = workspace.indexOf('final orderSubmissionActions');

      expect(menuCardIndex, isNonNegative);
      expect(selectedListIndex, isNonNegative);
      expect(reviewIndex, isNonNegative);
      expect(sendIndex, isNonNegative);
      expect(workspace, contains('onTap: addItem'));
      expect(workspace, contains('GestureDetector('));
      expect(workspace, contains('behavior: HitTestBehavior.opaque'));
      expect(workspace, contains("Key('menu_first_item')"));
      expect(workspace, contains('_SelectedMenuList('));
      expect(workspace, contains('if (cart.isNotEmpty)'));
      expect(workspace, contains("key: const Key('menu_item_grid')"));
      expect(workspace, contains('height: 96'));
      expect(workspace, contains('width: 168'));
      expect(workspace, contains('ListView.separated('));
      expect(workspace, isNot(contains('bottom: cart.isEmpty ? 0 : 76')));
      expect(workspace, contains("pending_cart_item_\${item.menuItemId}"));
      expect(workspace, contains("Key('pending_order_review')"));
      expect(
        workspace,
        contains("pending_order_review_item_\${item.menuItemId}"),
      );
      expect(workspace, contains('_PendingOrderReview('));
      expect(selectedListIndex, lessThan(menuCardIndex));
      expect(reviewIndex, lessThan(sendIndex));
    },
  );

  test('order workspace gives menu selection the primary ordering surface', () {
    final workspace = readRepoFile('lib/widgets/order_workspace.dart');
    final waiter = readRepoFile('lib/features/waiter/waiter_screen.dart');

    expect(workspace, contains('constraints.maxWidth >= 760'));
    expect(workspace, contains("Key('order_terminal_table_strip')"));
    expect(workspace, contains('final orderRailWidth'));
    expect(workspace, contains('PosDensity.orderRailWidth'));
    expect(workspace, contains('SizedBox(width: orderRailWidth'));
    expect(workspace, contains('flex: 8'));
    expect(workspace, contains('flex: 2'));
    expect(workspace, contains('useCompactPanel'));
    expect(workspace, contains('class _CompactCurrentOrderPanel'));
    expect(waiter, contains("Key('waiter_order_compact_header')"));
    expect(waiter, contains('showOrderWorkspace ? 9 : 7'));
    expect(waiter, contains('showOrderWorkspace ? 3 : 4'));
  });

  test('compact order panel exposes the same order success smoke hooks', () {
    final workspace = readRepoFile('lib/widgets/order_workspace.dart');
    final compactPanelIndex = workspace.indexOf(
      'class _CompactCurrentOrderPanel',
    );

    expect(workspace, contains('class _OrderCreateSuccessBanner'));
    expect(
      workspace,
      contains("key: const Key('order_create_success_banner')"),
    );
    expect(workspace, contains("key: const Key('latest_order_number_text')"));
    expect(workspace, contains("key: const Key('latest_order_id_full_text')"));
    expect(workspace, contains('maxLines: 1'));
    expect(workspace, contains('overflow: TextOverflow.ellipsis'));
    expect(compactPanelIndex, isNonNegative);
    expect(
      workspace.indexOf('order: state.activeOrder!', compactPanelIndex),
      isNonNegative,
    );
  });

  test('operational premium v2 gate records web tabular-number evidence', () {
    final gate = readRepoFile(
      'docs/pos/POS_OPERATIONAL_PREMIUM_V2_PHASE_GATE_2026_06_11.md',
    );
    final followUps = readRepoFile(
      'docs/pos/POS_OPERATIONAL_PREMIUM_V2_DATA_FOLLOWUPS.md',
    );

    expect(gate, contains('flutter test --platform chrome'));
    expect(gate, contains('FontFeature.tabularFigures'));
    expect(gate, contains('Admin Tables Phase 1'));
    expect(gate, contains('Inventory Phase 1'));
    expect(followUps, contains('Last completed payment'));
    expect(followUps, contains('Per-table revenue'));
    expect(followUps, contains('Explanation for zero recommendations'));
    expect(followUps, contains('frontend-only'));
  });
}
