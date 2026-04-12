import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../../core/services/daily_closing_service.dart';
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
      backgroundColor: AppColors.surface0,
      body: reportState.isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.amber500),
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
                  ],
                  const SizedBox(height: 16),
                  if (storeId != null)
                    _TodaySummarySection(storeId: storeId),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report saved.')),
      );
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

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          _tableHeader(),
          ...data.dailyBreakdown.asMap().entries.map((entry) {
            final index = entry.key;
            final row = entry.value;
            final rowColor = index.isEven
                ? AppColors.surface1
                : AppColors.surface0;
            return _tableRow(
              date: DateFormat('dd/MM').format(row.date),
              dineIn: row.dineIn,
              delivery: row.delivery,
              total: row.total,
              cash: row.cashAmount,
              card: row.cardAmount,
              pay: row.payAmount,
              bgColor: rowColor,
            );
          }),
          _totalsRow(data),
        ],
      ),
    );
  }

  Widget _tableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.surface2)),
      ),
      child: Row(
        children: [
          _cell('Date', flex: 2, bold: true),
          _cell('Dine-in', bold: true),
          _cell('Delivery', bold: true),
          _cell('Total', bold: true),
          _cell('Cash', bold: true),
          _cell('Card', bold: true),
          _cell('Pay', bold: true),
        ],
      ),
    );
  }

  Widget _tableRow({
    required String date,
    required double dineIn,
    required double delivery,
    required double total,
    required double cash,
    required double card,
    required double pay,
    required Color bgColor,
  }) {
    return Container(
      color: bgColor,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          _cell(date, flex: 2),
          _cell('₫${currency.format(dineIn)}'),
          _cell('₫${currency.format(delivery)}'),
          _cell('₫${currency.format(total)}'),
          _cell('₫${currency.format(cash)}'),
          _cell('₫${currency.format(card)}'),
          _cell('₫${currency.format(pay)}'),
        ],
      ),
    );
  }

  Widget _totalsRow(ReportSummary summary) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.surface2)),
      ),
      child: Row(
        children: [
          _cell('Total', flex: 2, bold: true),
          _cell('₫${currency.format(summary.dineInRevenue)}', bold: true),
          _cell('₫${currency.format(summary.deliveryRevenue)}', bold: true),
          _cell('₫${currency.format(summary.totalRevenue)}', bold: true),
          _cell('₫${currency.format(summary.cashTotal)}', bold: true),
          _cell('₫${currency.format(summary.cardTotal)}', bold: true),
          _cell('₫${currency.format(summary.payTotal)}', bold: true),
        ],
      ),
    );
  }

  Widget _cell(String text, {int flex = 1, bool bold = false}) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        style: GoogleFonts.notoSansKr(
          color: AppColors.textPrimary,
          fontSize: 12,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        ),
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
          if (summary.totalOrders > summary.completedOrders + summary.cancelledOrders) ...[
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
  const _PaymentMethodRow({
    required this.summary,
    required this.currency,
  });

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
              onTap: () =>
                  ref.refresh(adminTodaySummaryProvider(storeId)),
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
  const _HourlyRevenueSection({
    required this.summary,
    required this.currency,
  });

  final ReportSummary summary;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    final hours = summary.hourlyBreakdown;
    final maxAmount =
        hours.fold<double>(0, (m, h) => h.amount > m ? h.amount : m);

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
              final barFraction =
                  maxAmount > 0 ? (h.amount / maxAmount) : 0.0;
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

  Future<void> _createClosing() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Text(
          'Close Today',
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          "Save today's operations data as a closing record?",
          style: GoogleFonts.notoSansKr(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancel',
              style: GoogleFonts.notoSansKr(color: AppColors.textSecondary),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.amber500,
              foregroundColor: AppColors.surface0,
            ),
            child: const Text('Close'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isClosing = true);
    try {
      await dailyClosingService.createDailyClosing(
        storeId: widget.storeId,
      );
      ref.invalidate(dailyClosingHistoryProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Closing complete.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(mapDailyClosingError(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _isClosing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final historyAsync = ref.watch(
      dailyClosingHistoryProvider(widget.storeId),
    );
    final currency = NumberFormat('#,###', 'vi_VN');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
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
            FilledButton.icon(
              onPressed: _isClosing ? null : _createClosing,
              icon: _isClosing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        color: AppColors.surface0,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.lock_clock, size: 16),
              label: const Text('Close Today'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
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
          _dCell(record.closingDate.length >= 10
              ? record.closingDate.substring(5)
              : record.closingDate, flex: 2),
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
    final auditTraceAsync = ref.watch(
      adminAuditTraceProvider(storeId),
    );

    return AdminAuditTracePanel(
      auditTraceAsync: auditTraceAsync,
      storeId: storeId,
      allowedEntityTypes: const {
        'orders',
        'order_items',
        'payments',
      },
      maxItems: 10,
      compact: true,
      showRetry: true,
      emptyMessage: 'No recent operations.',
    );
  }
}
