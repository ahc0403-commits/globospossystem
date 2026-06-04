import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../core/i18n/locale_extensions.dart';
import '../../core/utils/time_utils.dart';

import '../../core/ui/app_primitives.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../main.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/error_toast.dart';
import '../../widgets/offline_banner.dart';
import '../auth/auth_provider.dart';
import 'kitchen_provider.dart';

final kitchenRestaurantNameProvider = FutureProvider.family<String, String>((
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

class KitchenScreen extends ConsumerStatefulWidget {
  const KitchenScreen({super.key});

  @override
  ConsumerState<KitchenScreen> createState() => _KitchenScreenState();
}

class _KitchenScreenState extends ConsumerState<KitchenScreen> {
  DateTime _now = DateTime.now().toUtc();
  Timer? _clockTimer;
  String? _initializedRestaurantId;
  final Set<String> _flashingOrderIds = <String>{};
  final Set<String> _completedOrderIds = <String>{};
  final Set<String> _processingItemIds = <String>{};
  final Map<String, Timer> _flashTimers = <String, Timer>{};
  String? _lastError;
  bool _hasObservedKitchenSnapshot = false;
  late final ProviderSubscription<KitchenState> _kitchenSub;
  late final ProviderSubscription<KitchenState> _kitchenErrorSub;

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _now = DateTime.now().toUtc(); // keep as UTC baseline
      });
    });

    _kitchenSub = ref.listenManual<KitchenState>(kitchenProvider, (prev, next) {
      if (next.isLoading) {
        return;
      }

      final previousOrders = prev?.orders ?? const <KitchenOrder>[];
      if (!_hasObservedKitchenSnapshot) {
        _hasObservedKitchenSnapshot = true;
        return;
      }

      final oldIds = previousOrders.map((order) => order.orderId).toSet();
      final previousItemIds = {
        for (final order in previousOrders)
          for (final item in order.items) item.itemId,
      };

      for (final order in next.orders) {
        final isNewOrder = !oldIds.contains(order.orderId);
        final hasNewPendingItem = order.items.any(
          (item) =>
              item.status == 'pending' &&
              !previousItemIds.contains(item.itemId),
        );
        if (isNewOrder || hasNewPendingItem) {
          _triggerKitchenNewOrderAlert(order);
        }
      }
    });

    _kitchenErrorSub = ref.listenManual<KitchenState>(kitchenProvider, (
      prev,
      next,
    ) {
      final error = next.error;
      if (error != null && error.isNotEmpty && error != _lastError) {
        _lastError = error;
        if (mounted) {
          showErrorToast(context, error);
        }
      }
    });
  }

  void _triggerFlash(String orderId) {
    _flashTimers[orderId]?.cancel();
    setState(() {
      _flashingOrderIds.add(orderId);
    });
    _flashTimers[orderId] = Timer(const Duration(seconds: 1), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _flashingOrderIds.remove(orderId);
      });
      _flashTimers.remove(orderId);
    });
  }

  void _triggerKitchenNewOrderAlert(KitchenOrder order) {
    _triggerFlash(order.orderId);
    unawaited(_playKitchenAlertSound());
    if (!mounted) {
      return;
    }
    final message =
        '${context.l10n.kitchenNewOrders} · ${context.l10n.kitchenTableLabel(order.tableNumber)}';
    showSuccessToast(context, message);
  }

  Future<void> _playKitchenAlertSound() async {
    try {
      await SystemSound.play(SystemSoundType.alert);
    } catch (_) {
      // Some web/mobile runtimes block alert sounds without user activation.
    }
  }

  void _ensureLoaded(String? storeId) {
    if (storeId == null || _initializedRestaurantId == storeId) {
      return;
    }
    _initializedRestaurantId = storeId;
    _hasObservedKitchenSnapshot = false;
    Future.microtask(() {
      ref.read(kitchenProvider.notifier).loadOrders(storeId);
    });
  }

  String _cycleStatus(String status) {
    return switch (status) {
      'pending' => 'preparing',
      'preparing' => 'ready',
      'ready' => 'served',
      _ => 'pending',
    };
  }

  Future<void> _handleItemAction(
    KitchenNotifier notifier,
    KitchenOrder order,
    KitchenItem item,
  ) async {
    if (_processingItemIds.contains(item.itemId)) {
      return;
    }
    final nextStatus = _cycleStatus(item.status);
    final completesTicket =
        nextStatus == 'served' && _isLastOpenItem(order, item);

    setState(() {
      _processingItemIds.add(item.itemId);
    });

    try {
      await notifier.updateItemStatus(item.itemId, nextStatus);
      if (!mounted) return;
      if (completesTicket) {
        setState(() {
          _completedOrderIds.add(order.orderId);
        });
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        setState(() {
          _completedOrderIds.remove(order.orderId);
        });
      }
    } finally {
      if (!mounted) {
        _processingItemIds.remove(item.itemId);
      } else {
        setState(() {
          _processingItemIds.remove(item.itemId);
        });
      }
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _kitchenSub.close();
    _kitchenErrorSub.close();
    for (final timer in _flashTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final storeId = authState.storeId;
    _ensureLoaded(storeId);

    final kitchenState = ref.watch(kitchenProvider);
    final notifier = ref.read(kitchenProvider.notifier);

    return Scaffold(
      key: const Key('kitchen_root'),
      backgroundColor: AppColors.surface0,
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: Column(
              children: [
                _KitchenTopBar(now: _now, storeId: storeId),
                Expanded(
                  child: Builder(
                    builder: (context) {
                      if (kitchenState.isLoading) {
                        return const ToastOperationalLoadingState(
                          label: PosLoadingCopy.loadingKitchen,
                        );
                      }
                      if (kitchenState.error != null) {
                        return AppErrorState(
                          title: context.l10n.kitchenLoadErrorTitle,
                          message: context.l10n.kitchenLoadErrorMessage,
                          onRetry: storeId == null
                              ? null
                              : () => notifier.loadOrders(storeId),
                        );
                      }

                      final queuedOrders = kitchenState.orders
                          .where(
                            (order) => order.items.any(
                              (item) => item.status == 'pending',
                            ),
                          )
                          .toList();
                      final preparingOrders = kitchenState.orders
                          .where(
                            (order) => order.items.any(
                              (item) => item.status == 'preparing',
                            ),
                          )
                          .toList();
                      final readyOrders = kitchenState.orders
                          .where(
                            (order) => order.items.any(
                              (item) => item.status == 'ready',
                            ),
                          )
                          .toList();
                      final pendingItems = kitchenState.orders
                          .expand((order) => order.items)
                          .where((item) => item.status == 'pending')
                          .length;
                      final longWaitCount = kitchenState.orders.where((order) {
                        final elapsed = _now
                            .difference(order.createdAt.toUtc())
                            .inMinutes;
                        return elapsed >= 15;
                      }).length;
                      final spotlightOrderId = queuedOrders.isNotEmpty
                          ? queuedOrders.first.orderId
                          : preparingOrders.isNotEmpty
                          ? preparingOrders.first.orderId
                          : readyOrders.isNotEmpty
                          ? readyOrders.first.orderId
                          : null;

                      return ToastResponsiveBody(
                        maxWidth: 1480,
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _KitchenCommandHeader(
                              queuedCount: queuedOrders.length,
                              preparingCount: preparingOrders.length,
                              readyCount: readyOrders.length,
                              pendingItemCount: pendingItems,
                              delayedCount: longWaitCount,
                            ),
                            const SizedBox(height: 16),
                            Expanded(
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  if (constraints.maxWidth < 1120) {
                                    return ListView(
                                      children: [
                                        _KitchenLaneColumn(
                                          title: context.l10n.kitchenNewOrders,
                                          subtitle: context
                                              .l10n
                                              .kitchenLaneNewSubtitle,
                                          statusColor: PosColors.info,
                                          visibleStatuses: const {'pending'},
                                          orders: queuedOrders,
                                          now: _now,
                                          spotlightOrderId: spotlightOrderId,
                                          flashingOrderIds: _flashingOrderIds,
                                          completedOrderIds: _completedOrderIds,
                                          processingItemIds: _processingItemIds,
                                          scrollable: false,
                                          onItemAction: (order, item) =>
                                              _handleItemAction(
                                                notifier,
                                                order,
                                                item,
                                              ),
                                        ),
                                        const SizedBox(height: 16),
                                        _KitchenLaneColumn(
                                          title: context.l10n.kitchenCooking,
                                          subtitle: context
                                              .l10n
                                              .kitchenLanePreparingSubtitle,
                                          statusColor: PosColors.warning,
                                          visibleStatuses: const {'preparing'},
                                          orders: preparingOrders,
                                          now: _now,
                                          spotlightOrderId: spotlightOrderId,
                                          flashingOrderIds: _flashingOrderIds,
                                          completedOrderIds: _completedOrderIds,
                                          processingItemIds: _processingItemIds,
                                          scrollable: false,
                                          onItemAction: (order, item) =>
                                              _handleItemAction(
                                                notifier,
                                                order,
                                                item,
                                              ),
                                        ),
                                        const SizedBox(height: 16),
                                        _KitchenLaneColumn(
                                          title: context.l10n.kitchenComplete,
                                          subtitle: context
                                              .l10n
                                              .kitchenLaneReadySubtitle,
                                          statusColor: PosColors.success,
                                          visibleStatuses: const {'ready'},
                                          orders: readyOrders,
                                          now: _now,
                                          spotlightOrderId: spotlightOrderId,
                                          flashingOrderIds: _flashingOrderIds,
                                          completedOrderIds: _completedOrderIds,
                                          processingItemIds: _processingItemIds,
                                          scrollable: false,
                                          onItemAction: (order, item) =>
                                              _handleItemAction(
                                                notifier,
                                                order,
                                                item,
                                              ),
                                        ),
                                      ],
                                    );
                                  }

                                  return Row(
                                    children: [
                                      Expanded(
                                        child: _KitchenLaneColumn(
                                          title: context.l10n.kitchenNewOrders,
                                          subtitle: context
                                              .l10n
                                              .kitchenLaneNewSubtitle,
                                          statusColor: PosColors.info,
                                          visibleStatuses: const {'pending'},
                                          orders: queuedOrders,
                                          now: _now,
                                          spotlightOrderId: spotlightOrderId,
                                          flashingOrderIds: _flashingOrderIds,
                                          completedOrderIds: _completedOrderIds,
                                          processingItemIds: _processingItemIds,
                                          onItemAction: (order, item) =>
                                              _handleItemAction(
                                                notifier,
                                                order,
                                                item,
                                              ),
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: _KitchenLaneColumn(
                                          title: context.l10n.kitchenCooking,
                                          subtitle: context
                                              .l10n
                                              .kitchenLanePreparingSubtitle,
                                          statusColor: PosColors.warning,
                                          visibleStatuses: const {'preparing'},
                                          orders: preparingOrders,
                                          now: _now,
                                          spotlightOrderId: spotlightOrderId,
                                          flashingOrderIds: _flashingOrderIds,
                                          completedOrderIds: _completedOrderIds,
                                          processingItemIds: _processingItemIds,
                                          onItemAction: (order, item) =>
                                              _handleItemAction(
                                                notifier,
                                                order,
                                                item,
                                              ),
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: _KitchenLaneColumn(
                                          title: context.l10n.kitchenComplete,
                                          subtitle: context
                                              .l10n
                                              .kitchenLaneReadySubtitle,
                                          statusColor: PosColors.success,
                                          visibleStatuses: const {'ready'},
                                          orders: readyOrders,
                                          now: _now,
                                          spotlightOrderId: spotlightOrderId,
                                          flashingOrderIds: _flashingOrderIds,
                                          completedOrderIds: _completedOrderIds,
                                          processingItemIds: _processingItemIds,
                                          onItemAction: (order, item) =>
                                              _handleItemAction(
                                                notifier,
                                                order,
                                                item,
                                              ),
                                        ),
                                      ),
                                    ],
                                  );
                                },
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

class _KitchenCommandHeader extends StatelessWidget {
  const _KitchenCommandHeader({
    required this.queuedCount,
    required this.preparingCount,
    required this.readyCount,
    required this.pendingItemCount,
    required this.delayedCount,
  });

  final int queuedCount;
  final int preparingCount;
  final int readyCount;
  final int pendingItemCount;
  final int delayedCount;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return ToastWorkSurface(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      backgroundColor: PosColors.surface,
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
                      l10n.kitchenTitle,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: PosColors.textPrimary,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.kitchenScreenSubtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PosColors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ToastStatusBadge(
                label: delayedCount > 0
                    ? l10n.kitchenDelayedCount(delayedCount)
                    : l10n.staffOperationalHealthy,
                color: delayedCount > 0 ? PosColors.danger : PosColors.success,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
          ToastMetricStrip(
            metrics: [
              ToastMetric(
                label: l10n.kitchenNewOrders,
                value: '$queuedCount',
                tone: PosColors.info,
              ),
              ToastMetric(
                label: l10n.kitchenCooking,
                value: '$preparingCount',
                tone: PosColors.warning,
              ),
              ToastMetric(
                label: l10n.kitchenReadyHandoff,
                value: '$readyCount',
                tone: PosColors.success,
              ),
              ToastMetric(
                label: l10n.kitchenPendingItems,
                value: '$pendingItemCount',
                tone: pendingItemCount > 0
                    ? PosColors.danger
                    : PosColors.textPrimary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _KitchenLaneColumn extends StatelessWidget {
  const _KitchenLaneColumn({
    required this.title,
    required this.subtitle,
    required this.statusColor,
    required this.visibleStatuses,
    required this.orders,
    required this.now,
    required this.spotlightOrderId,
    required this.flashingOrderIds,
    required this.completedOrderIds,
    required this.processingItemIds,
    required this.onItemAction,
    this.scrollable = true,
  });

  final String title;
  final String subtitle;
  final Color statusColor;
  final Set<String> visibleStatuses;
  final List<KitchenOrder> orders;
  final DateTime now;
  final String? spotlightOrderId;
  final Set<String> flashingOrderIds;
  final Set<String> completedOrderIds;
  final Set<String> processingItemIds;
  final bool scrollable;
  final Future<void> Function(KitchenOrder order, KitchenItem item)
  onItemAction;

  @override
  Widget build(BuildContext context) {
    return PosDataPanel(
      title: title,
      subtitle: subtitle,
      trailing: ToastStatusBadge(
        label: '${orders.length}',
        color: statusColor,
        compact: true,
      ),
      child: orders.isEmpty
          ? _KitchenLanePlaceholder(
              title: title,
              subtitle: subtitle,
              statusColor: statusColor,
            )
          : ListView.separated(
              padding: EdgeInsets.zero,
              shrinkWrap: !scrollable,
              physics: scrollable ? null : const NeverScrollableScrollPhysics(),
              itemCount: orders.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final order = orders[index];
                final visibleOrder = order.copyWith(
                  items: order.items
                      .where((item) => visibleStatuses.contains(item.status))
                      .toList(),
                );
                return _KitchenOrderCard(
                  key: Key('kitchen_order_${order.orderId}'),
                  spotlightKey: order.orderId == spotlightOrderId
                      ? const Key('kitchen_first_order_card')
                      : null,
                  order: visibleOrder,
                  now: now,
                  flashing: flashingOrderIds.contains(order.orderId),
                  completedFlashing: completedOrderIds.contains(order.orderId),
                  processingItemIds: processingItemIds,
                  onItemAction: (item) {
                    unawaited(onItemAction(order, item));
                  },
                );
              },
            ),
    );
  }
}

class _KitchenLanePlaceholder extends StatelessWidget {
  const _KitchenLanePlaceholder({
    required this.title,
    required this.subtitle,
    required this.statusColor,
  });

  final String title;
  final String subtitle;
  final Color statusColor;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final message = switch (title) {
      _ when title == l10n.kitchenNewOrders => l10n.kitchenEmptyNewMessage,
      _ when title == l10n.kitchenCooking => l10n.kitchenEmptyPreparingMessage,
      _ when title == l10n.kitchenComplete => l10n.kitchenEmptyReadyMessage,
      _ => subtitle,
    };

    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: statusColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: statusColor.withValues(alpha: 0.18)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined, color: statusColor, size: 22),
            const SizedBox(height: 10),
            Text(
              l10n.kitchenLaneWaiting(title),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: PosColors.textPrimary,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PosColors.textSecondary,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KitchenOrderCard extends StatelessWidget {
  const _KitchenOrderCard({
    super.key,
    this.spotlightKey,
    required this.order,
    required this.now,
    required this.flashing,
    required this.completedFlashing,
    required this.processingItemIds,
    required this.onItemAction,
  });

  final Key? spotlightKey;
  final KitchenOrder order;
  final DateTime now;
  final bool flashing;
  final bool completedFlashing;
  final Set<String> processingItemIds;
  final ValueChanged<KitchenItem> onItemAction;

  @override
  Widget build(BuildContext context) {
    final elapsed = _elapsedLabel(context, order.createdAt, now);
    final orderSummary = _orderQueueSummary(context, order);
    final priorityColor = _orderPriorityColor(order, now);
    final emphasized =
        spotlightKey != null ||
        flashing ||
        completedFlashing ||
        priorityColor == AppColors.statusCancelled;

    return AnimatedContainer(
      key: spotlightKey,
      duration: const Duration(milliseconds: 260),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: completedFlashing
              ? AppColors.statusAvailable
              : flashing
              ? AppColors.amber500
              : priorityColor.withValues(alpha: 0.44),
          width: emphasized ? 2.3 : 1.1,
        ),
        boxShadow: emphasized
            ? [
                BoxShadow(
                  color: priorityColor.withValues(alpha: 0.18),
                  blurRadius: 24,
                  offset: const Offset(0, 12),
                ),
              ]
            : ToastElevationTokens.low,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: priorityColor.withValues(alpha: 0.1),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
              border: Border(bottom: BorderSide(color: AppColors.surface3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.l10n.kitchenTableLabel(order.tableNumber),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.operationalTitle(size: 28),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      fit: FlexFit.loose,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: ToastStatusBadge.kitchen(
                            label: orderSummary.label,
                            status: orderSummary.status,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.schedule_rounded,
                      size: 14,
                      color: AppColors.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      elapsed,
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        orderSummary.supportingCopy,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: _KitchenTicketPreview(
              order: order,
              processingItemIds: processingItemIds,
              onItemAction: onItemAction,
            ),
          ),
        ],
      ),
    );
  }
}

class _KitchenTicketPreview extends StatelessWidget {
  const _KitchenTicketPreview({
    required this.order,
    required this.processingItemIds,
    required this.onItemAction,
  });

  final KitchenOrder order;
  final Set<String> processingItemIds;
  final ValueChanged<KitchenItem> onItemAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, item) in order.items.indexed) ...[
            _KitchenTicketItemRow(
              key: index == 0
                  ? const Key('kitchen_first_ticket_item_row')
                  : null,
              item: item,
              isProcessing: processingItemIds.contains(item.itemId),
              onItemAction: () => onItemAction(item),
            ),
            if (index != order.items.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _KitchenTicketItemRow extends StatelessWidget {
  const _KitchenTicketItemRow({
    super.key,
    required this.item,
    required this.isProcessing,
    required this.onItemAction,
  });

  final KitchenItem item;
  final bool isProcessing;
  final VoidCallback onItemAction;

  @override
  Widget build(BuildContext context) {
    final isActionable = _isKitchenItemActionable(item);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.surface3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 34,
                child: Text(
                  '${item.quantity}x',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.amber500,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _StatusChip(status: item.status),
            ],
          ),
          if (isActionable) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                key: const Key('kitchen_item_status_button'),
                onPressed: isProcessing ? null : onItemAction,
                icon: isProcessing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(_kitchenItemActionIcon(item.status), size: 16),
                label: Text(_kitchenItemActionLabel(context, item.status)),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ignore: unused_element
class _KitchenAttentionSection extends StatelessWidget {
  const _KitchenAttentionSection({required this.orders, required this.now});

  final List<KitchenOrder> orders;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final pendingItems = orders
        .expand((order) => order.items)
        .where((item) => item.status == 'pending')
        .length;
    final preparingItems = orders
        .expand((order) => order.items)
        .where((item) => item.status == 'preparing')
        .length;
    final readyItems = orders
        .expand((order) => order.items)
        .where((item) => item.status == 'ready')
        .length;
    final longWaitCount = orders.where((order) {
      final elapsed = now.difference(order.createdAt.toUtc()).inMinutes;
      return elapsed >= 15;
    }).length;
    final readyTables = orders
        .where((order) => order.items.any((item) => item.status == 'ready'))
        .length;
    final oldestWaitMinutes = orders.isEmpty
        ? 0
        : orders
              .map((order) => now.difference(order.createdAt.toUtc()).inMinutes)
              .reduce((a, b) => a > b ? a : b);
    final followUpCount = [
      if (pendingItems > 0) true,
      if (readyItems > 0) true,
      if (longWaitCount > 0) true,
    ].length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.surface3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.kitchenAttentionTitle,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.kitchenAttentionSubtitle,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _attentionMetric(
                l10n.kitchenAttentionFollowUpNow,
                '$followUpCount',
                followUpCount > 0
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
              _attentionMetric(
                l10n.kitchenAttentionPendingItems,
                '$pendingItems',
                pendingItems > 0
                    ? AppColors.statusCancelled
                    : AppColors.statusAvailable,
              ),
              _attentionMetric(
                l10n.kitchenAttentionReadyItems,
                '$readyItems',
                readyItems > 0 ? AppColors.amber500 : AppColors.statusAvailable,
              ),
              _attentionMetric(
                l10n.kitchenAttentionOldestWait,
                '${oldestWaitMinutes}m',
                oldestWaitMinutes >= 15
                    ? AppColors.statusCancelled
                    : AppColors.textPrimary,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _attentionChip(
                l10n.kitchenAttentionActiveTables(orders.length),
                AppColors.textPrimary,
              ),
              _attentionChip(
                l10n.kitchenAttentionPreparing(preparingItems),
                preparingItems > 0
                    ? AppColors.statusAvailable
                    : AppColors.textSecondary,
              ),
              _attentionChip(
                l10n.kitchenAttentionLongWaits(longWaitCount),
                longWaitCount > 0
                    ? AppColors.statusCancelled
                    : AppColors.statusAvailable,
              ),
              _attentionChip(
                l10n.kitchenAttentionReadyTables(readyTables),
                readyTables > 0
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _attentionSupportRow(
            l10n.kitchenAttentionFollowUpFocus,
            _followUpCopy(
              context: context,
              pendingItems: pendingItems,
              readyItems: readyItems,
              longWaitCount: longWaitCount,
            ),
          ),
          const SizedBox(height: 8),
          _attentionSupportRow(
            l10n.kitchenAttentionHandoffReadiness,
            _handoffReadinessCopy(
              context: context,
              readyItems: readyItems,
              readyTables: readyTables,
              oldestWaitMinutes: oldestWaitMinutes,
            ),
          ),
          const SizedBox(height: 8),
          _attentionSupportRow(
            l10n.kitchenAttentionBoundary,
            l10n.kitchenAttentionBoundaryBody,
          ),
        ],
      ),
    );
  }

  Widget _attentionMetric(String label, String value, Color color) {
    return Container(
      constraints: const BoxConstraints(minWidth: 120, maxWidth: 180),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: GoogleFonts.notoSansKr(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _attentionChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Text(
        label,
        style: GoogleFonts.notoSansKr(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _attentionSupportRow(String label, String body) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 108,
          child: Text(
            label,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Text(
            body,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }

  String _followUpCopy({
    required BuildContext context,
    required int pendingItems,
    required int readyItems,
    required int longWaitCount,
  }) {
    final l10n = context.l10n;
    if (longWaitCount > 0) {
      return l10n.kitchenAttentionFocusLongWait;
    }
    if (readyItems > 0) {
      return l10n.kitchenAttentionFocusReadyItems;
    }
    if (pendingItems > 0) {
      return l10n.kitchenAttentionFocusPendingItems;
    }
    return l10n.kitchenAttentionFocusNone;
  }

  String _handoffReadinessCopy({
    required BuildContext context,
    required int readyItems,
    required int readyTables,
    required int oldestWaitMinutes,
  }) {
    final l10n = context.l10n;
    if (readyItems > 0) {
      return l10n.kitchenAttentionHandoffReadyItems(readyItems, readyTables);
    }
    if (oldestWaitMinutes >= 15) {
      return l10n.kitchenAttentionHandoffAgingTickets;
    }
    return l10n.kitchenAttentionHandoffNone;
  }
}

class _KitchenTopBar extends ConsumerWidget {
  const _KitchenTopBar({required this.now, required this.storeId});

  final DateTime now;
  final String? storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final restaurantName = storeId == null
        ? AsyncValue<String>.data(l10n.store)
        : ref.watch(kitchenRestaurantNameProvider(storeId!));

    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: AppColors.surfaceTopbar,
        border: Border(bottom: BorderSide(color: AppColors.surface3)),
      ),
      child: Row(
        children: [
          const AppNavBar(),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.kitchenTitle.toUpperCase(),
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textSecondary,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.35,
                  ),
                ),
                const SizedBox(height: 1),
                restaurantName.when(
                  data: (name) => Text(
                    name.isEmpty ? l10n.store : name,
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  loading: () => Text(
                    l10n.loading,
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  error: (_, _) => Text(
                    l10n.store,
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: AppRadius.pill,
              border: Border.all(color: AppColors.surface3),
            ),
            child: Text(
              DateFormat('HH:mm:ss').format(TimeUtils.toVietnam(now)),
              style: GoogleFonts.notoSansKr(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            key: const Key('logout_button'),
            icon: const Icon(Icons.logout, color: AppColors.textSecondary),
            tooltip: l10n.logOut,
            onPressed: () async {
              await ref.read(authProvider.notifier).logout();
            },
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final normalized = status.toLowerCase();
    return ToastStatusBadge(
      label: _statusLabel(context, normalized),
      color: _kitchenStatusColor(normalized),
      compact: true,
    );
  }
}

String _elapsedLabel(BuildContext context, DateTime createdAt, DateTime now) {
  final diff = now.difference(createdAt);
  if (diff.inSeconds < 60) {
    return context.l10n.kitchenSecondsAgo(diff.inSeconds);
  }
  if (diff.inMinutes < 60) {
    return context.l10n.kitchenMinutesAgo(diff.inMinutes);
  }
  return context.l10n.kitchenHoursAgo(diff.inHours);
}

Color _orderPriorityColor(KitchenOrder order, DateTime now) {
  final hasPending = order.items.any((item) => item.status == 'pending');
  final hasPreparing = order.items.any((item) => item.status == 'preparing');
  final hasReady = order.items.any((item) => item.status == 'ready');
  final waitMinutes = now.difference(order.createdAt.toUtc()).inMinutes;
  if (waitMinutes >= 15) {
    return AppColors.statusCancelled;
  }
  if (hasPending || hasPreparing) {
    return AppColors.amber500;
  }
  if (hasReady) {
    return AppColors.statusAvailable;
  }
  return AppColors.surface3;
}

({
  String status,
  String label,
  String supportingCopy,
  String primaryActionLabel,
})
_orderQueueSummary(BuildContext context, KitchenOrder order) {
  final hasPending = order.items.any((item) => item.status == 'pending');
  final hasReady = order.items.any((item) => item.status == 'ready');
  final hasPreparing = order.items.any((item) => item.status == 'preparing');
  final l10n = context.l10n;

  if (hasPending) {
    return (
      status: 'pending',
      label: l10n.kitchenNewOrders,
      supportingCopy: l10n.kitchenPendingSupport,
      primaryActionLabel: l10n.kitchenStartCooking,
    );
  }
  if (hasPreparing) {
    return (
      status: 'preparing',
      label: l10n.kitchenCooking,
      supportingCopy: l10n.kitchenPreparingSupport,
      primaryActionLabel: l10n.kitchenMarkComplete,
    );
  }
  if (hasReady) {
    return (
      status: 'ready',
      label: l10n.kitchenReadyHandoff,
      supportingCopy: l10n.kitchenReadySupport,
      primaryActionLabel: l10n.kitchenHandoffComplete,
    );
  }
  return (
    status: 'served',
    label: l10n.kitchenComplete,
    supportingCopy: l10n.kitchenServedSupport,
    primaryActionLabel: l10n.kitchenNextTicket,
  );
}

bool _isKitchenItemActionable(KitchenItem item) {
  return item.status == 'pending' ||
      item.status == 'preparing' ||
      item.status == 'ready';
}

bool _isLastOpenItem(KitchenOrder order, KitchenItem item) {
  return order.items.every(
    (current) => current.itemId == item.itemId || current.status == 'served',
  );
}

String _kitchenItemActionLabel(BuildContext context, String status) {
  return switch (status) {
    'pending' => context.l10n.kitchenStartCooking,
    'preparing' => context.l10n.kitchenMarkComplete,
    'ready' => context.l10n.kitchenHandoffComplete,
    _ => context.l10n.kitchenMoveNextStep,
  };
}

IconData _kitchenItemActionIcon(String status) {
  return switch (status) {
    'pending' => Icons.local_fire_department_rounded,
    'preparing' => Icons.done_rounded,
    'ready' => Icons.room_service_rounded,
    _ => Icons.arrow_forward_rounded,
  };
}

String _statusLabel(BuildContext context, String normalizedStatus) {
  switch (normalizedStatus) {
    case 'pending':
      return context.l10n.pending;
    case 'preparing':
      return context.l10n.kitchenCooking;
    case 'ready':
      return context.l10n.kitchenComplete;
    case 'served':
      return context.l10n.kitchenServedStatus;
    default:
      return normalizedStatus;
  }
}

Color _kitchenStatusColor(String normalizedStatus) {
  switch (normalizedStatus) {
    case 'pending':
      return AppColors.textSecondary;
    case 'preparing':
      return AppColors.amber500;
    case 'ready':
      return AppColors.statusAvailable;
    case 'served':
      return AppColors.surface3;
    default:
      return AppColors.textSecondary;
  }
}
