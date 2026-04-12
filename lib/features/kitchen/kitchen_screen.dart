import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../core/utils/time_utils.dart';

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
                        return const Center(
                          child: CircularProgressIndicator(
                            color: AppColors.amber500,
                          ),
                        );
                      }
                      if (kitchenState.error != null) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Could not load kitchen orders.',
                                style: GoogleFonts.notoSansKr(
                                  color: AppColors.statusCancelled,
                                  fontSize: 14,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 12),
                              ElevatedButton(
                                onPressed: storeId == null
                                    ? null
                                    : () => notifier.loadOrders(storeId),
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
                      if (kitchenState.orders.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.restaurant_menu,
                                color: AppColors.textSecondary,
                                size: 54,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                'No active orders',
                                style: GoogleFonts.notoSansKr(
                                  color: AppColors.textSecondary,
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          ),
                        );
                      }

                      return GridView.builder(
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

                          return AnimatedContainer(
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
                          );
                        },
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
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.surface2)),
      ),
      child: Row(
        children: [
          const AppNavBar(),
          const SizedBox(width: 12),
          Text(
            'KITCHEN',
            style: GoogleFonts.bebasNeue(
              color: AppColors.amber500,
              fontSize: 28,
              letterSpacing: 1.0,
            ),
          ),
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
    Color color;
    Color textColor;
    switch (normalized) {
      case 'preparing':
        color = AppColors.amber500;
        textColor = AppColors.surface0;
      case 'ready':
        color = AppColors.statusAvailable;
        textColor = AppColors.surface0;
      case 'served':
        color = AppColors.surface2;
        textColor = AppColors.textSecondary;
      case 'pending':
      default:
        color = Colors.grey.shade600;
        textColor = AppColors.textPrimary;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        normalized.toUpperCase(),
        style: GoogleFonts.notoSansKr(
          color: textColor,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
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
