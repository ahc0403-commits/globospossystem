import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/pos_design_tokens.dart';
import '../../main.dart';

class EmergencyStoreStatus {
  const EmergencyStoreStatus({
    required this.restaurantId,
    required this.restaurantName,
    required this.active,
    required this.unresolvedQuantity,
    required this.orderCount,
    this.reason,
  });

  final String restaurantId;
  final String restaurantName;
  final bool active;
  final int unresolvedQuantity;
  final int orderCount;
  final String? reason;

  factory EmergencyStoreStatus.fromJson(Map<String, dynamic> json) =>
      EmergencyStoreStatus(
        restaurantId: json['restaurant_id']?.toString() ?? '',
        restaurantName: json['restaurant_name']?.toString() ?? '-',
        active: json['active'] == true,
        unresolvedQuantity: _intValue(json['unresolved_quantity']),
        orderCount: _intValue(json['order_count']),
        reason: json['reason']?.toString(),
      );
}

class EmergencyControlState {
  const EmergencyControlState({
    this.stores = const [],
    this.isLoading = false,
    this.processingStoreId,
    this.error,
  });

  final List<EmergencyStoreStatus> stores;
  final bool isLoading;
  final String? processingStoreId;
  final String? error;

  EmergencyControlState copyWith({
    List<EmergencyStoreStatus>? stores,
    bool? isLoading,
    String? processingStoreId,
    String? error,
    bool clearProcessing = false,
    bool clearError = false,
  }) => EmergencyControlState(
    stores: stores ?? this.stores,
    isLoading: isLoading ?? this.isLoading,
    processingStoreId: clearProcessing
        ? null
        : (processingStoreId ?? this.processingStoreId),
    error: clearError ? null : (error ?? this.error),
  );
}

class EmergencyControlNotifier extends StateNotifier<EmergencyControlState> {
  EmergencyControlNotifier() : super(const EmergencyControlState());

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final raw = await supabase.rpc(
        'super_admin_get_emergency_store_statuses',
      );
      final stores = raw is List
          ? raw
                .whereType<Map>()
                .map(
                  (row) => EmergencyStoreStatus.fromJson(
                    Map<String, dynamic>.from(row),
                  ),
                )
                .toList(growable: false)
          : const <EmergencyStoreStatus>[];
      state = state.copyWith(
        stores: stores,
        isLoading: false,
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'EMERGENCY_CONTROL_LOAD_FAILED: $error',
      );
    }
  }

  Future<bool> setMode({
    required String storeId,
    required bool enabled,
    required String reason,
    String resolution = 'digital_completed',
    bool force = false,
  }) async {
    state = state.copyWith(processingStoreId: storeId, clearError: true);
    try {
      await supabase.rpc(
        'super_admin_set_emergency_mode',
        params: {
          'p_store_id': storeId,
          'p_enabled': enabled,
          'p_reason': reason,
          'p_resolution': resolution,
          'p_force': force,
        },
      );
      await load();
      state = state.copyWith(clearProcessing: true);
      return true;
    } catch (error) {
      state = state.copyWith(
        clearProcessing: true,
        error: 'EMERGENCY_CONTROL_UPDATE_FAILED: $error',
      );
      return false;
    }
  }
}

final emergencyControlProvider =
    StateNotifierProvider.autoDispose<
      EmergencyControlNotifier,
      EmergencyControlState
    >((ref) => EmergencyControlNotifier());

class EmergencyControlPanel extends ConsumerStatefulWidget {
  const EmergencyControlPanel({super.key});

  @override
  ConsumerState<EmergencyControlPanel> createState() =>
      _EmergencyControlPanelState();
}

class _EmergencyControlPanelState extends ConsumerState<EmergencyControlPanel> {
  bool _initialized = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(emergencyControlProvider);
    final copy = _ControlCopy.of(context);
    if (!_initialized) {
      _initialized = true;
      Future.microtask(
        () => ref.read(emergencyControlProvider.notifier).load(),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: PosColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: PosColors.border),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final heading = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    copy.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    copy.description,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: PosColors.textSecondary,
                    ),
                  ),
                ],
              );
              final refresh = OutlinedButton.icon(
                onPressed: state.isLoading
                    ? null
                    : () => ref.read(emergencyControlProvider.notifier).load(),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(copy.refresh),
              );
              if (constraints.maxWidth < 600) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [heading, const SizedBox(height: 12), refresh],
                );
              }
              return Row(
                children: [
                  Expanded(child: heading),
                  refresh,
                ],
              );
            },
          ),
        ),
        if (state.error != null) ...[
          const SizedBox(height: 10),
          MaterialBanner(
            content: Text(state.error!),
            leading: const Icon(Icons.error_outline, color: PosColors.danger),
            actions: [
              TextButton(
                onPressed: () =>
                    ref.read(emergencyControlProvider.notifier).load(),
                child: Text(copy.retry),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: state.isLoading && state.stores.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : ListView.separated(
                  itemCount: state.stores.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final store = state.stores[index];
                    return _EmergencyStoreCard(
                      store: store,
                      busy: state.processingStoreId == store.restaurantId,
                      copy: copy,
                      onToggle: () => _showModeDialog(store, copy),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _showModeDialog(
    EmergencyStoreStatus store,
    _ControlCopy copy,
  ) async {
    var reason = '';
    var resolution = store.unresolvedQuantity > 0
        ? 'reprint'
        : 'digital_completed';
    var force = false;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(store.active ? copy.closeTitle : copy.openTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(store.restaurantName),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('emergency_mode_reason'),
                  minLines: 2,
                  maxLines: 4,
                  onChanged: (value) => reason = value,
                  decoration: InputDecoration(labelText: copy.reason),
                ),
                if (store.active) ...[
                  const SizedBox(height: 12),
                  Text('${copy.unserved}: ${store.unresolvedQuantity}'),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    key: const Key('emergency_close_resolution'),
                    initialValue: resolution,
                    decoration: InputDecoration(
                      labelText: copy.printResolution,
                    ),
                    items: [
                      if (store.unresolvedQuantity == 0)
                        DropdownMenuItem(
                          value: 'digital_completed',
                          child: Text(copy.digitalCompleted),
                        ),
                      DropdownMenuItem(
                        value: 'reprint',
                        child: Text(copy.reprint),
                      ),
                      DropdownMenuItem(
                        value: 'dismiss',
                        child: Text(copy.dismiss),
                      ),
                    ],
                    onChanged: (value) =>
                        setDialogState(() => resolution = value ?? resolution),
                  ),
                  if (store.unresolvedQuantity > 0)
                    CheckboxListTile(
                      key: const Key('emergency_force_close'),
                      contentPadding: EdgeInsets.zero,
                      value: force,
                      title: Text(copy.forceClose),
                      subtitle: Text(copy.forceCloseWarning),
                      onChanged: (value) =>
                          setDialogState(() => force = value ?? false),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(copy.cancel),
            ),
            FilledButton(
              key: const Key('emergency_mode_confirm'),
              onPressed: () {
                if (reason.trim().isEmpty ||
                    (store.active && store.unresolvedQuantity > 0 && !force)) {
                  return;
                }
                Navigator.of(dialogContext).pop(true);
              },
              style: FilledButton.styleFrom(
                backgroundColor: store.active
                    ? PosColors.textSecondary
                    : PosColors.danger,
              ),
              child: Text(store.active ? copy.close : copy.activate),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref
        .read(emergencyControlProvider.notifier)
        .setMode(
          storeId: store.restaurantId,
          enabled: !store.active,
          reason: reason.trim(),
          resolution: resolution,
          force: force,
        );
  }
}

class _EmergencyStoreCard extends StatelessWidget {
  const _EmergencyStoreCard({
    required this.store,
    required this.busy,
    required this.copy,
    required this.onToggle,
  });

  final EmergencyStoreStatus store;
  final bool busy;
  final _ControlCopy copy;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: store.active ? PosColors.danger : PosColors.border,
          width: store.active ? 2 : 1,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final info = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      store.restaurantName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Chip(
                    avatar: Icon(
                      store.active
                          ? Icons.crisis_alert_rounded
                          : Icons.print_rounded,
                      size: 16,
                    ),
                    label: Text(store.active ? copy.active : copy.inactive),
                    backgroundColor: store.active
                        ? const Color(0xFFFFE5E5)
                        : PosSurfaceRole.background.fill,
                  ),
                ],
              ),
              if (store.active) ...[
                Text('${copy.orders}: ${store.orderCount}'),
                Text('${copy.unserved}: ${store.unresolvedQuantity}'),
                if ((store.reason ?? '').isNotEmpty)
                  Text(
                    store.reason!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.textSecondary,
                    ),
                  ),
              ],
            ],
          );
          final button = FilledButton.icon(
            key: ValueKey('emergency_toggle_${store.restaurantId}'),
            onPressed: busy ? null : onToggle,
            icon: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(store.active ? Icons.stop_circle_outlined : Icons.bolt),
            label: Text(store.active ? copy.close : copy.activate),
            style: FilledButton.styleFrom(
              backgroundColor: store.active
                  ? PosColors.textSecondary
                  : PosColors.danger,
            ),
          );
          if (constraints.maxWidth < 640) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [info, const SizedBox(height: 12), button],
            );
          }
          return Row(
            children: [
              Expanded(child: info),
              const SizedBox(width: 16),
              button,
            ],
          );
        },
      ),
    );
  }
}

class _ControlCopy {
  const _ControlCopy(this.code);
  final String code;

  static _ControlCopy of(BuildContext context) =>
      _ControlCopy(Localizations.localeOf(context).languageCode);
  String pick(String ko, String vi, String en) => switch (code) {
    'vi' => vi,
    'en' => en,
    _ => ko,
  };
  String get title =>
      pick('비상 디지털 운영', 'Vận hành số khẩn cấp', 'Emergency digital operation');
  String get description => pick(
    '프린터 장애·정전 등 긴급 상황에만 매장별로 엽니다. 평상시는 출력물이 기준입니다.',
    'Chỉ bật theo từng cửa hàng khi máy in hỏng hoặc mất điện. Phiếu in là quy trình mặc định.',
    'Enable per store only for printer failure or power incidents. Printed tickets are the default.',
  );
  String get refresh => pick('새로고침', 'Làm mới', 'Refresh');
  String get retry => pick('다시 시도', 'Thử lại', 'Retry');
  String get active => pick('비상 운영 중', 'Đang khẩn cấp', 'Emergency active');
  String get inactive => pick('프린터 운영', 'Đang dùng máy in', 'Printer mode');
  String get activate => pick('비상 모드 열기', 'Bật khẩn cấp', 'Activate');
  String get close => pick('비상 모드 종료', 'Tắt khẩn cấp', 'Close');
  String get openTitle =>
      pick('비상 모드 활성화', 'Bật chế độ khẩn cấp', 'Activate emergency mode');
  String get closeTitle =>
      pick('비상 모드 종료', 'Đóng chế độ khẩn cấp', 'Close emergency mode');
  String get reason => pick('사유 (필수)', 'Lý do (bắt buộc)', 'Reason (required)');
  String get orders => pick('주문', 'Đơn', 'Orders');
  String get unserved =>
      pick('미제공 수량', 'Số lượng chưa phục vụ', 'Unserved quantity');
  String get printResolution =>
      pick('보류 출력물 처리', 'Xử lý phiếu đang giữ', 'Held print jobs');
  String get digitalCompleted =>
      pick('디지털 완료 처리', 'Hoàn tất bằng màn hình', 'Digital completion');
  String get reprint =>
      pick('보류 출력물 재출력', 'In lại phiếu đang giữ', 'Reprint held jobs');
  String get dismiss =>
      pick('보류 출력물 폐기', 'Bỏ phiếu đang giữ', 'Dismiss held jobs');
  String get forceClose => pick(
    '미제공 상태로 강제 종료',
    'Buộc đóng khi còn món',
    'Force close with unserved items',
  );
  String get forceCloseWarning => pick(
    '미제공 수량이 남습니다. 재출력 또는 폐기 선택을 반드시 확인하세요.',
    'Vẫn còn món chưa phục vụ. Hãy xác nhận in lại hoặc bỏ phiếu.',
    'Unserved items remain. Confirm reprint or dismissal.',
  );
  String get cancel => pick('취소', 'Hủy', 'Cancel');
}

int _intValue(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};
