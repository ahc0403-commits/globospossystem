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
        final isWide = constraints.maxWidth >= 760;
        if (isWide) {
          return Row(
            children: [
              Expanded(
                flex: 7,
                child: _MenuBrowser(
                  menuLoading: menuLoading,
                  menuError: menuError,
                  categories: categories,
                  selectedCategoryId: selectedCategoryId,
                  filteredItems: filteredItems,
                  cart: orderState.cart,
                  onSelectCategory: (categoryId) =>
                      menuNotifier?.selectCategory(categoryId),
                  onAddItem: onAddToCart,
                  onIncrementCartItem: onIncrementCartItem,
                  onDecrementCartItem: onDecrementCartItem,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
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
                onAddItem: onAddToCart,
                onIncrementCartItem: onIncrementCartItem,
                onDecrementCartItem: onDecrementCartItem,
              ),
            ),
            Expanded(
              flex: 2,
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
                        label: category['name']?.toString() ?? '-',
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
                          childAspectRatio: useSingleColumn
                              ? 3.15
                              : useThreeColumns
                              ? 2.15
                              : 2.35,
                        ),
                        itemBuilder: (context, index) {
                          final item = filteredItems[index];
                          final menuItemId = item['id']?.toString() ?? '';
                          final name = item['name']?.toString() ?? '-';
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
                                      Container(
                                        width: 36,
                                        height: 36,
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
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
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
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
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
          Text(
            '${item.quantity}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
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
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: PosColors.accent,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
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
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
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
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w900,
              ),
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
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PosColors.accent,
                fontSize: 12,
                fontWeight: FontWeight.w900,
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
              item.label ?? l10n.orderWorkspaceItemFallback,
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
      l10n.waiterSeatCount(widget.table.seatCount ?? 0),
      if (widget.state.activeOrder != null) l10n.orderWorkspaceCurrentCheck,
    ];
    final sendDisabledReason =
        !widget.allowSubmitWithoutCart && widget.state.cart.isEmpty
        ? PosActionDisabledReason.cartEmpty
        : null;
    final canSendOrder =
        !widget.state.isSubmitting &&
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
            onTransferTable: widget.onTransferTable,
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
                      ToastStatusBadge(
                        label: l10n.orderWorkspaceCurrentCheck,
                        color: PosColors.info,
                        compact: true,
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
                    if (widget.onTransferTable != null || canCancelOrder)
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
                                    style: const TextStyle(
                                      color: PosColors.danger,
                                    ),
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
                _OrderCreateSuccessBanner(order: widget.state.activeOrder!),
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
                          key: const Key('order_sent_items_secondary_detail'),
                          initiallyExpanded: false,
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: EdgeInsets.zero,
                          title: Text(
                            l10n.orderWorkspaceSentToKitchen,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
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
                                                          : PosColors
                                                                .textSecondary,
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
                                                    : () =>
                                                          _showEditQuantityDialog(
                                                            item,
                                                          ),
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                child: const Padding(
                                                  padding: EdgeInsets.all(2),
                                                  child: Icon(
                                                    Icons.edit,
                                                    size: 14,
                                                    color:
                                                        PosColors.textSecondary,
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
              orderSubmissionActions,
              if (widget.state.isSubmitting)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: ToastOperationalLoadingState(
                    label: PosLoadingCopy.syncing,
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
                        : () =>
                              widget.onProcessPayment!(_selectedPaymentMethod!),
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
    final shortOrderId = order.id.length >= 8
        ? order.id.substring(0, 8)
        : order.id;

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
    required this.onTransferTable,
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
  final VoidCallback? onTransferTable;

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
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                if (guestCount != null)
                  ToastStatusBadge(
                    label: l10n.orderWorkspaceGuestCount(guestCount!),
                    color: PosColors.warning,
                    compact: true,
                  ),
                if (state.activeOrder != null) ...[
                  const SizedBox(width: 6),
                  ToastStatusBadge(
                    label: l10n.orderWorkspaceCurrentCheck,
                    color: PosColors.info,
                    compact: true,
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
                if (onTransferTable != null || canCancelOrder)
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
                      if (canCancelOrder)
                        PopupMenuItem(
                          value: _OrderPanelOverflowAction.cancelOrder,
                          child: Text(PosActionVerbs.cancelOrder),
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
                  label: PosActionVerbs.cancel,
                  tone: PosActionTone.secondary,
                  icon: PosActionIcons.cancel,
                  compact: compact,
                  onPressed: state.isSubmitting ? null : onCancel,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: compact ? 5 : 4,
                child: PosActionButton(
                  key: const Key('cart_submit_order'),
                  label: l10n.orderWorkspaceSendToKitchen,
                  tone: PosActionTone.primary,
                  icon: PosActionIcons.sendOrder,
                  compact: compact,
                  loading: state.isSubmitting,
                  onPressed: canSendOrder ? onSendOrder : null,
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
    final l10n = context.l10n;
    final (color, label) = switch (normalized) {
      'pending' => (PosColors.textSecondary, l10n.orderStatusPending),
      'preparing' => (PosColors.accent, l10n.orderStatusPreparing),
      'ready' => (PosColors.success, l10n.orderWorkspaceReady),
      'served' => (PosColors.warning, l10n.orderStatusServed),
      'cancelled' => (PosColors.danger, l10n.orderStatusCancelled),
      _ => (PosColors.textSecondary, normalized.toUpperCase()),
    };
    return ToastStatusChip(label: label, color: color);
  }
}
