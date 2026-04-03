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
  restaurantId,
) async {
  final response = await supabase
      .from('restaurants')
      .select('name')
      .eq('id', restaurantId)
      .maybeSingle();
  return response?['name']?.toString() ?? 'Restaurant';
});

class RestaurantSettings {
  const RestaurantSettings({
    required this.operationMode,
    required this.perPersonCharge,
  });

  final String operationMode;
  final double? perPersonCharge;
}

final restaurantSettingsProvider =
    FutureProvider.family<RestaurantSettings, String>((
      ref,
      restaurantId,
    ) async {
      final response = await supabase
          .from('restaurants')
          .select('operation_mode, per_person_charge')
          .eq('id', restaurantId)
          .single();

      final mode =
          response['operation_mode']?.toString().toLowerCase() ?? 'standard';
      final rawCharge = response['per_person_charge'];
      final charge = switch (rawCharge) {
        num value => value.toDouble(),
        String value => double.tryParse(value),
        _ => null,
      };

      return RestaurantSettings(operationMode: mode, perPersonCharge: charge);
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

  Future<void> _onSelectTable(
    PosTable table,
    String restaurantId,
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
        .loadActiveOrder(table.id, restaurantId);
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
          '주문을 취소하시겠습니까?',
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          'T$tableNumber 주문이 취소되고 테이블이 비워집니다.',
          style: GoogleFonts.notoSansKr(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('돌아가기'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.statusCancelled,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.cancel),
            label: const Text('주문 취소'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showOrderCancelledSnackBar() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '주문이 취소되었습니다',
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
    final restaurantId = authState.restaurantId;

    _ensureRestaurantLoaded(restaurantId);

    final tableState = ref.watch(waiterTableProvider);
    final orderState = ref.watch(orderProvider);
    final restaurantSettings = restaurantId == null
        ? const AsyncValue<RestaurantSettings>.data(
            RestaurantSettings(
              operationMode: 'standard',
              perPersonCharge: null,
            ),
          )
        : ref.watch(restaurantSettingsProvider(restaurantId));
    final menuState = restaurantId == null
        ? const MenuState()
        : ref.watch(menuProvider(restaurantId));
    final menuNotifier = restaurantId == null
        ? null
        : ref.read(menuProvider(restaurantId).notifier);
    final orderNotifier = ref.read(orderProvider.notifier);

    final selectedTable = _resolveSelectedTable(tableState.tables);
    final operationMode =
        restaurantSettings.valueOrNull?.operationMode.toLowerCase() ??
        'standard';
    final isBuffetMode = operationMode == 'buffet' || operationMode == 'hybrid';
    final allowSubmitWithoutCart =
        isBuffetMode && orderState.activeOrder == null;

    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: Column(
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
                            onCancelOrder: () async {
                              final activeOrder = orderState.activeOrder;
                              if (restaurantId == null || activeOrder == null) {
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
                                restaurantId,
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
                              if (restaurantId == null) {
                                return;
                              }
                              if (orderState.activeOrder == null) {
                                if (isBuffetMode) {
                                  await orderNotifier.submitBuffetOrder(
                                    restaurantId,
                                    selectedTable.id,
                                    _selectedGuestCount ?? 1,
                                  );
                                } else {
                                  await orderNotifier.submitOrder(
                                    restaurantId,
                                    selectedTable.id,
                                  );
                                }
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
                                ref
                                    .read(waiterTableProvider.notifier)
                                    .loadTables(restaurantId);
                              }
                            },
                            onTapTable: (table) {
                              if (restaurantId != null) {
                                _onSelectTable(
                                  table,
                                  restaurantId,
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
