import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/i18n/locale_extensions.dart';
import '../core/services/connectivity_service.dart';
import '../core/ui/app_primitives.dart';
import '../core/ui/pos_design_tokens.dart';
import '../core/ui/toast/toast.dart';
import '../core/utils/number_input_utils.dart';
import '../features/admin/providers/menu_provider.dart';
import '../features/order/order_model.dart';
import '../features/order/order_provider.dart';
import '../features/table/table_model.dart';
import 'error_toast.dart';

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
    this.canCreateSales = true,
    this.canCompletePayment = true,
    this.cutoffMessage,
    this.onCancelOrderItem,
    this.onEditOrderItemQuantity,
    this.onTransferTable,
    this.onChangeGuestCount,
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
  final bool canCreateSales;
  final bool canCompletePayment;
  final String? cutoffMessage;
  final Future<void> Function(String itemId)? onCancelOrderItem;
  final Future<void> Function(String itemId, int newQuantity)?
  onEditOrderItemQuantity;
  final VoidCallback? onTransferTable;
  final Future<void> Function()? onChangeGuestCount;

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
        final isWide = constraints.maxWidth >= 760;
        final orderPanel = _CurrentOrderPanel(
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
          canCreateSales: canCreateSales,
          canCompletePayment: canCompletePayment,
          cutoffMessage: cutoffMessage,
          onCancelOrderItem: onCancelOrderItem,
          onEditOrderItemQuantity: onEditOrderItemQuantity,
          onTransferTable: onTransferTable,
          onChangeGuestCount: onChangeGuestCount,
        );

        if (isWide) {
          final orderRailWidth = constraints.maxWidth >= 1180
              ? 376.0
              : PosDensity.orderRailWidth;
          return Column(
            children: [
              _OrderTerminalTableStrip(
                table: table,
                guestCount: guestCount,
                state: orderState,
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: _MenuBrowser(
                        menuLoading: menuLoading,
                        menuError: menuError,
                        categories: categories,
                        selectedCategoryId: selectedCategoryId,
                        filteredItems: filteredItems,
                        cart: orderState.cart,
                        onSelectCategory: (categoryId) =>
                            menuNotifier?.selectCategory(categoryId),
                        onAddItem: canCreateSales ? onAddToCart : (_) {},
                        onIncrementCartItem: canCreateSales
                            ? onIncrementCartItem
                            : (_) {},
                        onDecrementCartItem: onDecrementCartItem,
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(width: orderRailWidth, child: orderPanel),
                  ],
                ),
              ),
            ],
          );
        }

        return Column(
          children: [
            _OrderTerminalTableStrip(
              table: table,
              guestCount: guestCount,
              state: orderState,
              compact: true,
            ),
            const SizedBox(height: 8),
            Expanded(
              flex: 8,
              child: _MenuBrowser(
                menuLoading: menuLoading,
                menuError: menuError,
                categories: categories,
                selectedCategoryId: selectedCategoryId,
                filteredItems: filteredItems,
                cart: orderState.cart,
                onSelectCategory: (categoryId) =>
                    menuNotifier?.selectCategory(categoryId),
                onAddItem: canCreateSales ? onAddToCart : (_) {},
                onIncrementCartItem: canCreateSales
                    ? onIncrementCartItem
                    : (_) {},
                onDecrementCartItem: onDecrementCartItem,
              ),
            ),
            Expanded(flex: 2, child: orderPanel),
          ],
        );
      },
    );
  }
}

class _OrderTerminalTableStrip extends StatelessWidget {
  const _OrderTerminalTableStrip({
    required this.table,
    required this.guestCount,
    required this.state,
    this.compact = false,
  });

  final PosTable table;
  final int? guestCount;
  final OrderState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final pendingCount = state.cart.fold<int>(
      0,
      (sum, item) => sum + item.quantity,
    );
    final sentCount = (state.activeOrder?.items ?? const <OrderItem>[])
        .where((item) => item.status != 'cancelled')
        .fold<int>(0, (sum, item) => sum + item.quantity);
    final statusColor = state.activeOrder == null
        ? PosColors.success
        : pendingCount > 0
        ? PosColors.warning
        : PosColors.info;
    final statusLabel = state.activeOrder == null
        ? l10n.waiterStatusAvailable
        : pendingCount > 0
        ? l10n.orderWorkspaceNewItems
        : l10n.orderWorkspaceCurrentCheck;

    return ToastWorkSurface(
      key: const Key('order_terminal_table_strip'),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 14,
        vertical: compact ? 8 : 10,
      ),
      backgroundColor: PosTerminalColors.lightPanel,
      child: Row(
        children: [
          Container(
            width: compact ? 36 : 42,
            height: compact ? 36 : 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: statusColor.withValues(alpha: 0.42)),
            ),
            child: Icon(
              Icons.table_restaurant_outlined,
              size: compact ? 18 : 20,
              color: statusColor,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  l10n.waiterTableLabel(table.tableNumber),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PosNumericText.tableId.copyWith(
                    color: PosColors.textPrimary,
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(height: 2),
                  Text(
                    [
                      l10n.waiterSeatCount(table.seatCount ?? 0),
                      if (guestCount != null)
                        l10n.orderWorkspaceGuestCount(guestCount!),
                      l10n.orderWorkspaceItemsCount(pendingCount + sentCount),
                    ].join(' • '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          ToastStatusBadge(
            label: statusLabel,
            color: statusColor,
            compact: true,
          ),
        ],
      ),
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
    required this.cart,
    required this.onSelectCategory,
    required this.onAddItem,
    required this.onIncrementCartItem,
    required this.onDecrementCartItem,
  });

  final bool menuLoading;
  final bool menuError;
  final List<Map<String, dynamic>> categories;
  final String? selectedCategoryId;
  final List<Map<String, dynamic>> filteredItems;
  final List<CartItem> cart;
  final ValueChanged<String> onSelectCategory;
  final ValueChanged<CartItem> onAddItem;
  final ValueChanged<CartItem> onIncrementCartItem;
  final ValueChanged<String> onDecrementCartItem;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final currency = NumberFormat('#,###', 'vi_VN');

    if (menuLoading) {
      return ToastOperationalLoadingState(
        label: l10n.orderWorkspaceLoadingMenu,
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
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                l10n.orderWorkspaceMenus,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.orderWorkspaceTapItemToAdd,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 38,
            child: categories.isEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      l10n.menuNoCategories,
                      style: const TextStyle(
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
                        label: _localizedMenuDataLabel(
                          context,
                          category['name'],
                        ),
                        selected: selected,
                        onSelected: categoryId.isEmpty
                            ? () {}
                            : () => onSelectCategory(categoryId),
                      );
                    },
                  ),
          ),
          if (cart.isNotEmpty) ...[
            const SizedBox(height: 8),
            _SelectedMenuList(
              cart: cart,
              formatter: currency,
              onIncrementCartItem: onIncrementCartItem,
              onDecrementCartItem: onDecrementCartItem,
            ),
            const SizedBox(height: 8),
          ] else
            const SizedBox(height: 8),
          Expanded(
            child: filteredItems.isEmpty
                ? ToastOperationalEmptyState(
                    headline: l10n.orderWorkspaceNoItemsTitle,
                    helper: l10n.orderWorkspaceNoItemsMessage,
                    icon: Icons.inventory_2_outlined,
                  )
                : LayoutBuilder(
                    builder: (context, gridConstraints) {
                      final useSingleColumn = gridConstraints.maxWidth < 420;
                      final useThreeColumns = gridConstraints.maxWidth >= 780;
                      final crossAxisCount = useSingleColumn
                          ? 1
                          : useThreeColumns
                          ? 3
                          : 2;
                      return GridView.builder(
                        key: const Key('menu_item_grid'),
                        padding: EdgeInsets.zero,
                        itemCount: filteredItems.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          // Slightly taller cards: the two-line name + price
                          // column overflowed by ~5px at the previous ratios.
                          childAspectRatio: useSingleColumn
                              ? 2.95
                              : useThreeColumns
                              ? 2.05
                              : 2.25,
                        ),
                        itemBuilder: (context, index) {
                          final item = filteredItems[index];
                          final menuItemId = item['id']?.toString() ?? '';
                          final name = item['name']?.toString() ?? '-';
                          final displayName = _localizedMenuDataLabel(
                            context,
                            name,
                          );
                          final rawPrice = item['price'];
                          final price = switch (rawPrice) {
                            num value => value.toDouble(),
                            String value => parseDecimalInput(value) ?? 0,
                            _ => 0.0,
                          };
                          final addItem = menuItemId.isEmpty
                              ? null
                              : () => onAddItem(
                                  CartItem(
                                    menuItemId: menuItemId,
                                    name: name,
                                    price: price,
                                    quantity: 1,
                                  ),
                                );

                          return Semantics(
                            key: index == 0
                                ? const Key('menu_first_item_add_card')
                                : null,
                            button: true,
                            enabled: addItem != null,
                            child: MouseRegion(
                              cursor: addItem == null
                                  ? SystemMouseCursors.basic
                                  : SystemMouseCursors.click,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: addItem,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: PosColors.surface,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: PosColors.panelMuted,
                                    ),
                                  ),
                                  padding: const EdgeInsets.all(12),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Flexible(
                                              child: Text(
                                                displayName,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodyMedium
                                                    ?.copyWith(
                                                      fontSize: 15,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              '₫${currency.format(price)}',
                                              style: PosNumericText.amountLine
                                                  .copyWith(
                                                    color: PosColors.accent,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        width: PosDensity.touchTargetMin,
                                        height: PosDensity.touchTargetMin,
                                        decoration: BoxDecoration(
                                          color: addItem == null
                                              ? PosColors.textMuted
                                              : PosColors.accent,
                                          shape: BoxShape.circle,
                                        ),
                                        child: IconButton(
                                          key: index == 0
                                              ? const Key('menu_first_item')
                                              : ValueKey<String>(
                                                  'menu_item_add_$menuItemId',
                                                ),
                                          padding: EdgeInsets.zero,
                                          visualDensity: VisualDensity.compact,
                                          onPressed: addItem,
                                          icon: const Icon(
                                            Icons.add,
                                            size: 22,
                                            color: PosColors.canvas,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SelectedMenuList extends StatelessWidget {
  const _SelectedMenuList({
    required this.cart,
    required this.formatter,
    required this.onIncrementCartItem,
    required this.onDecrementCartItem,
  });

  final List<CartItem> cart;
  final NumberFormat formatter;
  final ValueChanged<CartItem> onIncrementCartItem;
  final ValueChanged<String> onDecrementCartItem;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final itemCount = cart.fold<int>(0, (sum, item) => sum + item.quantity);

    return SizedBox(
      height: 96,
      child: Container(
        key: const Key('pending_cart_preview'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: PosColors.accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: PosColors.accent.withValues(alpha: 0.24)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 64,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    l10n.orderWorkspaceNewItems,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    '$itemCount',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: PosNumericText.qtyUnit.copyWith(
                      color: PosColors.accent,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: cart.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final item = cart[index];
                  return _SelectedMenuListItem(
                    item: item,
                    formatter: formatter,
                    onIncrementCartItem: onIncrementCartItem,
                    onDecrementCartItem: onDecrementCartItem,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectedMenuListItem extends StatelessWidget {
  const _SelectedMenuListItem({
    required this.item,
    required this.formatter,
    required this.onIncrementCartItem,
    required this.onDecrementCartItem,
  });

  final CartItem item;
  final NumberFormat formatter;
  final ValueChanged<CartItem> onIncrementCartItem;
  final ValueChanged<String> onDecrementCartItem;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey<String>('pending_cart_item_${item.menuItemId}'),
      width: 168,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PosColors.panelMuted),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  '₫${formatter.format(item.price)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PosNumericText.amountCompact.copyWith(
                    color: PosColors.accent,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
            onPressed: () => onDecrementCartItem(item.menuItemId),
            icon: const Icon(Icons.remove_circle_outline, size: 16),
            color: PosColors.textSecondary,
          ),
          Text('${item.quantity}', style: PosNumericText.qtyUnit),
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
            onPressed: () => onIncrementCartItem(item),
            icon: const Icon(Icons.add_circle_outline, size: 16),
            color: PosColors.accent,
          ),
        ],
      ),
    );
  }
}

class _PendingOrderReview extends StatelessWidget {
  const _PendingOrderReview({
    required this.cart,
    required this.formatter,
    required this.onIncrementCartItem,
    required this.onDecrementCartItem,
  });

  final List<CartItem> cart;
  final NumberFormat formatter;
  final ValueChanged<CartItem> onIncrementCartItem;
  final ValueChanged<String> onDecrementCartItem;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final itemCount = cart.fold<int>(0, (sum, item) => sum + item.quantity);
    final total = cart.fold<double>(
      0,
      (sum, item) => sum + (item.price * item.quantity),
    );

    return Container(
      key: const Key('pending_order_review'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PosColors.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PosColors.accent.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.playlist_add_check_circle_outlined,
                color: PosColors.accent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.orderWorkspaceNewItems,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              ToastStatusBadge(
                label: '$itemCount',
                color: PosColors.accent,
                compact: true,
              ),
              const SizedBox(width: 8),
              Text(
                '₫${formatter.format(total)}',
                style: PosNumericText.amountLine.copyWith(
                  color: PosColors.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...cart.map(
            (item) => _PendingOrderReviewLine(
              item: item,
              formatter: formatter,
              onIncrementCartItem: onIncrementCartItem,
              onDecrementCartItem: onDecrementCartItem,
            ),
          ),
        ],
      ),
    );
  }
}

class _PendingOrderReviewLine extends StatelessWidget {
  const _PendingOrderReviewLine({
    required this.item,
    required this.formatter,
    required this.onIncrementCartItem,
    required this.onDecrementCartItem,
  });

  final CartItem item;
  final NumberFormat formatter;
  final ValueChanged<CartItem> onIncrementCartItem;
  final ValueChanged<String> onDecrementCartItem;

  @override
  Widget build(BuildContext context) {
    final subtotal = item.price * item.quantity;

    return Container(
      key: ValueKey<String>('pending_order_review_item_${item.menuItemId}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: PosColors.surface,
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '₫${formatter.format(item.price)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PosNumericText.unitPrice.copyWith(
                    color: PosColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            padding: EdgeInsets.zero,
            onPressed: () => onDecrementCartItem(item.menuItemId),
            icon: const Icon(Icons.remove_circle_outline, size: 18),
            color: PosColors.textSecondary,
          ),
          SizedBox(
            width: 28,
            child: Text(
              '${item.quantity}',
              textAlign: TextAlign.center,
              style: PosNumericText.qtyUnit,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            padding: EdgeInsets.zero,
            onPressed: () => onIncrementCartItem(item),
            icon: const Icon(Icons.add_circle_outline, size: 18),
            color: PosColors.accent,
          ),
          SizedBox(
            width: 74,
            child: Text(
              '₫${formatter.format(subtotal)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: PosNumericText.lineAmount.copyWith(
                color: PosColors.accent,
              ),
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
    required this.canCreateSales,
    required this.canCompletePayment,
    required this.cutoffMessage,
    this.onCancelOrderItem,
    this.onEditOrderItemQuantity,
    this.onTransferTable,
    this.onChangeGuestCount,
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
  final bool canCreateSales;
  final bool canCompletePayment;
  final String? cutoffMessage;
  final Future<void> Function(String itemId)? onCancelOrderItem;
  final Future<void> Function(String itemId, int newQuantity)?
  onEditOrderItemQuantity;
  final VoidCallback? onTransferTable;
  final Future<void> Function()? onChangeGuestCount;

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
    final l10n = context.l10n;
    final controller = TextEditingController(text: '${item.quantity}');
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: PosColors.surface,
        title: Text(
          l10n.orderWorkspaceChangeQuantity,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _localizedMenuDataLabel(
                context,
                item.label ?? l10n.orderWorkspaceItemFallback,
              ),
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
              decoration: InputDecoration(
                labelText: l10n.orderWorkspaceNewQuantity,
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: PosColors.accent,
              foregroundColor: PosColors.canvas,
            ),
            onPressed: () {
              final qty = parseIntInput(controller.text);
              if (qty == null || qty < 1) return;
              Navigator.of(context).pop(qty);
            },
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    // Dispose only after the dialog's exit transition finishes — disposing
    // immediately throws "TextEditingController was used after being
    // disposed" during the closing frame and error-boxes the surface.
    Future.delayed(const Duration(milliseconds: 400), controller.dispose);
    if (!mounted) {
      return;
    }
    if (result != null && result != item.quantity) {
      if (result > item.quantity && !widget.canCreateSales) {
        showErrorToast(
          context,
          widget.cutoffMessage ?? context.l10n.restaurantKitchenClosed,
        );
        return;
      }
      await widget.onEditOrderItemQuantity!(item.id, result);
    }
  }

  Future<void> _showCurrentTicketSheet() async {
    final activeOrder = widget.state.activeOrder;
    if (activeOrder == null) {
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: PosColors.surface,
      builder: (sheetContext) {
        return _CurrentTicketDetailSheet(
          order: activeOrder,
          onEditQuantity: widget.onEditOrderItemQuantity == null
              ? null
              : (item) async {
                  Navigator.of(sheetContext).pop();
                  await _showEditQuantityDialog(item);
                },
          onCancelItem: widget.onCancelOrderItem == null
              ? null
              : (item) async {
                  Navigator.of(sheetContext).pop();
                  await widget.onCancelOrderItem!(item.id);
                },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isOnline = ref.watch(connectivityProvider).asData?.value ?? true;
    final formatter = NumberFormat('#,###', 'vi_VN');
    final cartTotal = widget.state.cart.fold<double>(
      0,
      (sum, item) => sum + (item.price * item.quantity),
    );
    final activeTotal = (widget.state.activeOrder?.items ?? const <OrderItem>[])
        .where((item) => item.status != 'cancelled')
        .fold<double>(0, (sum, item) => sum + (item.unitPrice * item.quantity));
    final readyItemCount =
        (widget.state.activeOrder?.items ?? const <OrderItem>[])
            .where((item) => item.status == 'ready')
            .fold<int>(0, (sum, item) => sum + item.quantity);
    final summaryTotal = widget.showPaymentActions
        ? activeTotal
        : activeTotal + cartTotal;
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
      l10n.waiterSeatCount(widget.table.seatCount ?? 0),
      if (widget.state.activeOrder != null) l10n.orderWorkspaceCurrentCheck,
    ];
    final sendDisabledReason =
        !widget.allowSubmitWithoutCart && widget.state.cart.isEmpty
        ? PosActionDisabledReason.cartEmpty
        : null;
    final canSendOrder =
        !widget.state.isSubmitting &&
        widget.canCreateSales &&
        (widget.allowSubmitWithoutCart || widget.state.cart.isNotEmpty);
    final orderSubmissionActions = _OrderSendFooter(
      state: widget.state,
      isOnline: isOnline,
      canSendOrder: canSendOrder,
      showEmptyHint: sendDisabledReason == PosActionDisabledReason.cartEmpty,
      onCancel: widget.onCancel,
      onSendOrder: widget.onSendOrder,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final useCompactPanel =
            !widget.showPaymentActions &&
            (constraints.maxWidth < 360 || constraints.maxHeight < 340);

        if (useCompactPanel) {
          return _CompactCurrentOrderPanel(
            table: widget.table,
            guestCount: widget.guestCount,
            state: widget.state,
            formatter: formatter,
            isOnline: isOnline,
            canCancelOrder: canCancelOrder,
            canSendOrder: canSendOrder,
            sendDisabledReason: sendDisabledReason,
            onCancel: widget.onCancel,
            onCancelOrder: widget.onCancelOrder,
            onSendOrder: widget.onSendOrder,
            onViewCurrentTicket: _showCurrentTicketSheet,
            onTransferTable: widget.onTransferTable,
            onChangeGuestCount: widget.onChangeGuestCount,
          );
        }

        return ToastWorkSurface(
          key: const Key('orders_root'),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ToastSelectedContextHeader(
                title: l10n.waiterTableLabel(widget.table.tableNumber),
                subtitle: subtitleParts.join(' • '),
                trailing: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (widget.state.activeOrder != null)
                      OutlinedButton.icon(
                        key: const Key('order_current_ticket_detail_action'),
                        onPressed: widget.state.isSubmitting
                            ? null
                            : () => unawaited(_showCurrentTicketSheet()),
                        icon: const Icon(Icons.receipt_long_outlined, size: 16),
                        label: Text(l10n.orderWorkspaceCurrentCheck),
                      ),
                    if (widget.guestCount != null &&
                        widget.state.activeOrder == null)
                      ToastStatusBadge(
                        label: l10n.orderWorkspaceGuestCount(
                          widget.guestCount!,
                        ),
                        color: PosColors.warning,
                        compact: true,
                      ),
                    if (widget.onChangeGuestCount != null)
                      IconButton(
                        key: const Key('order_guest_count_edit_action'),
                        tooltip: l10n.waiterGuestCountTitle,
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.state.isSubmitting
                            ? null
                            : () => unawaited(widget.onChangeGuestCount!()),
                        icon: const Icon(
                          Icons.group_add_outlined,
                          size: 18,
                          color: PosColors.textSecondary,
                        ),
                      ),
                    if (canCancelOrder)
                      OutlinedButton.icon(
                        key: const Key('order_cancel_order_direct_action'),
                        onPressed: widget.state.isSubmitting
                            ? null
                            : () => unawaited(widget.onCancelOrder()),
                        icon: const Icon(Icons.cancel_outlined, size: 16),
                        label: Text(l10n.waiterCancelOrderAction),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: PosColors.danger,
                          side: const BorderSide(color: PosColors.danger),
                        ),
                      ),
                    if (widget.onTransferTable != null)
                      PopupMenuButton<_OrderPanelOverflowAction>(
                        tooltip: l10n.moreActions,
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
                _OrderCreateSuccessBanner(order: widget.state.activeOrder!),
              ],
              if (readyItemCount > 0) ...[
                const SizedBox(height: 6),
                _WaiterReadyHandoffNotice(readyItemCount: readyItemCount),
              ],
              const SizedBox(height: 10),
              Expanded(
                child: ListView(
                  children: [
                    if (widget.state.cart.isNotEmpty) ...[
                      _PendingOrderReview(
                        cart: widget.state.cart,
                        formatter: formatter,
                        onIncrementCartItem: widget.onIncrementCartItem,
                        onDecrementCartItem: widget.onDecrementCartItem,
                      ),
                      const SizedBox(height: 14),
                    ] else if (widget.state.activeOrder == null) ...[
                      ToastOperationalEmptyState(
                        headline: l10n.orderWorkspaceNoItemsAdded,
                        helper: l10n.orderWorkspaceTapItemToAdd,
                        icon: Icons.playlist_add_outlined,
                      ),
                    ],
                    if (widget.state.activeOrder != null &&
                        widget.state.activeOrder!.items.isNotEmpty) ...[
                      Theme(
                        data: Theme.of(
                          context,
                        ).copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          key: const Key(
                            'order_sent_items_always_visible_detail',
                          ),
                          initiallyExpanded: true,
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: EdgeInsets.zero,
                          title: Text(
                            '${l10n.orderWorkspaceSentToKitchen} · ${l10n.orderWorkspaceCurrentCheckDetails}',
                            key: const Key(
                              'order_current_ticket_reconfirm_header',
                            ),
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: PosColors.textSecondary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          children: [
                            Padding(
                              key: const Key(
                                'order_current_ticket_reconfirm_hint',
                              ),
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.receipt_long_outlined,
                                    size: 16,
                                    color: PosColors.info,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      '${l10n.orderWorkspaceCurrentCheckReconfirmHint} · ${l10n.orderWorkspaceItemsCount(widget.state.activeOrder!.items.length)}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: PosColors.textSecondary,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                key: const Key(
                                  'order_current_ticket_open_detail_button',
                                ),
                                onPressed: widget.state.isSubmitting
                                    ? null
                                    : () =>
                                          unawaited(_showCurrentTicketSheet()),
                                icon: const Icon(
                                  Icons.receipt_long_outlined,
                                  size: 16,
                                ),
                                label: Text(
                                  l10n.orderWorkspaceCurrentCheckDetails,
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            ...widget.state.activeOrder!.items.map((item) {
                              final label = _localizedMenuDataLabel(
                                context,
                                item.label ?? 'Item',
                              );
                              final isCancelled = item.status == 'cancelled';
                              final statusLabel = _orderItemStatusLabel(
                                context,
                                item.status,
                              );
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
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Flexible(
                                                  child: Text(
                                                    label,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodyMedium
                                                        ?.copyWith(
                                                          color: isCancelled
                                                              ? PosColors.danger
                                                              : PosColors
                                                                    .textSecondary,
                                                          fontSize: 13,
                                                          decoration:
                                                              isCancelled
                                                              ? TextDecoration
                                                                    .lineThrough
                                                              : null,
                                                        ),
                                                  ),
                                                ),
                                                if (canEditQty) ...[
                                                  const SizedBox(width: 4),
                                                  InkWell(
                                                    onTap:
                                                        widget
                                                            .state
                                                            .isSubmitting
                                                        ? null
                                                        : () =>
                                                              _showEditQuantityDialog(
                                                                item,
                                                              ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          10,
                                                        ),
                                                    child: const Padding(
                                                      padding: EdgeInsets.all(
                                                        2,
                                                      ),
                                                      child: Icon(
                                                        Icons.edit,
                                                        size: 14,
                                                        color: PosColors
                                                            .textSecondary,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              key: ValueKey<String>(
                                                'order_sent_item_reconfirm_${item.id}',
                                              ),
                                              '${l10n.orderWorkspaceItemsCount(item.quantity)} · $statusLabel',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                    color:
                                                        PosColors.textSecondary,
                                                    fontSize: 11.5,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
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
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
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
                                            : () =>
                                                  widget.onCycleSentItemStatus!(
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
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (!widget.canCreateSales && widget.cutoffMessage != null) ...[
                Text(
                  widget.cutoffMessage!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.danger,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              orderSubmissionActions,
              if (widget.state.isSubmitting)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: ToastOperationalLoadingState(
                    label: PosLoadingCopy.syncing(l10n),
                  ),
                ),
              const SizedBox(height: 8),
              Container(
                key: const Key('order_summary_amount'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: PosSurfaceRole.background.fill,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: PosSurfaceRole.background.stroke),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.showPaymentActions
                            ? l10n.orderWorkspacePaymentDue
                            : l10n.orderWorkspaceSubtotal,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: PosSurfaceRole.background.helper,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '₫${formatter.format(summaryTotal)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: PosNumericText.amountLarge.copyWith(
                        color: PosColors.accent,
                      ),
                    ),
                  ],
                ),
              ),
              if (canProcessPayment) ...[
                const SizedBox(height: 12),
                Text(
                  '${l10n.orderWorkspacePaymentDue} (₫${formatter.format(activeTotal)})',
                  style: PosNumericText.unitPrice.copyWith(
                    color: PosColors.textSecondary,
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
                            !widget.canCompletePayment ||
                            _selectedPaymentMethod == null ||
                            widget.onProcessPayment == null
                        ? null
                        : () =>
                              widget.onProcessPayment!(_selectedPaymentMethod!),
                    disabledReason: _selectedPaymentMethod == null
                        ? PosActionDisabledReason.paymentMethodNotSelected
                        : null,
                  ),
                ),
                if (widget.isProcessingPayment)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: ToastOperationalLoadingState(
                      label: PosLoadingCopy.syncing(l10n),
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
      },
    );
  }
}

class _OrderCreateSuccessBanner extends StatelessWidget {
  const _OrderCreateSuccessBanner({required this.order, this.compact = false});

  final Order order;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final shortOrderId = _shortOrderTicketCode(order.id);

    return Container(
      key: const Key('order_create_success_banner'),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 8,
        vertical: compact ? 4 : 4,
      ),
      decoration: BoxDecoration(
        color: PosColors.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.check_circle_outline,
            color: PosColors.success,
            size: compact ? 11 : 12,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              key: const Key('latest_order_number_text'),
              '${l10n.orderWorkspaceKitchenTicketSent} · $shortOrderId',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: PosColors.success,
                fontSize: compact ? 10.5 : 11,
              ),
            ),
          ),
          Offstage(
            offstage: true,
            child: Text(key: const Key('latest_order_id_full_text'), order.id),
          ),
        ],
      ),
    );
  }
}

class _WaiterReadyHandoffNotice extends StatelessWidget {
  const _WaiterReadyHandoffNotice({
    required this.readyItemCount,
    this.compact = false,
  });

  final int readyItemCount;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Container(
      key: const Key('order_waiter_ready_handoff_notice'),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 6 : 8,
      ),
      decoration: BoxDecoration(
        color: PosColors.success.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PosColors.success.withValues(alpha: 0.32)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.room_service_outlined,
            color: PosColors.success,
            size: compact ? 16 : 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${l10n.kitchenReadyHandoff} · ${l10n.orderWorkspaceItemsCount(readyItemCount)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: PosColors.success,
                    fontWeight: FontWeight.w900,
                    fontSize: compact ? 11.5 : 12.5,
                  ),
                ),
                Text(
                  l10n.kitchenReadySupport,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textSecondary,
                    fontSize: compact ? 10.5 : 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CurrentTicketDetailSheet extends StatelessWidget {
  const _CurrentTicketDetailSheet({
    required this.order,
    required this.onEditQuantity,
    required this.onCancelItem,
  });

  final Order order;
  final Future<void> Function(OrderItem item)? onEditQuantity;
  final Future<void> Function(OrderItem item)? onCancelItem;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final formatter = NumberFormat('#,###', 'vi_VN');
    final activeItems = order.items
        .where((item) => item.status != 'cancelled')
        .toList();
    final subtotal = activeItems.fold<double>(
      0,
      (sum, item) => sum + (item.unitPrice * item.quantity),
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 620),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.orderWorkspaceCurrentCheckDetails,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.orderWorkspaceTicketCode(
                            _shortOrderTicketCode(order.id),
                          ),
                          key: const Key('order_current_ticket_code_text'),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: PosColors.textSecondary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                    ),
                  ),
                  ToastStatusBadge(
                    label: l10n.orderWorkspaceItemsCount(activeItems.length),
                    color: PosColors.info,
                    compact: true,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                l10n.orderWorkspaceCurrentCheckReconfirmHint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: PosColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: ListView.separated(
                  itemCount: order.items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = order.items[index];
                    final isCancelled = item.status == 'cancelled';
                    final canEditQty =
                        item.status == 'pending' && onEditQuantity != null;
                    final canCancel =
                        !isCancelled &&
                        item.status != 'ready' &&
                        item.status != 'served' &&
                        onCancelItem != null;

                    return Container(
                      key: ValueKey<String>(
                        'order_current_ticket_detail_item_${item.id}',
                      ),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: PosSurfaceRole.background.fill,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isCancelled
                              ? PosColors.danger.withValues(alpha: 0.28)
                              : PosSurfaceRole.background.stroke,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _localizedMenuDataLabel(
                                    context,
                                    item.label ??
                                        l10n.orderWorkspaceItemFallback,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        decoration: isCancelled
                                            ? TextDecoration.lineThrough
                                            : null,
                                        fontWeight: FontWeight.w800,
                                      ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              _OrderItemStatusChip(status: item.status),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${l10n.orderWorkspaceItemsCount(item.quantity)} · ₫${formatter.format(item.unitPrice * item.quantity)}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: PosColors.textSecondary,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          if (!canEditQty && !isCancelled) ...[
                            const SizedBox(height: 6),
                            Text(
                              l10n.orderWorkspaceItemLockedAfterKitchen,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: PosColors.textSecondary,
                                    fontSize: 11.5,
                                  ),
                            ),
                          ],
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            alignment: WrapAlignment.end,
                            children: [
                              OutlinedButton.icon(
                                key: ValueKey<String>(
                                  'order_current_ticket_edit_qty_${item.id}',
                                ),
                                onPressed: canEditQty
                                    ? () => unawaited(onEditQuantity!(item))
                                    : null,
                                icon: const Icon(Icons.edit_outlined, size: 16),
                                label: Text(
                                  l10n.orderWorkspaceEditQuantityAction,
                                ),
                              ),
                              OutlinedButton.icon(
                                key: ValueKey<String>(
                                  'order_current_ticket_cancel_item_${item.id}',
                                ),
                                onPressed: canCancel
                                    ? () => unawaited(onCancelItem!(item))
                                    : null,
                                icon: const Icon(Icons.close_rounded, size: 16),
                                label: Text(
                                  l10n.orderWorkspaceCancelItemAction,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: PosColors.accent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.orderWorkspaceSubtotal,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Text(
                      '₫${formatter.format(subtotal)}',
                      style: PosNumericText.amountLarge.copyWith(
                        color: PosColors.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactCurrentOrderPanel extends StatelessWidget {
  const _CompactCurrentOrderPanel({
    required this.table,
    required this.guestCount,
    required this.state,
    required this.formatter,
    required this.isOnline,
    required this.canCancelOrder,
    required this.canSendOrder,
    required this.sendDisabledReason,
    required this.onCancel,
    required this.onCancelOrder,
    required this.onSendOrder,
    required this.onViewCurrentTicket,
    required this.onTransferTable,
    required this.onChangeGuestCount,
  });

  final PosTable table;
  final int? guestCount;
  final OrderState state;
  final NumberFormat formatter;
  final bool isOnline;
  final bool canCancelOrder;
  final bool canSendOrder;
  final PosActionDisabledReason? sendDisabledReason;
  final VoidCallback onCancel;
  final Future<void> Function() onCancelOrder;
  final Future<void> Function() onSendOrder;
  final Future<void> Function() onViewCurrentTicket;
  final VoidCallback? onTransferTable;
  final Future<void> Function()? onChangeGuestCount;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final pendingCount = state.cart.fold<int>(
      0,
      (sum, item) => sum + item.quantity,
    );
    final sentCount = (state.activeOrder?.items ?? const <OrderItem>[])
        .where((item) => item.status != 'cancelled')
        .fold<int>(0, (sum, item) => sum + item.quantity);
    final readyItemCount = (state.activeOrder?.items ?? const <OrderItem>[])
        .where((item) => item.status == 'ready')
        .fold<int>(0, (sum, item) => sum + item.quantity);
    final total = state.cart.fold<double>(
      0,
      (sum, item) => sum + (item.price * item.quantity),
    );

    return ToastWorkSurface(
      key: const Key('orders_root'),
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.waiterTableLabel(table.tableNumber),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: PosNumericText.tableId.copyWith(
                      color: PosColors.textPrimary,
                    ),
                  ),
                ),
                if (guestCount != null)
                  ToastStatusBadge(
                    label: l10n.orderWorkspaceGuestCount(guestCount!),
                    color: PosColors.warning,
                    compact: true,
                  ),
                if (onChangeGuestCount != null)
                  IconButton(
                    key: const Key('order_guest_count_edit_action_compact'),
                    tooltip: l10n.waiterGuestCountTitle,
                    visualDensity: VisualDensity.compact,
                    onPressed: state.isSubmitting
                        ? null
                        : () => unawaited(onChangeGuestCount!()),
                    icon: const Icon(Icons.group_add_outlined, size: 18),
                  ),
                if (state.activeOrder != null) ...[
                  const SizedBox(width: 6),
                  IconButton(
                    key: const Key(
                      'order_current_ticket_detail_action_compact',
                    ),
                    tooltip: l10n.orderWorkspaceCurrentCheckDetails,
                    visualDensity: VisualDensity.compact,
                    onPressed: state.isSubmitting
                        ? null
                        : () => unawaited(onViewCurrentTicket()),
                    icon: const Icon(Icons.receipt_long_outlined, size: 18),
                  ),
                ],
              ],
            ),
            if (state.activeOrder != null && !state.isSubmitting) ...[
              const SizedBox(height: 6),
              _OrderCreateSuccessBanner(
                order: state.activeOrder!,
                compact: true,
              ),
            ],
            if (readyItemCount > 0) ...[
              const SizedBox(height: 6),
              _WaiterReadyHandoffNotice(
                readyItemCount: readyItemCount,
                compact: true,
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    pendingCount > 0
                        ? '${l10n.orderWorkspaceNewItems} $pendingCount · ₫${formatter.format(total)}'
                        : '${l10n.orderWorkspaceSentToKitchen} $sentCount',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: pendingCount > 0
                          ? PosColors.accent
                          : PosColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (canCancelOrder)
                  IconButton(
                    key: const Key('order_cancel_order_direct_action_compact'),
                    tooltip: l10n.waiterCancelOrderAction,
                    visualDensity: VisualDensity.compact,
                    onPressed: state.isSubmitting
                        ? null
                        : () => unawaited(onCancelOrder()),
                    icon: const Icon(
                      Icons.cancel_outlined,
                      size: 18,
                      color: PosColors.danger,
                    ),
                  ),
                if (onTransferTable != null)
                  PopupMenuButton<_OrderPanelOverflowAction>(
                    tooltip: l10n.moreActions,
                    enabled: !state.isSubmitting,
                    onSelected: (action) async {
                      switch (action) {
                        case _OrderPanelOverflowAction.moveTable:
                          onTransferTable?.call();
                          break;
                        case _OrderPanelOverflowAction.cancelOrder:
                          await onCancelOrder();
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      if (onTransferTable != null)
                        PopupMenuItem(
                          value: _OrderPanelOverflowAction.moveTable,
                          child: Text(l10n.orderWorkspaceMove),
                        ),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(Icons.more_horiz, size: 18),
                    ),
                  ),
              ],
            ),
            if (!isOnline || state.offlineQueueCount > 0) ...[
              const SizedBox(height: 6),
              Text(
                !isOnline
                    ? l10n.orderWorkspaceOfflineQueueMessage
                    : l10n.orderWorkspaceQueuedOrderOperations(
                        state.offlineQueueCount,
                      ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: !isOnline ? PosColors.warning : PosColors.accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 8),
            _OrderSendFooter(
              state: state,
              isOnline: isOnline,
              canSendOrder: canSendOrder,
              showEmptyHint:
                  sendDisabledReason == PosActionDisabledReason.cartEmpty,
              onCancel: onCancel,
              onSendOrder: onSendOrder,
              compact: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderSendFooter extends StatelessWidget {
  const _OrderSendFooter({
    required this.state,
    required this.isOnline,
    required this.canSendOrder,
    required this.showEmptyHint,
    required this.onCancel,
    required this.onSendOrder,
    this.compact = false,
  });

  final OrderState state;
  final bool isOnline;
  final bool canSendOrder;
  final bool showEmptyHint;
  final VoidCallback onCancel;
  final Future<void> Function() onSendOrder;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final supportStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: PosColors.textSecondary,
      fontSize: compact ? 11 : 12,
      fontWeight: FontWeight.w700,
    );
    final sendTileState = state.isSubmitting
        ? PosActionTileState.processing
        : !isOnline
        ? PosActionTileState.offlineBlocked
        : canSendOrder
        ? PosActionTileState.idle
        : PosActionTileState.disabled;
    final sendHelper = state.isSubmitting
        ? PosLoadingCopy.syncing(l10n)
        : !isOnline
        ? l10n.orderWorkspaceOfflineQueueMessage
        : showEmptyHint
        ? l10n.orderWorkspaceTapItemToAdd
        : state.offlineQueueCount > 0
        ? l10n.orderWorkspaceQueuedOrderOperations(state.offlineQueueCount)
        : null;

    return Container(
      key: const Key('cart_submit_order_sticky_footer'),
      padding: EdgeInsets.only(top: compact ? 8 : 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: PosColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                flex: compact ? 3 : 2,
                child: PosActionButton(
                  key: const Key('order_workspace_cancel_button'),
                  label: l10n.cancel,
                  tone: PosActionTone.secondary,
                  icon: PosActionIcons.cancel,
                  compact: compact,
                  onPressed: state.isSubmitting ? null : onCancel,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: compact ? 5 : 4,
                child: PosActionTile(
                  key: const Key('cart_submit_order'),
                  label: l10n.orderWorkspaceSendToKitchen,
                  helper: sendHelper,
                  icon: PosActionIcons.sendOrder,
                  state: sendTileState,
                  allowOfflineBlockedTap: canSendOrder,
                  onTap: canSendOrder ? () => unawaited(onSendOrder()) : null,
                ),
              ),
            ],
          ),
          if (showEmptyHint) ...[
            SizedBox(height: compact ? 6 : 8),
            Text(
              l10n.orderWorkspaceTapItemToAdd,
              textAlign: TextAlign.right,
              style: supportStyle,
            ),
          ],
          if (!isOnline) ...[
            SizedBox(height: compact ? 6 : 8),
            Text(
              l10n.orderWorkspaceOfflineQueueMessage,
              textAlign: TextAlign.right,
              style: supportStyle?.copyWith(color: PosColors.warning),
            ),
          ],
          if (state.offlineQueueCount > 0 || state.isSyncingOfflineQueue) ...[
            SizedBox(height: compact ? 6 : 8),
            Text(
              state.isSyncingOfflineQueue
                  ? l10n.orderWorkspaceSyncingQueuedOrders
                  : l10n.orderWorkspaceQueuedOrderOperations(
                      state.offlineQueueCount,
                    ),
              textAlign: TextAlign.right,
              style: supportStyle?.copyWith(color: PosColors.accent),
            ),
          ],
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
      'pending' => (
        PosColors.textSecondary,
        _orderItemStatusLabel(context, normalized),
      ),
      'preparing' => (
        PosColors.accent,
        _orderItemStatusLabel(context, normalized),
      ),
      'ready' => (
        PosColors.success,
        _orderItemStatusLabel(context, normalized),
      ),
      'served' => (
        PosColors.warning,
        _orderItemStatusLabel(context, normalized),
      ),
      'cancelled' => (
        PosColors.danger,
        _orderItemStatusLabel(context, normalized),
      ),
      _ => (PosColors.textSecondary, normalized.toUpperCase()),
    };
    return ToastStatusChip(label: label, color: color);
  }
}

String _orderItemStatusLabel(BuildContext context, String status) {
  final l10n = context.l10n;
  return switch (status.toLowerCase()) {
    'pending' => l10n.orderStatusPending,
    'preparing' => l10n.orderStatusPreparing,
    'ready' => l10n.orderWorkspaceReady,
    'served' => l10n.orderStatusServed,
    'cancelled' => l10n.orderStatusCancelled,
    _ => status.toUpperCase(),
  };
}

String _shortOrderTicketCode(String orderId) {
  final normalized = orderId.trim();
  return normalized.length >= 8 ? normalized.substring(0, 8) : normalized;
}

String _localizedMenuDataLabel(BuildContext context, Object? value) {
  final raw = value?.toString().trim();
  if (raw == null || raw.isEmpty) {
    return '-';
  }
  final language = Localizations.localeOf(context).languageCode;
  return switch (raw.toLowerCase()) {
    'food' => switch (language) {
      'vi' => 'Món ăn',
      'ko' => '음식',
      _ => 'Food',
    },
    'drinks' || 'drink' => switch (language) {
      'vi' => 'Đồ uống',
      'ko' => '음료',
      _ => 'Drinks',
    },
    'desserts' || 'dessert' => switch (language) {
      'vi' => 'Tráng miệng',
      'ko' => '디저트',
      _ => 'Desserts',
    },
    'waiter test menu' ||
    '웨이터 테스트 메뉴' ||
    'menu thử phục vụ' => switch (language) {
      'vi' => 'Menu thử phục vụ',
      'ko' => '웨이터 테스트 메뉴',
      _ => 'Waiter test menu',
    },
    'qa test menu' => switch (language) {
      'vi' => 'Menu thử nghiệm QA',
      'ko' => 'QA 테스트 메뉴',
      _ => 'QA Test Menu',
    },
    'qa iced tea' => switch (language) {
      'vi' => 'Trà đá QA',
      'ko' => 'QA 아이스티',
      _ => 'QA Iced Tea',
    },
    'qa spring roll' => switch (language) {
      'vi' => 'Chả giò QA',
      'ko' => 'QA 스프링롤',
      _ => 'QA Spring Roll',
    },
    'qa com rang' || 'qa cơm rang' => switch (language) {
      'vi' => 'Cơm rang QA',
      'ko' => 'QA 볶음밥',
      _ => 'QA Fried Rice',
    },
    'qa banh mi' || 'qa bánh mì' => switch (language) {
      'vi' => 'Bánh mì QA',
      'ko' => 'QA 반미',
      _ => 'QA Banh Mi',
    },
    'qa pho bo' || 'qa phở bò' => switch (language) {
      'vi' => 'Phở bò QA',
      'ko' => 'QA 쌀국수',
      _ => 'QA Pho Bo',
    },
    '테스트 보리차' => switch (language) {
      'vi' => 'Trà lúa mạch thử nghiệm',
      'ko' => raw,
      _ => 'Test barley tea',
    },
    '테스트 만두' => switch (language) {
      'vi' => 'Mandu thử nghiệm',
      'ko' => raw,
      _ => 'Test dumplings',
    },
    '테스트 냉면' => switch (language) {
      'vi' => 'Naengmyeon thử nghiệm',
      'ko' => raw,
      _ => 'Test cold noodles',
    },
    '테스트 치킨' => switch (language) {
      'vi' => 'Gà rán thử nghiệm',
      'ko' => raw,
      _ => 'Test fried chicken',
    },
    '테스트 떡볶이' => switch (language) {
      'vi' => 'Tteokbokki thử nghiệm',
      'ko' => raw,
      _ => 'Test tteokbokki',
    },
    '테스트 제육볶음' => switch (language) {
      'vi' => 'Thịt heo xào cay thử nghiệm',
      'ko' => raw,
      _ => 'Test spicy pork',
    },
    '테스트 불고기덮밥' => switch (language) {
      'vi' => 'Cơm bulgogi thử nghiệm',
      'ko' => raw,
      _ => 'Test bulgogi rice bowl',
    },
    '테스트 비빔밥' => switch (language) {
      'vi' => 'Bibimbap thử nghiệm',
      'ko' => raw,
      _ => 'Test bibimbap',
    },
    '불백' || '불백2' || 'bulbaek' => switch (language) {
      'vi' => 'Thịt nướng Hàn',
      'ko' => raw,
      _ => 'Korean BBQ pork',
    },
    '불고기밥' || 'bulgogi rice' => switch (language) {
      'vi' => 'Cơm bulgogi',
      'ko' => '불고기밥',
      _ => 'Bulgogi Rice',
    },
    '떡볶이' || 'tteokbokki' => switch (language) {
      'vi' => 'Bánh gạo cay',
      'ko' => '떡볶이',
      _ => 'Tteokbokki',
    },
    '김치찌개' || 'kimchi jjigae' => switch (language) {
      'vi' => 'Canh kimchi',
      'ko' => '김치찌개',
      _ => 'Kimchi Jjigae',
    },
    '비빔밥' || 'bibimbap' => switch (language) {
      'vi' => 'Bibimbap',
      'ko' => '비빔밥',
      _ => 'Bibimbap',
    },
    _ => raw,
  };
}
