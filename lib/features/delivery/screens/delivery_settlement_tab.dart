import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../../main.dart';
import '../delivery_models.dart';
import '../delivery_settlement_provider.dart';
import '../../auth/auth_provider.dart';

class DeliverySettlementTab extends ConsumerStatefulWidget {
  const DeliverySettlementTab({super.key});

  @override
  ConsumerState<DeliverySettlementTab> createState() =>
      _DeliverySettlementTabState();
}

class _DeliverySettlementTabState
    extends ConsumerState<DeliverySettlementTab> {
  String? _statusFilter;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  void _loadData() {
    final rid = ref.read(authProvider).storeId;
    if (rid != null) {
      ref.read(deliverySettlementProvider.notifier).load(rid);
    }
  }

  String _fmtVnd(double v) =>
      '${NumberFormat('#,###').format(v.round())} ₫';

  List<DeliverySettlement> _filteredSettlements(
      List<DeliverySettlement> all) {
    if (_statusFilter == null) return all;
    return all.where((s) => s.status == _statusFilter).toList();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(deliverySettlementProvider);

    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator(
        color: AppColors.amber500,
      ));
    }

    if (state.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(state.error!,
                style: const TextStyle(color: AppColors.statusCancelled)),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _loadData,
              child: const Text('Retry'),
            ),
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
              child: Center(
                child: Text(
                  _statusFilter != null
                      ? 'No settlements in this status'
                      : 'No settlements',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            )
          else
            ...filtered.map(_buildSettlementCard),
        ],
      ),
    );
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
          _filterChip(
            _statusLabel(entry.key),
            entry.key,
            entry.value,
          ),
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
    final isSelected = _statusFilter == status;
    return InkWell(
      onTap: () => setState(() => _statusFilter = status),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.amber500 : AppColors.surface1,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? AppColors.amber500 : AppColors.surface2,
          ),
        ),
        child: Text(
          '$label ($count)',
          style: GoogleFonts.notoSansKr(
            color: isSelected ? AppColors.surface0 : AppColors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
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
                Text('Settlement pending',
                    style: GoogleFonts.notoSansKr(
                        color: AppColors.amber500,
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 4),
                Text(_fmtVnd(u.revenue),
                    style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                        fontSize: 24,
                        fontWeight: FontWeight.bold)),
                Text('${u.orderCount}',
                    style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary, fontSize: 13)),
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
            Text('${s.statusEmoji} ',
                style: const TextStyle(fontSize: 18)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${s.periodLabel}  ($dateRange)',
                      style: GoogleFonts.notoSansKr(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(s.statusLabel,
                      style: GoogleFonts.notoSansKr(
                          color: AppColors.textSecondary,
                          fontSize: 12)),
                ],
              ),
            ),
            Text(_fmtVnd(s.netSettlement),
                style: GoogleFonts.notoSansKr(
                    color: AppColors.statusAvailable,
                    fontWeight: FontWeight.bold,
                    fontSize: 15)),
          ],
        ),
        children: [
          // 매출 총액
          _detailRow('Delivery Revenue (gross)', _fmtVnd(s.grossTotal),
              color: AppColors.textPrimary),
          const Divider(color: AppColors.surface2, height: 16),
          // 차감 항목
          ...s.items.map((item) => _detailRow(
                item.label,
                '-${_fmtVnd(item.amount)}',
                color: AppColors.statusCancelled,
              )),
          if (s.items.isNotEmpty)
            const Divider(color: AppColors.surface2, height: 16),
          // 합계
          _detailRow('Total Deducted', '-${_fmtVnd(s.totalDeductions)}',
              color: AppColors.statusCancelled, bold: true),
          _detailRow('Actual Deposit Amount', _fmtVnd(s.netSettlement),
              color: AppColors.statusAvailable, bold: true),
          if (s.orderCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Orders: ${s.orderCount}',
                  style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary, fontSize: 12)),
            ),
          // 입금 확인 버튼
          if (s.canConfirmReceived) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.statusAvailable,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: ref.watch(deliverySettlementProvider)
                            .confirmingId ==
                        s.id
                    ? null
                    : () => _confirmReceived(s.id),
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: const Text('Confirm Deposit'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─── 헬퍼 위젯 ────────────────────────

  Widget _detailRow(String label, String value,
      {Color? color, bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 13,
                fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
              )),
          Text(value,
              style: GoogleFonts.notoSansKr(
                color: color ?? AppColors.textPrimary,
                fontSize: 13,
                fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
              )),
        ],
      ),
    );
  }

  Future<void> _confirmReceived(String settlementId) async {
    final rid = ref.read(authProvider).storeId;
    if (rid == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Text('Confirm Deposit',
            style: GoogleFonts.notoSansKr(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700)),
        content: Text('Confirmed the deposit on the actual bank account?',
            style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.statusAvailable,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref
          .read(deliverySettlementProvider.notifier)
          .confirmReceived(settlementId, rid);
    }
  }
}
