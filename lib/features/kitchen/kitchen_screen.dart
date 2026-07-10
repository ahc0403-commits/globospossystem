import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/i18n/locale_extensions.dart';
import '../../core/layout/platform_info.dart';
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
  final TextEditingController _ticketSearchController = TextEditingController();
  String? _lastError;
  bool _hasObservedKitchenSnapshot = false;
  late final ProviderSubscription<KitchenState> _kitchenSub;
  late final ProviderSubscription<KitchenState> _kitchenErrorSub;

  @override
  void initState() {
    super.initState();
    _ticketSearchController.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
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
        '${context.l10n.kitchenNewOrders} · ${order.isDeliveryOrder ? context.l10n.delivery : context.l10n.kitchenTableLabel(order.tableNumber)}';
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
    _ticketSearchController.dispose();
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
      backgroundColor: PosSurfaceRole.background.fill,
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
                        return ToastOperationalLoadingState(
                          label: PosLoadingCopy.loadingKitchen(context.l10n),
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

                      final searchQuery = _ticketSearchController.text.trim();
                      final visibleOrders = _filterKitchenOrders(
                        kitchenState.orders,
                        searchQuery,
                      );
                      final queuedOrders = visibleOrders
                          .where(
                            (order) => order.items.any(
                              (item) => item.status == 'pending',
                            ),
                          )
                          .toList();
                      final preparingOrders = visibleOrders
                          .where(
                            (order) => order.items.any(
                              (item) => item.status == 'preparing',
                            ),
                          )
                          .toList();
                      final readyOrders = visibleOrders
                          .where(
                            (order) => order.items.any(
                              (item) => item.status == 'ready',
                            ),
                          )
                          .toList();
                      final pendingItems = visibleOrders
                          .expand((order) => order.items)
                          .where((item) => item.status == 'pending')
                          .length;
                      final supplementalPendingItems = visibleOrders
                          .expand((order) => order.items)
                          .where(
                            (item) =>
                                item.status == 'pending' && item.isSupplemental,
                          )
                          .length;
                      final longWaitCount = visibleOrders.where((order) {
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
                              supplementalPendingItemCount:
                                  supplementalPendingItems,
                              delayedCount: longWaitCount,
                            ),
                            const SizedBox(height: 16),
                            _KitchenTicketSearchBar(
                              controller: _ticketSearchController,
                              resultCount: visibleOrders.length,
                              totalCount: kitchenState.orders.length,
                              onClear: () => _ticketSearchController.clear(),
                            ),
                            if (searchQuery.isNotEmpty &&
                                visibleOrders.isEmpty) ...[
                              const SizedBox(height: 12),
                              _KitchenSearchEmptyState(query: searchQuery),
                            ],
                            const SizedBox(height: 16),
                            Expanded(
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  if (constraints.maxWidth < 1120) {
                                    // Live lanes come BEFORE the completed
                                    // history: on narrow screens the lazy
                                    // ListView otherwise buries new orders
                                    // below a full-viewport history panel
                                    // (kitchen primary job = new orders).
                                    return ListView(
                                      children: [
                                        _KitchenAttentionSection(
                                          orders: visibleOrders,
                                          now: _now,
                                        ),
                                        const SizedBox(height: 16),
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
                                        const SizedBox(height: 16),
                                        _KitchenCompletedHistoryPanel(
                                          orders: kitchenState.completedOrders,
                                          now: _now,
                                          scrollable: false,
                                        ),
                                      ],
                                    );
                                  }

                                  return Row(
                                    children: [
                                      Expanded(
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: _KitchenLaneColumn(
                                                title: context
                                                    .l10n
                                                    .kitchenNewOrders,
                                                subtitle: context
                                                    .l10n
                                                    .kitchenLaneNewSubtitle,
                                                statusColor: PosColors.info,
                                                visibleStatuses: const {
                                                  'pending',
                                                },
                                                orders: queuedOrders,
                                                now: _now,
                                                spotlightOrderId:
                                                    spotlightOrderId,
                                                flashingOrderIds:
                                                    _flashingOrderIds,
                                                completedOrderIds:
                                                    _completedOrderIds,
                                                processingItemIds:
                                                    _processingItemIds,
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
                                                title:
                                                    context.l10n.kitchenCooking,
                                                subtitle: context
                                                    .l10n
                                                    .kitchenLanePreparingSubtitle,
                                                statusColor: PosColors.warning,
                                                visibleStatuses: const {
                                                  'preparing',
                                                },
                                                orders: preparingOrders,
                                                now: _now,
                                                spotlightOrderId:
                                                    spotlightOrderId,
                                                flashingOrderIds:
                                                    _flashingOrderIds,
                                                completedOrderIds:
                                                    _completedOrderIds,
                                                processingItemIds:
                                                    _processingItemIds,
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
                                                title: context
                                                    .l10n
                                                    .kitchenComplete,
                                                subtitle: context
                                                    .l10n
                                                    .kitchenLaneReadySubtitle,
                                                statusColor: PosColors.success,
                                                visibleStatuses: const {
                                                  'ready',
                                                },
                                                orders: readyOrders,
                                                now: _now,
                                                spotlightOrderId:
                                                    spotlightOrderId,
                                                flashingOrderIds:
                                                    _flashingOrderIds,
                                                completedOrderIds:
                                                    _completedOrderIds,
                                                processingItemIds:
                                                    _processingItemIds,
                                                onItemAction: (order, item) =>
                                                    _handleItemAction(
                                                      notifier,
                                                      order,
                                                      item,
                                                    ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      SizedBox(
                                        width: 318,
                                        child: SingleChildScrollView(
                                          physics:
                                              const AlwaysScrollableScrollPhysics(
                                                parent: ClampingScrollPhysics(),
                                              ),
                                          child: Column(
                                            children: [
                                              _KitchenAttentionSection(
                                                orders: visibleOrders,
                                                now: _now,
                                              ),
                                              const SizedBox(height: 16),
                                              _KitchenCompletedHistoryPanel(
                                                orders: kitchenState
                                                    .completedOrders,
                                                now: _now,
                                                scrollable: false,
                                              ),
                                            ],
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
    required this.supplementalPendingItemCount,
    required this.delayedCount,
  });

  final int queuedCount;
  final int preparingCount;
  final int readyCount;
  final int pendingItemCount;
  final int supplementalPendingItemCount;
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
              ToastMetric(
                label: l10n.kitchenSupplementalItems,
                value: '$supplementalPendingItemCount',
                tone: supplementalPendingItemCount > 0
                    ? PosColors.warning
                    : PosColors.textPrimary,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            key: const Key('kitchen_state_flow_legend'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: PosSurfaceRole.background.fill,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: PosSurfaceRole.background.stroke),
            ),
            child: Text(
              '${l10n.kitchenNewOrders} > ${l10n.kitchenCooking} > ${l10n.kitchenReadyHandoff} > ${l10n.kitchenServedStatus}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PosColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KitchenTicketSearchBar extends StatelessWidget {
  const _KitchenTicketSearchBar({
    required this.controller,
    required this.resultCount,
    required this.totalCount,
    required this.onClear,
  });

  final TextEditingController controller;
  final int resultCount;
  final int totalCount;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final hasQuery = controller.text.trim().isNotEmpty;

    return ToastWorkSurface(
      key: const Key('kitchen_ticket_search_toolbar'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      backgroundColor: PosColors.surface,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('kitchen_ticket_search_field'),
              controller: controller,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: PosColors.textPrimary),
              decoration: InputDecoration(
                labelText: l10n.kitchenTicketSearchLabel,
                hintText: l10n.kitchenTicketSearchHint,
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: hasQuery
                    ? IconButton(
                        key: const Key('kitchen_ticket_search_clear'),
                        tooltip: l10n.kitchenTicketSearchClear,
                        onPressed: onClear,
                        icon: const Icon(Icons.close_rounded),
                      )
                    : null,
              ),
            ),
          ),
          const SizedBox(width: 12),
          ToastStatusBadge(
            label: hasQuery
                ? l10n.kitchenTicketSearchResultCount(resultCount, totalCount)
                : l10n.kitchenTicketSearchAllCount(totalCount),
            color: hasQuery ? PosColors.info : PosColors.textSecondary,
            compact: true,
          ),
        ],
      ),
    );
  }
}

class _KitchenSearchEmptyState extends StatelessWidget {
  const _KitchenSearchEmptyState({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    return ToastOperationalEmptyState(
      key: const Key('kitchen_ticket_search_empty'),
      headline: context.l10n.kitchenTicketNoResults,
      helper: context.l10n.kitchenTicketNoResultsFor(query),
      icon: Icons.search_off_rounded,
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

    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        key: const Key('kitchen_empty_lane_slim_rail'),
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 72),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: PosSurfaceTints.tone(statusColor, alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: statusColor.withValues(alpha: 0.34)),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: statusColor.withValues(alpha: 0.34)),
              ),
              child: Icon(Icons.inbox_outlined, color: statusColor, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.kitchenLaneWaiting(title),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: PosColors.textPrimary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
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
    final elapsedMinutes = _kitchenElapsedMinutes(order.createdAt, now);
    final elapsedColor = elapsedMinutes >= _kitchenOverdueMinutes
        ? PosColors.danger
        : PosColors.textPrimary;
    final orderSummary = _orderQueueSummary(context, order);
    final priorityColor = _orderPriorityColor(order, now);
    final priorityFill = _orderPriorityFill(order, now);
    final hasSupplementalItems = order.items.any((item) => item.isSupplemental);
    final emphasized =
        spotlightKey != null ||
        flashing ||
        completedFlashing ||
        elapsedMinutes >= _kitchenOverdueMinutes;

    return AnimatedContainer(
      key: spotlightKey,
      duration: const Duration(milliseconds: 260),
      decoration: BoxDecoration(
        color: PosSurfaceRole.operating.fill,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: completedFlashing
              ? PosColors.success
              : flashing
              ? PosColors.warning
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
              color: priorityFill,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
              border: Border(
                bottom: BorderSide(color: PosSurfaceRole.operating.stroke),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        order.isDeliveryOrder
                            ? context.l10n.delivery
                            : order.isStaffMeal
                            ? context.l10n.cashierStaffMealBadge
                            : context.l10n.kitchenTableLabel(order.tableNumber),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: PosNumericText.tableId.copyWith(
                          color: PosSurfaceRole.operating.text,
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _KitchenStatusCue(status: orderSummary.status),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ToastStatusBadge(
                      key: Key('kitchen_ticket_code_${order.orderId}'),
                      label: context.l10n.kitchenTicketCode(
                        _shortKitchenTicketCode(order.orderId),
                      ),
                      color: PosColors.info,
                      compact: true,
                    ),
                    if (order.isStaffMeal)
                      ToastStatusBadge(
                        key: Key('staff_meal_badge_${order.orderId}'),
                        label: context.l10n.cashierStaffMealBadge,
                        color: PosColors.warning,
                        compact: true,
                      ),
                    if (order.isDeliveryOrder)
                      ToastStatusBadge(
                        key: Key(
                          'kitchen_delivery_order_badge_${order.orderId}',
                        ),
                        label: context.l10n.delivery,
                        color: PosColors.warning,
                        compact: true,
                      ),
                    if (order.isQrOrder)
                      ToastStatusBadge(
                        key: Key('kitchen_qr_order_badge_${order.orderId}'),
                        label: 'QR',
                        color: PosColors.accent,
                        compact: true,
                      ),
                    if (hasSupplementalItems) ...[
                      ToastStatusBadge(
                        key: Key(
                          'kitchen_ticket_supplemental_badge_${order.orderId}',
                        ),
                        label: context.l10n.kitchenSupplementalItems,
                        color: PosColors.warning,
                        compact: true,
                      ),
                    ],
                    ToastStatusBadge.kitchen(
                      label: orderSummary.label,
                      status: orderSummary.status,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      elapsedMinutes >= _kitchenOverdueMinutes
                          ? Icons.timer_off_rounded
                          : Icons.schedule_rounded,
                      size: 16,
                      color: elapsedColor,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      elapsed,
                      style:
                          (elapsedMinutes >= _kitchenOverdueMinutes
                                  ? PosNumericText.elapsedOverdue
                                  : PosNumericText.elapsedPrimary)
                              .copyWith(color: elapsedColor),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        orderSummary.supportingCopy,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: PosSurfaceRole.operating.text,
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
        color: PosSurfaceRole.background.fill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PosSurfaceRole.background.stroke),
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
    final statusColor = _kitchenStatusColor(item.status);
    final itemLabel = _localizedKitchenItemLabel(context, item.label);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: PosSurfaceRole.action.fill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: statusColor.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                constraints: const BoxConstraints(minWidth: 38),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                decoration: BoxDecoration(
                  color: _kitchenStatusFill(item.status),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: statusColor.withValues(alpha: 0.2)),
                ),
                child: Text(
                  '${item.quantity}x',
                  textAlign: TextAlign.center,
                  style: PosNumericText.qtyUnit.copyWith(
                    color: statusColor,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  itemLabel,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: PosSurfaceRole.action.text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: _StatusChip(status: item.status),
          ),
          if (item.isSupplemental) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: ToastStatusBadge(
                key: Key('kitchen_supplemental_item_${item.itemId}'),
                label: context.l10n.kitchenSupplementalItem,
                color: PosColors.warning,
                compact: true,
              ),
            ),
          ],
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
                  minimumSize: const Size(
                    PosDensity.touchTargetMin,
                    PosDensity.touchTargetMin,
                  ),
                  foregroundColor: isProcessing
                      ? PosSurfaceRole.processing.text
                      : statusColor,
                  backgroundColor: isProcessing
                      ? PosSurfaceRole.processing.fill
                      : PosSurfaceRole.action.fill,
                  side: BorderSide(
                    color: isProcessing
                        ? PosSurfaceRole.processing.stroke
                        : statusColor.withValues(alpha: 0.42),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  visualDensity: VisualDensity.standard,
                  tapTargetSize: MaterialTapTargetSize.padded,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

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
      final elapsed = _kitchenElapsedMinutes(order.createdAt, now);
      return elapsed >= 15;
    }).length;
    final readyTables = orders
        .where((order) => order.items.any((item) => item.status == 'ready'))
        .length;
    final oldestWaitMinutes = orders.isEmpty
        ? 0
        : orders
              .map((order) => _kitchenElapsedMinutes(order.createdAt, now))
              .reduce((a, b) => a > b ? a : b);
    final followUpCount = [
      if (pendingItems > 0) true,
      if (readyItems > 0) true,
      if (longWaitCount > 0) true,
    ].length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: PosSurfaceRole.operating.fill,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PosSurfaceRole.operating.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.kitchenAttentionTitle,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.kitchenAttentionSubtitle,
            style: AppFonts.system(
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
                valueStyle:
                    (oldestWaitMinutes >= _kitchenOverdueMinutes
                            ? PosNumericText.elapsedOverdue
                            : PosNumericText.elapsedPrimary)
                        .copyWith(
                          color: oldestWaitMinutes >= _kitchenOverdueMinutes
                              ? PosColors.danger
                              : PosColors.textPrimary,
                        ),
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

  Widget _attentionMetric(
    String label,
    String value,
    Color color, {
    TextStyle? valueStyle,
  }) {
    return Container(
      constraints: const BoxConstraints(minWidth: 120, maxWidth: 180),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PosSurfaceRole.background.fill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PosSurfaceRole.background.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style:
                valueStyle ??
                PosNumericText.qtyUnit.copyWith(
                  color: color,
                  fontWeight: FontWeight.w800,
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
        style: AppFonts.system(
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
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Text(
            body,
            style: AppFonts.system(
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

class _KitchenCompletedHistoryPanel extends StatelessWidget {
  const _KitchenCompletedHistoryPanel({
    required this.orders,
    required this.now,
    this.scrollable = true,
  });

  final List<KitchenOrder> orders;
  final DateTime now;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return PosDataPanel(
      key: const Key('kitchen_completed_history_panel'),
      title: '${l10n.kitchenComplete} ${l10n.changeHistory}',
      subtitle: l10n.kitchenServedStatus,
      trailing: ToastStatusBadge(
        label: '${orders.length}',
        color: PosColors.success,
        compact: true,
      ),
      child: orders.isEmpty
          ? ToastOperationalEmptyState(
              headline: l10n.kitchenComplete,
              helper: l10n.kitchenEmptyReadyMessage,
              icon: Icons.fact_check_outlined,
            )
          : ListView.separated(
              padding: EdgeInsets.zero,
              shrinkWrap: !scrollable,
              physics: scrollable ? null : const NeverScrollableScrollPhysics(),
              itemCount: orders.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final order = orders[index];
                final servedCount = order.items.fold<int>(
                  0,
                  (sum, item) => sum + item.quantity,
                );
                return Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: PosSurfaceRole.background.fill,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: PosSurfaceRole.background.stroke),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: PosColors.success.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.check_circle_rounded,
                          size: 18,
                          color: PosColors.success,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              order.isDeliveryOrder
                                  ? l10n.delivery
                                  : order.isStaffMeal
                                  ? l10n.cashierStaffMealBadge
                                  : l10n.kitchenTableLabel(order.tableNumber),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w900),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${l10n.orderWorkspaceItemsCount(servedCount)} · ${_elapsedLabel(context, order.createdAt.toUtc(), now)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: PosColors.textSecondary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _StatusChip(status: 'served'),
                    ],
                  ),
                );
              },
            ),
    );
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
                  style: AppFonts.system(
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.system(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  loading: () => Text(
                    l10n.loading,
                    style: AppFonts.system(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  error: (_, _) => Text(
                    l10n.store,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.system(
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
              style: AppFonts.system(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (storeId != null) ...[
            if (PlatformInfo.isKioskSupported) ...[
              IconButton.outlined(
                key: const Key('kitchen_attendance_kiosk_entry'),
                tooltip: l10n.attendance,
                onPressed: () => context.go('/attendance-kiosk'),
                icon: const Icon(
                  Icons.fingerprint_outlined,
                  color: AppColors.textSecondary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 8),
            ],
            if (PlatformInfo.isPrinterSupported) ...[
              IconButton.outlined(
                key: const Key('kitchen_print_station_entry'),
                tooltip: l10n.printStationOpen,
                onPressed: () => context.go('/print-station'),
                icon: const Icon(
                  Icons.print_outlined,
                  color: AppColors.textSecondary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 8),
            ],
            _KitchenFailedPrintJobsButton(storeId: storeId!),
            const SizedBox(width: 8),
          ],
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

class _KitchenFailedPrintJobsButton extends ConsumerWidget {
  const _KitchenFailedPrintJobsButton({required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final failedJobs = ref.watch(failedPrintJobsProvider(storeId));
    final count = failedJobs.maybeWhen(
      data: (jobs) => jobs.length,
      orElse: () => 0,
    );
    final color = count > 0 ? PosColors.warning : AppColors.textSecondary;

    return IconButton.outlined(
      key: const Key('kitchen_failed_print_jobs_button'),
      tooltip: context.l10n.kitchenFailedPrintJobs,
      onPressed: () => _showFailedPrintJobsDialog(context, ref, storeId),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(Icons.print_disabled_outlined, color: color, size: 20),
          if (count > 0)
            Positioned(
              right: -8,
              top: -8,
              child: Container(
                key: const Key('kitchen_failed_print_jobs_badge'),
                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                padding: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(
                  color: PosColors.warning,
                  borderRadius: BorderRadius.circular(999),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$count',
                  style: AppFonts.system(
                    color: AppColors.surface0,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showFailedPrintJobsDialog(
    BuildContext context,
    WidgetRef ref,
    String storeId,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return Consumer(
          builder: (context, ref, _) {
            final failedJobs = ref.watch(failedPrintJobsProvider(storeId));

            return AlertDialog(
              key: const Key('kitchen_failed_print_jobs_dialog'),
              backgroundColor: AppColors.surface1,
              title: Text(
                context.l10n.kitchenFailedPrintJobs,
                style: AppFonts.system(color: AppColors.textPrimary),
              ),
              content: SizedBox(
                width: 420,
                child: failedJobs.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(18),
                    child: Center(
                      child: CircularProgressIndicator(
                        color: AppColors.amber500,
                      ),
                    ),
                  ),
                  error: (error, _) => PosExceptionAlert(
                    label: context.l10n.kitchenPrintQueueUnavailable,
                    detail: '$error',
                    color: PosColors.warning,
                    icon: Icons.warning_amber_outlined,
                  ),
                  data: (jobs) {
                    if (jobs.isEmpty) {
                      return PosExceptionAlert(
                        label: context.l10n.kitchenNoFailedPrintJobs,
                        detail: context.l10n.kitchenNoFailedPrintJobsDetail,
                        color: PosColors.success,
                        icon: Icons.check_circle_outline,
                      );
                    }

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final job in jobs)
                          _KitchenFailedPrintJobRow(
                            job: job,
                            onReprint: () async {
                              await ref
                                  .read(kitchenProvider.notifier)
                                  .reprintPrintJob(job.id);
                              ref.invalidate(failedPrintJobsProvider(storeId));
                              if (dialogContext.mounted) {
                                showSuccessToast(
                                  dialogContext,
                                  context.l10n.kitchenReprintQueued,
                                );
                              }
                            },
                          ),
                      ],
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(context.l10n.close),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _KitchenFailedPrintJobRow extends StatelessWidget {
  const _KitchenFailedPrintJobRow({required this.job, required this.onReprint});

  final FailedPrintJob job;
  final Future<void> Function() onReprint;

  @override
  Widget build(BuildContext context) {
    final updatedAt = TimeUtils.toVietnam(job.updatedAt);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${job.floorLabel} / ${job.tableNumber} / ${job.copyType}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.system(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  context.l10n.kitchenPrintJobBatch(
                    job.batchNo,
                    DateFormat('HH:mm').format(updatedAt),
                  ),
                  style: AppFonts.system(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                if (job.lastError != null && job.lastError!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    job.lastError!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.system(
                      color: PosColors.warning,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: const Key('kitchen_reprint_print_job_button'),
            onPressed: onReprint,
            icon: const Icon(Icons.refresh_outlined, size: 16),
            label: Text(context.l10n.cashierReprint),
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
      icon: _kitchenStatusIcon(normalized),
      compact: true,
    );
  }
}

class _KitchenStatusCue extends StatelessWidget {
  const _KitchenStatusCue({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final normalized = status.toLowerCase();
    final color = _kitchenStatusColor(normalized);

    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: _kitchenStatusFill(normalized),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Icon(_kitchenStatusIcon(normalized), color: color, size: 17),
    );
  }
}

List<KitchenOrder> _filterKitchenOrders(
  List<KitchenOrder> orders,
  String query,
) {
  final normalizedQuery = _normalizeKitchenSearch(query);
  if (normalizedQuery.isEmpty) {
    return orders;
  }

  return orders.where((order) {
    final ticketCode = _shortKitchenTicketCode(order.orderId);
    final haystack = [
      order.orderId,
      ticketCode,
      order.tableNumber,
      if (order.isStaffMeal) 'staff meal',
      if (order.isQrOrder) 'qr table order',
      ...order.items.map((item) => item.label),
    ].map(_normalizeKitchenSearch).join(' ');
    return haystack.contains(normalizedQuery);
  }).toList();
}

String _shortKitchenTicketCode(String orderId) {
  final normalized = orderId.trim();
  return normalized.length >= 8 ? normalized.substring(0, 8) : normalized;
}

String _normalizeKitchenSearch(String raw) {
  return raw.trim().toLowerCase();
}

const int _kitchenOverdueMinutes = 15;
const int _kitchenStaleDisplayHours = 24;

Duration _kitchenDisplayElapsed(DateTime createdAt, DateTime now) {
  final diff = now.toUtc().difference(createdAt.toUtc());
  if (diff.isNegative) {
    return Duration.zero;
  }
  final staleLimit = Duration(hours: _kitchenStaleDisplayHours);
  if (diff > staleLimit) {
    return staleLimit;
  }
  return diff;
}

int _kitchenElapsedMinutes(DateTime createdAt, DateTime now) {
  return _kitchenDisplayElapsed(createdAt, now).inMinutes;
}

String _elapsedLabel(BuildContext context, DateTime createdAt, DateTime now) {
  final rawDiff = now.toUtc().difference(createdAt.toUtc());
  final diff = _kitchenDisplayElapsed(createdAt, now);
  if (diff.inSeconds < 60) {
    return context.l10n.kitchenSecondsAgo(diff.inSeconds);
  }
  if (diff.inMinutes < 60) {
    return context.l10n.kitchenMinutesAgo(diff.inMinutes);
  }
  final label = context.l10n.kitchenHoursAgo(diff.inHours);
  return rawDiff > Duration(hours: _kitchenStaleDisplayHours)
      ? '$label+'
      : label;
}

Color _orderPriorityColor(KitchenOrder order, DateTime now) {
  final hasPending = order.items.any((item) => item.status == 'pending');
  final hasPreparing = order.items.any((item) => item.status == 'preparing');
  final hasReady = order.items.any((item) => item.status == 'ready');
  final waitMinutes = _kitchenElapsedMinutes(order.createdAt, now);
  if (waitMinutes >= _kitchenOverdueMinutes) {
    return PosColors.danger;
  }
  if (hasPending || hasPreparing) {
    return PosColors.warning;
  }
  if (hasReady) {
    return PosColors.success;
  }
  return PosSurfaceRole.background.stroke;
}

Color _orderPriorityFill(KitchenOrder order, DateTime now) {
  final hasPending = order.items.any((item) => item.status == 'pending');
  final hasPreparing = order.items.any((item) => item.status == 'preparing');
  final hasReady = order.items.any((item) => item.status == 'ready');
  final waitMinutes = _kitchenElapsedMinutes(order.createdAt, now);
  if (waitMinutes >= _kitchenOverdueMinutes) {
    return PosStatusPalette.delayed;
  }
  if (hasPending) {
    return PosStatusPalette.newOrder;
  }
  if (hasPreparing) {
    return PosStatusPalette.preparing;
  }
  if (hasReady) {
    return PosStatusPalette.handoffReady;
  }
  return PosSurfaceRole.background.fill;
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

IconData _kitchenStatusIcon(String normalizedStatus) {
  return switch (normalizedStatus) {
    'pending' => Icons.fiber_new_rounded,
    'preparing' => Icons.local_fire_department_rounded,
    'ready' => Icons.room_service_rounded,
    'served' => Icons.check_circle_rounded,
    _ => Icons.circle_outlined,
  };
}

String _statusLabel(BuildContext context, String normalizedStatus) {
  switch (normalizedStatus) {
    case 'pending':
      return context.l10n.kitchenNewOrders;
    case 'preparing':
      return context.l10n.kitchenCooking;
    case 'ready':
      return context.l10n.kitchenReadyHandoff;
    case 'served':
      return context.l10n.kitchenServedStatus;
    default:
      return normalizedStatus;
  }
}

String _localizedKitchenItemLabel(BuildContext context, Object? value) {
  final raw = value?.toString().trim();
  if (raw == null || raw.isEmpty) {
    return '-';
  }
  final language = Localizations.localeOf(context).languageCode;
  return switch (raw.toLowerCase()) {
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

Color _kitchenStatusColor(String normalizedStatus) {
  switch (normalizedStatus) {
    case 'pending':
      return PosColors.info;
    case 'preparing':
      return PosColors.warning;
    case 'ready':
      return PosColors.success;
    case 'served':
      return PosColors.textSecondary;
    default:
      return PosColors.textSecondary;
  }
}

Color _kitchenStatusFill(String normalizedStatus) {
  return switch (normalizedStatus) {
    'pending' => PosStatusPalette.newOrder,
    'preparing' => PosStatusPalette.preparing,
    'ready' => PosStatusPalette.handoffReady,
    'served' => PosStatusPalette.available,
    _ => PosSurfaceRole.background.fill,
  };
}
