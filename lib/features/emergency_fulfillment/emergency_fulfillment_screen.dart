import 'dart:async';

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
  String? _selectedOrderId;
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

  Set<String> _actionableOrderIds(EmergencyFulfillmentState value) {
    final station = value.stationType;
    return value.orders
        .where((order) {
          return order.items.any(
            (item) => switch (station) {
              'kitchen' => item.kitchenDoneQuantity < item.orderedQuantity,
              'tray' =>
                item.trayReceivedQuantity < item.kitchenDoneQuantity ||
                    item.trayDispatchedQuantity < item.trayReceivedQuantity,
              'floor' => item.floorServedQuantity < item.trayDispatchedQuantity,
              _ => false,
            },
          );
        })
        .map((order) => order.orderId)
        .toSet();
  }

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

    return Scaffold(
      key: const Key('emergency_fulfillment_screen'),
      backgroundColor: _flashing
          ? const Color(0xFFFFE0B2)
          : PosSurfaceRole.background.fill,
      body: SafeArea(
        child: Column(
          children: [
            const OfflineBanner(),
            _EmergencyHeader(
              title: state.stationType == null || state.stationType == 'kitchen'
                  ? context.l10n.kitchenTitle
                  : copy.stationTitle(state.stationType, state.floorLabel),
              active: state.active,
              alarmEnabled: _alarmEnabled,
              pendingOutboxCount: state.pendingOutboxCount,
              onEnableAlarm: state.assigned ? () => _enableAlarm(state) : null,
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
    );
  }

  Widget _buildActive(
    BuildContext context,
    EmergencyFulfillmentState state,
    _EmergencyCopy copy,
  ) {
    if (state.orders.isEmpty) {
      return _EmergencyLockedState(
        icon: Icons.task_alt_rounded,
        title: copy.noOrders,
        body: copy.noOrdersBody,
      );
    }
    final selected = state.orders.firstWhere(
      (order) => order.orderId == _selectedOrderId,
      orElse: () => state.orders.first,
    );
    _selectedOrderId ??= selected.orderId;
    final queue = _EmergencyOrderQueue(
      orders: state.orders,
      stationType: state.stationType ?? 'kitchen',
      selectedOrderId: selected.orderId,
      onSelected: (orderId) => setState(() => _selectedOrderId = orderId),
      copy: copy,
    );
    final details = _EmergencyOrderDetails(
      order: selected,
      stationType: state.stationType ?? 'kitchen',
      copy: copy,
      onProgress: (itemId, stage, delta) => ref
          .read(emergencyFulfillmentProvider.notifier)
          .recordProgress(itemId: itemId, stage: stage, delta: delta),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final tabletKitchen =
            state.stationType == 'kitchen' && constraints.maxWidth >= 760;
        if (tabletKitchen) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                SizedBox(width: 300, child: queue),
                const SizedBox(width: 16),
                Expanded(child: details),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              SizedBox(height: 156, child: queue),
              const SizedBox(height: 12),
              Expanded(child: details),
            ],
          ),
        );
      },
    );
  }
}

class _EmergencyHeader extends StatelessWidget {
  const _EmergencyHeader({
    required this.title,
    required this.active,
    required this.alarmEnabled,
    required this.pendingOutboxCount,
    required this.onEnableAlarm,
    required this.onRefresh,
  });

  final String title;
  final bool active;
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
                active ? Icons.crisis_alert_rounded : Icons.print_rounded,
                color: active ? PosColors.danger : PosColors.textSecondary,
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
                      active ? copy.emergencyActive : copy.normalOperation,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: active
                            ? PosColors.danger
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

class _EmergencyOrderQueue extends StatelessWidget {
  const _EmergencyOrderQueue({
    required this.orders,
    required this.stationType,
    required this.selectedOrderId,
    required this.onSelected,
    required this.copy,
  });

  final List<EmergencyFulfillmentOrder> orders;
  final String stationType;
  final String selectedOrderId;
  final ValueChanged<String> onSelected;
  final _EmergencyCopy copy;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      scrollDirection: MediaQuery.sizeOf(context).width < 760
          ? Axis.horizontal
          : Axis.vertical,
      itemCount: orders.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8, height: 8),
      itemBuilder: (context, index) {
        final order = orders[index];
        final stage = stationType == 'floor'
            ? 'floor_served'
            : stationType == 'tray'
            ? 'tray_dispatched'
            : 'kitchen_done';
        final complete = order.isCompleteForStage(stage);
        final selected = order.orderId == selectedOrderId;
        return SizedBox(
          width: MediaQuery.sizeOf(context).width < 760 ? 184 : null,
          child: Material(
            color: selected ? PosColors.accentMuted : PosColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: selected ? PosColors.accent : PosColors.border,
                width: selected ? 2 : 1,
              ),
            ),
            child: InkWell(
              key: ValueKey('emergency_order_${order.orderId}'),
              onTap: () => onSelected(order.orderId),
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          '#${order.queueNo}',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        const Spacer(),
                        Icon(
                          complete
                              ? Icons.check_circle_rounded
                              : Icons.schedule_rounded,
                          color: complete
                              ? PosColors.success
                              : PosColors.warning,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${copy.table} ${order.tableNumber} · ${order.floorLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${order.items.length} ${copy.items}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PosColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EmergencyOrderDetails extends StatelessWidget {
  const _EmergencyOrderDetails({
    required this.order,
    required this.stationType,
    required this.copy,
    required this.onProgress,
  });

  final EmergencyFulfillmentOrder order;
  final String stationType;
  final _EmergencyCopy copy;
  final void Function(String itemId, String stage, int delta) onProgress;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: PosColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${copy.order} #${order.queueNo} · ${copy.table} ${order.tableNumber}',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Chip(label: Text(order.floorLabel)),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: order.items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) => _EmergencyItemCard(
                item: order.items[index],
                stationType: stationType,
                copy: copy,
                onProgress: onProgress,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmergencyItemCard extends StatelessWidget {
  const _EmergencyItemCard({
    required this.item,
    required this.stationType,
    required this.copy,
    required this.onProgress,
  });

  final EmergencyFulfillmentItem item;
  final String stationType;
  final _EmergencyCopy copy;
  final void Function(String itemId, String stage, int delta) onProgress;

  @override
  Widget build(BuildContext context) {
    final languageCode = Localizations.localeOf(context).languageCode;
    final primaryStage = stationType == 'floor'
        ? 'floor_served'
        : stationType == 'tray'
        ? 'tray_received'
        : 'kitchen_done';
    final primaryCount = item.quantityForStage(primaryStage);
    final primaryLimit = switch (primaryStage) {
      'tray_received' => item.kitchenDoneQuantity,
      'floor_served' => item.trayDispatchedQuantity,
      _ => item.orderedQuantity,
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: PosSurfaceRole.background.fill,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: item.needsReview ? PosColors.danger : PosColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.localizedName(languageCode),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                '$primaryCount / $primaryLimit',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: primaryCount >= primaryLimit && primaryLimit > 0
                      ? PosColors.success
                      : PosColors.textPrimary,
                ),
              ),
            ],
          ),
          if (item.needsReview) ...[
            const SizedBox(height: 6),
            Text(
              copy.quantityReview,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PosColors.danger,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (stationType == 'tray')
            LayoutBuilder(
              builder: (context, constraints) {
                final received = _StageControl(
                  label: copy.received,
                  value: item.trayReceivedQuantity,
                  limit: item.kitchenDoneQuantity,
                  canDecrement:
                      item.trayReceivedQuantity > item.trayDispatchedQuantity,
                  onDelta: (delta) =>
                      onProgress(item.id, 'tray_received', delta),
                );
                final dispatched = _StageControl(
                  label: copy.dispatched,
                  value: item.trayDispatchedQuantity,
                  limit: item.trayReceivedQuantity,
                  canDecrement:
                      item.trayDispatchedQuantity > item.floorServedQuantity,
                  onDelta: (delta) =>
                      onProgress(item.id, 'tray_dispatched', delta),
                );
                if (constraints.maxWidth < 620) {
                  return Column(
                    children: [received, const SizedBox(height: 8), dispatched],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: received),
                    const SizedBox(width: 10),
                    Expanded(child: dispatched),
                  ],
                );
              },
            )
          else
            _StageControl(
              label: stationType == 'floor' ? copy.served : copy.cooked,
              value: primaryCount,
              limit: primaryLimit,
              canDecrement: stationType == 'floor'
                  ? item.floorServedQuantity > 0
                  : item.kitchenDoneQuantity > item.trayReceivedQuantity,
              onDelta: (delta) => onProgress(item.id, primaryStage, delta),
            ),
        ],
      ),
    );
  }
}

class _StageControl extends StatelessWidget {
  const _StageControl({
    required this.label,
    required this.value,
    required this.limit,
    required this.canDecrement,
    required this.onDelta,
  });

  final String label;
  final int value;
  final int limit;
  final bool canDecrement;
  final ValueChanged<int> onDelta;

  @override
  Widget build(BuildContext context) {
    final done = limit > 0 && value >= limit;
    return Row(
      children: [
        IconButton.outlined(
          onPressed: canDecrement ? () => onDelta(-1) : null,
          icon: const Icon(Icons.remove_rounded),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.icon(
            onPressed: value < limit ? () => onDelta(1) : null,
            icon: Icon(done ? Icons.check_rounded : Icons.touch_app_rounded),
            label: Text('$label $value/$limit'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              backgroundColor: done ? PosColors.success : PosColors.accent,
            ),
          ),
        ),
      ],
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

  String get emergencyActive =>
      _pick('비상 화면 운영 중', 'Đang vận hành khẩn cấp', 'Emergency mode active');
  String get normalOperation =>
      _pick('정상 프린터 운영', 'Vận hành máy in bình thường', 'Normal printer mode');
  String get printerMode =>
      _pick('프린터 우선 모드', 'Chế độ ưu tiên máy in', 'Printer-first mode');
  String get printerModeBody => _pick(
    'Super Admin이 비상 모드를 열기 전에는 출력물로 운영합니다.',
    'Vận hành bằng phiếu in cho đến khi Super Admin bật chế độ khẩn cấp.',
    'Printed tickets remain authoritative until a Super Admin activates emergency mode.',
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
  String get enableAlarm => _pick('알람 켜기', 'Bật cảnh báo', 'Enable alerts');
  String get alarmOn => _pick('알람 켜짐', 'Đã bật cảnh báo', 'Alerts on');
  String get pendingSync => _pick('전송 대기', 'Chờ đồng bộ', 'Pending sync');
  String get refresh => _pick('새로고침', 'Làm mới', 'Refresh');
  String get table => _pick('테이블', 'Bàn', 'Table');
  String get items => _pick('메뉴', 'món', 'items');
  String get order => _pick('오더', 'Đơn', 'Order');
  String get cooked => _pick('조리 완료', 'Nấu xong', 'Cooked');
  String get received => _pick('주방 수령', 'Đã nhận từ bếp', 'Received');
  String get dispatched => _pick('층별 전달', 'Đã chuyển lên tầng', 'Dispatched');
  String get served => _pick('제공 완료', 'Đã phục vụ', 'Served');
  String get quantityReview => _pick(
    '주문 수량이 처리 수량보다 줄었습니다. 관리자 확인이 필요합니다.',
    'Số lượng đơn đã giảm dưới số lượng xử lý. Cần quản lý xác nhận.',
    'Ordered quantity fell below processed quantity. Manager review is required.',
  );
}
