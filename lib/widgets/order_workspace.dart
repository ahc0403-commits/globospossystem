import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../core/services/connectivity_service.dart';
import '../features/admin/providers/menu_provider.dart';
import '../features/order/order_model.dart';
import '../features/order/order_provider.dart';
import '../features/table/table_model.dart';
import '../main.dart';

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
  final Future<void> Function(OrderItem item, String nextStatus)? onCycleSentItemStatus;
  final bool showPaymentActions;
  final Future<void> Function(String method)? onProcessPayment;
  final bool isProcessingPayment;

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
    final currency = NumberFormat('#,###', 'vi_VN');

    if (menuLoading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.amber500),
      );
    }

    if (menuError) {
      return Center(
        child: Text(
          'Failed to load menu.',
          style: GoogleFonts.notoSansKr(
            color: AppColors.statusCancelled,
            fontSize: 14,
          ),
        ),
      );
    }

    return Container(
      color: AppColors.surface0,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Menu',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 42,
            child: categories.isEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'No categories',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
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

                      return InkWell(
                        onTap: categoryId.isEmpty
                            ? null
                            : () => onSelectCategory(categoryId),
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          decoration: BoxDecoration(
                            color: selected
                                ? AppColors.amber500
                                : AppColors.surface1,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: selected
                                  ? AppColors.amber500
                                  : AppColors.surface2,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            category['name']?.toString() ?? '-',
                            style: GoogleFonts.notoSansKr(
                              color: selected
                                  ? AppColors.surface0
                                  : AppColors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: filteredItems.isEmpty
                ? Center(
                    child: Text(
                      'No menu items in this category.',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                        fontSize: 14,
                      ),
                    ),
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
                        decoration: BoxDecoration(
                          color: AppColors.surface1,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.surface2),
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
                                    style: GoogleFonts.notoSansKr(
                                      color: AppColors.textPrimary,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '₫${currency.format(price)}',
                                    style: GoogleFonts.bebasNeue(
                                      color: AppColors.amber500,
                                      fontSize: 24,
                                      letterSpacing: 0.8,
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
                                  color: AppColors.amber500,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.add,
                                  size: 22,
                                  color: AppColors.surface0,
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
  final Future<void> Function(OrderItem item, String nextStatus)? onCycleSentItemStatus;
  final bool showPaymentActions;
  final Future<void> Function(String method)? onProcessPayment;
  final bool isProcessingPayment;

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

  @override
  Widget build(BuildContext context) {
    final isOnline = ref.watch(connectivityProvider).asData?.value ?? true;
    final formatter = NumberFormat('#,###', 'vi_VN');
    final total = widget.state.cart.fold<double>(
      0,
      (sum, item) => sum + (item.price * item.quantity),
    );
    final activeTotal = (widget.state.activeOrder?.items ?? const <OrderItem>[])
        .fold<double>(
          0,
          (sum, item) => sum + (item.unitPrice * item.quantity),
        );
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

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface1,
        border: Border(left: BorderSide(color: AppColors.surface2)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Table ${widget.table.tableNumber}',
                style: GoogleFonts.bebasNeue(
                  color: AppColors.amber500,
                  fontSize: 36,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              if (widget.state.activeOrder != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surface2,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    'OPEN ORDER',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              if (widget.guestCount != null && widget.state.activeOrder == null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surface2,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '${widget.guestCount} guests',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView(
              children: [
                if (widget.state.activeOrder != null &&
                    widget.state.activeOrder!.items.isNotEmpty) ...[
                  Text(
                    'Already Sent',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...widget.state.activeOrder!.items.map((item) {
                    final label = item.label ?? 'Item';
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.surface2,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '$label x${item.quantity}',
                              style: GoogleFonts.notoSansKr(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: !widget.canManageSentItems ||
                                    widget.onCycleSentItemStatus == null
                                ? null
                                : () => widget.onCycleSentItemStatus!(
                                      item,
                                      _cycleStatus(item.status),
                                    ),
                            borderRadius: BorderRadius.circular(10),
                            child: _OrderItemStatusChip(status: item.status),
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 14),
                ],
                Text(
                  'New Items',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                if (widget.state.cart.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.surface2,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'No items added yet.',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ...widget.state.cart.map((item) {
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.surface0,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.surface2),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.name,
                                style: GoogleFonts.notoSansKr(
                                  color: AppColors.textPrimary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '₫${formatter.format(item.price)}',
                                style: GoogleFonts.bebasNeue(
                                  color: AppColors.amber500,
                                  fontSize: 22,
                                  letterSpacing: 0.7,
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
                              color: AppColors.textSecondary,
                            ),
                            Text(
                              '${item.quantity}',
                              style: GoogleFonts.notoSansKr(
                                color: AppColors.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              onPressed: () => widget.onIncrementCartItem(item),
                              icon: const Icon(Icons.add_circle_outline),
                              color: AppColors.amber500,
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
                'TOTAL',
                style: GoogleFonts.notoSansKr(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                '₫${formatter.format(total)}',
                style: GoogleFonts.bebasNeue(
                  color: AppColors.amber500,
                  fontSize: 34,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 56,
            child: Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: widget.onCancel,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.surface2,
                      foregroundColor: AppColors.textPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      'CANCEL',
                      style: GoogleFonts.notoSansKr(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed:
                        widget.state.isSubmitting ||
                            (!widget.allowSubmitWithoutCart &&
                                widget.state.cart.isEmpty) ||
                            !isOnline
                        ? null
                        : widget.onSendOrder,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.amber500,
                      foregroundColor: AppColors.surface0,
                      disabledBackgroundColor: AppColors.amber500.withValues(
                        alpha: 0.4,
                      ),
                      disabledForegroundColor: AppColors.surface0.withValues(
                        alpha: 0.8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: widget.state.isSubmitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.3,
                              color: AppColors.surface0,
                            ),
                          )
                        : Text(
                            'SEND ORDER',
                            style: GoogleFonts.notoSansKr(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
          if (!isOnline)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '인터넷 연결이 필요합니다',
                style: GoogleFonts.notoSansKr(
                  color: AppColors.statusOccupied,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          if (canCancelOrder) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton.icon(
                onPressed: widget.state.isSubmitting ? null : widget.onCancelOrder,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.statusCancelled,
                  side: const BorderSide(color: AppColors.statusCancelled),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.cancel),
                label: Text(
                  '주문 취소',
                  style: GoogleFonts.notoSansKr(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
          if (canProcessPayment) ...[
            const SizedBox(height: 12),
            Text(
              '결제 처리 (₫${formatter.format(activeTotal)})',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: const [
                _PaymentMethodTag(method: 'cash', label: 'CASH'),
                _PaymentMethodTag(method: 'card', label: 'CARD'),
                _PaymentMethodTag(method: 'pay', label: 'PAY'),
                _PaymentMethodTag(method: 'service', label: 'SERVICE'),
              ].map((tag) {
                final selected = _selectedPaymentMethod == tag.method;
                return ChoiceChip(
                  selected: selected,
                  onSelected: (_) {
                    setState(() => _selectedPaymentMethod = tag.method);
                  },
                  label: Text(tag.label),
                  selectedColor: AppColors.amber500.withValues(alpha: 0.3),
                  labelStyle: GoogleFonts.notoSansKr(
                    color: selected
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                  side: BorderSide(
                    color: selected ? AppColors.amber500 : AppColors.surface2,
                  ),
                  backgroundColor: AppColors.surface2,
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: widget.isProcessingPayment ||
                        _selectedPaymentMethod == null ||
                        widget.onProcessPayment == null
                    ? null
                    : () => widget.onProcessPayment!(_selectedPaymentMethod!),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                child: widget.isProcessingPayment
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        '결제 완료',
                        style: GoogleFonts.notoSansKr(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
          ],
          if (widget.showPaymentActions && widget.state.cart.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '결제 전 새로 추가한 항목을 먼저 전송하세요.',
                style: GoogleFonts.notoSansKr(
                  color: AppColors.statusOccupied,
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
      'pending' => (AppColors.textSecondary, 'PENDING'),
      'preparing' => (AppColors.amber500, 'PREPARING'),
      'ready' => (AppColors.statusAvailable, 'READY'),
      'served' => (AppColors.statusOccupied, 'SERVED'),
      _ => (AppColors.textSecondary, normalized.toUpperCase()),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Text(
        label,
        style: GoogleFonts.notoSansKr(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
