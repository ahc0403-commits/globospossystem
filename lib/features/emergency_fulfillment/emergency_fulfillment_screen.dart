import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/services/emergency_web_bridge.dart';
import '../../core/services/emergency_web_push_service.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/offline_banner.dart';
import 'emergency_fulfillment_provider.dart';

class EmergencyFulfillmentScreen extends ConsumerStatefulWidget {
  const EmergencyFulfillmentScreen({
    super.key,
    this.expectedStationType,
    this.printerModeKey,
  });

  final String? expectedStationType;
  final Key? printerModeKey;

  @override
  ConsumerState<EmergencyFulfillmentScreen> createState() =>
      _EmergencyFulfillmentScreenState();
}

class _EmergencyFulfillmentScreenState
    extends ConsumerState<EmergencyFulfillmentScreen> {
  bool _initialSnapshotObserved = false;
  bool _alarmEnabled = false;
  bool _flashing = false;
  bool _showRecent = false;
  bool _actionBusy = false;
  String? _selectedOrderId;
  int _page = 0;
  Timer? _flashTimer;
  late final ProviderSubscription<EmergencyFulfillmentState> _stateSub;

  @override
  void initState() {
    super.initState();
    _stateSub = ref.listenManual<EmergencyFulfillmentState>(
      emergencyFulfillmentProvider,
      _onStateChanged,
    );
    Future.microtask(
      () => ref.read(emergencyFulfillmentProvider.notifier).load(),
    );
  }

  void _onStateChanged(
    EmergencyFulfillmentState? previous,
    EmergencyFulfillmentState next,
  ) {
    if (next.isLoading) return;
    if (!_initialSnapshotObserved) {
      _initialSnapshotObserved = true;
      return;
    }
    final oldActionable = _actionableOrderIds(
      previous ?? const EmergencyFulfillmentState(),
    );
    final newActionable = _actionableOrderIds(next);
    if (newActionable.difference(oldActionable).isNotEmpty) {
      _triggerAlarm();
    }
    if (_selectedOrderId != null &&
        !next.orders.any((order) => order.orderId == _selectedOrderId)) {
      setState(() => _selectedOrderId = null);
    }
  }

  Set<String> _actionableOrderIds(EmergencyFulfillmentState value) => value
      .orders
      .where((order) => order.hasActionableQuantity(value.stationType ?? ''))
      .map((order) => order.orderId)
      .toSet();

  Future<void> _triggerAlarm() async {
    if (!mounted) return;
    setState(() => _flashing = true);
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _flashing = false);
    });
    if (_alarmEnabled) {
      await EmergencyWebBridge.playAlarm();
      try {
        await SystemSound.play(SystemSoundType.alert);
      } catch (_) {
        // The Web Audio bridge is the browser path; SystemSound is fallback.
      }
    }
  }

  Future<void> _enableAlarm(EmergencyFulfillmentState state) async {
    final foregroundReady = await EmergencyWebBridge.enableAlarm();
    final storeId = state.restaurantId;
    if (storeId != null) {
      await EmergencyWebPushService.instance.enable(storeId: storeId);
    }
    if (!mounted) return;
    setState(() => _alarmEnabled = foregroundReady);
    if (foregroundReady) await _triggerAlarm();
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    _stateSub.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(emergencyFulfillmentProvider);
    final copy = _EmergencyCopy.of(context);
    final expected = widget.expectedStationType;
    final stationMismatch =
        expected != null &&
        state.stationType != null &&
        state.stationType != expected;

    return PopScope(
      canPop: _selectedOrderId == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectedOrderId != null) {
          setState(() => _selectedOrderId = null);
        }
      },
      child: Scaffold(
        key: const Key('emergency_fulfillment_screen'),
        backgroundColor: _flashing
            ? const Color(0xFFFFE0B2)
            : PosSurfaceRole.background.fill,
        body: SafeArea(
          child: Column(
            children: [
              const OfflineBanner(),
              _EmergencyHeader(
                title:
                    state.stationType == null || state.stationType == 'kitchen'
                    ? context.l10n.kitchenTitle
                    : copy.stationTitle(state.stationType, state.floorLabel),
                active: state.active,
                draining: state.isDraining,
                alarmEnabled: _alarmEnabled,
                pendingOutboxCount: state.pendingOutboxCount,
                onEnableAlarm: state.assigned
                    ? () => _enableAlarm(state)
                    : null,
                onRefresh: () => ref
                    .read(emergencyFulfillmentProvider.notifier)
                    .load(showLoading: false),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: state.isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : stationMismatch
                      ? _EmergencyLockedState(
                          icon: Icons.lock_outline_rounded,
                          title: copy.assignmentMismatch,
                          body: copy.assignmentMismatchBody,
                        )
                      : !state.assigned
                      ? _EmergencyLockedState(
                          icon: Icons.badge_outlined,
                          title: copy.noAssignment,
                          body: copy.noAssignmentBody,
                        )
                      : !state.active
                      ? _EmergencyLockedState(
                          key:
                              widget.printerModeKey ??
                              const Key('emergency_printer_mode_state'),
                          icon: Icons.print_rounded,
                          title: copy.printerMode,
                          body: copy.printerModeBody,
                        )
                      : _buildActive(context, state, copy),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActive(
    BuildContext context,
    EmergencyFulfillmentState state,
    _EmergencyCopy copy,
  ) {
    final stationType = state.stationType ?? 'kitchen';
    final activeOrders = state.orders
        .where(
          (order) =>
              order.hasActionableQuantity(stationType) ||
              state.pendingQueueIds.contains(order.queueId),
        )
        .toList(growable: false);
    final recentOrders =
        state.orders
            .where(
              (order) =>
                  !order.hasActionableQuantity(stationType) &&
                  order.lastActionId != null,
            )
            .toList(growable: false)
          ..sort(
            (a, b) => (b.lastActionAt ?? b.createdAt).compareTo(
              a.lastActionAt ?? a.createdAt,
            ),
          );

    final selected = _selectedOrderId == null
        ? null
        : state.orders.cast<EmergencyFulfillmentOrder?>().firstWhere(
            (order) => order?.orderId == _selectedOrderId,
            orElse: () => null,
          );
    if (selected != null) {
      return _EmergencyOrderDetails(
        order: selected,
        stationType: stationType,
        copy: copy,
        busy: _actionBusy,
        pending: state.pendingQueueIds.contains(selected.queueId),
        error: state.error,
        onBack: () => setState(() => _selectedOrderId = null),
        onComplete: () => _completeOrder(selected),
        onItemAction: (item) => _completeItem(item, stationType),
        onRevert: selected.lastActionId == null
            ? null
            : () => _revertOrder(selected),
      );
    }

    final orders = _showRecent ? recentOrders : activeOrders;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BoardModeSelector(
            showRecent: _showRecent,
            activeCount: activeOrders.length,
            recentCount: recentOrders.length,
            copy: copy,
            onChanged: (showRecent) => setState(() {
              _showRecent = showRecent;
              _page = 0;
            }),
          ),
          if (state.error != null) ...[
            const SizedBox(height: 8),
            _EmergencyStatusBanner(message: copy.errorMessage(state.error!)),
          ],
          const SizedBox(height: 10),
          Expanded(
            child: orders.isEmpty
                ? _EmergencyLockedState(
                    icon: _showRecent
                        ? Icons.history_toggle_off_rounded
                        : Icons.task_alt_rounded,
                    title: _showRecent ? copy.noRecent : copy.noOrders,
                    body: _showRecent ? copy.noRecentBody : copy.noOrdersBody,
                  )
                : _EmergencyOrderBoard(
                    orders: orders,
                    stationType: stationType,
                    pendingQueueIds: state.pendingQueueIds,
                    requestedPage: _page,
                    copy: copy,
                    onPageChanged: (page) => setState(() => _page = page),
                    onSelected: (orderId) =>
                        setState(() => _selectedOrderId = orderId),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _completeOrder(EmergencyFulfillmentOrder order) async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    final success = await ref
        .read(emergencyFulfillmentProvider.notifier)
        .completeOrder(queueId: order.queueId);
    if (!mounted) return;
    final nextState = ref.read(emergencyFulfillmentProvider);
    final nextOrder = nextState.orders
        .where(
          (candidate) =>
              candidate.orderId != order.orderId &&
              candidate.hasActionableQuantity(nextState.stationType ?? ''),
        )
        .cast<EmergencyFulfillmentOrder?>()
        .firstWhere((_) => true, orElse: () => null);
    setState(() {
      _actionBusy = false;
      if (success) {
        _showRecent = false;
        _selectedOrderId = nextOrder?.orderId;
        _page = 0;
      }
    });
  }

  Future<void> _completeItem(
    EmergencyFulfillmentItem item,
    String stationType,
  ) async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    final notifier = ref.read(emergencyFulfillmentProvider.notifier);
    try {
      switch (stationType) {
        case 'kitchen':
          await notifier.recordProgress(itemId: item.id, stage: 'kitchen_done');
        case 'tray':
          await notifier.recordProgress(
            itemId: item.id,
            stage: 'tray_received',
          );
          await notifier.recordProgress(
            itemId: item.id,
            stage: 'tray_dispatched',
          );
        case 'floor':
          await notifier.recordProgress(itemId: item.id, stage: 'floor_served');
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _revertOrder(EmergencyFulfillmentOrder order) async {
    final actionId = order.lastActionId;
    if (_actionBusy || actionId == null) return;
    setState(() => _actionBusy = true);
    final success = await ref
        .read(emergencyFulfillmentProvider.notifier)
        .revertOrder(queueId: order.queueId, actionId: actionId);
    if (!mounted) return;
    setState(() {
      _actionBusy = false;
      if (success) {
        _showRecent = false;
        _selectedOrderId = order.orderId;
        _page = 0;
      }
    });
  }
}

class _EmergencyHeader extends StatelessWidget {
  const _EmergencyHeader({
    required this.title,
    required this.active,
    required this.draining,
    required this.alarmEnabled,
    required this.pendingOutboxCount,
    required this.onEnableAlarm,
    required this.onRefresh,
  });

  final String title;
  final bool active;
  final bool draining;
  final bool alarmEnabled;
  final int pendingOutboxCount;
  final VoidCallback? onEnableAlarm;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final copy = _EmergencyCopy.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      color: PosColors.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 680;
          final identity = Row(
            children: [
              Icon(
                active ? Icons.tablet_mac_rounded : Icons.print_rounded,
                color: active ? PosColors.accent : PosColors.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      active
                          ? (draining ? copy.draining : copy.emergencyActive)
                          : copy.normalOperation,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: active
                            ? PosColors.accent
                            : PosColors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
          final alarmButton = onEnableAlarm == null
              ? const SizedBox.shrink()
              : FilledButton.icon(
                  key: const Key('emergency_enable_alarm'),
                  onPressed: alarmEnabled ? null : onEnableAlarm,
                  icon: Icon(
                    alarmEnabled
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_off_outlined,
                    size: 18,
                  ),
                  label: Text(alarmEnabled ? copy.alarmOn : copy.enableAlarm),
                );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: identity),
                    IconButton(
                      tooltip: copy.refresh,
                      onPressed: onRefresh,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                    const AppNavBar(showLogout: true),
                  ],
                ),
                if (pendingOutboxCount > 0)
                  Text(
                    '${copy.pendingSync} $pendingOutboxCount',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.warning,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                if (onEnableAlarm != null) ...[
                  const SizedBox(height: 8),
                  alarmButton,
                ],
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: identity),
              if (pendingOutboxCount > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Chip(
                    avatar: const Icon(Icons.cloud_upload_outlined, size: 16),
                    label: Text('${copy.pendingSync} $pendingOutboxCount'),
                  ),
                ),
              IconButton(
                tooltip: copy.refresh,
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
              alarmButton,
              const SizedBox(width: 6),
              const AppNavBar(showLogout: true),
            ],
          );
        },
      ),
    );
  }
}

class _BoardModeSelector extends StatelessWidget {
  const _BoardModeSelector({
    required this.showRecent,
    required this.activeCount,
    required this.recentCount,
    required this.copy,
    required this.onChanged,
  });

  final bool showRecent;
  final int activeCount;
  final int recentCount;
  final _EmergencyCopy copy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      key: const Key('emergency_board_mode_selector'),
      segments: [
        ButtonSegment(
          value: false,
          icon: const Icon(Icons.grid_view_rounded),
          label: Text('${copy.waiting} $activeCount'),
        ),
        ButtonSegment(
          value: true,
          icon: const Icon(Icons.history_rounded),
          label: Text('${copy.recentCompleted} $recentCount'),
        ),
      ],
      selected: {showRecent},
      onSelectionChanged: (selection) => onChanged(selection.first),
      showSelectedIcon: false,
    );
  }
}

class _EmergencyOrderBoard extends StatelessWidget {
  const _EmergencyOrderBoard({
    required this.orders,
    required this.stationType,
    required this.pendingQueueIds,
    required this.requestedPage,
    required this.copy,
    required this.onPageChanged,
    required this.onSelected,
  });

  final List<EmergencyFulfillmentOrder> orders;
  final String stationType;
  final Set<String> pendingQueueIds;
  final int requestedPage;
  final _EmergencyCopy copy;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isPhone = size.shortestSide < 600;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final pageSize = isPhone ? 4 : 8;
    final columns = landscape ? 4 : 2;
    final pageCount = math.max(1, (orders.length / pageSize).ceil());
    final page = requestedPage.clamp(0, pageCount - 1);
    final firstIndex = page * pageSize;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BoardPager(
          page: page,
          pageCount: pageCount,
          orderCount: orders.length,
          copy: copy,
          onPrevious: page > 0 ? () => onPageChanged(page - 1) : null,
          onNext: page + 1 < pageCount ? () => onPageChanged(page + 1) : null,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 10.0;
              final rows = pageSize ~/ columns;
              final cellWidth =
                  (constraints.maxWidth - spacing * (columns - 1)) / columns;
              final cellHeight =
                  (constraints.maxHeight - spacing * (rows - 1)) / rows;
              return GridView.builder(
                key: Key('emergency_order_grid_${pageSize}_slots'),
                physics: const NeverScrollableScrollPhysics(),
                itemCount: pageSize,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: spacing,
                  mainAxisSpacing: spacing,
                  childAspectRatio: cellWidth / math.max(cellHeight, 1),
                ),
                itemBuilder: (context, slot) {
                  final orderIndex = firstIndex + slot;
                  if (orderIndex >= orders.length) {
                    return _EmptyBoardSlot(slot: slot);
                  }
                  final order = orders[orderIndex];
                  return _EmergencyOrderCard(
                    order: order,
                    stationType: stationType,
                    pending: pendingQueueIds.contains(order.queueId),
                    copy: copy,
                    onTap: () => onSelected(order.orderId),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _BoardPager extends StatelessWidget {
  const _BoardPager({
    required this.page,
    required this.pageCount,
    required this.orderCount,
    required this.copy,
    required this.onPrevious,
    required this.onNext,
  });

  final int page;
  final int pageCount;
  final int orderCount;
  final _EmergencyCopy copy;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton.outlined(
          key: const Key('emergency_board_previous'),
          tooltip: copy.previousPage,
          onPressed: onPrevious,
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Expanded(
          child: Text(
            '${page + 1} / $pageCount · ${copy.totalOrders} $orderCount',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        IconButton.outlined(
          key: const Key('emergency_board_next'),
          tooltip: copy.nextPage,
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ],
    );
  }
}

class _EmptyBoardSlot extends StatelessWidget {
  const _EmptyBoardSlot({required this.slot});

  final int slot;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('emergency_empty_slot_$slot'),
      decoration: BoxDecoration(
        color: PosColors.surface.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PosColors.border.withValues(alpha: 0.65)),
      ),
    );
  }
}

class _EmergencyOrderCard extends StatelessWidget {
  const _EmergencyOrderCard({
    required this.order,
    required this.stationType,
    required this.pending,
    required this.copy,
    required this.onTap,
  });

  final EmergencyFulfillmentOrder order;
  final String stationType;
  final bool pending;
  final _EmergencyCopy copy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final actionable = order.hasActionableQuantity(stationType);
    final tone = pending
        ? PosColors.warning
        : actionable
        ? _stationColor(stationType)
        : PosColors.success;
    final elapsed = DateTime.now().difference(order.createdAt.toLocal());
    final elapsedMinutes = math.max(0, elapsed.inMinutes);
    final semantics =
        '${copy.order} ${order.queueNo}, ${copy.table} ${order.tableNumber}, '
        '${order.floorLabel}, ${order.items.length} ${copy.items}';

    return Semantics(
      button: true,
      label: semantics,
      child: Material(
        color: PosColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: tone, width: 2),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('emergency_order_${order.orderId}'),
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                color: tone,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '#${order.queueNo}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                            ),
                      ),
                    ),
                    Icon(
                      pending
                          ? Icons.cloud_upload_outlined
                          : actionable
                          ? Icons.schedule_rounded
                          : Icons.check_circle_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${copy.table} ${order.tableNumber}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        '${order.floorLabel} · ${order.items.length} ${copy.items}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: PosColors.textSecondary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        pending
                            ? copy.pendingSync
                            : actionable
                            ? copy.waitingForAction
                            : copy.completed,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: tone,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        copy.elapsedMinutes(elapsedMinutes),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmergencyOrderDetails extends StatelessWidget {
  const _EmergencyOrderDetails({
    required this.order,
    required this.stationType,
    required this.copy,
    required this.busy,
    required this.pending,
    required this.error,
    required this.onBack,
    required this.onComplete,
    required this.onItemAction,
    required this.onRevert,
  });

  final EmergencyFulfillmentOrder order;
  final String stationType;
  final _EmergencyCopy copy;
  final bool busy;
  final bool pending;
  final String? error;
  final VoidCallback onBack;
  final VoidCallback onComplete;
  final ValueChanged<EmergencyFulfillmentItem> onItemAction;
  final VoidCallback? onRevert;

  @override
  Widget build(BuildContext context) {
    final canComplete = order.hasActionableQuantity(stationType) && !pending;
    return Padding(
      key: Key('emergency_order_detail_${order.orderId}'),
      padding: const EdgeInsets.all(12),
      child: Container(
        decoration: BoxDecoration(
          color: PosColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: PosColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 14, 8),
              child: Row(
                children: [
                  IconButton(
                    key: const Key('emergency_detail_back'),
                    tooltip: copy.backToBoard,
                    onPressed: busy ? null : onBack,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${copy.order} #${order.queueNo} · '
                          '${copy.table} ${order.tableNumber}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        Text(
                          '${order.floorLabel} · ${copy.stageTitle(stationType)}',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: _stationColor(stationType),
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                      ],
                    ),
                  ),
                  if (pending)
                    Chip(
                      avatar: const Icon(Icons.cloud_upload_outlined, size: 16),
                      label: Text(copy.pendingSync),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: _EmergencyStatusBanner(
                  message: copy.errorMessage(error!),
                ),
              ),
            Expanded(
              child: ListView.separated(
                key: const Key('emergency_detail_menu_list'),
                padding: const EdgeInsets.all(12),
                itemCount: order.items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) => _EmergencyMenuRow(
                  item: order.items[index],
                  stationType: stationType,
                  copy: copy,
                  busy: busy || pending,
                  onTap: () => onItemAction(order.items[index]),
                ),
              ),
            ),
            const Divider(height: 1),
            _EmergencyDetailActions(
              busy: busy,
              canComplete: canComplete,
              canRevert: onRevert != null && !pending,
              copy: copy,
              onComplete: onComplete,
              onRevert: onRevert,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmergencyMenuRow extends StatelessWidget {
  const _EmergencyMenuRow({
    required this.item,
    required this.stationType,
    required this.copy,
    required this.busy,
    required this.onTap,
  });

  final EmergencyFulfillmentItem item;
  final String stationType;
  final _EmergencyCopy copy;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final languageCode = Localizations.localeOf(context).languageCode;
    final (value, limit) = switch (stationType) {
      'kitchen' => (item.kitchenDoneQuantity, item.orderedQuantity),
      'tray' => (item.trayDispatchedQuantity, item.kitchenDoneQuantity),
      'floor' => (item.floorServedQuantity, item.trayDispatchedQuantity),
      _ => (0, item.orderedQuantity),
    };
    final done = limit > 0 && value >= limit;
    final canAdvance = !busy && limit > 0 && value < limit;
    return Semantics(
      button: true,
      enabled: canAdvance,
      label:
          '${item.localizedName(languageCode)}, $value / $limit, '
          '${done ? copy.completed : copy.waitingForAction}',
      child: GestureDetector(
        key: ValueKey('emergency_menu_item_${item.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: canAdvance ? onTap : null,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: PosSurfaceRole.background.fill,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: item.needsReview ? PosColors.danger : PosColors.border,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.localizedName(languageCode),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${copy.orderedQuantity} ${item.orderedQuantity}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PosColors.textSecondary,
                      ),
                    ),
                    if (item.needsReview) ...[
                      const SizedBox(height: 4),
                      Text(
                        copy.quantityReview,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: PosColors.danger,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '$value / $limit',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: done ? PosColors.success : PosColors.textPrimary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    done ? copy.completed : copy.waitingForAction,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: done ? PosColors.success : PosColors.warning,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmergencyDetailActions extends StatelessWidget {
  const _EmergencyDetailActions({
    required this.busy,
    required this.canComplete,
    required this.canRevert,
    required this.copy,
    required this.onComplete,
    required this.onRevert,
  });

  final bool busy;
  final bool canComplete;
  final bool canRevert;
  final _EmergencyCopy copy;
  final VoidCallback onComplete;
  final VoidCallback? onRevert;

  @override
  Widget build(BuildContext context) {
    final revert = OutlinedButton.icon(
      key: const Key('emergency_revert_order'),
      onPressed: !busy && canRevert ? onRevert : null,
      icon: const Icon(Icons.undo_rounded),
      label: Text(copy.cancelAndRevert),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        foregroundColor: PosColors.danger,
      ),
    );
    final complete = FilledButton.icon(
      key: const Key('emergency_complete_order'),
      onPressed: !busy && canComplete ? onComplete : null,
      icon: busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.arrow_forward_rounded),
      label: Text(copy.completeAndNext),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        backgroundColor: PosColors.success,
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [revert, const SizedBox(height: 8), complete],
            );
          }
          return Row(
            children: [
              Expanded(child: revert),
              const SizedBox(width: 10),
              Expanded(child: complete),
            ],
          );
        },
      ),
    );
  }
}

class _EmergencyStatusBanner extends StatelessWidget {
  const _EmergencyStatusBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: PosColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PosColors.warning),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, color: PosColors.warning),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}

class _EmergencyLockedState extends StatelessWidget {
  const _EmergencyLockedState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: PosColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: PosColors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 46, color: PosColors.accent),
                const SizedBox(height: 14),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 8),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: PosColors.textSecondary,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Color _stationColor(String stationType) => switch (stationType) {
  'tray' => const Color(0xFF1976D2),
  'floor' => const Color(0xFF7B1FA2),
  _ => const Color(0xFFD84343),
};

class _EmergencyCopy {
  const _EmergencyCopy(this.languageCode);

  final String languageCode;

  static _EmergencyCopy of(BuildContext context) =>
      _EmergencyCopy(Localizations.localeOf(context).languageCode);

  String _pick(String ko, String vi, String en) => switch (languageCode) {
    'vi' => vi,
    'en' => en,
    _ => ko,
  };

  String stationTitle(String? station, String? floor) => switch (station) {
    'tray' => _pick('트레이', 'Khay', 'Tray'),
    'floor' => _pick(
      '${floor ?? '1F'} 주문확인',
      'Tầng ${floor ?? '1F'}',
      '${floor ?? '1F'} floor',
    ),
    _ => _pick('주방', 'Bếp', 'Kitchen'),
  };

  String stageTitle(String station) => switch (station) {
    'tray' => _pick('트레이 인계', 'Bàn giao khay', 'Tray handoff'),
    'floor' => _pick('테이블 제공', 'Phục vụ bàn', 'Table service'),
    _ => _pick('주방 조리', 'Chế biến tại bếp', 'Kitchen preparation'),
  };

  String get emergencyActive =>
      _pick('페이퍼리스 작업 중', 'Đang vận hành không giấy', 'Paperless operation');
  String get draining => _pick(
    '기존 페이퍼리스 주문 마감 중',
    'Đang hoàn tất đơn không giấy cũ',
    'Draining existing paperless orders',
  );
  String get normalOperation =>
      _pick('포스 프린트 모드', 'Chế độ in POS', 'POS print mode');
  String get printerMode => _pick(
    '포스 프린트 모드 대기',
    'Đang chờ ở chế độ in POS',
    'Waiting in POS print mode',
  );
  String get printerModeBody => _pick(
    '운영 방식이 페이퍼리스로 전환되면 새 주문이 이 화면에 표시됩니다.',
    'Đơn mới sẽ hiển thị tại đây khi chuyển sang chế độ không giấy.',
    'New orders will appear here when the store switches to paperless mode.',
  );
  String get noAssignment =>
      _pick('스테이션 미배정', 'Chưa phân công trạm', 'Station not assigned');
  String get noAssignmentBody => _pick(
    '이 아이디에 주방·트레이·층별 스테이션을 배정해야 합니다.',
    'Tài khoản này cần được phân công bếp, khay hoặc tầng.',
    'Assign this account to a kitchen, tray, or floor station.',
  );
  String get assignmentMismatch =>
      _pick('잘못된 스테이션 배정', 'Phân công trạm không đúng', 'Station mismatch');
  String get assignmentMismatchBody => _pick(
    '현재 아이디의 스테이션 배정을 확인하세요.',
    'Kiểm tra lại phân công trạm của tài khoản này.',
    'Check the station assignment for this account.',
  );
  String get noOrders =>
      _pick('대기 주문 없음', 'Không có đơn chờ', 'No waiting orders');
  String get noOrdersBody => _pick(
    '새 주문이 들어오면 화면과 알람으로 알려드립니다.',
    'Đơn mới sẽ hiển thị và phát cảnh báo.',
    'New work will appear here with an alert.',
  );
  String get noRecent =>
      _pick('최근 완료 없음', 'Chưa có đơn vừa xong', 'No recent completions');
  String get noRecentBody => _pick(
    '이 화면에서 완료한 주문이 여기에 표시됩니다.',
    'Đơn hoàn tất tại màn hình này sẽ hiển thị ở đây.',
    'Orders completed at this station will appear here.',
  );
  String get enableAlarm => _pick('알람 켜기', 'Bật cảnh báo', 'Enable alerts');
  String get alarmOn => _pick('알람 켜짐', 'Đã bật cảnh báo', 'Alerts on');
  String get pendingSync => _pick('전송 대기', 'Chờ đồng bộ', 'Pending sync');
  String get refresh => _pick('새로고침', 'Làm mới', 'Refresh');
  String get waiting => _pick('대기', 'Đang chờ', 'Waiting');
  String get recentCompleted =>
      _pick('최근 완료', 'Vừa hoàn tất', 'Recently completed');
  String get table => _pick('테이블', 'Bàn', 'Table');
  String get items => _pick('메뉴', 'món', 'items');
  String get order => _pick('주문', 'Đơn', 'Order');
  String get orderedQuantity => _pick('주문 수량', 'Số lượng', 'Ordered');
  String get completed => _pick('완료', 'Hoàn tất', 'Completed');
  String get waitingForAction => _pick('처리 대기', 'Chờ xử lý', 'Action required');
  String get totalOrders => _pick('총 주문', 'Tổng đơn', 'Total');
  String get previousPage => _pick('이전 페이지', 'Trang trước', 'Previous page');
  String get nextPage => _pick('다음 페이지', 'Trang sau', 'Next page');
  String get backToBoard => _pick('주문 보드로', 'Về bảng đơn', 'Back to board');
  String get cancelAndRevert =>
      _pick('취소 (원복)', 'Hủy (hoàn tác)', 'Cancel (undo)');
  String get completeAndNext =>
      _pick('완료 (다음 단계)', 'Hoàn tất (bước tiếp theo)', 'Complete (next stage)');

  String elapsedMinutes(int minutes) =>
      _pick('$minutes분 경과', 'Đã chờ $minutes phút', '$minutes min elapsed');

  String errorMessage(String error) {
    if (error.contains('EMERGENCY_REVERT_DOWNSTREAM_PROGRESS')) {
      return _pick(
        '다음 단계에서 이미 처리하여 원복할 수 없습니다.',
        'Không thể hoàn tác vì bước tiếp theo đã xử lý.',
        'Cannot undo because the next station has already processed it.',
      );
    }
    if (error.contains('EMERGENCY_ORDER_ACTION_QUEUED')) {
      return _pick(
        '연결이 복구되면 이 작업을 자동 전송합니다.',
        'Thao tác sẽ tự gửi khi kết nối trở lại.',
        'This action will send automatically when the connection returns.',
      );
    }
    return _pick(
      '작업을 처리하지 못했습니다. 새로고침 후 다시 시도하세요.',
      'Không thể xử lý. Hãy làm mới và thử lại.',
      'The action could not be processed. Refresh and try again.',
    );
  }

  String get quantityReview => _pick(
    '주문 수량이 처리 수량보다 줄었습니다. 관리자 확인이 필요합니다.',
    'Số lượng đơn đã giảm dưới số lượng xử lý. Cần quản lý xác nhận.',
    'Ordered quantity fell below processed quantity. Manager review is required.',
  );
}
