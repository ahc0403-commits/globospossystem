import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../main.dart';
import '../../../widgets/error_toast.dart';
import '../../../widgets/order_workspace.dart';
import '../../auth/auth_provider.dart';
import '../../order/order_provider.dart';
import '../../payment/payment_provider.dart';
import '../../table/table_model.dart';
import '../providers/menu_provider.dart';
import '../providers/tables_provider.dart';

class TablesTab extends ConsumerStatefulWidget {
  const TablesTab({super.key});

  @override
  ConsumerState<TablesTab> createState() => _TablesTabState();
}

class _TablesTabState extends ConsumerState<TablesTab> {
  PosTable? _selectedTable;
  bool _showOrderPanel = false;
  String? _initializedRestaurantId;
  String? _lastOrderError;
  String? _lastPaymentError;

  void _ensureLoaded(String? restaurantId) {
    if (restaurantId == null || _initializedRestaurantId == restaurantId) {
      return;
    }
    _initializedRestaurantId = restaurantId;
    Future.microtask(() {
      ref.read(tablesProvider(restaurantId).notifier).fetchTables();
      ref.read(orderProvider.notifier).clearSession();
      ref.read(paymentProvider.notifier).loadOrders(restaurantId);
    });
  }

  Future<void> _onTapTable(Map<String, dynamic> table, String restaurantId) async {
    final tableId = table['id']?.toString() ?? '';
    final tableNumber = table['table_number']?.toString() ?? '-';
    if (tableId.isEmpty) {
      return;
    }

    setState(() {
      _selectedTable = PosTable(
        id: tableId,
        restaurantId: restaurantId,
        tableNumber: tableNumber,
        seatCount: int.tryParse(table['seat_count']?.toString() ?? '0') ?? 0,
        status: table['status']?.toString().toLowerCase() ?? 'available',
      );
      _showOrderPanel = true;
    });

    await ref.read(orderProvider.notifier).loadActiveOrder(tableId, restaurantId);
  }

  void _closeOrderPanel() {
    ref.read(orderProvider.notifier).clearCart();
    setState(() {
      _showOrderPanel = false;
      _selectedTable = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final restaurantId = ref.watch(authProvider).restaurantId;
    _ensureLoaded(restaurantId);

    if (restaurantId == null) {
      return const _RestaurantMissingView();
    }

    final tablesState = ref.watch(tablesProvider(restaurantId));
    final tablesNotifier = ref.read(tablesProvider(restaurantId).notifier);
    final menuState = ref.watch(menuProvider(restaurantId));
    final menuNotifier = ref.read(menuProvider(restaurantId).notifier);
    final orderState = ref.watch(orderProvider);
    final orderNotifier = ref.read(orderProvider.notifier);
    final paymentState = ref.watch(paymentProvider);
    final paymentNotifier = ref.read(paymentProvider.notifier);

    if (orderState.error != null &&
        orderState.error!.isNotEmpty &&
        orderState.error != _lastOrderError) {
      _lastOrderError = orderState.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showErrorToast(context, orderState.error!);
        }
      });
    }
    if (paymentState.error != null &&
        paymentState.error!.isNotEmpty &&
        paymentState.error != _lastPaymentError) {
      _lastPaymentError = paymentState.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showErrorToast(context, paymentState.error!);
        }
      });
    }

    final selectedTable = _resolveSelectedTable(tablesState.tables);

    return Scaffold(
      backgroundColor: AppColors.surface0,
      floatingActionButton: _showOrderPanel
          ? null
          : FloatingActionButton(
              backgroundColor: AppColors.amber500,
              onPressed: () => _showAddTableDialog(context, tablesNotifier),
              child: const Icon(Icons.add, color: AppColors.surface0),
            ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: _showOrderPanel && selectedTable != null
            ? Row(
                key: ValueKey<String>('admin-order-${selectedTable.id}'),
                children: [
                  Expanded(
                    flex: 5,
                    child: _buildTableGrid(
                      tablesState: tablesState,
                      tablesNotifier: tablesNotifier,
                      restaurantId: restaurantId,
                    ),
                  ),
                  Expanded(
                    flex: 6,
                    child: OrderWorkspace(
                      table: selectedTable,
                      guestCount: null,
                      menuState: menuState,
                      menuNotifier: menuNotifier,
                      orderState: orderState,
                      allowSubmitWithoutCart: false,
                      onAddToCart: orderNotifier.addToCart,
                      onIncrementCartItem: (cartItem) {
                        orderNotifier.addToCart(cartItem.copyWith(quantity: 1));
                      },
                      onDecrementCartItem: orderNotifier.decrementCartItem,
                      onCancel: _closeOrderPanel,
                      onCancelOrder: () async {
                        final activeOrder = orderState.activeOrder;
                        if (activeOrder == null) return;
                        await orderNotifier.cancelOrder(activeOrder.id, restaurantId);
                        await tablesNotifier.fetchTables();
                        final next = ref.read(orderProvider);
                        if (!context.mounted) return;
                        if (next.error == null) {
                          showSuccessToast(context, '주문이 취소되었습니다');
                          _closeOrderPanel();
                        }
                      },
                      onSendOrder: () async {
                        if (orderState.activeOrder == null) {
                          await orderNotifier.submitOrder(restaurantId, selectedTable.id);
                        } else {
                          await orderNotifier.addMoreItems(
                            orderState.activeOrder!.id,
                            restaurantId,
                          );
                        }
                        await tablesNotifier.fetchTables();
                      },
                      canManageSentItems: true,
                      onCycleSentItemStatus: (item, nextStatus) async {
                        await orderNotifier.updateOrderItemStatus(
                          item.id,
                          nextStatus,
                          restaurantId,
                          selectedTable.id,
                        );
                        await tablesNotifier.fetchTables();
                      },
                      showPaymentActions: true,
                      isProcessingPayment: paymentState.isProcessing,
                      onProcessPayment: (method) async {
                        final activeOrder = orderState.activeOrder;
                        if (activeOrder == null) return;
                        final amount = activeOrder.items.fold<double>(
                          0,
                          (sum, item) => sum + (item.unitPrice * item.quantity),
                        );
                        await paymentNotifier.processPayment(
                          restaurantId,
                          activeOrder.id,
                          amount,
                          method,
                        );
                        final next = ref.read(paymentProvider);
                        if (next.error == null) {
                          await tablesNotifier.fetchTables();
                          if (context.mounted) {
                            showSuccessToast(context, '결제가 완료되었습니다');
                          }
                          _closeOrderPanel();
                        }
                      },
                    ),
                  ),
                ],
              )
            : _buildTableGrid(
                key: const ValueKey<String>('admin-table-grid'),
                tablesState: tablesState,
                tablesNotifier: tablesNotifier,
                restaurantId: restaurantId,
              ),
      ),
    );
  }

  PosTable? _resolveSelectedTable(List<Map<String, dynamic>> tables) {
    final selected = _selectedTable;
    if (selected == null) return null;

    for (final table in tables) {
      final id = table['id']?.toString() ?? '';
      if (id != selected.id) continue;
      return PosTable(
        id: id,
        restaurantId: selected.restaurantId,
        tableNumber: table['table_number']?.toString() ?? selected.tableNumber,
        seatCount:
            int.tryParse(table['seat_count']?.toString() ?? '') ?? selected.seatCount,
        status: table['status']?.toString().toLowerCase() ?? selected.status,
      );
    }
    return selected;
  }

  Widget _buildTableGrid({
    Key? key,
    required TablesState tablesState,
    required TablesNotifier tablesNotifier,
    required String restaurantId,
  }) {
    if (tablesState.isLoading && tablesState.tables.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.amber500),
      );
    }

    if (tablesState.error != null && tablesState.tables.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Failed to load tables.',
              style: GoogleFonts.notoSansKr(
                color: AppColors.statusCancelled,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: tablesNotifier.fetchTables,
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

    if (tablesState.tables.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.table_restaurant,
              size: 48,
              color: AppColors.textSecondary,
            ),
            const SizedBox(height: 12),
            Text(
              'No tables yet. Add your first table.',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      key: key,
      padding: const EdgeInsets.all(16),
      itemCount: tablesState.tables.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.25,
      ),
      itemBuilder: (context, index) {
        final table = tablesState.tables[index];
        final tableId = table['id']?.toString() ?? '';
        final tableNumber = table['table_number']?.toString() ?? '-';
        final seatCount = table['seat_count']?.toString() ?? '0';
        final occupied = _isOccupied(table);
        final summary = tablesState.activeOrderSummaryByTableId[tableId];

        return InkWell(
          onTap: () => _onTapTable(table, restaurantId),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.surface1,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _selectedTable?.id == tableId
                    ? AppColors.amber500
                    : AppColors.surface2,
                width: _selectedTable?.id == tableId ? 1.5 : 1,
              ),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: InkWell(
                    onTap: tableId.isEmpty
                        ? null
                        : () => tablesNotifier.deleteTable(tableId),
                    child: const Icon(
                      Icons.delete_outline,
                      color: AppColors.textSecondary,
                      size: 18,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  tableNumber,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.bebasNeue(
                    color: AppColors.amber500,
                    fontSize: 32,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$seatCount seats',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
                if (summary != null)
                  Text(
                    '🍽 ${summary.itemCount}개 메뉴 · ${summary.elapsedMinutes}분 전',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.statusOccupied,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: occupied
                            ? AppColors.statusOccupied
                            : AppColors.statusAvailable,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      occupied ? 'Occupied' : 'Available',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showAddTableDialog(
    BuildContext context,
    TablesNotifier tablesNotifier,
  ) async {
    final tableController = TextEditingController();
    final seatController = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface1,
          title: Text(
            'Add Table',
            style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: tableController,
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                decoration: const InputDecoration(labelText: 'Table number'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: seatController,
                keyboardType: TextInputType.number,
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                decoration: const InputDecoration(labelText: 'Seat count'),
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
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              onPressed: () async {
                final tableNumber = tableController.text.trim();
                final seatCount = int.tryParse(seatController.text.trim());
                if (tableNumber.isEmpty || seatCount == null || seatCount <= 0) {
                  return;
                }

                await tablesNotifier.addTable(tableNumber, seatCount);
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: const Text('Add'),
            ),
          ],
        );
      },
    );

    tableController.dispose();
    seatController.dispose();
  }

  bool _isOccupied(Map<String, dynamic> table) {
    final status = table['status']?.toString().toLowerCase();
    final isOccupied = table['is_occupied'];

    if (isOccupied is bool) {
      return isOccupied;
    }

    return status == 'occupied';
  }
}

class _RestaurantMissingView extends StatelessWidget {
  const _RestaurantMissingView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: Center(
        child: Text(
          'Restaurant not found for this account.',
          style: GoogleFonts.notoSansKr(
            color: AppColors.statusCancelled,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
