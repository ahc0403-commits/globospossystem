import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../../core/ui/toast/toast.dart';
import '../../../main.dart';
import '../delivery_models.dart';
import '../delivery_settlement_provider.dart';
import '../../auth/auth_provider.dart';
import '../../../core/utils/permission_utils.dart';

class DeliverySettlementTab extends ConsumerStatefulWidget {
  const DeliverySettlementTab({super.key});

  @override
  ConsumerState<DeliverySettlementTab> createState() =>
      _DeliverySettlementTabState();
}

class _DeliverySettlementTabState extends ConsumerState<DeliverySettlementTab> {
  String? _statusFilter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
  }

  void _loadData() {
    final rid = ref.read(authProvider).storeId;
    if (rid != null) {
      ref.read(deliverySettlementProvider.notifier).load(rid);
    }
  }

  String _fmtVnd(double v) => '${NumberFormat('#,###').format(v.round())} ₫';

  List<DeliverySettlement> _filteredSettlements(List<DeliverySettlement> all) {
    if (_statusFilter == null) return all;
    return all.where((s) => s.status == _statusFilter).toList();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(deliverySettlementProvider);
    final role = ref.watch(authProvider).role;

    if (!PermissionUtils.canAccessDeliverySettlement(role)) {
      return Center(
        child: Text(
          'This Deliberry settlement workspace is only available to admin roles.',
          style: GoogleFonts.notoSansKr(color: AppColors.textSecondary),
        ),
      );
    }

    if (state.isLoading) {
      return const ToastOperationalLoadingState(
        label: PosLoadingCopy.loadingSettlements,
      );
    }

    if (state.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              state.error!,
              style: const TextStyle(color: AppColors.statusCancelled),
            ),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _loadData, child: const Text('Retry')),
          ],
        ),
      );
    }

    final filtered = _filteredSettlements(state.settlements);

    return RefreshIndicator(
      onRefresh: () async => _loadData(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface1,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.surface2),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.info_outline,
                  color: AppColors.amber500,
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Deliberry settlement is a separate financial workflow. It is not part of Photo Objet office operations.',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (state.unsettled != null || state.settlements.isNotEmpty)
            _buildOperationalAttention(
              unsettled: state.unsettled,
              settlements: state.settlements,
            ),
          if (state.unsettled != null || state.settlements.isNotEmpty)
            const SizedBox(height: 16),
          // ─── 미정산 카드 ───
          if (state.unsettled != null) _buildUnsettledCard(state.unsettled!),
          const SizedBox(height: 16),
          // ─── 정산 요약 ───
          if (state.settlements.isNotEmpty)
            _buildAggregateSummary(state.settlements),
          const SizedBox(height: 16),
          // ─── 필터 + 이력 헤더 ───
          Row(
            children: [
              Text(
                'Settlement History',
                style: GoogleFonts.notoSansKr(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (state.settlements.isNotEmpty)
                Text(
                  '${filtered.length}',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // ─── 상태 필터 칩 ───
          if (state.settlements.isNotEmpty)
            _buildStatusFilters(state.settlements),
          const SizedBox(height: 12),
          if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: ToastOperationalEmptyState(
                headline: _statusFilter != null
                    ? PosEmptyStateCopy.settlementsFilterEmpty
                    : PosEmptyStateCopy.settlementsEmpty,
              ),
            )
          else
            ...filtered.map(_buildSettlementCard),
        ],
      ),
    );
  }

  Widget _buildOperationalAttention({
    required UnsettledRevenueSummary? unsettled,
    required List<DeliverySettlement> settlements,
  }) {
    final unsettledOrders = unsettled?.orderCount ?? 0;
    final unsettledRevenue = unsettled?.revenue ?? 0;
    final pendingCount = settlements.where((s) => s.status == 'pending').length;
    final statementCount = settlements
        .where((s) => s.status == 'calculated')
        .length;
    final disputeCount = settlements.where((s) => s.status == 'disputed').length;
    final settledCount = settlements.where((s) => s.status == 'received').length;
    final statementNet = settlements
        .where((s) => s.status == 'calculated')
        .fold<double>(0, (sum, s) => sum + s.netSettlement);
    final pendingNet = settlements
        .where((s) => s.status == 'pending')
        .fold<double>(0, (sum, s) => sum + s.netSettlement);
    final disputedNet = settlements
        .where((s) => s.status == 'disputed')
        .fold<double>(0, (sum, s) => sum + s.netSettlement);
    final atRiskNet = unsettledRevenue + pendingNet + statementNet + disputedNet;
    final followUpSignals = [
      if (unsettledOrders > 0) 'Unsettled Deliberry revenue is still open.',
      if (statementCount > 0) 'Generated statements still need deposit confirmation.',
      if (disputeCount > 0) 'Disputed periods need separate financial review.',
      if (pendingCount > 0) 'Pending settlement periods are still waiting for statement generation.',
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Settlement Attention',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Read-only settlement readiness layer built from tracked Deliberry settlement state.',
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
                '${followUpSignals.length}',
                followUpSignals.isNotEmpty
                    ? AppColors.statusCancelled
                    : AppColors.statusAvailable,
              ),
              _attentionMetric(
                'Statements waiting',
                '$statementCount',
                statementCount > 0 ? AppColors.amber500 : AppColors.statusAvailable,
              ),
              _attentionMetric(
                'Settled periods',
                '$settledCount',
                AppColors.statusAvailable,
              ),
              _attentionMetric(
                'Net at risk',
                _fmtVnd(atRiskNet),
                atRiskNet > 0
                    ? AppColors.statusCancelled
                    : AppColors.statusAvailable,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _attentionChip(
                'Unsettled orders $unsettledOrders',
                unsettledOrders > 0
                    ? AppColors.statusCancelled
                    : AppColors.statusAvailable,
              ),
              _attentionChip(
                'Pending periods $pendingCount',
                pendingCount > 0 ? AppColors.amber500 : AppColors.statusAvailable,
              ),
              _attentionChip(
                'Statements $statementCount',
                statementCount > 0 ? AppColors.amber500 : AppColors.statusAvailable,
              ),
              _attentionChip(
                'Disputes $disputeCount',
                disputeCount > 0
                    ? AppColors.statusCancelled
                    : AppColors.statusAvailable,
              ),
              _attentionChip(
                'Ready to confirm $statementCount',
                statementCount > 0
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _attentionSupportRow(
            'Follow-up focus',
            followUpSignals.isEmpty
                ? 'No immediate Deliberry settlement follow-up signal is ahead of the others for the current snapshot.'
                : followUpSignals.first,
          ),
          const SizedBox(height: 8),
          _attentionSupportRow(
            'Deposit readiness',
            _depositReadinessCopy(
              statementCount: statementCount,
              statementNet: statementNet,
              unsettledOrders: unsettledOrders,
            ),
          ),
          const SizedBox(height: 8),
          _attentionSupportRow(
            'At-risk mix',
            _atRiskMixCopy(
              pendingCount: pendingCount,
              disputeCount: disputeCount,
              unsettledRevenue: unsettledRevenue,
              pendingNet: pendingNet,
              disputedNet: disputedNet,
            ),
          ),
          const SizedBox(height: 8),
          _attentionSupportRow(
            'Boundary',
            'Read-only readiness surface only. Statement generation and deposit confirmation workflows remain in their tracked controls below.',
          ),
        ],
      ),
    );
  }

  Widget _attentionMetric(String label, String value, Color color) {
    return Container(
      constraints: const BoxConstraints(minWidth: 128, maxWidth: 180),
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

  String _depositReadinessCopy({
    required int statementCount,
    required double statementNet,
    required int unsettledOrders,
  }) {
    if (statementCount > 0) {
      return '$statementCount generated statements worth ${_fmtVnd(statementNet)} are ready for the tracked deposit-confirmation step.';
    }
    if (unsettledOrders > 0) {
      return 'There are still unsettled Deliberry orders, so the next financial checkpoint is statement generation rather than deposit confirmation.';
    }
    return 'No immediate deposit-confirmation queue is visible in the current settlement snapshot.';
  }

  String _atRiskMixCopy({
    required int pendingCount,
    required int disputeCount,
    required double unsettledRevenue,
    required double pendingNet,
    required double disputedNet,
  }) {
    if (disputeCount > 0) {
      return '$disputeCount disputed periods account for ${_fmtVnd(disputedNet)} of the current at-risk settlement surface.';
    }
    if (pendingCount > 0) {
      return '$pendingCount pending periods still represent ${_fmtVnd(pendingNet)} before final statement confirmation is possible.';
    }
    if (unsettledRevenue > 0) {
      return 'The remaining at-risk exposure is concentrated in open Deliberry revenue: ${_fmtVnd(unsettledRevenue)}.';
    }
    return 'No material at-risk settlement mix is visible beyond the already-settled periods.';
  }

  // ─── 정산 합계 요약 ──────────────────

  Widget _buildAggregateSummary(List<DeliverySettlement> settlements) {
    double totalGross = 0;
    double totalDeductions = 0;
    double totalNet = 0;
    int totalOrders = 0;
    for (final s in settlements) {
      totalGross += s.grossTotal;
      totalDeductions += s.totalDeductions;
      totalNet += s.netSettlement;
      totalOrders += s.orderCount;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'All Settlements Summary',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _summaryMetric(
                  'Total Revenue',
                  _fmtVnd(totalGross),
                  AppColors.textPrimary,
                ),
              ),
              Expanded(
                child: _summaryMetric(
                  'Total Deducted',
                  '-${_fmtVnd(totalDeductions)}',
                  AppColors.statusCancelled,
                ),
              ),
              Expanded(
                child: _summaryMetric(
                  'Actual Deposit',
                  _fmtVnd(totalNet),
                  AppColors.statusAvailable,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${settlements.length} settlements · $totalOrders orders',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryMetric(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.notoSansKr(
            color: AppColors.textSecondary,
            fontSize: 11,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: GoogleFonts.notoSansKr(
            color: color,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  // ─── 상태 필터 칩 ────────────────────

  Widget _buildStatusFilters(List<DeliverySettlement> settlements) {
    final statusCounts = <String, int>{};
    for (final s in settlements) {
      statusCounts[s.status] = (statusCounts[s.status] ?? 0) + 1;
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _filterChip('All', null, settlements.length),
        for (final entry in statusCounts.entries)
          _filterChip(_statusLabel(entry.key), entry.key, entry.value),
      ],
    );
  }

  String _statusLabel(String status) => switch (status) {
    'pending' => 'Pending',
    'calculated' => 'Statement',
    'received' => 'Done',
    'disputed' => 'Dispute',
    'adjusted' => 'Adjustment',
    _ => status,
  };

  Widget _filterChip(String label, String? status, int count) {
    return ToastFilterChip(
      label: label,
      count: count,
      selected: _statusFilter == status,
      onSelected: () => setState(() => _statusFilter = status),
    );
  }

  // ─── 미정산 금액 카드 ──────────────────

  Widget _buildUnsettledCard(UnsettledRevenueSummary u) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.amber500.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.amber500.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.schedule, color: AppColors.amber500, size: 32),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Settlement pending',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.amber500,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _fmtVnd(u.revenue),
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '${u.orderCount}',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── 정산 카드 ────────────────────────

  Widget _buildSettlementCard(DeliverySettlement s) {
    final dateRange =
        '${DateFormat('M/d').format(s.periodStart)}~${DateFormat('M/d').format(s.periodEnd)}';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        iconColor: AppColors.textSecondary,
        collapsedIconColor: AppColors.textSecondary,
        title: Row(
          children: [
            Text('${s.statusEmoji} ', style: const TextStyle(fontSize: 18)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${s.periodLabel}  ($dateRange)',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    s.statusLabel,
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              _fmtVnd(s.netSettlement),
              style: GoogleFonts.notoSansKr(
                color: AppColors.statusAvailable,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
          ],
        ),
        children: [
          // 매출 총액
          _detailRow(
            'Delivery Revenue (gross)',
            _fmtVnd(s.grossTotal),
            color: AppColors.textPrimary,
          ),
          const Divider(color: AppColors.surface2, height: 16),
          // 차감 항목
          ...s.items.map(
            (item) => _detailRow(
              item.label,
              '-${_fmtVnd(item.amount)}',
              color: AppColors.statusCancelled,
            ),
          ),
          if (s.items.isNotEmpty)
            const Divider(color: AppColors.surface2, height: 16),
          // 합계
          _detailRow(
            'Total Deducted',
            '-${_fmtVnd(s.totalDeductions)}',
            color: AppColors.statusCancelled,
            bold: true,
          ),
          _detailRow(
            'Actual Deposit Amount',
            _fmtVnd(s.netSettlement),
            color: AppColors.statusAvailable,
            bold: true,
          ),
          if (s.orderCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Orders: ${s.orderCount}',
                style: GoogleFonts.notoSansKr(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
          // 입금 확인 버튼
          if (s.canConfirmReceived) ...[
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: PosActionButton(
                label: 'Confirm Deposit',
                tone: PosActionTone.affirm,
                icon: Icons.check_circle_outline,
                loading:
                    ref.watch(deliverySettlementProvider).confirmingId == s.id,
                onPressed: () => _confirmReceived(s.id),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─── 헬퍼 위젯 ────────────────────────

  Widget _detailRow(
    String label,
    String value, {
    Color? color,
    bool bold = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 13,
              fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          Text(
            value,
            style: GoogleFonts.notoSansKr(
              color: color ?? AppColors.textPrimary,
              fontSize: 13,
              fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmReceived(String settlementId) async {
    final rid = ref.read(authProvider).storeId;
    if (rid == null) return;

    final confirmed = await ToastConfirmDialog.show(
      context: context,
      title: 'Confirm Deposit',
      description: 'Confirmed the deposit on the actual bank account?',
      confirmLabel: 'Confirm',
      confirmTone: PosActionTone.affirm,
    );

    if (confirmed == true) {
      await ref
          .read(deliverySettlementProvider.notifier)
          .confirmReceived(settlementId, rid);
    }
  }
}
