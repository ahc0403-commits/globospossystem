import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../main.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/error_toast.dart';
import '../../widgets/offline_banner.dart';
import '../../widgets/order_workspace.dart';
import '../admin/providers/menu_provider.dart';
import '../auth/auth_provider.dart';
import '../order/order_provider.dart';
import '../table/table_model.dart';
import '../table/table_provider.dart';

final restaurantNameProvider = FutureProvider.family<String, String>((
  ref,
  storeId,
) async {
  final response = await supabase
      .from('restaurants')
      .select('name')
      .eq('id', storeId)
      .maybeSingle();
  return response?['name']?.toString() ?? 'Store';
});

class StoreSettings {
  const StoreSettings({
    required this.operationMode,
    required this.perPersonCharge,
  });

  final String operationMode;
  final double? perPersonCharge;
}

final restaurantSettingsProvider =
    FutureProvider.family<StoreSettings, String>((
      ref,
      storeId,
    ) async {
      final response = await supabase
          .from('restaurants')
          .select('operation_mode, per_person_charge')
          .eq('id', storeId)
          .single();

      final mode =
          response['operation_mode']?.toString().toLowerCase() ?? 'standard';
      final rawCharge = response['per_person_charge'];
      final charge = switch (rawCharge) {
        num value => value.toDouble(),
        String value => double.tryParse(value),
        _ => null,
      };

      return StoreSettings(operationMode: mode, perPersonCharge: charge);
    });

class WaiterScreen extends ConsumerStatefulWidget {
  const WaiterScreen({super.key});

  @override
  ConsumerState<WaiterScreen> createState() => _WaiterScreenState();
}

class _WaiterScreenState extends ConsumerState<WaiterScreen> {
  PosTable? _selectedTable;
  int? _selectedGuestCount;
  bool _showOrderPanel = false;
  int _orderPanelNonce = 0;
  String? _initializedRestaurantId;
  String? _lastOrderError;
  late final ProviderSubscription<OrderState> _orderSub;

  @override
  void initState() {
    super.initState();
    _orderSub = ref.listenManual<OrderState>(orderProvider, (previous, next) {
      final error = next.error;
      if (error != null && error.isNotEmpty && error != _lastOrderError) {
        _lastOrderError = error;
        if (mounted) {
          showErrorToast(context, error);
        }
      }
    });
  }

  void _ensureRestaurantLoaded(String? storeId) {
    if (storeId == null || storeId == _initializedRestaurantId) {
      return;
    }
    _initializedRestaurantId = storeId;
    Future.microtask(() {
      ref.read(waiterTableProvider.notifier).loadTables(storeId);
      ref.read(orderProvider.notifier).clearSession();
    });
  }

  Future<void> _onSelectTable(
    PosTable table,
    String storeId,
    bool requireGuestCount,
  ) async {
    int? guestCount;
    if (requireGuestCount) {
      guestCount = await _showGuestCountDialog();
      if (guestCount == null) {
        return;
      }
    }

    setState(() {
      _selectedTable = table;
      _selectedGuestCount = guestCount;
      _showOrderPanel = true;
      _orderPanelNonce = DateTime.now().millisecondsSinceEpoch;
    });
    await ref
        .read(orderProvider.notifier)
        .loadActiveOrder(table.id, storeId);
  }

  void _onCancelOrderPanel() {
    ref.read(orderProvider.notifier).clearCart();
    setState(() {
      _showOrderPanel = false;
      _selectedTable = null;
      _selectedGuestCount = null;
    });
  }

  Future<int?> _showGuestCountDialog() async {
    final controller = TextEditingController(
      text: _selectedGuestCount?.toString() ?? '',
    );
    final result = await showDialog<int>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface1,
          title: Text(
            'How many guests?',
            style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
          ),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
            decoration: const InputDecoration(labelText: 'Guest count'),
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
              onPressed: () {
                final guestCount = int.tryParse(controller.text.trim());
                if (guestCount == null || guestCount < 1) {
                  return;
                }
                Navigator.of(context).pop(guestCount);
              },
              child: const Text('Confirm'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return result;
  }

  Future<bool> _showCancelOrderDialog({required String tableNumber}) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Text(
          'Cancel this order?',
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          'Table T$tableNumber order will be cancelled and the table cleared.',
          style: GoogleFonts.notoSansKr(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Back'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.statusCancelled,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.cancel),
            label: const Text('Cancel Order'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<PosTable?> _showTransferTableDialog(String storeId) async {
    final tableState = ref.read(waiterTableProvider);
    final currentTableId = _selectedTable?.id;
    final availableTables = tableState.tables
        .where((t) => t.id != currentTableId && !t.isOccupied)
        .toList();

    if (availableTables.isEmpty) {
      if (mounted) {
        showErrorToast(context, 'No empty tables available to move to.');
      }
      return null;
    }

    return showDialog<PosTable>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Text(
          'Move Table',
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: SizedBox(
          width: 280,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: availableTables.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final table = availableTables[index];
              return ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                tileColor: AppColors.surface2,
                title: Text(
                  'Table ${table.tableNumber}',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  '${table.seatCount ?? 0} seats',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                onTap: () => Navigator.of(context).pop(table),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _showOrderCancelledSnackBar() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Order cancelled',
          style: GoogleFonts.notoSansKr(color: Colors.white, fontSize: 14),
        ),
        backgroundColor: AppColors.statusOccupied,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  void dispose() {
    _orderSub.close();
    super.dispose();
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
    final storeId = authState.storeId;

    _ensureRestaurantLoaded(storeId);

    final tableState = ref.watch(waiterTableProvider);
    final orderState = ref.watch(orderProvider);
    final restaurantSettings = storeId == null
        ? const AsyncValue<StoreSettings>.data(
            StoreSettings(
              operationMode: 'standard',
              perPersonCharge: null,
            ),
          )
        : ref.watch(restaurantSettingsProvider(storeId));
    final menuState = storeId == null
        ? const MenuState()
        : ref.watch(menuProvider(storeId));
    final menuNotifier = storeId == null
        ? null
        : ref.read(menuProvider(storeId).notifier);
    final orderNotifier = ref.read(orderProvider.notifier);

    final selectedTable = _resolveSelectedTable(tableState.tables);
    final operationMode =
        restaurantSettings.valueOrNull?.operationMode.toLowerCase() ??
        'standard';
    final isBuffetMode = operationMode == 'buffet' || operationMode == 'hybrid';
    final allowSubmitWithoutCart =
        isBuffetMode && orderState.activeOrder == null;

    return Scaffold(
      key: const Key('dashboard_root'),
      backgroundColor: AppColors.surface0,
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: Column(
              children: [
                _WaiterTopBar(storeId: storeId),
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
                        ? OrderWorkspace(
                            key: ValueKey<String>(
                              'order-${selectedTable.id}-$_orderPanelNonce',
                            ),
                            table: selectedTable,
                            guestCount: _selectedGuestCount,
                            menuState: menuState,
                            menuNotifier: menuNotifier,
                            orderState: orderState,
                            allowSubmitWithoutCart: allowSubmitWithoutCart,
                            onAddToCart: orderNotifier.addToCart,
                            onIncrementCartItem: (cartItem) {
                              orderNotifier.addToCart(
                                cartItem.copyWith(quantity: 1),
                              );
                            },
                            onDecrementCartItem:
                                orderNotifier.decrementCartItem,
                            onCancel: _onCancelOrderPanel,
                            onCancelOrderItem: storeId == null
                                ? null
                                : (itemId) => orderNotifier.cancelOrderItem(
                                      itemId,
                                      storeId,
                                    ),
                            onEditOrderItemQuantity: storeId == null
                                ? null
                                : (itemId, qty) =>
                                    orderNotifier.editOrderItemQuantity(
                                      itemId,
                                      storeId,
                                      qty,
                                    ),
                            onTransferTable: storeId == null ||
                                    orderState.activeOrder == null
                                ? null
                                : () async {
                                    final newTable =
                                        await _showTransferTableDialog(
                                          storeId,
                                        );
                                    if (newTable == null) return;
                                    await orderNotifier.transferOrderTable(
                                      orderState.activeOrder!.id,
                                      storeId,
                                      newTable.id,
                                    );
                                    ref
                                        .read(waiterTableProvider.notifier)
                                        .loadTables(storeId);
                                    if (!mounted) return;
                                    setState(() {
                                      _selectedTable = newTable;
                                    });
                                  },
                            onCancelOrder: () async {
                              final activeOrder = orderState.activeOrder;
                              if (storeId == null || activeOrder == null) {
                                return;
                              }
                              final confirmed = await _showCancelOrderDialog(
                                tableNumber: selectedTable.tableNumber,
                              );
                              if (!confirmed) {
                                return;
                              }

                              await orderNotifier.cancelOrder(
                                activeOrder.id,
                                storeId,
                              );
                              final nextState = ref.read(orderProvider);
                              if (!mounted) {
                                return;
                              }
                              if (nextState.error == null) {
                                _onCancelOrderPanel();
                                _showOrderCancelledSnackBar();
                              }
                            },
                            onSendOrder: () async {
                              if (storeId == null) {
                                return;
                              }
                              if (orderState.activeOrder == null) {
                                if (isBuffetMode) {
                                  await orderNotifier.submitBuffetOrder(
                                    storeId,
                                    selectedTable.id,
                                    _selectedGuestCount ?? 1,
                                  );
                                } else {
                                  await orderNotifier.submitOrder(
                                    storeId,
                                    selectedTable.id,
                                  );
                                }
                              } else {
                                await orderNotifier.addMoreItems(
                                  orderState.activeOrder!.id,
                                  storeId,
                                );
                              }
                            },
                          )
                        : _TableGridView(
                            key: const Key('tables_root'),
                            state: tableState,
                            onRetry: () {
                              if (storeId != null) {
                                ref
                                    .read(waiterTableProvider.notifier)
                                    .loadTables(storeId);
                              }
                            },
                            onTapTable: (table) {
                              if (storeId != null) {
                                _onSelectTable(
                                  table,
                                  storeId,
                                  isBuffetMode,
                                );
                              }
                            },
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

class _WaiterTopBar extends ConsumerWidget {
  const _WaiterTopBar({required this.storeId});

  final String? storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final restaurantName = storeId == null
        ? const AsyncValue<String>.data('Store')
        : ref.watch(restaurantNameProvider(storeId!));

    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: AppColors.surface0,
        border: Border(bottom: BorderSide(color: AppColors.surface2)),
      ),
      child: Row(
        children: [
          const AppNavBar(),
          const SizedBox(width: 12),
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
                  'Store',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            key: const Key('logout_button'),
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
              key: index == 0 ? const Key('table_first_card') : null,
              borderRadius: BorderRadius.circular(16),
              onTap: () => onTapTable(table),
              child: Container(
                constraints: const BoxConstraints(
                  minWidth: 120,
                  minHeight: 120,
                ),
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
                        ? BorderSide(
                            color: AppColors.statusOccupied.withValues(
                              alpha: 0.4,
                            ),
                          )
                        : BorderSide.none,
                    right: isOccupied
                        ? BorderSide(
                            color: AppColors.statusOccupied.withValues(
                              alpha: 0.4,
                            ),
                          )
                        : BorderSide.none,
                    bottom: isOccupied
                        ? BorderSide(
                            color: AppColors.statusOccupied.withValues(
                              alpha: 0.4,
                            ),
                          )
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
