import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/utils/number_input_utils.dart';
import '../../main.dart';
import '../../core/ui/toast/toast.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/error_toast.dart';
import '../../widgets/offline_banner.dart';
import '../../widgets/order_workspace.dart';
import '../admin/providers/menu_provider.dart';
import '../auth/auth_provider.dart';
import '../order/order_provider.dart';
import '../table/floor_layout.dart';
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
  return response?['name']?.toString() ?? '';
});

class StoreSettings {
  const StoreSettings({
    required this.operationMode,
    required this.perPersonCharge,
  });

  final String operationMode;
  final double? perPersonCharge;
}

final restaurantSettingsProvider = FutureProvider.family<StoreSettings, String>(
  (ref, storeId) async {
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
      String value => parseDecimalInput(value),
      _ => null,
    };

    return StoreSettings(operationMode: mode, perPersonCharge: charge);
  },
);

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
    if (table.isReserved) {
      showErrorToast(
        context,
        context.l10n.waiterTableReservedUnavailable(table.tableNumber),
      );
      return;
    }

    int? guestCount;
    if (requireGuestCount) {
      guestCount = await _showGuestCountDialog();
      if (guestCount == null) {
        return;
      }
    }

    final selectingDifferentTable = _selectedTable?.id != table.id;
    if (selectingDifferentTable) {
      ref.read(orderProvider.notifier).clearSession();
    }

    setState(() {
      _selectedTable = table;
      _selectedGuestCount = guestCount;
      _showOrderPanel = true;
      _orderPanelNonce = DateTime.now().millisecondsSinceEpoch;
    });
    await ref.read(orderProvider.notifier).loadActiveOrder(table.id, storeId);
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
    final l10n = context.l10n;
    final controller = TextEditingController(
      text: _selectedGuestCount?.toString() ?? '',
    );
    final result = await showDialog<int>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface1,
          title: Text(
            l10n.waiterGuestCountTitle,
            style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
          ),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
            decoration: InputDecoration(labelText: l10n.waiterGuestCountField),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              onPressed: () {
                final guestCount = parseIntInput(controller.text);
                if (guestCount == null || guestCount < 1) {
                  return;
                }
                Navigator.of(context).pop(guestCount);
              },
              child: Text(l10n.confirm),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return result;
  }

  Future<bool> _showCancelOrderDialog({required String tableNumber}) async {
    final l10n = context.l10n;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Text(
          l10n.waiterCancelOrderTitle,
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          l10n.waiterCancelOrderMessage(tableNumber),
          style: GoogleFonts.notoSansKr(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.waiterBack),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.statusCancelled,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.cancel),
            label: Text(l10n.waiterCancelOrderAction),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<PosTable?> _showTransferTableDialog(String storeId) async {
    final l10n = context.l10n;
    final tableState = ref.read(waiterTableProvider);
    final currentTableId = _selectedTable?.id;
    final availableTables = tableState.tables
        .where((t) => t.id != currentTableId && t.isAvailable)
        .toList();

    if (availableTables.isEmpty) {
      if (mounted) {
        showErrorToast(context, l10n.waiterNoEmptyTables);
      }
      return null;
    }

    return showDialog<PosTable>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Text(
          l10n.waiterMoveTableTitle,
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
                  l10n.waiterTableLabel(table.tableNumber),
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  l10n.waiterSeatCount(table.seatCount ?? 0),
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
            child: Text(l10n.cancel),
          ),
        ],
      ),
    );
  }

  void _showOrderCancelledSnackBar() {
    final l10n = context.l10n;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          l10n.waiterOrderCancelled,
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

  Widget _buildOrderWorkspace({
    required String? storeId,
    required PosTable selectedTable,
    required MenuState menuState,
    required MenuNotifier? menuNotifier,
    required OrderState orderState,
    required bool allowSubmitWithoutCart,
    required bool isBuffetMode,
  }) {
    final orderNotifier = ref.read(orderProvider.notifier);
    final l10n = context.l10n;

    return OrderWorkspace(
      key: ValueKey<String>('order-${selectedTable.id}-$_orderPanelNonce'),
      table: selectedTable,
      guestCount: _selectedGuestCount,
      menuState: menuState,
      menuNotifier: menuNotifier,
      orderState: orderState,
      allowSubmitWithoutCart: allowSubmitWithoutCart,
      onAddToCart: orderNotifier.addToCart,
      onIncrementCartItem: (cartItem) {
        orderNotifier.addToCart(cartItem.copyWith(quantity: 1));
      },
      onDecrementCartItem: orderNotifier.decrementCartItem,
      onCancel: _onCancelOrderPanel,
      onCancelOrderItem: storeId == null
          ? null
          : (itemId) async {
              await orderNotifier.cancelOrderItem(itemId, storeId);
              if (!mounted) {
                return;
              }
              await ref.read(waiterTableProvider.notifier).loadTables(storeId);
            },
      onEditOrderItemQuantity: storeId == null
          ? null
          : (itemId, qty) async {
              await orderNotifier.editOrderItemQuantity(itemId, storeId, qty);
              if (!mounted) {
                return;
              }
              await ref.read(waiterTableProvider.notifier).loadTables(storeId);
            },
      onTransferTable: storeId == null || orderState.activeOrder == null
          ? null
          : () async {
              final newTable = await _showTransferTableDialog(storeId);
              if (newTable == null) return;
              await orderNotifier.transferOrderTable(
                orderState.activeOrder!.id,
                storeId,
                newTable.id,
              );
              ref.read(waiterTableProvider.notifier).loadTables(storeId);
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

        await orderNotifier.cancelOrder(activeOrder.id, storeId);
        final nextState = ref.read(orderProvider);
        if (!mounted) {
          return;
        }
        if (nextState.error == null) {
          await ref.read(waiterTableProvider.notifier).loadTables(storeId);
          if (!mounted) {
            return;
          }
          _onCancelOrderPanel();
          _showOrderCancelledSnackBar();
        }
      },
      onSendOrder: () async {
        if (storeId == null) {
          showErrorToast(context, l10n.orderWorkspaceMenuOfflineTitle);
          return;
        }
        final latestOrderState = ref.read(orderProvider);
        if (!allowSubmitWithoutCart && latestOrderState.cart.isEmpty) {
          showErrorToast(context, l10n.orderWorkspaceNoItemsAdded);
          return;
        }

        final activeOrder = latestOrderState.activeOrder;
        if (activeOrder == null) {
          if (isBuffetMode) {
            await orderNotifier.submitBuffetOrder(
              storeId,
              selectedTable.id,
              _selectedGuestCount ?? 1,
            );
          } else {
            await orderNotifier.submitOrder(storeId, selectedTable.id);
          }
        } else {
          await orderNotifier.addMoreItems(activeOrder.id, storeId);
        }
        if (!mounted) {
          return;
        }
        if (ref.read(orderProvider).error == null) {
          await ref.read(waiterTableProvider.notifier).loadTables(storeId);
        }
      },
    );
  }

  Widget _buildWaiterCommandHeader({
    required int tableCount,
    required int occupiedCount,
    required int emptyCount,
    required PosTable? selectedTable,
    required bool isBuffetMode,
    required bool showOrderWorkspace,
  }) {
    final l10n = context.l10n;
    final hasSelection = selectedTable != null;
    final compactMetricsLabel =
        '${l10n.waiterMetricTotal} $tableCount · '
        '${l10n.waiterMetricOccupied} $occupiedCount · '
        '${l10n.waiterMetricAvailable} $emptyCount';

    if (showOrderWorkspace) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final useMobileHeader = constraints.maxWidth < 560;
          if (useMobileHeader) {
            return ToastWorkSurface(
              key: const Key('waiter_mobile_order_header'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              backgroundColor: AppColors.surface1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(
                        l10n.waiterScreenTitle,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(width: 8),
                      ToastStatusBadge(
                        label: hasSelection
                            ? l10n.waiterSelectedTable(
                                selectedTable.tableNumber,
                              )
                            : l10n.waiterDiningFloor,
                        color: hasSelection ? PosColors.accent : PosColors.info,
                        compact: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      ToastStatusBadge(
                        label: isBuffetMode
                            ? l10n.waiterBuffetStartPrompt
                            : l10n.waiterWorkspaceReadyPrompt,
                        color: isBuffetMode
                            ? PosColors.warning
                            : PosColors.success,
                        compact: true,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          compactMetricsLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: PosColors.textSecondary,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }

          return ToastWorkSurface(
            key: const Key('waiter_order_compact_header'),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            backgroundColor: AppColors.surface1,
            child: Row(
              children: [
                Text(
                  l10n.waiterScreenTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(width: 10),
                ToastStatusBadge(
                  label: hasSelection
                      ? l10n.waiterSelectedTable(selectedTable.tableNumber)
                      : l10n.waiterDiningFloor,
                  color: hasSelection ? PosColors.accent : PosColors.info,
                  compact: true,
                ),
                const SizedBox(width: 8),
                ToastStatusBadge(
                  label: isBuffetMode
                      ? l10n.waiterBuffetStartPrompt
                      : l10n.waiterWorkspaceReadyPrompt,
                  color: isBuffetMode ? PosColors.warning : PosColors.success,
                  compact: true,
                ),
                const Spacer(),
                Text(
                  compactMetricsLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          );
        },
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final useMobileHeader = constraints.maxWidth < 560;
        if (useMobileHeader) {
          return ToastWorkSurface(
            key: const Key('waiter_mobile_command_header'),
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            backgroundColor: AppColors.surface1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.waiterScreenTitle,
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l10n.waiterTapTableToStart,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: PosColors.textSecondary,
                                  fontSize: 12,
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    ToastStatusBadge(
                      label: hasSelection
                          ? l10n.waiterSelectedTable(selectedTable.tableNumber)
                          : l10n.waiterDiningFloor,
                      color: hasSelection ? PosColors.accent : PosColors.info,
                      compact: true,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    ToastStatusBadge(
                      label: isBuffetMode
                          ? l10n.waiterBuffetStartPrompt
                          : l10n.waiterWorkspaceReadyPrompt,
                      color: isBuffetMode
                          ? PosColors.warning
                          : PosColors.success,
                      compact: true,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        compactMetricsLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: PosColors.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        }

        return ToastWorkSurface(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
          backgroundColor: AppColors.surface1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.waiterScreenTitle,
                          style: Theme.of(context).textTheme.headlineLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          showOrderWorkspace
                              ? l10n.waiterSelectedTableSubtitle
                              : l10n.waiterTapTableToStart,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: PosColors.textSecondary,
                                fontSize: 13,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  ToastStatusBadge(
                    label: hasSelection
                        ? l10n.waiterSelectedTable(selectedTable.tableNumber)
                        : l10n.waiterDiningFloor,
                    color: hasSelection ? PosColors.accent : PosColors.info,
                    compact: true,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ToastMetricStrip(
                metrics: [
                  ToastMetric(
                    label: l10n.waiterMetricTotal,
                    value: '$tableCount',
                  ),
                  ToastMetric(
                    label: l10n.waiterMetricOccupied,
                    value: '$occupiedCount',
                    tone: occupiedCount > 0
                        ? PosColors.accent
                        : PosColors.textSecondary,
                  ),
                  ToastMetric(
                    label: l10n.waiterMetricAvailable,
                    value: '$emptyCount',
                    tone: PosColors.success,
                  ),
                  ToastMetric(
                    label: l10n.waiterSelectedTableLabel,
                    value: selectedTable?.tableNumber ?? '-',
                    tone: hasSelection
                        ? PosColors.accent
                        : PosColors.textSecondary,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  ToastStatusBadge(
                    label: isBuffetMode
                        ? l10n.waiterBuffetStartPrompt
                        : l10n.waiterWorkspaceReadyPrompt,
                    color: isBuffetMode ? PosColors.warning : PosColors.success,
                    compact: true,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.waiterScreenSubtitle,
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
            ],
          ),
        );
      },
    );
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
            StoreSettings(operationMode: 'standard', perPersonCharge: null),
          )
        : ref.watch(restaurantSettingsProvider(storeId));
    final menuState = storeId == null
        ? const MenuState()
        : ref.watch(menuProvider(storeId));
    final menuNotifier = storeId == null
        ? null
        : ref.read(menuProvider(storeId).notifier);

    final selectedTable = _resolveSelectedTable(tableState.tables);
    final operationMode =
        restaurantSettings.valueOrNull?.operationMode.toLowerCase() ??
        'standard';
    final isBuffetMode = operationMode == 'buffet' || operationMode == 'hybrid';
    final allowSubmitWithoutCart =
        isBuffetMode && orderState.activeOrder == null;
    final showOrderWorkspace = _showOrderPanel && selectedTable != null;
    final occupiedCount = tableState.tables
        .where((table) => table.isOccupied)
        .length;
    final reservedCount = tableState.tables
        .where((table) => table.isReserved)
        .length;
    final emptyCount = tableState.tables.length - occupiedCount - reservedCount;

    return Scaffold(
      key: const Key('dashboard_root'),
      backgroundColor: AppColors.surface0,
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: Column(
              children: [
                _WaiterTopBar(
                  storeId: storeId,
                  showOrderWorkspace: showOrderWorkspace,
                  onReturnToFloor: _onCancelOrderPanel,
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final queuePane = _TableGridView(
                        key: const Key('tables_root'),
                        state: tableState,
                        selectedTableId: selectedTable?.id,
                        onRetry: () {
                          if (storeId != null) {
                            ref
                                .read(waiterTableProvider.notifier)
                                .loadTables(storeId);
                          }
                        },
                        onTapTable: (table) {
                          if (storeId != null) {
                            _onSelectTable(table, storeId, isBuffetMode);
                          }
                        },
                      );
                      final detailPane = AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: showOrderWorkspace
                            ? _buildOrderWorkspace(
                                storeId: storeId,
                                selectedTable: selectedTable,
                                menuState: menuState,
                                menuNotifier: menuNotifier,
                                orderState: orderState,
                                allowSubmitWithoutCart: allowSubmitWithoutCart,
                                isBuffetMode: isBuffetMode,
                              )
                            : const _WaiterSelectionPlaceholder(
                                key: ValueKey<String>('waiter-empty-detail'),
                              ),
                      );

                      return ToastResponsiveBody(
                        maxWidth: 1480,
                        padding: EdgeInsets.all(showOrderWorkspace ? 10 : 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildWaiterCommandHeader(
                              tableCount: tableState.tables.length,
                              occupiedCount: occupiedCount,
                              emptyCount: emptyCount,
                              selectedTable: selectedTable,
                              isBuffetMode: isBuffetMode,
                              showOrderWorkspace: showOrderWorkspace,
                            ),
                            SizedBox(height: showOrderWorkspace ? 10 : 16),
                            Expanded(
                              child: constraints.maxWidth >= 1120
                                  ? Row(
                                      children: [
                                        Expanded(
                                          flex: showOrderWorkspace ? 3 : 4,
                                          child: queuePane,
                                        ),
                                        SizedBox(
                                          width: showOrderWorkspace ? 12 : 16,
                                        ),
                                        Expanded(
                                          flex: showOrderWorkspace ? 9 : 7,
                                          child: detailPane,
                                        ),
                                      ],
                                    )
                                  : AnimatedSwitcher(
                                      duration: const Duration(
                                        milliseconds: 260,
                                      ),
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
                                      child: showOrderWorkspace
                                          ? detailPane
                                          : queuePane,
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
          ),
        ],
      ),
    );
  }
}

class _WaiterTopBar extends ConsumerWidget {
  const _WaiterTopBar({
    required this.storeId,
    required this.showOrderWorkspace,
    required this.onReturnToFloor,
  });

  final String? storeId;
  final bool showOrderWorkspace;
  final VoidCallback onReturnToFloor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final restaurantName = storeId == null
        ? AsyncValue<String>.data(l10n.store)
        : ref.watch(restaurantNameProvider(storeId!));

    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: AppColors.surfaceTopbar,
        border: Border(bottom: BorderSide(color: AppColors.surface3)),
      ),
      child: Row(
        children: [
          AppNavBar(
            forceBackEnabled: showOrderWorkspace,
            forceHomeEnabled: showOrderWorkspace,
            onBackPressed: showOrderWorkspace ? onReturnToFloor : null,
            onHomePressed: showOrderWorkspace ? onReturnToFloor : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.waiterDiningFloor,
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textSecondary,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.35,
                  ),
                ),
                restaurantName.when(
                  data: (name) => Text(
                    name.isEmpty ? l10n.store : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  loading: () => Text(
                    l10n.waiterLoading,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                  error: (_, _) => Text(
                    l10n.store,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
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
    required this.selectedTableId,
    required this.onRetry,
    required this.onTapTable,
  });

  final WaiterTableState state;
  final String? selectedTableId;
  final VoidCallback onRetry;
  final ValueChanged<PosTable> onTapTable;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (state.isLoading) {
      return const ToastWorkSurface(
        child: Center(
          child: CircularProgressIndicator(color: AppColors.amber500),
        ),
      );
    }

    if (state.error != null) {
      return ToastWorkSurface(
        child: Center(
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
                child: Text(l10n.retry),
              ),
            ],
          ),
        ),
      );
    }

    if (state.tables.isEmpty) {
      return ToastWorkSurface(
        child: PosEmptyState(
          title: l10n.waiterNoTablesTitle,
          subtitle: l10n.waiterNoTablesSubtitle,
          icon: Icons.table_restaurant_outlined,
        ),
      );
    }

    return PosDataPanel(
      title: l10n.waiterTableStatusTitle,
      subtitle: selectedTableId == null
          ? l10n.waiterTapTableToStart
          : l10n.waiterSelectedTableSubtitle,
      trailing: selectedTableId == null
          ? null
          : ToastStatusBadge(
              label: l10n.waiterSelectedBadge,
              color: PosColors.accent,
              compact: true,
            ),
      child: FloorLayoutView(
        tables: state.tables,
        selectedTableId: selectedTableId,
        orderPreviewByTableId: state.orderPreviewByTableId,
        onTapTable: onTapTable,
        editable: false,
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
      ),
    );
  }
}

class _WaiterSelectionPlaceholder extends StatelessWidget {
  const _WaiterSelectionPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return ToastWorkSurface(
      child: Center(
        child: PosEmptyState(
          title: context.l10n.waiterSelectTableTitle,
          subtitle: context.l10n.waiterTapTableToStart,
          icon: Icons.table_restaurant_outlined,
        ),
      ),
    );
  }
}
