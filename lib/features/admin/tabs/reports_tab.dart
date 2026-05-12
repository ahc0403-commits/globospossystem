import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../core/services/daily_closing_service.dart';
import '../../../core/ui/toast/toast.dart';
import '../../../main.dart';
import '../../auth/auth_provider.dart';
import '../../report/report_provider.dart';
import '../providers/admin_audit_provider.dart';
import '../providers/daily_closing_provider.dart';
import '../widgets/admin_audit_trace_panel.dart';

class ReportsTab extends ConsumerStatefulWidget {
  const ReportsTab({super.key});

  @override
  ConsumerState<ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends ConsumerState<ReportsTab> {
  DateTime? _pendingStart;
  DateTime? _pendingEnd;
  String? _initializedRestaurantId;

  @override
  Widget build(BuildContext context) {
    final storeId = ref.watch(authProvider).storeId;
    final reportState = ref.watch(reportProvider);
    final reportNotifier = ref.read(reportProvider.notifier);
    final currency = NumberFormat('#,###', 'vi_VN');
    final dateFormat = DateFormat('dd/MM/yyyy');

    if (_pendingStart == null || _pendingEnd == null) {
      _pendingStart ??= reportState.startDate;
      _pendingEnd ??= reportState.endDate;
    }

    if (storeId != null && _initializedRestaurantId != storeId) {
      _initializedRestaurantId = storeId;
      Future.microtask(() => reportNotifier.loadReport(storeId));
    }

    return Scaffold(
      key: const Key('reports_root'),
      backgroundColor: AppColors.surface0,
      body: reportState.isLoading
          ? const ToastOperationalLoadingState(
              label: PosLoadingCopy.loadingReport,
            )
          : reportState.error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    reportState.error!,
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
                        : () => reportNotifier.loadReport(storeId),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.amber500,
                      foregroundColor: AppColors.surface0,
                    ),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _pendingStart ?? reportState.startDate,
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now(),
                          );
                          if (picked != null) {
                            setState(() => _pendingStart = picked);
                          }
                        },
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.surface2),
                        ),
                        child: Text(
                          'From ${dateFormat.format(_pendingStart ?? reportState.startDate)}',
                          style: GoogleFonts.notoSansKr(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      OutlinedButton(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _pendingEnd ?? reportState.endDate,
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now(),
                          );
                          if (picked != null) {
                            setState(() => _pendingEnd = picked);
                          }
                        },
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.surface2),
                        ),
                        child: Text(
                          'To ${dateFormat.format(_pendingEnd ?? reportState.endDate)}',
                          style: GoogleFonts.notoSansKr(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      FilledButton(
                        onPressed: storeId == null
                            ? null
                            : () {
                                final start =
                                    _pendingStart ?? reportState.startDate;
                                final end = _pendingEnd ?? reportState.endDate;
                                reportNotifier.setDateRange(
                                  start,
                                  end,
                                  storeId,
                                );
                              },
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.amber500,
                          foregroundColor: AppColors.surface0,
                        ),
                        child: const Text('Apply'),
                      ),
                      if (reportState.summary != null)
                        OutlinedButton.icon(
                          onPressed: () => _exportReport(reportNotifier),
                          icon: const Icon(Icons.download, size: 16),
                          label: const Text('Excel'),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: AppColors.surface2),
                            foregroundColor: AppColors.textPrimary,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _quickRangeChip(
                        'Today',
                        onTap: storeId == null
                            ? null
                            : () {
                                final now = DateTime.now();
                                final start = DateTime(
                                  now.year,
                                  now.month,
                                  now.day,
                                );
                                setState(() {
                                  _pendingStart = start;
                                  _pendingEnd = now;
                                });
                                reportNotifier.setDateRange(
                                  start,
                                  now,
                                  storeId,
                                );
                              },
                      ),
                      _quickRangeChip(
                        'This Week',
                        onTap: storeId == null
                            ? null
                            : () {
                                final now = DateTime.now();
                                final weekdayOffset = now.weekday - 1;
                                final start = DateTime(
                                  now.year,
                                  now.month,
                                  now.day,
                                ).subtract(Duration(days: weekdayOffset));
                                setState(() {
                                  _pendingStart = start;
                                  _pendingEnd = now;
                                });
                                reportNotifier.setDateRange(
                                  start,
                                  now,
                                  storeId,
                                );
                              },
                      ),
                      _quickRangeChip(
                        'This Month',
                        onTap: storeId == null
                            ? null
                            : () {
                                final now = DateTime.now();
                                final start = DateTime(now.year, now.month, 1);
                                setState(() {
                                  _pendingStart = start;
                                  _pendingEnd = now;
                                });
                                reportNotifier.setDateRange(
                                  start,
                                  now,
                                  storeId,
                                );
                              },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _SummaryGrid(
                    summary: reportState.summary,
                    currency: currency,
                  ),
                  if (reportState.summary != null) ...[
                    const SizedBox(height: 8),
                    _OrderCountRow(summary: reportState.summary!),
                    const SizedBox(height: 8),
                    _PaymentMethodRow(
                      summary: reportState.summary!,
                      currency: currency,
                    ),
                    const SizedBox(height: 8),
                    _OperationalAttentionSection(summary: reportState.summary!),
                  ],
                  const SizedBox(height: 16),
                  if (storeId != null) _TodaySummarySection(storeId: storeId),
                  if (storeId != null) ...[
                    const SizedBox(height: 16),
                    _DailyClosingSection(storeId: storeId),
                  ],
                  const SizedBox(height: 16),
                  _DailyTable(summary: reportState.summary, currency: currency),
                  if (reportState.summary != null &&
                      reportState.summary!.hourlyBreakdown.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _HourlyRevenueSection(
                      summary: reportState.summary!,
                      currency: currency,
                    ),
                  ],
                  if (storeId != null) ...[
                    const SizedBox(height: 24),
                    Text(
                      'Recent Operations',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _ReportsAuditTraceSection(storeId: storeId),
                  ],
                ],
              ),
            ),
    );
  }

  Future<void> _exportReport(ReportNotifier notifier) async {
    final reportState = ref.read(reportProvider);
    final bytes = notifier.exportToExcel();
    if (bytes.isEmpty) return;

    final dateFormat = DateFormat('yyyyMMdd');
    final fileName =
        'report_${dateFormat.format(reportState.startDate)}_${dateFormat.format(reportState.endDate)}';

    await FileSaver.instance.saveFile(
      name: fileName,
      bytes: Uint8List.fromList(bytes),
      ext: 'xlsx',
      mimeType: MimeType.microsoftExcel,
    );

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Report saved.')));
    }
  }

  Widget _quickRangeChip(String label, {VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.surface1,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.surface2),
        ),
        child: Text(
          label,
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _SummaryGrid extends StatelessWidget {
  const _SummaryGrid({required this.summary, required this.currency});

  final ReportSummary? summary;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    final data = summary;
    if (data == null) {
      return _noData();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth < 1100 ? 2 : 4;
        return GridView.count(
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: constraints.maxWidth < 700 ? 1.35 : 1.85,
          children: [
            _summaryCard(
              title: 'Dine-in Revenue',
              value: '₫${currency.format(data.dineInRevenue)}',
              valueColor: AppColors.amber500,
              valueFontSize: 28,
            ),
            _summaryCard(
              title: 'Delivery Revenue',
              value: '₫${currency.format(data.deliveryRevenue)}',
              valueColor: AppColors.statusAvailable,
              valueFontSize: 28,
            ),
            _summaryCard(
              title: 'Service Expenses (not included in revenue)',
              value: '₫${currency.format(data.serviceTotal)}',
              valueColor: AppColors.textSecondary,
              valueFontSize: 28,
            ),
            _summaryCard(
              title: 'Total Revenue',
              value: '₫${currency.format(data.totalRevenue)}',
              valueColor: AppColors.amber500,
              valueFontSize: 32,
            ),
          ],
        );
      },
    );
  }

  Widget _summaryCard({
    required String title,
    required String value,
    required Color valueColor,
    required double valueFontSize,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            title,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: GoogleFonts.bebasNeue(
              color: valueColor,
              fontSize: valueFontSize,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _noData() {
    return Container(
      height: 130,
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(16),
      ),
      alignment: Alignment.center,
      child: Text(
        'No data for selected period',
        style: GoogleFonts.notoSansKr(color: AppColors.textSecondary),
      ),
    );
  }
}

class _DailyTable extends StatelessWidget {
  const _DailyTable({required this.summary, required this.currency});

  final ReportSummary? summary;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    final data = summary;
    if (data == null || data.dailyBreakdown.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Text(
            'No data for selected period',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 14,
            ),
          ),
        ),
      );
    }

    String vnd(double v) => '₫${currency.format(v)}';

    return ToastDenseDataTable(
      columns: const [
        ToastDenseColumn(label: 'Date', flex: 2),
        ToastDenseColumn(label: 'Dine-in'),
        ToastDenseColumn(label: 'Delivery'),
        ToastDenseColumn(label: 'Total'),
        ToastDenseColumn(label: 'Cash'),
        ToastDenseColumn(label: 'Card'),
        ToastDenseColumn(label: 'Pay'),
      ],
      rows: [
        for (final row in data.dailyBreakdown)
          ToastDenseRow(
            cells: [
              DateFormat('dd/MM').format(row.date),
              vnd(row.dineIn),
              vnd(row.delivery),
              vnd(row.total),
              vnd(row.cashAmount),
              vnd(row.cardAmount),
              vnd(row.payAmount),
            ],
          ),
      ],
      totalsRow: ToastDenseRow(
        bold: true,
        cells: [
          'Total',
          vnd(data.dineInRevenue),
          vnd(data.deliveryRevenue),
          vnd(data.totalRevenue),
          vnd(data.cashTotal),
          vnd(data.cardTotal),
          vnd(data.payTotal),
        ],
      ),
    );
  }
}

class _OrderCountRow extends StatelessWidget {
  const _OrderCountRow({required this.summary});

  final ReportSummary summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Text(
            'Order ${summary.totalOrders}',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'Done ${summary.completedOrders}',
            style: GoogleFonts.notoSansKr(
              color: AppColors.statusAvailable,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (summary.totalOrders >
              summary.completedOrders + summary.cancelledOrders) ...[
            const SizedBox(width: 12),
            Text(
              'In Progress ${summary.totalOrders - summary.completedOrders - summary.cancelledOrders}',
              style: GoogleFonts.notoSansKr(
                color: AppColors.amber500,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (summary.cancelledOrders > 0) ...[
            const SizedBox(width: 12),
            Text(
              'Cancel ${summary.cancelledOrders} (items ${summary.cancelledItems})',
              style: GoogleFonts.notoSansKr(
                color: AppColors.statusCancelled,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PaymentMethodRow extends StatelessWidget {
  const _PaymentMethodRow({required this.summary, required this.currency});

  final ReportSummary summary;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Text(
            'Payment Method',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'Cash ₫${currency.format(summary.cashTotal)}',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'Card ₫${currency.format(summary.cardTotal)}',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (summary.payTotal > 0) ...[
            const SizedBox(width: 12),
            Text(
              'Pay ₫${currency.format(summary.payTotal)}',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _OperationalAttentionSection extends StatelessWidget {
  const _OperationalAttentionSection({required this.summary});

  final ReportSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final wt08CoverageText = summary.wt08ComparablePosCount == 0
        ? l10n.reportsOperationalWt08ComparableNone
        : l10n.reportsOperationalWt08ComparableReported(
            summary.wetaxReportedCount,
            summary.wt08ComparablePosCount,
          );
    final proofRate = summary.proofCompletePercent.toStringAsFixed(0);
    final healthySignals = _healthySignalCount();
    final followUpSignals = _followUpSignalCount();
    final proofAttentionColor = summary.missingProofPhotosCount > 0
        ? AppColors.statusCancelled
        : summary.proofCompletePercent < 100
        ? AppColors.amber500
        : AppColors.statusAvailable;
    final einvoiceAttentionColor = summary.failedEinvoiceJobsCount > 0
        ? AppColors.statusCancelled
        : AppColors.statusAvailable;
    final wt08AttentionColor =
        summary.wetaxReportedCount < summary.wt08ComparablePosCount
        ? AppColors.amber500
        : AppColors.statusAvailable;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.reportsOperationalAttentionTitle,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.reportsOperationalAttentionSubtitle,
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
              _supportMetric(
                l10n.reportsOperationalFollowUpNow,
                '$followUpSignals',
                followUpSignals > 0
                    ? AppColors.statusCancelled
                    : AppColors.statusAvailable,
              ),
              _supportMetric(
                l10n.reportsOperationalHealthySignals,
                '$healthySignals/4',
                healthySignals == 4
                    ? AppColors.statusAvailable
                    : AppColors.amber500,
              ),
              _supportMetric(
                l10n.reportsOperationalWt08Readiness,
                summary.wt08ComparablePosCount == 0
                    ? l10n.reportsOperationalNotApplicable
                    : wt08CoverageText,
                summary.wetaxReportedCount < summary.wt08ComparablePosCount
                    ? AppColors.amber500
                    : AppColors.textPrimary,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _signalCard(
                title: l10n.reportsOperationalProofCompletion(proofRate),
                headline: l10n.reportsOperationalMissingProof(
                  summary.missingProofPhotosCount,
                ),
                body: summary.missingProofPhotosCount > 0
                    ? l10n.reportsOperationalFocusMissingProof
                    : l10n.reportsOperationalHealthyAligned,
                color: proofAttentionColor,
              ),
              _signalCard(
                title: l10n.reportsOperationalFailedEInvoice(
                  summary.failedEinvoiceJobsCount,
                ),
                headline: l10n.reportsOperationalFollowUpFocus,
                body: summary.failedEinvoiceJobsCount > 0
                    ? l10n.reportsOperationalFocusFailedEinvoice
                    : l10n.reportsOperationalFocusNone,
                color: einvoiceAttentionColor,
              ),
              _signalCard(
                title: l10n.reportsOperationalWt08Readiness,
                headline: wt08CoverageText,
                body: summary.wt08ComparablePosCount == 0
                    ? l10n.reportsOperationalNotApplicable
                    : summary.wetaxReportedCount <
                          summary.wt08ComparablePosCount
                    ? l10n.reportsOperationalFocusWt08
                    : l10n.reportsOperationalHealthyAligned,
                color: wt08AttentionColor,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _attentionChip(
                l10n.reportsOperationalMissingProof(
                  summary.missingProofPhotosCount,
                ),
                summary.missingProofPhotosCount > 0
                    ? AppColors.statusCancelled
                    : AppColors.statusAvailable,
              ),
              _attentionChip(
                l10n.reportsOperationalFailedEInvoice(
                  summary.failedEinvoiceJobsCount,
                ),
                summary.failedEinvoiceJobsCount > 0
                    ? AppColors.statusCancelled
                    : AppColors.statusAvailable,
              ),
              _attentionChip(
                l10n.reportsOperationalProofCompletion(proofRate),
                summary.proofCompletePercent < 100
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
              _attentionChip(
                wt08CoverageText,
                summary.wetaxReportedCount < summary.wt08ComparablePosCount
                    ? AppColors.amber500
                    : AppColors.textPrimary,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _statusStrip(
            children: [
              _statusStripBadge(
                label: l10n.reportsOperationalFollowUpNow,
                value: '$followUpSignals',
                color: followUpSignals > 0
                    ? AppColors.statusCancelled
                    : AppColors.statusAvailable,
              ),
              _statusStripBadge(
                label: l10n.reportsOperationalHealthySignals,
                value: '$healthySignals/4',
                color: healthySignals == 4
                    ? AppColors.statusAvailable
                    : AppColors.amber500,
              ),
              _statusStripBadge(
                label: l10n.reportsOperationalBoundary,
                value: summary.totalOrders == 0
                    ? l10n.reportsOperationalNotApplicable
                    : '${summary.completedOrders}/${summary.totalOrders}',
                color: AppColors.textPrimary,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _attentionSupportRow(
            l10n.reportsOperationalFollowUpFocus,
            _followUpFocusCopy(context),
          ),
          const SizedBox(height: 8),
          _attentionSupportRow(
            l10n.reportsOperationalHealthyBaseline,
            _healthyBaselineCopy(context),
          ),
          const SizedBox(height: 8),
          _attentionSupportRow(
            l10n.reportsOperationalBoundary,
            l10n.reportsOperationalBoundaryBody,
          ),
          const SizedBox(height: 12),
          Text(
            _attentionNarrative(context),
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  Widget _supportMetric(String label, String value, Color color) {
    return Container(
      constraints: const BoxConstraints(minWidth: 132, maxWidth: 220),
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
              height: 1.35,
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

  Widget _signalCard({
    required String title,
    required String headline,
    required String body,
    required Color color,
  }) {
    return Container(
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 260),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            headline,
            style: GoogleFonts.notoSansKr(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusStrip({required List<Widget> children}) {
    return Wrap(spacing: 10, runSpacing: 10, children: children);
  }

  Widget _statusStripBadge({
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.surface2),
      ),
      child: RichText(
        text: TextSpan(
          style: GoogleFonts.notoSansKr(
            color: AppColors.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
          children: [
            TextSpan(text: '$label '),
            TextSpan(
              text: value,
              style: GoogleFonts.notoSansKr(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
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

  int _followUpSignalCount() {
    var count = 0;
    if (summary.failedEinvoiceJobsCount > 0) count += 1;
    if (summary.missingProofPhotosCount > 0) count += 1;
    if (summary.wetaxReportedCount < summary.wt08ComparablePosCount) count += 1;
    if (summary.proofCompletePercent < 100) count += 1;
    return count;
  }

  int _healthySignalCount() => 4 - _followUpSignalCount();

  String _followUpFocusCopy(BuildContext context) {
    final l10n = context.l10n;
    if (summary.failedEinvoiceJobsCount > 0) {
      return l10n.reportsOperationalFocusFailedEinvoice;
    }
    if (summary.missingProofPhotosCount > 0) {
      return l10n.reportsOperationalFocusMissingProof;
    }
    if (summary.wetaxReportedCount < summary.wt08ComparablePosCount) {
      return l10n.reportsOperationalFocusWt08;
    }
    if (summary.proofCompletePercent < 100) {
      return l10n.reportsOperationalFocusProofCompletion;
    }
    return l10n.reportsOperationalFocusNone;
  }

  String _healthyBaselineCopy(BuildContext context) {
    final l10n = context.l10n;
    if (_healthySignalCount() == 4) {
      return l10n.reportsOperationalHealthyAligned;
    }
    return l10n.reportsOperationalHealthyMixed;
  }

  String _attentionNarrative(BuildContext context) {
    final l10n = context.l10n;
    if (summary.failedEinvoiceJobsCount > 0) {
      return l10n.reportsOperationalNarrativeFailedEinvoice;
    }
    if (summary.missingProofPhotosCount > 0) {
      return l10n.reportsOperationalNarrativeMissingProof;
    }
    if (summary.wetaxReportedCount < summary.wt08ComparablePosCount) {
      return l10n.reportsOperationalNarrativeWt08;
    }
    if (summary.proofCompletePercent < 100) {
      return l10n.reportsOperationalNarrativeProofCompletion;
    }
    return l10n.reportsOperationalNarrativeHealthy;
  }
}

class _TodaySummarySection extends ConsumerWidget {
  const _TodaySummarySection({required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(adminTodaySummaryProvider(storeId));
    final currency = NumberFormat('#,###', 'vi_VN');

    return summaryAsync.when(
      data: (summary) => _buildContent(summary, currency, ref),
      loading: () => const SizedBox(
        height: 60,
        child: Center(
          child: CircularProgressIndicator(
            color: AppColors.amber500,
            strokeWidth: 2,
          ),
        ),
      ),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildContent(
    TodaySummary summary,
    NumberFormat currency,
    WidgetRef ref,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              "Today's Operations",
              style: GoogleFonts.notoSansKr(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            InkWell(
              onTap: () => ref.refresh(adminTodaySummaryProvider(storeId)),
              borderRadius: BorderRadius.circular(4),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(
                  Icons.refresh,
                  size: 18,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final crossAxisCount = constraints.maxWidth < 700 ? 2 : 4;
            return GridView.count(
              physics: const NeverScrollableScrollPhysics(),
              shrinkWrap: true,
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: constraints.maxWidth < 700 ? 2.0 : 2.5,
              children: [
                _metricTile(
                  'Order',
                  '${summary.ordersTotal}',
                  AppColors.textPrimary,
                ),
                _metricTile(
                  'Done',
                  '${summary.ordersCompleted}',
                  AppColors.statusAvailable,
                ),
                _metricTile(
                  'In Progress',
                  '${summary.ordersPending + summary.ordersConfirmed + summary.ordersServing}',
                  AppColors.amber500,
                ),
                _metricTile(
                  'Cancel',
                  '${summary.ordersCancelled} (items ${summary.itemsCancelled})',
                  AppColors.statusCancelled,
                ),
                _metricTile(
                  'Payment',
                  '${summary.paymentsCount}',
                  AppColors.textPrimary,
                ),
                _metricTile(
                  'Payment Total',
                  '₫${currency.format(summary.paymentsTotal)}',
                  AppColors.amber500,
                ),
                _metricTile(
                  'Cash / Card',
                  '₫${currency.format(summary.paymentsCash)} / ₫${currency.format(summary.paymentsCard)}',
                  AppColors.textSecondary,
                ),
                _metricTile(
                  'Table',
                  '${summary.tablesOccupied} / ${summary.tablesTotal} in use',
                  AppColors.statusOccupied,
                ),
                _metricTile(
                  'Low Stock',
                  '${summary.lowStockCount}',
                  summary.lowStockCount > 0
                      ? AppColors.statusCancelled
                      : AppColors.statusAvailable,
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _metricTile(String label, String value, Color valueColor) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: GoogleFonts.notoSansKr(
              color: valueColor,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _HourlyRevenueSection extends StatelessWidget {
  const _HourlyRevenueSection({required this.summary, required this.currency});

  final ReportSummary summary;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    final hours = summary.hourlyBreakdown;
    final maxAmount = hours.fold<double>(
      0,
      (m, h) => h.amount > m ? h.amount : m,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Revenue by Hour',
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface1,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: hours.map((h) {
              final barFraction = maxAmount > 0 ? (h.amount / maxAmount) : 0.0;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 36,
                      child: Text(
                        '${h.hour.toString().padLeft(2, '0')}:00',
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return Stack(
                            children: [
                              Container(
                                height: 18,
                                decoration: BoxDecoration(
                                  color: AppColors.surface2,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              Container(
                                height: 18,
                                width: constraints.maxWidth * barFraction,
                                decoration: BoxDecoration(
                                  color: AppColors.amber500,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 90,
                      child: Text(
                        '₫${currency.format(h.amount)}',
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textPrimary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

class _DailyClosingSection extends ConsumerStatefulWidget {
  const _DailyClosingSection({required this.storeId});

  final String storeId;

  @override
  ConsumerState<_DailyClosingSection> createState() =>
      _DailyClosingSectionState();
}

class _DailyClosingSectionState extends ConsumerState<_DailyClosingSection> {
  bool _isClosing = false;
  bool _closingSucceeded = false;
  bool _closingAlreadyClosed = false;

  Future<void> _createClosing() async {
    final confirmed = await ToastConfirmDialog.show(
      context: context,
      title: 'Close Today',
      description: "Save today's operations data as a closing record?",
      confirmLabel: 'Close',
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isClosing = true);
    try {
      await dailyClosingService.createDailyClosing(storeId: widget.storeId);
      ref.invalidate(dailyClosingHistoryProvider);
      if (mounted) {
        setState(() => _closingSucceeded = true);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Closing complete.')));
      }
    } catch (e) {
      if (mounted) {
        final errorMsg = mapDailyClosingError(e);
        final isAlreadyClosed = errorMsg.contains('already complete');
        if (isAlreadyClosed) {
          setState(() => _closingAlreadyClosed = true);
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(errorMsg)));
      }
    } finally {
      if (mounted) setState(() => _isClosing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final historyAsync = ref.watch(dailyClosingHistoryProvider(widget.storeId));
    final currency = NumberFormat('#,###', 'vi_VN');

    return Column(
      key: const Key('daily_closing_root'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          key: const Key('nav_daily_closing'),
          children: [
            Text(
              'Daily Close',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            PosActionButton(
              key: const Key('daily_closing_submit_button'),
              label: 'Close Today',
              tone: PosActionTone.primary,
              icon: Icons.lock_clock,
              loading: _isClosing,
              onPressed: _createClosing,
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_closingSucceeded)
          Container(
            key: const Key('daily_closing_success_banner'),
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.check_circle_outline,
                  color: AppColors.statusAvailable,
                  size: 14,
                ),
                const SizedBox(width: 4),
                Text(
                  'Closing complete.',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.statusAvailable,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        if (_closingAlreadyClosed)
          Container(
            key: const Key('daily_closing_already_closed_banner'),
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Today is already complete.',
              style: GoogleFonts.notoSansKr(
                color: AppColors.amber500,
                fontSize: 12,
              ),
            ),
          ),
        historyAsync.when(
          data: (records) => records.isEmpty
              ? Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface1,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: Text(
                      'No closing history.',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                )
              : Container(
                  decoration: BoxDecoration(
                    color: AppColors.surface1,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      _closingTableHeader(),
                      ...records.take(10).toList().asMap().entries.map((entry) {
                        final index = entry.key;
                        final record = entry.value;
                        return _closingTableRow(
                          record: record,
                          currency: currency,
                          bgColor: index.isEven
                              ? AppColors.surface1
                              : AppColors.surface0,
                        );
                      }),
                    ],
                  ),
                ),
          loading: () => const SizedBox(
            height: 40,
            child: Center(
              child: CircularProgressIndicator(
                color: AppColors.amber500,
                strokeWidth: 2,
              ),
            ),
          ),
          error: (e, _) => Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface1,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                mapDailyClosingError(e),
                style: GoogleFonts.notoSansKr(
                  color: AppColors.statusCancelled,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _closingTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.surface2)),
      ),
      child: Row(
        children: [
          _hCell('Date', flex: 2),
          _hCell('Order'),
          _hCell('Done'),
          _hCell('Cancel'),
          _hCell('Revenue'),
          _hCell('Cash'),
          _hCell('Card'),
          _hCell('Low'),
          _hCell('Assignee'),
        ],
      ),
    );
  }

  Widget _closingTableRow({
    required DailyClosingRecord record,
    required NumberFormat currency,
    required Color bgColor,
  }) {
    return Container(
      color: bgColor,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _dCell(
            record.closingDate.length >= 10
                ? record.closingDate.substring(5)
                : record.closingDate,
            flex: 2,
          ),
          _dCell('${record.ordersTotal}'),
          _dCell('${record.ordersCompleted}'),
          _dCell('${record.ordersCancelled}'),
          _dCell('₫${currency.format(record.paymentsTotal)}'),
          _dCell('₫${currency.format(record.paymentsCash)}'),
          _dCell('₫${currency.format(record.paymentsCard)}'),
          _dCell('${record.lowStockCount}'),
          _dCell(record.closedByName, overflow: true),
        ],
      ),
    );
  }

  Widget _hCell(String text, {int flex = 1}) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        style: GoogleFonts.notoSansKr(
          color: AppColors.textPrimary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _dCell(String text, {int flex = 1, bool overflow = false}) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        style: GoogleFonts.notoSansKr(
          color: AppColors.textPrimary,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
        overflow: overflow ? TextOverflow.ellipsis : null,
      ),
    );
  }
}

class _ReportsAuditTraceSection extends ConsumerWidget {
  const _ReportsAuditTraceSection({required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auditTraceAsync = ref.watch(adminAuditTraceProvider(storeId));

    return AdminAuditTracePanel(
      auditTraceAsync: auditTraceAsync,
      storeId: storeId,
      allowedEntityTypes: const {'orders', 'order_items', 'payments'},
      maxItems: 10,
      compact: true,
      showRetry: true,
      emptyMessage: 'No recent operations.',
    );
  }
}
