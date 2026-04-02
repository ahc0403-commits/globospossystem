import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../main.dart';
import '../admin/providers/menu_provider.dart';
import '../auth/auth_provider.dart';
import '../order/order_model.dart';
import '../order/order_provider.dart';
import '../table/table_model.dart';
import '../table/table_provider.dart';

final restaurantNameProvider = FutureProvider.family<String, String>((
  ref,
  restaurantId,
) async {
  final response = await supabase
      .from('restaurants')
      .select('name')
      .eq('id', restaurantId)
      .maybeSingle();
  return response?['name']?.toString() ?? 'Restaurant';
});

class WaiterScreen extends ConsumerStatefulWidget {
  const WaiterScreen({super.key});

  @override
  ConsumerState<WaiterScreen> createState() => _WaiterScreenState();
}

class _WaiterScreenState extends ConsumerState<WaiterScreen> {
  PosTable? _selectedTable;
  bool _showOrderPanel = false;
  String? _initializedRestaurantId;

  void _ensureRestaurantLoaded(String? restaurantId) {
    if (restaurantId == null || restaurantId == _initializedRestaurantId) {
      return;
    }
    _initializedRestaurantId = restaurantId;
    Future.microtask(() {
      ref.read(waiterTableProvider.notifier).loadTables(restaurantId);
      ref.read(orderProvider.notifier).clearSession();
    });
  }

  Future<void> _onSelectTable(PosTable table, String restaurantId) async {
    setState(() {
      _selectedTable = table;
      _showOrderPanel = true;
    });
    await ref.read(orderProvider.notifier).loadActiveOrder(table.id, restaurantId);
  }

  void _onCancelOrderPanel() {
    ref.read(orderProvider.notifier).clearCart();
    setState(() {
      _showOrderPanel = false;
      _selectedTable = null;
    });
  }

  PosTable? _resolveSelectedTable(List<PosTable> tables) {
    final selected = _selectedTable;
    if (selected == null) {
      return null;
    }
    for (final table in tables) {
      if (table.id == selected.id) {
        return table;
      }
    }
    return selected;
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final restaurantId = authState.restaurantId;

    _ensureRestaurantLoaded(restaurantId);

    final tableState = ref.watch(waiterTableProvider);
    final orderState = ref.watch(orderProvider);
    final menuState = restaurantId == null
        ? const MenuState()
        : ref.watch(menuProvider(restaurantId));
    final menuNotifier = restaurantId == null
        ? null
        : ref.read(menuProvider(restaurantId).notifier);
    final orderNotifier = ref.read(orderProvider.notifier);

    final selectedTable = _resolveSelectedTable(tableState.tables);

    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: Column(
        children: [
          _WaiterTopBar(restaurantId: restaurantId),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              transitionBuilder: (child, animation) {
                final curved = CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                );
                return SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.15, 0),
                    end: Offset.zero,
                  ).animate(curved),
                  child: child,
                );
              },
              child: _showOrderPanel && selectedTable != null
                  ? _OrderWorkspace(
                      key: ValueKey<String>('order-${selectedTable.id}'),
                      table: selectedTable,
                      menuState: menuState,
                      menuNotifier: menuNotifier,
                      orderState: orderState,
                      onAddToCart: orderNotifier.addToCart,
                      onIncrementCartItem: (cartItem) {
                        orderNotifier.addToCart(
                          cartItem.copyWith(quantity: 1),
                        );
                      },
                      onDecrementCartItem: orderNotifier.decrementCartItem,
                      onCancel: _onCancelOrderPanel,
                      onSendOrder: () async {
                        if (restaurantId == null) {
                          return;
                        }
                        if (orderState.activeOrder == null) {
                          await orderNotifier.submitOrder(
                            restaurantId,
                            selectedTable.id,
                          );
                        } else {
                          await orderNotifier.addMoreItems(
                            orderState.activeOrder!.id,
                            restaurantId,
                          );
                        }
                      },
                    )
                  : _TableGridView(
                      key: const ValueKey<String>('tables'),
                      state: tableState,
                      onRetry: () {
                        if (restaurantId != null) {
                          ref.read(waiterTableProvider.notifier).loadTables(restaurantId);
                        }
                      },
                      onTapTable: (table) {
                        if (restaurantId != null) {
                          _onSelectTable(table, restaurantId);
                        }
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WaiterTopBar extends ConsumerWidget {
  const _WaiterTopBar({required this.restaurantId});

  final String? restaurantId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final restaurantName = restaurantId == null
        ? const AsyncValue<String>.data('Restaurant')
        : ref.watch(restaurantNameProvider(restaurantId!));

    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: AppColors.surface0,
        border: Border(
          bottom: BorderSide(color: AppColors.surface2),
        ),
      ),
      child: Row(
        children: [
          Text(
            'GLOBOS POS',
            style: GoogleFonts.bebasNeue(
              color: AppColors.amber500,
              fontSize: 30,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Center(
              child: restaurantName.when(
                data: (name) => Text(
                  name,
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                loading: () => Text(
                  'Loading...',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
                error: (_, _) => Text(
                  'Restaurant',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: () => ref.read(authProvider.notifier).logout(),
            icon: const Icon(Icons.logout),
            color: AppColors.textPrimary,
          ),
        ],
      ),
    );
  }
}

class _TableGridView extends StatelessWidget {
  const _TableGridView({
    super.key,
    required this.state,
    required this.onRetry,
    required this.onTapTable,
  });

  final WaiterTableState state;
  final VoidCallback onRetry;
  final ValueChanged<PosTable> onTapTable;

  @override
  Widget build(BuildContext context) {
    if (state.isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.amber500),
      );
    }

    if (state.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              state.error!,
              style: GoogleFonts.notoSansKr(
                color: AppColors.statusCancelled,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (state.tables.isEmpty) {
      return Center(
        child: Text(
          'No tables found.',
          style: GoogleFonts.notoSansKr(
            color: AppColors.textSecondary,
            fontSize: 14,
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth < 1024 ? 3 : 4;

        return GridView.builder(
          padding: const EdgeInsets.all(20),
          itemCount: state.tables.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 1,
          ),
          itemBuilder: (context, index) {
            final table = state.tables[index];
            final isOccupied = table.isOccupied;

            return InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => onTapTable(table),
              child: Container(
                constraints: const BoxConstraints(minWidth: 120, minHeight: 120),
                decoration: BoxDecoration(
                  color: isOccupied
                      ? AppColors.surface1.withValues(alpha: 0.95)
                      : AppColors.surface1,
                  borderRadius: BorderRadius.circular(16),
                  border: Border(
                    left: isOccupied
                        ? const BorderSide(color: AppColors.amber500, width: 4)
                        : const BorderSide(color: AppColors.surface2, width: 1),
                    top: isOccupied
                        ? BorderSide(color: AppColors.statusOccupied.withValues(alpha: 0.4))
                        : BorderSide.none,
                    right: isOccupied
                        ? BorderSide(color: AppColors.statusOccupied.withValues(alpha: 0.4))
                        : BorderSide.none,
                    bottom: isOccupied
                        ? BorderSide(color: AppColors.statusOccupied.withValues(alpha: 0.4))
                        : BorderSide.none,
                  ),
                  gradient: isOccupied
                      ? LinearGradient(
                          colors: [
                            AppColors.statusOccupied.withValues(alpha: 0.22),
                            AppColors.surface1,
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        )
                      : null,
                ),
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    const Spacer(),
                    Text(
                      table.tableNumber,
                      style: GoogleFonts.bebasNeue(
                        color: AppColors.textPrimary,
                        fontSize: 40,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${table.seatCount ?? 0} seats',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    const Spacer(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: isOccupied
                                ? AppColors.statusOccupied
                                : AppColors.statusAvailable,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isOccupied ? 'Occupied' : 'Available',
                          style: GoogleFonts.notoSansKr(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _OrderWorkspace extends StatelessWidget {
  const _OrderWorkspace({
    super.key,
    required this.table,
    required this.menuState,
    required this.menuNotifier,
    required this.orderState,
    required this.onAddToCart,
    required this.onIncrementCartItem,
    required this.onDecrementCartItem,
    required this.onCancel,
    required this.onSendOrder,
  });

  final PosTable table;
  final MenuState menuState;
  final MenuNotifier? menuNotifier;
  final OrderState orderState;
  final ValueChanged<CartItem> onAddToCart;
  final ValueChanged<CartItem> onIncrementCartItem;
  final ValueChanged<String> onDecrementCartItem;
  final VoidCallback onCancel;
  final Future<void> Function() onSendOrder;

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = menuState.categories;
    final itemsAsync = menuState.items;
    final menuLoading = categoriesAsync.isLoading || itemsAsync.isLoading;
    final menuError = categoriesAsync.hasError || itemsAsync.hasError;

    final categories = categoriesAsync.valueOrNull ?? const <Map<String, dynamic>>[];
    final items = itemsAsync.valueOrNull ?? const <Map<String, dynamic>>[];
    final selectedCategoryId = menuState.selectedCategoryId;

    final filteredItems = selectedCategoryId == null
        ? const <Map<String, dynamic>>[]
        : items.where((item) {
            final matchesCategory = item['category_id']?.toString() == selectedCategoryId;
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
                  onSelectCategory: (categoryId) => menuNotifier?.selectCategory(categoryId),
                  onAddItem: onAddToCart,
                ),
              ),
              Expanded(
                flex: 4,
                child: _CurrentOrderPanel(
                  table: table,
                  state: orderState,
                  onIncrementCartItem: onIncrementCartItem,
                  onDecrementCartItem: onDecrementCartItem,
                  onCancel: onCancel,
                  onSendOrder: onSendOrder,
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
                onSelectCategory: (categoryId) => menuNotifier?.selectCategory(categoryId),
                onAddItem: onAddToCart,
              ),
            ),
            Expanded(
              flex: 4,
              child: _CurrentOrderPanel(
                table: table,
                state: orderState,
                onIncrementCartItem: onIncrementCartItem,
                onDecrementCartItem: onDecrementCartItem,
                onCancel: onCancel,
                onSendOrder: onSendOrder,
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
                        onTap: categoryId.isEmpty ? null : () => onSelectCategory(categoryId),
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          decoration: BoxDecoration(
                            color: selected ? AppColors.amber500 : AppColors.surface1,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: selected ? AppColors.amber500 : AppColors.surface2,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            category['name']?.toString() ?? '-',
                            style: GoogleFonts.notoSansKr(
                              color: selected ? AppColors.surface0 : AppColors.textPrimary,
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
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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

class _CurrentOrderPanel extends StatelessWidget {
  const _CurrentOrderPanel({
    required this.table,
    required this.state,
    required this.onIncrementCartItem,
    required this.onDecrementCartItem,
    required this.onCancel,
    required this.onSendOrder,
  });

  final PosTable table;
  final OrderState state;
  final ValueChanged<CartItem> onIncrementCartItem;
  final ValueChanged<String> onDecrementCartItem;
  final VoidCallback onCancel;
  final Future<void> Function() onSendOrder;

  @override
  Widget build(BuildContext context) {
    final formatter = NumberFormat('#,###', 'vi_VN');
    final total = state.cart.fold<double>(
      0,
      (sum, item) => sum + (item.price * item.quantity),
    );

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
                'Table ${table.tableNumber}',
                style: GoogleFonts.bebasNeue(
                  color: AppColors.amber500,
                  fontSize: 36,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              if (state.activeOrder != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
            ],
          ),
          const SizedBox(height: 10),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                state.error!,
                style: GoogleFonts.notoSansKr(
                  color: AppColors.statusCancelled,
                  fontSize: 13,
                ),
              ),
            ),
          Expanded(
            child: ListView(
              children: [
                if (state.activeOrder != null && state.activeOrder!.items.isNotEmpty) ...[
                  Text(
                    'Already Sent',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...state.activeOrder!.items.map((item) {
                    final label = item.label ?? 'Item';
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.surface2,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$label x${item.quantity}',
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
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
                if (state.cart.isEmpty)
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
                ...state.cart.map((item) {
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
                              onPressed: () => onDecrementCartItem(item.menuItemId),
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
                              onPressed: () => onIncrementCartItem(item),
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
                    onPressed: onCancel,
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
                    onPressed: state.isSubmitting || state.cart.isEmpty ? null : onSendOrder,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.amber500,
                      foregroundColor: AppColors.surface0,
                      disabledBackgroundColor: AppColors.amber500.withValues(alpha: 0.4),
                      disabledForegroundColor: AppColors.surface0.withValues(alpha: 0.8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: state.isSubmitting
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
        ],
      ),
    );
  }
}
