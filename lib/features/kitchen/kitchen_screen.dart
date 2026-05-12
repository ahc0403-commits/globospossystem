import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../core/utils/time_utils.dart';

import '../../core/ui/app_primitives.dart';
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
  return response?['name']?.toString() ?? 'Store';
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
  final Map<String, Timer> _flashTimers = <String, Timer>{};
  String? _lastError;
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
      final oldIds = (prev?.orders ?? const <KitchenOrder>[])
          .map((order) => order.orderId)
          .toSet();
      final newOrders = next.orders.where(
        (order) => !oldIds.contains(order.orderId),
      );
      for (final order in newOrders) {
        _triggerFlash(order.orderId);
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

  void _ensureLoaded(String? storeId) {
    if (storeId == null || _initializedRestaurantId == storeId) {
      return;
    }
    _initializedRestaurantId = storeId;
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

  Future<void> _handleItemTap(
    KitchenNotifier notifier,
    KitchenOrder order,
    KitchenItem item,
  ) async {
    final nextStatus = _cycleStatus(item.status);
    final isLastToServe =
        nextStatus == 'served' &&
        order.items.every(
          (current) =>
              current.itemId == item.itemId || current.status == 'served',
        );

    if (isLastToServe) {
      setState(() {
        _completedOrderIds.add(order.orderId);
      });
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      setState(() {
        _completedOrderIds.remove(order.orderId);
      });
    }

    await notifier.updateItemStatus(item.itemId, nextStatus);
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
                          title: 'Could not load kitchen orders',
                          message:
                              'Try reloading this board once the connection is stable.',
                          onRetry: storeId == null
                              ? null
                              : () => notifier.loadOrders(storeId),
                        );
                      }
                      if (kitchenState.orders.isEmpty) {
                        return const ToastOperationalEmptyState(
                          headline: PosEmptyStateCopy.kitchenQueueClear,
                          helper: PosEmptyStateCopy.kitchenQueueClearHelper,
                          icon: Icons.restaurant_menu,
                        );
                      }

                      return Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                            child: _KitchenAttentionSection(
                              orders: kitchenState.orders,
                              now: _now,
                            ),
                          ),
                          Expanded(
                            child: GridView.builder(
                              padding: const EdgeInsets.all(16),
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 420,
                                    mainAxisSpacing: 14,
                                    crossAxisSpacing: 14,
                                    childAspectRatio: 1.1,
                                  ),
                              itemCount: kitchenState.orders.length,
                              itemBuilder: (context, index) {
                          final order = kitchenState.orders[index];
                          final hasPending = order.items.any(
                            (item) => item.status == 'pending',
                          );
                          final flashing = _flashingOrderIds.contains(
                            order.orderId,
                          );
                          final completedFlashing = _completedOrderIds.contains(
                            order.orderId,
                          );
                          final elapsed = _elapsedLabel(order.createdAt, _now);

                                return KeyedSubtree(
                                  key: Key('kitchen_order_${order.orderId}'),
                                  child: AnimatedContainer(
                            key: index == 0
                                ? const Key('kitchen_first_order_card')
                                : null,
                            duration: const Duration(milliseconds: 260),
                            decoration: BoxDecoration(
                              color: AppColors.surface1,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: completedFlashing
                                    ? AppColors.statusAvailable
                                    : flashing
                                    ? AppColors.amber500
                                    : AppColors.surface2,
                                width: flashing ? 2.5 : 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.4),
                                  blurRadius: 16,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: hasPending
                                        ? AppColors.amber500
                                        : AppColors.surface2,
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(16),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Text(
                                        'T${order.tableNumber}',
                                        style: GoogleFonts.bebasNeue(
                                          color: hasPending
                                              ? AppColors.surface0
                                              : AppColors.textPrimary,
                                          fontSize: 32,
                                          letterSpacing: 1.0,
                                        ),
                                      ),
                                      const Spacer(),
                                      Text(
                                        elapsed,
                                        style: GoogleFonts.notoSansKr(
                                          color: hasPending
                                              ? AppColors.surface0
                                              : AppColors.textSecondary,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: ListView.separated(
                                    padding: const EdgeInsets.all(12),
                                    itemCount: order.items.length,
                                    separatorBuilder: (_, _) =>
                                        const SizedBox(height: 8),
                                    itemBuilder: (context, itemIndex) {
                                      final item = order.items[itemIndex];
                                      return InkWell(
                                        key: (index == 0 && itemIndex == 0)
                                            ? const Key(
                                                'kitchen_advance_status_button',
                                              )
                                            : null,
                                        onTap: () => _handleItemTap(
                                          notifier,
                                          order,
                                          item,
                                        ),
                                        borderRadius: BorderRadius.circular(10),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            color: AppColors.surface0,
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            border: Border.all(
                                              color: AppColors.surface2,
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              Text(
                                                '${item.quantity}x',
                                                style: GoogleFonts.bebasNeue(
                                                  color: AppColors.amber500,
                                                  fontSize: 24,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  item.label,
                                                  style: GoogleFonts.notoSansKr(
                                                    color:
                                                        AppColors.textPrimary,
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                              _StatusChip(status: item.status),
                                            ],
                                          ),
                                        ),
                                              );
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
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

class _KitchenAttentionSection extends StatelessWidget {
  const _KitchenAttentionSection({required this.orders, required this.now});

  final List<KitchenOrder> orders;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
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
    final readyTables = orders.where(
      (order) => order.items.any((item) => item.status == 'ready'),
    ).length;
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
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Kitchen Attention',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Read-only kitchen readiness layer built from the tracked active order queue.',
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
                'Follow-up now',
                '$followUpCount',
                followUpCount > 0
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
              _attentionMetric(
                'Pending items',
                '$pendingItems',
                pendingItems > 0
                    ? AppColors.statusCancelled
                    : AppColors.statusAvailable,
              ),
              _attentionMetric(
                'Ready items',
                '$readyItems',
                readyItems > 0 ? AppColors.amber500 : AppColors.statusAvailable,
              ),
              _attentionMetric(
                'Oldest wait',
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
                'Active tables ${orders.length}',
                AppColors.textPrimary,
              ),
              _attentionChip(
                'Preparing $preparingItems',
                preparingItems > 0
                    ? AppColors.statusAvailable
                    : AppColors.textSecondary,
              ),
              _attentionChip(
                'Long waits $longWaitCount',
                longWaitCount > 0
                    ? AppColors.statusCancelled
                    : AppColors.statusAvailable,
              ),
              _attentionChip(
                'Ready tables $readyTables',
                readyTables > 0 ? AppColors.amber500 : AppColors.statusAvailable,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _attentionSupportRow(
            'Follow-up focus',
            _followUpCopy(
              pendingItems: pendingItems,
              readyItems: readyItems,
              longWaitCount: longWaitCount,
            ),
          ),
          const SizedBox(height: 8),
          _attentionSupportRow(
            'Handoff readiness',
            _handoffReadinessCopy(
              readyItems: readyItems,
              readyTables: readyTables,
              oldestWaitMinutes: oldestWaitMinutes,
            ),
          ),
          const SizedBox(height: 8),
          _attentionSupportRow(
            'Boundary',
            'Read-only kitchen readiness surface only. Status advancement remains on the tracked order cards below.',
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
    required int pendingItems,
    required int readyItems,
    required int longWaitCount,
  }) {
    if (longWaitCount > 0) {
      return 'Long-wait tickets should be checked first because they signal the highest service risk in the active kitchen queue.';
    }
    if (readyItems > 0) {
      return 'Ready items are waiting on the next handoff step, so they are the clearest near-term release point in the queue.';
    }
    if (pendingItems > 0) {
      return 'Pending items still dominate the active queue, so prep throughput is the primary watch item right now.';
    }
    return 'No immediate kitchen follow-up signal is ahead of the others for the current board snapshot.';
  }

  String _handoffReadinessCopy({
    required int readyItems,
    required int readyTables,
    required int oldestWaitMinutes,
  }) {
    if (readyItems > 0) {
      return '$readyItems ready items across $readyTables tables are waiting on the next handoff step.';
    }
    if (oldestWaitMinutes >= 15) {
      return 'No items are marked ready yet, but aging tickets suggest the next service release point should be checked closely.';
    }
    return 'No immediate handoff queue is visible right now, so the board is still prep-dominant rather than release-dominant.';
  }
}

class _KitchenTopBar extends ConsumerWidget {
  const _KitchenTopBar({required this.now, required this.storeId});

  final DateTime now;
  final String? storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final restaurantName = storeId == null
        ? const AsyncValue<String>.data('Store')
        : ref.watch(kitchenRestaurantNameProvider(storeId!));

    return Container(
      height: 76,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.surface3)),
      ),
      child: Row(
        children: [
          const AppNavBar(),
          const SizedBox(width: 12),
          Text('KITCHEN', style: AppTextStyles.operationalTitle(size: 28)),
          const SizedBox(width: 16),
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
          Text(
            DateFormat('HH:mm:ss').format(TimeUtils.toVietnam(now)), // UTC→VN
            style: GoogleFonts.bebasNeue(
              color: AppColors.textPrimary,
              fontSize: 30,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            key: const Key('logout_button'),
            icon: const Icon(Icons.logout, color: AppColors.textSecondary),
            tooltip: 'Log Out',
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
    final color = switch (normalized) {
      'preparing' => AppColors.amber500,
      'ready' => AppColors.statusAvailable,
      'served' => AppColors.surface2,
      _ => const Color(0xFF757575),
    };
    return ToastStatusChip(label: normalized, color: color, solid: true);
  }
}

String _elapsedLabel(DateTime createdAt, DateTime now) {
  final diff = now.difference(createdAt);
  if (diff.inSeconds < 60) {
    return '${diff.inSeconds}s ago';
  }
  if (diff.inMinutes < 60) {
    return '${diff.inMinutes} min ago';
  }
  return '${diff.inHours}h ago';
}
