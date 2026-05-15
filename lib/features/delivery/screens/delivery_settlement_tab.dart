import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../core/ui/pos_design_tokens.dart';
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
    final l10n = context.l10n;
    final state = ref.watch(deliverySettlementProvider);
    final role = ref.watch(authProvider).role;

    if (!PermissionUtils.canAccessDeliverySettlement(role)) {
      return Center(
        child: Text(
          l10n.deliveryAdminOnlyMessage,
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
            ElevatedButton(onPressed: _loadData, child: Text(l10n.retry)),
          ],
        ),
      );
    }

    final filtered = _filteredSettlements(state.settlements);
    final unsettledOrders = state.unsettled?.orderCount ?? 0;
    final unsettledRevenue = state.unsettled?.revenue ?? 0;
    final pendingCount = state.settlements
        .where((s) => s.status == 'pending')
        .length;
    final statementCount = state.settlements
        .where((s) => s.status == 'calculated')
        .length;
    final disputeCount = state.settlements
        .where((s) => s.status == 'disputed')
        .length;
    final completedCount = state.settlements
        .where((s) => s.status == 'received')
        .length;
    final pendingNet = state.settlements
        .where((s) => s.status == 'pending')
        .fold<double>(0, (sum, s) => sum + s.netSettlement);
    final statementNet = state.settlements
        .where((s) => s.status == 'calculated')
        .fold<double>(0, (sum, s) => sum + s.netSettlement);
    final disputedNet = state.settlements
        .where((s) => s.status == 'disputed')
        .fold<double>(0, (sum, s) => sum + s.netSettlement);
    final atRiskNet =
        unsettledRevenue + pendingNet + statementNet + disputedNet;
    final needsAttention =
        unsettledOrders > 0 ||
        pendingCount > 0 ||
        statementCount > 0 ||
        disputeCount > 0;

    return RefreshIndicator(
      onRefresh: () async => _loadData(),
      child: ToastResponsiveScrollBody(
        maxWidth: 1240,
        children: [
          _buildDeliverySettlementHeader(
            needsAttention: needsAttention,
            unsettledOrders: unsettledOrders,
            unsettledRevenue: unsettledRevenue,
            statementCount: statementCount,
            statementNet: statementNet,
            disputeCount: disputeCount,
            disputedNet: disputedNet,
            pendingCount: pendingCount,
            atRiskNet: atRiskNet,
          ),
          const SizedBox(height: 12),
          if (state.settlements.isNotEmpty)
            _buildDeliveryQueueControls(
              settlements: state.settlements,
              filteredCount: filtered.length,
              pendingCount: pendingCount,
              statementCount: statementCount,
              disputeCount: disputeCount,
              completedCount: completedCount,
            ),
          if (state.settlements.isNotEmpty) const SizedBox(height: 16),
          if (state.unsettled != null) _buildUnsettledCard(state.unsettled!),
          if (state.unsettled != null) const SizedBox(height: 16),
          if (state.unsettled != null || state.settlements.isNotEmpty)
            _buildOperationalAttention(
              unsettled: state.unsettled,
              settlements: state.settlements,
            ),
          if (state.unsettled != null || state.settlements.isNotEmpty)
            const SizedBox(height: 16),
          if (state.settlements.isNotEmpty)
            _buildAggregateSecondaryDetail(state.settlements),
          if (state.settlements.isNotEmpty) const SizedBox(height: 16),
          Row(
            children: [
              Text(
                l10n.deliverySettlementHistory,
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
          if (state.settlements.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              _historySummaryCopy(
                context: context,
                filteredCount: filtered.length,
                totalCount: state.settlements.length,
              ),
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
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

  Widget _buildDeliverySettlementHeader({
    required bool needsAttention,
    required int unsettledOrders,
    required double unsettledRevenue,
    required int statementCount,
    required double statementNet,
    required int disputeCount,
    required double disputedNet,
    required int pendingCount,
    required double atRiskNet,
  }) {
    final l10n = context.l10n;

    return ToastWorkSurface(
      key: const Key('delivery_settlement_queue_header'),
      padding: const EdgeInsets.all(18),
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
                      l10n.deliveryHeaderTitle,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.deliveryHeaderSubtitle,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: PosColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ToastStatusBadge(
                label: needsAttention
                    ? l10n.deliveryAttentionRequired
                    : l10n.deliveryHealthyQueue,
                color: disputeCount > 0
                    ? PosColors.danger
                    : needsAttention
                    ? PosColors.warning
                    : PosColors.success,
                compact: true,
              ),
            ],
          ),
          if (needsAttention) ...[
            const SizedBox(height: 12),
            PosExceptionAlert(
              label: disputeCount > 0
                  ? l10n.deliveryAttentionDisputeOpen(disputeCount)
                  : statementCount > 0
                  ? l10n.deliveryAttentionStatementWaiting(statementCount)
                  : unsettledOrders > 0
                  ? l10n.deliveryAttentionUnsettledOpen(unsettledOrders)
                  : l10n.deliveryAttentionFollowUpRemaining,
              detail: disputeCount > 0
                  ? l10n.deliveryAttentionDisputedAmount(_fmtVnd(disputedNet))
                  : statementCount > 0
                  ? l10n.deliveryAttentionPendingAmount(_fmtVnd(statementNet))
                  : l10n.deliveryAttentionRiskAmount(_fmtVnd(atRiskNet)),
              color: disputeCount > 0 ? PosColors.danger : PosColors.warning,
            ),
          ],
          const SizedBox(height: 14),
          ToastMetricStrip(
            metrics: [
              ToastMetric(
                label: l10n.deliveryKpiUnsettledOrders,
                value: '$unsettledOrders',
                tone: unsettledOrders > 0
                    ? PosColors.warning
                    : PosColors.textPrimary,
              ),
              ToastMetric(
                label: l10n.deliveryKpiStatementPending,
                value: '$statementCount',
                tone: statementCount > 0
                    ? PosColors.accent
                    : PosColors.textPrimary,
              ),
              ToastMetric(
                label: l10n.deliveryKpiDispute,
                value: '$disputeCount',
                tone: disputeCount > 0 ? PosColors.danger : PosColors.success,
              ),
              ToastMetric(
                label: l10n.deliveryKpiRiskNet,
                value: _fmtVnd(atRiskNet),
                tone: atRiskNet > 0 ? PosColors.warning : PosColors.success,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            pendingCount > 0
                ? l10n.deliveryPendingIncluded(pendingCount)
                : l10n.deliveryOpenRevenue(_fmtVnd(unsettledRevenue)),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildDeliveryQueueControls({
    required List<DeliverySettlement> settlements,
    required int filteredCount,
    required int pendingCount,
    required int statementCount,
    required int disputeCount,
    required int completedCount,
  }) {
    final l10n = context.l10n;

    return ToastWorkSurface(
      key: const Key('delivery_settlement_queue_controls'),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _filterChip(l10n.all, null, settlements.length),
              _filterChip(l10n.deliveryFilterPending, 'pending', pendingCount),
              _filterChip(
                l10n.deliveryFilterStatement,
                'calculated',
                statementCount,
              ),
              _filterChip(l10n.deliveryFilterDispute, 'disputed', disputeCount),
              _filterChip(
                l10n.deliveryFilterCompleted,
                'received',
                completedCount,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _historySummaryCopy(
              context: context,
              filteredCount: filteredCount,
              totalCount: settlements.length,
            ),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildAggregateSecondaryDetail(List<DeliverySettlement> settlements) {
    return ToastWorkSurface(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ExpansionTile(
        key: const Key('delivery_aggregate_secondary_detail'),
        initiallyExpanded: false,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 12),
        title: Text(
          context.l10n.deliveryAggregateSummary,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: PosColors.textPrimary,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          context.l10n.deliverySettlementBoundaryBody,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
        ),
        children: [_buildAggregateSummary(settlements)],
      ),
    );
  }

  Widget _buildOperationalAttention({
    required UnsettledRevenueSummary? unsettled,
    required List<DeliverySettlement> settlements,
  }) {
    final l10n = context.l10n;
    final unsettledOrders = unsettled?.orderCount ?? 0;
    final unsettledRevenue = unsettled?.revenue ?? 0;
    final pendingCount = settlements.where((s) => s.status == 'pending').length;
    final statementCount = settlements
        .where((s) => s.status == 'calculated')
        .length;
    final disputeCount = settlements
        .where((s) => s.status == 'disputed')
        .length;
    final settledCount = settlements
        .where((s) => s.status == 'received')
        .length;
    final statementNet = settlements
        .where((s) => s.status == 'calculated')
        .fold<double>(0, (sum, s) => sum + s.netSettlement);
    final pendingNet = settlements
        .where((s) => s.status == 'pending')
        .fold<double>(0, (sum, s) => sum + s.netSettlement);
    final disputedNet = settlements
        .where((s) => s.status == 'disputed')
        .fold<double>(0, (sum, s) => sum + s.netSettlement);
    final atRiskNet =
        unsettledRevenue + pendingNet + statementNet + disputedNet;
    final followUpSignals = [
      if (unsettledOrders > 0)
        l10n.deliverySettlementAtRiskOpenRevenue(_fmtVnd(unsettledRevenue)),
      if (statementCount > 0)
        l10n.deliverySettlementDepositReady(
          statementCount,
          _fmtVnd(statementNet),
        ),
      if (disputeCount > 0)
        l10n.deliverySettlementAtRiskDisputed(
          disputeCount,
          _fmtVnd(disputedNet),
        ),
      if (pendingCount > 0)
        l10n.deliverySettlementAtRiskPending(pendingCount, _fmtVnd(pendingNet)),
    ];

    return ToastWorkSurface(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.deliverySettlementAttentionTitle,
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                context.l10n.deliveryFollowUpCount(followUpSignals.length),
                style: GoogleFonts.notoSansKr(
                  color: followUpSignals.isNotEmpty
                      ? AppColors.statusCancelled
                      : AppColors.statusAvailable,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _attentionChip(
                l10n.deliverySettlementUnsettledOrders(unsettledOrders),
                unsettledOrders > 0
                    ? AppColors.statusCancelled
                    : AppColors.statusAvailable,
              ),
              _attentionChip(
                l10n.deliverySettlementStatements(statementCount),
                statementCount > 0
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
              _attentionChip(
                l10n.deliverySettlementDisputes(disputeCount),
                disputeCount > 0
                    ? AppColors.statusCancelled
                    : AppColors.statusAvailable,
              ),
              _attentionChip(
                '${l10n.deliverySettlementSettledPeriods} $settledCount',
                AppColors.statusAvailable,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _attentionSupportRow(
            l10n.deliverySettlementFollowUpFocus,
            followUpSignals.isEmpty
                ? l10n.deliverySettlementFocusNone
                : followUpSignals.first,
          ),
          const SizedBox(height: 8),
          _attentionSupportRow(
            l10n.deliverySettlementDepositReadiness,
            _depositReadinessCopy(
              context: context,
              statementCount: statementCount,
              statementNet: statementNet,
              unsettledOrders: unsettledOrders,
            ),
          ),
          const SizedBox(height: 8),
          _attentionSupportRow(
            l10n.deliverySettlementAtRiskMix,
            _atRiskMixCopy(
              context: context,
              pendingCount: pendingCount,
              disputeCount: disputeCount,
              unsettledRevenue: unsettledRevenue,
              pendingNet: pendingNet,
              disputedNet: disputedNet,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.deliveryRiskNetAndCompleted(
              _fmtVnd(atRiskNet),
              settledCount,
            ),
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 12,
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
    required BuildContext context,
    required int statementCount,
    required double statementNet,
    required int unsettledOrders,
  }) {
    final l10n = context.l10n;
    if (statementCount > 0) {
      return l10n.deliverySettlementDepositReady(
        statementCount,
        _fmtVnd(statementNet),
      );
    }
    if (unsettledOrders > 0) {
      return l10n.deliverySettlementDepositNeedsStatementGeneration;
    }
    return l10n.deliverySettlementDepositNoQueue;
  }

  String _atRiskMixCopy({
    required BuildContext context,
    required int pendingCount,
    required int disputeCount,
    required double unsettledRevenue,
    required double pendingNet,
    required double disputedNet,
  }) {
    final l10n = context.l10n;
    if (disputeCount > 0) {
      return l10n.deliverySettlementAtRiskDisputed(
        disputeCount,
        _fmtVnd(disputedNet),
      );
    }
    if (pendingCount > 0) {
      return l10n.deliverySettlementAtRiskPending(
        pendingCount,
        _fmtVnd(pendingNet),
      );
    }
    if (unsettledRevenue > 0) {
      return l10n.deliverySettlementAtRiskOpenRevenue(
        _fmtVnd(unsettledRevenue),
      );
    }
    return l10n.deliverySettlementAtRiskNone;
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
    final averageNet = settlements.isEmpty
        ? 0.0
        : totalNet / settlements.length;
    final averageOrders = settlements.isEmpty
        ? 0.0
        : totalOrders / settlements.length;
    final receivedCount = settlements
        .where((s) => s.status == 'received')
        .length;
    final followUpCount = settlements
        .where((s) => s.status != 'received')
        .length;

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
            context.l10n.deliveryAggregateSummary,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 180,
                child: _summaryMetric(
                  context.l10n.reportsTotalSales,
                  _fmtVnd(totalGross),
                  AppColors.textPrimary,
                ),
              ),
              SizedBox(
                width: 180,
                child: _summaryMetric(
                  context.l10n.deliveryTotalDeductions,
                  '-${_fmtVnd(totalDeductions)}',
                  AppColors.statusCancelled,
                ),
              ),
              SizedBox(
                width: 180,
                child: _summaryMetric(
                  context.l10n.deliveryActualDeposit,
                  _fmtVnd(totalNet),
                  AppColors.statusAvailable,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _summarySupportMetric(
                context.l10n.deliverySettlementPeriods,
                '${settlements.length}',
                AppColors.textPrimary,
              ),
              _summarySupportMetric(
                context.l10n.reportsTotalOrders,
                '$totalOrders',
                AppColors.textPrimary,
              ),
              _summarySupportMetric(
                context.l10n.deliveryAverageDeposit,
                _fmtVnd(averageNet),
                AppColors.statusAvailable,
              ),
              _summarySupportMetric(
                context.l10n.deliveryAverageOrders,
                averageOrders.toStringAsFixed(1),
                AppColors.textSecondary,
              ),
              _summarySupportMetric(
                context.l10n.complete,
                '$receivedCount',
                AppColors.statusAvailable,
              ),
              _summarySupportMetric(
                context.l10n.deliveryAttentionRequired,
                '$followUpCount',
                followUpCount > 0
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
            ],
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

  Widget _summarySupportMetric(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(10),
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
            ),
          ),
          const SizedBox(height: 2),
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

  String _statusLabel(BuildContext context, String status) => switch (status) {
    'pending' => context.l10n.pending,
    'calculated' => context.l10n.deliveryStatementPending,
    'received' => context.l10n.complete,
    'disputed' => context.l10n.deliveryDispute,
    'adjusted' => context.l10n.adjusted,
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
                  '정산 대기',
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
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _statusBadge(s.statusLabel, _statusColor(s.status)),
                      _statusBadge('주문 ${s.orderCount}건', AppColors.statusInfo),
                      _statusBadge(
                        '차감 ${s.items.length}건',
                        s.items.isNotEmpty
                            ? AppColors.statusCancelled
                            : AppColors.statusAvailable,
                      ),
                    ],
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
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _settlementMiniMetric(
                '총매출',
                _fmtVnd(s.grossTotal),
                AppColors.textPrimary,
              ),
              _settlementMiniMetric(
                '차감',
                '-${_fmtVnd(s.totalDeductions)}',
                AppColors.statusCancelled,
              ),
              _settlementMiniMetric(
                '입금',
                _fmtVnd(s.netSettlement),
                AppColors.statusAvailable,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _detailRow('상태', s.statusLabel, color: _statusColor(s.status)),
          _detailRow('정산 기간', dateRange),
          _detailRow(
            '입금 확인',
            _formatDateTime(s.receivedAt),
            color: s.receivedAt != null
                ? AppColors.statusAvailable
                : AppColors.textSecondary,
          ),
          _detailRow(
            '메모',
            _stringOrDash(s.notes),
            color: s.notes?.trim().isNotEmpty == true
                ? AppColors.textPrimary
                : AppColors.textSecondary,
          ),
          const Divider(color: AppColors.surface2, height: 16),
          // 매출 총액
          _detailRow(
            '배달 총매출',
            _fmtVnd(s.grossTotal),
            color: AppColors.textPrimary,
          ),
          const Divider(color: AppColors.surface2, height: 16),
          // 차감 항목
          if (s.items.isEmpty)
            _detailRow(
              '차감 항목',
              '기록된 차감 내역이 없습니다.',
              color: AppColors.textSecondary,
            )
          else
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
            '총 차감',
            '-${_fmtVnd(s.totalDeductions)}',
            color: AppColors.statusCancelled,
            bold: true,
          ),
          _detailRow(
            '실입금액',
            _fmtVnd(s.netSettlement),
            color: AppColors.statusAvailable,
            bold: true,
          ),
          if (s.orderCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '주문 ${s.orderCount}건',
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
                label: '입금 확인',
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

  Widget _settlementMiniMetric(String label, String value, Color color) {
    return Container(
      constraints: const BoxConstraints(minWidth: 120, maxWidth: 170),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(10),
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
            ),
          ),
          const SizedBox(height: 4),
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

  Widget _statusBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Text(
        label,
        style: GoogleFonts.notoSansKr(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  String _historySummaryCopy({
    required BuildContext context,
    required int filteredCount,
    required int totalCount,
  }) {
    if (_statusFilter == null) {
      return context.l10n.deliveryHistorySummaryAll(totalCount);
    }
    return context.l10n.deliveryHistorySummaryFiltered(
      totalCount,
      filteredCount,
      _statusLabel(context, _statusFilter!),
    );
  }

  String _formatDateTime(DateTime? value) {
    if (value == null) return '-';
    return DateFormat('yyyy-MM-dd HH:mm').format(value.toLocal());
  }

  String _stringOrDash(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return '-';
    return text;
  }

  Color _statusColor(String status) => switch (status) {
    'received' => AppColors.statusAvailable,
    'calculated' => AppColors.amber500,
    'pending' => AppColors.statusInfo,
    'disputed' => AppColors.statusCancelled,
    'adjusted' => AppColors.statusReady,
    _ => AppColors.textSecondary,
  };

  Future<void> _confirmReceived(String settlementId) async {
    final rid = ref.read(authProvider).storeId;
    if (rid == null) return;

    final confirmed = await ToastConfirmDialog.show(
      context: context,
      title: context.l10n.deliveryConfirmDeposit,
      description: context.l10n.deliveryConfirmDepositQuestion,
      confirmLabel: context.l10n.confirm,
      confirmTone: PosActionTone.affirm,
    );

    if (confirmed == true) {
      await ref
          .read(deliverySettlementProvider.notifier)
          .confirmReceived(settlementId, rid);
    }
  }
}
