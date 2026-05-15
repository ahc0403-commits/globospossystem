import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/i18n/locale_extensions.dart';
import '../core/services/connectivity_service.dart';
import '../core/ui/app_primitives.dart';
import '../core/ui/pos_design_tokens.dart';
import '../core/ui/toast/toast.dart';
import '../features/admin/providers/menu_provider.dart';
import '../features/order/order_model.dart';
import '../features/order/order_provider.dart';
import '../features/table/table_model.dart';
import '../main.dart';

enum _OrderPanelOverflowAction { moveTable, cancelOrder }

class OrderWorkspace extends StatelessWidget {
  const OrderWorkspace({
    super.key,
    required this.table,
    required this.guestCount,
    required this.menuState,
    required this.menuNotifier,
    required this.orderState,
    required this.allowSubmitWithoutCart,
    required this.onAddToCart,
    required this.onIncrementCartItem,
    required this.onDecrementCartItem,
    required this.onCancel,
    required this.onCancelOrder,
    required this.onSendOrder,
    this.canManageSentItems = false,
    this.onCycleSentItemStatus,
    this.showPaymentActions = false,
    this.onProcessPayment,
    this.isProcessingPayment = false,
    this.onCancelOrderItem,
    this.onEditOrderItemQuantity,
    this.onTransferTable,
  });

  final PosTable table;
  final int? guestCount;
  final MenuState menuState;
  final MenuNotifier? menuNotifier;
  final OrderState orderState;
  final bool allowSubmitWithoutCart;
  final ValueChanged<CartItem> onAddToCart;
  final ValueChanged<CartItem> onIncrementCartItem;
  final ValueChanged<String> onDecrementCartItem;
  final VoidCallback onCancel;
  final Future<void> Function() onCancelOrder;
  final Future<void> Function() onSendOrder;
  final bool canManageSentItems;
  final Future<void> Function(OrderItem item, String nextStatus)?
  onCycleSentItemStatus;
  final bool showPaymentActions;
  final Future<void> Function(String method)? onProcessPayment;
  final bool isProcessingPayment;
  final Future<void> Function(String itemId)? onCancelOrderItem;
  final Future<void> Function(String itemId, int newQuantity)?
  onEditOrderItemQuantity;
  final VoidCallback? onTransferTable;

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = menuState.categories;
    final itemsAsync = menuState.items;
    final menuLoading = categoriesAsync.isLoading || itemsAsync.isLoading;
    final menuError = categoriesAsync.hasError || itemsAsync.hasError;

    final categories =
        categoriesAsync.valueOrNull ?? const <Map<String, dynamic>>[];
    final items = itemsAsync.valueOrNull ?? const <Map<String, dynamic>>[];
    final selectedCategoryId = menuState.selectedCategoryId;

    final filteredItems = selectedCategoryId == null
        ? const <Map<String, dynamic>>[]
        : items.where((item) {
            final matchesCategory =
                item['category_id']?.toString() == selectedCategoryId;
            final isAvailable = item['is_available'];
            if (isAvailable is bool) {
              return matchesCategory && isAvailable;
            }
            return matchesCategory;
          }).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 1100;
        if (isWide) {
          return Row(
            children: [
              Expanded(
                flex: 6,
                child: _MenuBrowser(
                  menuLoading: menuLoading,
                  menuError: menuError,
                  categories: categories,
                  selectedCategoryId: selectedCategoryId,
                  filteredItems: filteredItems,
                  onSelectCategory: (categoryId) =>
                      menuNotifier?.selectCategory(categoryId),
                  onAddItem: onAddToCart,
                ),
              ),
              Expanded(
                flex: 4,
                child: _CurrentOrderPanel(
                  table: table,
                  guestCount: guestCount,
                  state: orderState,
                  allowSubmitWithoutCart: allowSubmitWithoutCart,
                  onIncrementCartItem: onIncrementCartItem,
                  onDecrementCartItem: onDecrementCartItem,
                  onCancel: onCancel,
                  onCancelOrder: onCancelOrder,
                  onSendOrder: onSendOrder,
                  canManageSentItems: canManageSentItems,
                  onCycleSentItemStatus: onCycleSentItemStatus,
                  showPaymentActions: showPaymentActions,
                  onProcessPayment: onProcessPayment,
                  isProcessingPayment: isProcessingPayment,
                  onCancelOrderItem: onCancelOrderItem,
                  onEditOrderItemQuantity: onEditOrderItemQuantity,
                  onTransferTable: onTransferTable,
                ),
              ),
            ],
          );
        }

        return Column(
          children: [
            Expanded(
              flex: 5,
              child: _MenuBrowser(
                menuLoading: menuLoading,
                menuError: menuError,
                categories: categories,
                selectedCategoryId: selectedCategoryId,
                filteredItems: filteredItems,
                onSelectCategory: (categoryId) =>
                    menuNotifier?.selectCategory(categoryId),
                onAddItem: onAddToCart,
              ),
            ),
            Expanded(
              flex: 4,
              child: _CurrentOrderPanel(
                table: table,
                guestCount: guestCount,
                state: orderState,
                allowSubmitWithoutCart: allowSubmitWithoutCart,
                onIncrementCartItem: onIncrementCartItem,
                onDecrementCartItem: onDecrementCartItem,
                onCancel: onCancel,
                onCancelOrder: onCancelOrder,
                onSendOrder: onSendOrder,
                canManageSentItems: canManageSentItems,
                onCycleSentItemStatus: onCycleSentItemStatus,
                showPaymentActions: showPaymentActions,
                onProcessPayment: onProcessPayment,
                isProcessingPayment: isProcessingPayment,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MenuBrowser extends StatelessWidget {
  const _MenuBrowser({
    required this.menuLoading,
    required this.menuError,
    required this.categories,
    required this.selectedCategoryId,
    required this.filteredItems,
    required this.onSelectCategory,
    required this.onAddItem,
  });

  final bool menuLoading;
  final bool menuError;
  final List<Map<String, dynamic>> categories;
  final String? selectedCategoryId;
  final List<Map<String, dynamic>> filteredItems;
  final ValueChanged<String> onSelectCategory;
  final ValueChanged<CartItem> onAddItem;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final currency = NumberFormat('#,###', 'vi_VN');

    if (menuLoading) {
      return const ToastOperationalLoadingState(
        label: PosLoadingCopy.loadingMenu,
      );
    }

    if (menuError) {
      return AppErrorState(
        title: l10n.orderWorkspaceMenuOfflineTitle,
        message: l10n.orderWorkspaceMenuOfflineMessage,
      );
    }

    return ToastWorkSurface(
      key: const Key('menu_root'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSectionHeader(
            title: l10n.orderWorkspaceMenus,
            subtitle: l10n.orderWorkspaceTapItemToAdd,
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 42,
            child: categories.isEmpty
                ? const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      PosEmptyStateCopy.menuNoCategories,
                      style: TextStyle(
                        color: PosColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: categories.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final category = categories[index];
                      final categoryId = category['id']?.toString() ?? '';
                      final selected = selectedCategoryId == categoryId;

                      return ToastFilterChip(
                        label: category['name']?.toString() ?? '-',
                        selected: selected,
                        onSelected: categoryId.isEmpty
                            ? () {}
                            : () => onSelectCategory(categoryId),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: filteredItems.isEmpty
                ? const ToastOperationalEmptyState(
                    headline: PosEmptyStateCopy.menuCategoryEmpty,
                    helper: 'Switch categories or add menu entries in admin.',
                    icon: Icons.inventory_2_outlined,
                  )
                : GridView.builder(
                    itemCount: filteredItems.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 1.9,
                        ),
                    itemBuilder: (context, index) {
                      final item = filteredItems[index];
                      final menuItemId = item['id']?.toString() ?? '';
                      final name = item['name']?.toString() ?? '-';
                      final rawPrice = item['price'];
                      final price = switch (rawPrice) {
                        num value => value.toDouble(),
                        String value => double.tryParse(value) ?? 0,
                        _ => 0.0,
                      };

                      return Container(
                        key: index == 0 ? const Key('menu_first_item') : null,
                        decoration: BoxDecoration(
                          color: PosColors.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: PosColors.panelMuted),
                        ),
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '₫${currency.format(price)}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          color: PosColors.accent,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: -0.2,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            InkWell(
                              onTap: menuItemId.isEmpty
                                  ? null
                                  : () => onAddItem(
                                      CartItem(
                                        menuItemId: menuItemId,
                                        name: name,
                                        price: price,
                                        quantity: 1,
                                      ),
                                    ),
                              borderRadius: BorderRadius.circular(20),
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: const BoxDecoration(
                                  color: PosColors.accent,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.add,
                                  size: 22,
                                  color: PosColors.canvas,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _CurrentOrderPanel extends ConsumerStatefulWidget {
  const _CurrentOrderPanel({
    required this.table,
    required this.guestCount,
    required this.state,
    required this.allowSubmitWithoutCart,
    required this.onIncrementCartItem,
    required this.onDecrementCartItem,
    required this.onCancel,
    required this.onCancelOrder,
    required this.onSendOrder,
    required this.canManageSentItems,
    required this.onCycleSentItemStatus,
    required this.showPaymentActions,
    required this.onProcessPayment,
    required this.isProcessingPayment,
    this.onCancelOrderItem,
    this.onEditOrderItemQuantity,
    this.onTransferTable,
  });

  final PosTable table;
  final int? guestCount;
  final OrderState state;
  final bool allowSubmitWithoutCart;
  final ValueChanged<CartItem> onIncrementCartItem;
  final ValueChanged<String> onDecrementCartItem;
  final VoidCallback onCancel;
  final Future<void> Function() onCancelOrder;
  final Future<void> Function() onSendOrder;
  final bool canManageSentItems;
  final Future<void> Function(OrderItem item, String nextStatus)?
  onCycleSentItemStatus;
  final bool showPaymentActions;
  final Future<void> Function(String method)? onProcessPayment;
  final bool isProcessingPayment;
  final Future<void> Function(String itemId)? onCancelOrderItem;
  final Future<void> Function(String itemId, int newQuantity)?
  onEditOrderItemQuantity;
  final VoidCallback? onTransferTable;

  @override
  ConsumerState<_CurrentOrderPanel> createState() => _CurrentOrderPanelState();
}

class _CurrentOrderPanelState extends ConsumerState<_CurrentOrderPanel> {
  String? _selectedPaymentMethod;

  String _cycleStatus(String status) {
    return switch (status) {
      'pending' => 'preparing',
      'preparing' => 'ready',
      'ready' => 'served',
      _ => 'pending',
    };
  }

  Future<void> _showEditQuantityDialog(OrderItem item) async {
    final controller = TextEditingController(text: '${item.quantity}');
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: PosColors.surface,
        title: Text(
          'Change Quantity',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.label ?? 'Item',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PosColors.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              style: Theme.of(context).textTheme.bodyMedium,
              decoration: const InputDecoration(labelText: 'New quantity'),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: PosColors.accent,
              foregroundColor: PosColors.canvas,
            ),
            onPressed: () {
              final qty = int.tryParse(controller.text.trim());
              if (qty == null || qty < 1) return;
              Navigator.of(context).pop(qty);
            },
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null && result != item.quantity) {
      await widget.onEditOrderItemQuantity!(item.id, result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isOnline = ref.watch(connectivityProvider).asData?.value ?? true;
    final formatter = NumberFormat('#,###', 'vi_VN');
    final total = widget.state.cart.fold<double>(
      0,
      (sum, item) => sum + (item.price * item.quantity),
    );
    final activeTotal = (widget.state.activeOrder?.items ?? const <OrderItem>[])
        .where((item) => item.status != 'cancelled')
        .fold<double>(0, (sum, item) => sum + (item.unitPrice * item.quantity));
    final activeStatus = widget.state.activeOrder?.status.toLowerCase();
    final canCancelOrder =
        widget.state.activeOrder != null &&
        activeStatus != 'completed' &&
        activeStatus != 'cancelled';
    final canProcessPayment =
        widget.showPaymentActions &&
        widget.state.activeOrder != null &&
        activeStatus != 'completed' &&
        activeStatus != 'cancelled' &&
        widget.state.cart.isEmpty;
    final subtitleParts = <String>[
      if (widget.guestCount != null)
        l10n.orderWorkspaceGuestCount(widget.guestCount!),
      '${widget.table.seatCount ?? 0} seats',
      if (widget.state.activeOrder != null) l10n.orderWorkspaceCurrentCheck,
    ];

    return ToastWorkSurface(
      key: const Key('orders_root'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ToastSelectedContextHeader(
            title: 'Table ${widget.table.tableNumber}',
            subtitle: subtitleParts.join(' • '),
            trailing: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (widget.state.activeOrder != null)
                  ToastStatusBadge(
                    label: l10n.orderWorkspaceCurrentCheck,
                    color: PosColors.info,
                    compact: true,
                  ),
                if (widget.guestCount != null &&
                    widget.state.activeOrder == null)
                  ToastStatusBadge(
                    label: l10n.orderWorkspaceGuestCount(widget.guestCount!),
                    color: PosColors.warning,
                    compact: true,
                  ),
                if (widget.onTransferTable != null || canCancelOrder)
                  PopupMenuButton<_OrderPanelOverflowAction>(
                    tooltip: 'More actions',
                    enabled: !widget.state.isSubmitting,
                    onSelected: (action) async {
                      switch (action) {
                        case _OrderPanelOverflowAction.moveTable:
                          widget.onTransferTable?.call();
                          break;
                        case _OrderPanelOverflowAction.cancelOrder:
                          await widget.onCancelOrder();
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      if (widget.onTransferTable != null)
                        PopupMenuItem(
                          value: _OrderPanelOverflowAction.moveTable,
                          child: Row(
                            children: [
                              const Icon(Icons.swap_horiz, size: 18),
                              const SizedBox(width: 8),
                              Text(l10n.orderWorkspaceMove),
                            ],
                          ),
                        ),
                      if (canCancelOrder)
                        PopupMenuItem(
                          value: _OrderPanelOverflowAction.cancelOrder,
                          child: Row(
                            children: [
                              const Icon(
                                Icons.cancel_outlined,
                                size: 18,
                                color: PosColors.danger,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                PosActionVerbs.cancelOrder,
                                style: const TextStyle(color: PosColors.danger),
                              ),
                            ],
                          ),
                        ),
                    ],
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: PosColors.panelMuted,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: PosColors.border),
                      ),
                      child: const Icon(
                        Icons.more_horiz,
                        size: 18,
                        color: PosColors.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (widget.state.activeOrder != null &&
              !widget.state.isSubmitting) ...[
            const SizedBox(height: 6),
            Container(
              key: const Key('order_create_success_banner'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: PosColors.success.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.check_circle_outline,
                    color: PosColors.success,
                    size: 12,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    key: const Key('latest_order_number_text'),
                    '${l10n.orderWorkspaceKitchenTicketSent} · ${widget.state.activeOrder!.id.length >= 8 ? widget.state.activeOrder!.id.substring(0, 8) : widget.state.activeOrder!.id}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: PosColors.success,
                      fontSize: 11,
                    ),
                  ),
                  Offstage(
                    offstage: true,
                    child: Text(
                      key: const Key('latest_order_id_full_text'),
                      widget.state.activeOrder!.id,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Expanded(
            child: ListView(
              children: [
                if (widget.state.activeOrder != null &&
                    widget.state.activeOrder!.items.isNotEmpty) ...[
                  Theme(
                    data: Theme.of(
                      context,
                    ).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      key: const Key('order_sent_items_secondary_detail'),
                      initiallyExpanded: false,
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      title: Text(
                        l10n.orderWorkspaceSentToKitchen,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: PosColors.textSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      children: [
                        ...widget.state.activeOrder!.items.map((item) {
                          final label = item.label ?? 'Item';
                          final isCancelled = item.status == 'cancelled';
                          final canCancel =
                              !isCancelled &&
                              item.status != 'ready' &&
                              item.status != 'served' &&
                              widget.onCancelOrderItem != null;
                          final canEditQty =
                              item.status == 'pending' &&
                              widget.onEditOrderItemQuantity != null;
                          return Opacity(
                            opacity: isCancelled ? 0.45 : 1.0,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: isCancelled
                                    ? PosColors.panelMuted.withValues(
                                        alpha: 0.5,
                                      )
                                    : PosColors.panelMuted,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            '$label x${item.quantity}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.copyWith(
                                                  color: isCancelled
                                                      ? PosColors.danger
                                                      : PosColors.textSecondary,
                                                  fontSize: 13,
                                                  decoration: isCancelled
                                                      ? TextDecoration
                                                            .lineThrough
                                                      : null,
                                                ),
                                          ),
                                        ),
                                        if (canEditQty) ...[
                                          const SizedBox(width: 4),
                                          InkWell(
                                            onTap: widget.state.isSubmitting
                                                ? null
                                                : () => _showEditQuantityDialog(
                                                    item,
                                                  ),
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            child: const Padding(
                                              padding: EdgeInsets.all(2),
                                              child: Icon(
                                                Icons.edit,
                                                size: 14,
                                                color: PosColors.textSecondary,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  if (canCancel)
                                    InkWell(
                                      onTap: widget.state.isSubmitting
                                          ? null
                                          : () => widget.onCancelOrderItem!(
                                              item.id,
                                            ),
                                      borderRadius: BorderRadius.circular(10),
                                      child: const Padding(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 2,
                                        ),
                                        child: Icon(
                                          Icons.close,
                                          size: 16,
                                          color: PosColors.danger,
                                        ),
                                      ),
                                    ),
                                  const SizedBox(width: 4),
                                  InkWell(
                                    onTap:
                                        !widget.canManageSentItems ||
                                            widget.onCycleSentItemStatus ==
                                                null ||
                                            isCancelled
                                        ? null
                                        : () => widget.onCycleSentItemStatus!(
                                            item,
                                            _cycleStatus(item.status),
                                          ),
                                    borderRadius: BorderRadius.circular(10),
                                    child: _OrderItemStatusChip(
                                      status: item.status,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                Text(
                  l10n.orderWorkspaceNewItems,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                if (widget.state.cart.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: PosColors.panelMuted,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      PosEmptyStateCopy.cartEmpty,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: PosColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ...widget.state.cart.map((item) {
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: PosColors.canvas,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: PosColors.panelMuted),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.name,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '₫${formatter.format(item.price)}',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      color: PosColors.accent,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.2,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        Row(
                          children: [
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              onPressed: () =>
                                  widget.onDecrementCartItem(item.menuItemId),
                              icon: const Icon(Icons.remove_circle_outline),
                              color: PosColors.textSecondary,
                            ),
                            Text(
                              '${item.quantity}',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              onPressed: () => widget.onIncrementCartItem(item),
                              icon: const Icon(Icons.add_circle_outline),
                              color: PosColors.accent,
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                l10n.orderWorkspacePaymentDue,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: PosColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                '₫${formatter.format(total)}',
                style: AppTextStyles.operationalTitle(
                  size: 28,
                  color: PosColors.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ToastPrimaryActionZone(
            actions: [
              PosActionButton(
                label: PosActionVerbs.cancel,
                tone: PosActionTone.secondary,
                icon: PosActionIcons.cancel,
                onPressed: widget.onCancel,
              ),
              PosActionButton(
                key: const Key('cart_submit_order'),
                label: l10n.orderWorkspaceSendToKitchen,
                tone: PosActionTone.primary,
                icon: PosActionIcons.sendOrder,
                onPressed:
                    widget.state.isSubmitting ||
                        (!widget.allowSubmitWithoutCart &&
                            widget.state.cart.isEmpty)
                    ? null
                    : widget.onSendOrder,
                disabledReason:
                    !widget.allowSubmitWithoutCart && widget.state.cart.isEmpty
                    ? PosActionDisabledReason.cartEmpty
                    : null,
              ),
            ],
            supporting: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (!isOnline)
                  Text(
                    'Offline orders are queued locally and sync with the same mutation key after connection recovery.',
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.warning,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                if (widget.state.offlineQueueCount > 0 ||
                    widget.state.isSyncingOfflineQueue)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      widget.state.isSyncingOfflineQueue
                          ? 'Syncing queued orders...'
                          : '${widget.state.offlineQueueCount} queued order operation(s) waiting for sync.',
                      textAlign: TextAlign.right,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PosColors.accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (widget.state.isSubmitting)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: ToastOperationalLoadingState(
                label: PosLoadingCopy.syncing,
              ),
            ),
          if (canProcessPayment) ...[
            const SizedBox(height: 12),
            Text(
              '${l10n.orderWorkspacePaymentDue} (₫${formatter.format(activeTotal)})',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PosColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children:
                  [
                    _PaymentMethodTag(
                      method: 'CASH',
                      label: l10n.orderWorkspaceCash,
                    ),
                    _PaymentMethodTag(
                      method: 'CREDITCARD',
                      label: l10n.orderWorkspaceCard,
                    ),
                    _PaymentMethodTag(
                      method: 'OTHER',
                      label: l10n.orderWorkspaceEPay,
                    ),
                  ].map((tag) {
                    final selected = _selectedPaymentMethod == tag.method;
                    return ToastFilterChip(
                      label: tag.label,
                      selected: selected,
                      onSelected: () {
                        setState(() => _selectedPaymentMethod = tag.method);
                      },
                    );
                  }).toList(),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: PosActionButton(
                label: l10n.orderWorkspacePay,
                tone: PosActionTone.primary,
                icon: PosActionIcons.paymentComplete,
                onPressed:
                    widget.isProcessingPayment ||
                        _selectedPaymentMethod == null ||
                        widget.onProcessPayment == null
                    ? null
                    : () => widget.onProcessPayment!(_selectedPaymentMethod!),
                disabledReason: _selectedPaymentMethod == null
                    ? PosActionDisabledReason.paymentMethodNotSelected
                    : null,
              ),
            ),
            if (widget.isProcessingPayment)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: ToastOperationalLoadingState(
                  label: PosLoadingCopy.syncing,
                ),
              ),
          ],
          if (widget.showPaymentActions && widget.state.cart.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l10n.orderWorkspaceSendBeforePayment,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: PosColors.warning,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PaymentMethodTag {
  const _PaymentMethodTag({required this.method, required this.label});

  final String method;
  final String label;
}

class _OrderItemStatusChip extends StatelessWidget {
  const _OrderItemStatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final normalized = status.toLowerCase();
    final (color, label) = switch (normalized) {
      'pending' => (PosColors.textSecondary, 'PENDING'),
      'preparing' => (PosColors.accent, 'PREPARING'),
      'ready' => (PosColors.success, 'READY'),
      'served' => (PosColors.warning, 'SERVED'),
      'cancelled' => (PosColors.danger, 'CANCELLED'),
      _ => (PosColors.textSecondary, normalized.toUpperCase()),
    };
    return ToastStatusChip(label: label, color: color);
  }
}
