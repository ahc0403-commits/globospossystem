import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/fulfillment_mode.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../main.dart';

class EmergencyStoreStatus {
  const EmergencyStoreStatus({
    required this.restaurantId,
    required this.restaurantName,
    required this.unresolvedQuantity,
    required this.orderCount,
    FulfillmentMode? mode,
    bool? active,
    this.draining = false,
    this.kdsReady = false,
    this.reason,
  }) : mode =
           mode ??
           (active == true
               ? FulfillmentMode.paperless
               : FulfillmentMode.posPrint);

  final String restaurantId;
  final String restaurantName;
  final FulfillmentMode mode;
  final int unresolvedQuantity;
  final int orderCount;
  final bool draining;
  final bool kdsReady;
  final String? reason;

  bool get active => mode.isPaperless;

  factory EmergencyStoreStatus.fromJson(Map<String, dynamic> json) =>
      EmergencyStoreStatus(
        restaurantId: json['restaurant_id']?.toString() ?? '',
        restaurantName: json['restaurant_name']?.toString() ?? '-',
        mode: FulfillmentMode.fromValue(json['mode']),
        unresolvedQuantity: _intValue(json['unresolved_quantity']),
        orderCount: _intValue(json['order_count']),
        draining: json['draining'] == true,
        kdsReady: json['kds_ready'] == true,
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
        'super_admin_get_fulfillment_store_statuses',
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
        'super_admin_set_fulfillment_mode',
        params: {
          'p_store_id': storeId,
          'p_mode': enabled
              ? FulfillmentMode.paperless.dbValue
              : FulfillmentMode.posPrint.dbValue,
          'p_reason': reason,
          'p_request_id': const Uuid().v4(),
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
                const SizedBox(height: 12),
                _ModeChangeNotice(store: store, copy: copy),
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
                if (reason.trim().isEmpty) {
                  return;
                }
                Navigator.of(dialogContext).pop(true);
              },
              style: FilledButton.styleFrom(
                backgroundColor: store.active
                    ? PosColors.textSecondary
                    : PosColors.accent,
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
        );
  }
}

class _ModeChangeNotice extends StatelessWidget {
  const _ModeChangeNotice({required this.store, required this.copy});

  final EmergencyStoreStatus store;
  final _ControlCopy copy;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: PosSurfaceRole.background.fill,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: PosColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(copy.newOrdersOnly),
        if (!store.active)
          Text(store.kdsReady ? copy.kdsReady : copy.kdsWarning),
        if (store.unresolvedQuantity > 0)
          Text(
            '${copy.unserved}: ${store.unresolvedQuantity} · ${copy.drainNotice}',
          ),
      ],
    ),
  );
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
                          ? Icons.tablet_mac_rounded
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
              if (store.active || store.draining) ...[
                Text('${copy.orders}: ${store.orderCount}'),
                Text('${copy.unserved}: ${store.unresolvedQuantity}'),
                if (store.draining) Text(copy.draining),
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
                  : PosColors.accent,
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
      pick('매장 운영 방식', 'Chế độ vận hành', 'Store operation mode');
  String get description => pick(
    '포스 프린트 또는 페이퍼리스 작업 방식을 매장별로 선택합니다. 전환은 새 주문부터 적용됩니다.',
    'Chọn in POS hoặc vận hành không giấy cho từng cửa hàng. Thay đổi áp dụng cho đơn mới.',
    'Choose POS print or paperless operation per store. Changes apply to new orders.',
  );
  String get refresh => pick('새로고침', 'Làm mới', 'Refresh');
  String get retry => pick('다시 시도', 'Thử lại', 'Retry');
  String get active => pick('페이퍼리스 모드', 'Chế độ không giấy', 'Paperless mode');
  String get inactive => pick('포스 프린트 모드', 'Chế độ in POS', 'POS print mode');
  String get activate =>
      pick('페이퍼리스로 전환', 'Chuyển sang không giấy', 'Switch to paperless');
  String get close =>
      pick('포스 프린트로 전환', 'Chuyển sang in POS', 'Switch to POS print');
  String get openTitle => pick(
    '페이퍼리스 모드로 전환',
    'Chuyển sang chế độ không giấy',
    'Switch to paperless mode',
  );
  String get closeTitle => pick(
    '포스 프린트 모드로 전환',
    'Chuyển sang chế độ in POS',
    'Switch to POS print mode',
  );
  String get reason => pick('사유 (필수)', 'Lý do (bắt buộc)', 'Reason (required)');
  String get orders => pick('주문', 'Đơn', 'Orders');
  String get unserved =>
      pick('미제공 수량', 'Số lượng chưa phục vụ', 'Unserved quantity');
  String get newOrdersOnly => pick(
    '전환 이후 생성되는 새 주문과 추가 메뉴부터 적용됩니다.',
    'Áp dụng cho đơn và món thêm được tạo sau khi chuyển.',
    'Applies to new orders and added items created after the switch.',
  );
  String get kdsReady => pick(
    '키친·트레이·층별 KDS 준비 완료',
    'KDS bếp, khay và tầng đã sẵn sàng',
    'Kitchen, tray, and floor KDS are ready',
  );
  String get kdsWarning => pick(
    'KDS 배정을 확인하세요. 전환 후 주문은 화면으로 전달됩니다.',
    'Kiểm tra phân công KDS. Đơn mới sẽ được chuyển tới màn hình.',
    'Check KDS assignments. New orders will route to screens.',
  );
  String get drainNotice => pick(
    '기존 주문은 KDS에서 마감',
    'Hoàn tất đơn cũ trên KDS',
    'Finish existing orders on KDS',
  );
  String get draining => pick(
    '기존 페이퍼리스 주문 마감 중',
    'Đang hoàn tất đơn không giấy cũ',
    'Draining existing paperless orders',
  );
  String get cancel => pick('취소', 'Hủy', 'Cancel');
}

int _intValue(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};
