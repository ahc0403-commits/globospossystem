import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../main.dart';
import 'delivery_models.dart';

// ─── State ───────────────────────────────────

class DeliverySettlementState {
  const DeliverySettlementState({
    this.settlements = const [],
    this.unsettled,
    this.isLoading = false,
    this.error,
    this.confirmingId,
  });

  final List<DeliverySettlement> settlements;
  final UnsettledRevenueSummary? unsettled;
  final bool isLoading;
  final String? error;
  final String? confirmingId; // ID currently being confirmed

  DeliverySettlementState copyWith({
    List<DeliverySettlement>? settlements,
    UnsettledRevenueSummary? unsettled,
    bool? isLoading,
    String? error,
    bool clearError = false,
    String? confirmingId,
    bool clearConfirming = false,
  }) {
    return DeliverySettlementState(
      settlements: settlements ?? this.settlements,
      unsettled: unsettled ?? this.unsettled,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      confirmingId: clearConfirming
          ? null
          : (confirmingId ?? this.confirmingId),
    );
  }
}

// ─── Notifier ────────────────────────────────

class DeliverySettlementNotifier
    extends StateNotifier<DeliverySettlementState> {
  DeliverySettlementNotifier() : super(const DeliverySettlementState());

  /// 정산 데이터 전체 로드 (화면 진입 시)
  Future<void> load(String storeId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      // 1) 미정산 매출
      final unsettledRes = await supabase
          .from('external_sales')
          .select('gross_amount')
          .eq('restaurant_id', storeId)
          .eq('is_revenue', true)
          .isFilter('settlement_id', null);

      double unsettledRevenue = 0;
      for (final row in unsettledRes) {
        final r = Map<String, dynamic>.from(row);
        final raw = r['gross_amount'];
        unsettledRevenue += switch (raw) {
          num v => v.toDouble(),
          String v => double.tryParse(v) ?? 0,
          _ => 0,
        };
      }

      // 2) 최근 정산 (v_settlement_summary 뷰)
      final settlementsRes = await supabase
          .from('v_settlement_summary')
          .select()
          .eq('restaurant_id', storeId)
          .order('period_start', ascending: false)
          .limit(20);

      final settlements = (settlementsRes as List)
          .map<DeliverySettlement>(
            (row) =>
                DeliverySettlement.fromJson(Map<String, dynamic>.from(row)),
          )
          .toList();

      state = state.copyWith(
        settlements: settlements,
        unsettled: UnsettledRevenueSummary(
          revenue: unsettledRevenue,
          orderCount: unsettledRes.length,
        ),
        isLoading: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load settlement data: $e',
      );
    }
  }

  /// 입금 확인 (admin)
  Future<void> confirmReceived(String settlementId, String storeId) async {
    state = state.copyWith(confirmingId: settlementId);
    try {
      await supabase.rpc(
        'confirm_delivery_settlement_received',
        params: {'p_settlement_id': settlementId, 'p_store_id': storeId},
      );

      // 성공 후 전체 리로드
      await load(storeId);
      state = state.copyWith(clearConfirming: true);
    } catch (e) {
      state = state.copyWith(
        error: 'Deposit confirmation failed: $e',
        clearConfirming: true,
      );
    }
  }
}

// ─── Provider ────────────────────────────────

final deliverySettlementProvider =
    StateNotifierProvider<DeliverySettlementNotifier, DeliverySettlementState>(
      (ref) => DeliverySettlementNotifier(),
    );
