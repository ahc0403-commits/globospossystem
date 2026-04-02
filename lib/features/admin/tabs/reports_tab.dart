import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../../main.dart';
import '../../auth/auth_provider.dart';
import '../../report/report_provider.dart';

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
    final restaurantId = ref.watch(authProvider).restaurantId;
    final reportState = ref.watch(reportProvider);
    final reportNotifier = ref.read(reportProvider.notifier);
    final currency = NumberFormat('#,###', 'vi_VN');
    final dateFormat = DateFormat('dd/MM/yyyy');

    if (_pendingStart == null || _pendingEnd == null) {
      _pendingStart ??= reportState.startDate;
      _pendingEnd ??= reportState.endDate;
    }

    if (restaurantId != null && _initializedRestaurantId != restaurantId) {
      _initializedRestaurantId = restaurantId;
      Future.microtask(() => reportNotifier.loadReport(restaurantId));
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
                    onPressed: restaurantId == null
                        ? null
                        : () => reportNotifier.loadReport(restaurantId),
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
                          style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
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
                          style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                        ),
                      ),
                      FilledButton(
                        onPressed: restaurantId == null
                            ? null
                            : () {
                                final start = _pendingStart ?? reportState.startDate;
                                final end = _pendingEnd ?? reportState.endDate;
                                reportNotifier.setDateRange(start, end, restaurantId);
                              },
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.amber500,
                          foregroundColor: AppColors.surface0,
                        ),
                        child: const Text('Apply'),
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
                        onTap: restaurantId == null
                            ? null
                            : () {
                                final now = DateTime.now();
                                final start = DateTime(now.year, now.month, now.day);
                                setState(() {
                                  _pendingStart = start;
                                  _pendingEnd = now;
                                });
                                reportNotifier.setDateRange(start, now, restaurantId);
                              },
                      ),
                      _quickRangeChip(
                        'This Week',
                        onTap: restaurantId == null
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
                                reportNotifier.setDateRange(start, now, restaurantId);
                              },
                      ),
                      _quickRangeChip(
                        'This Month',
                        onTap: restaurantId == null
                            ? null
                            : () {
                                final now = DateTime.now();
                                final start = DateTime(now.year, now.month, 1);
                                setState(() {
                                  _pendingStart = start;
                                  _pendingEnd = now;
                                });
                                reportNotifier.setDateRange(start, now, restaurantId);
                              },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _SummaryGrid(summary: reportState.summary, currency: currency),
                  const SizedBox(height: 16),
                  _DailyTable(summary: reportState.summary, currency: currency),
                ],
              ),
            ),
    );
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
              title: 'Service Total',
              value: '₫${currency.format(data.serviceTotal)}',
              valueColor: Colors.grey.shade500,
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
            final rowColor = index.isEven ? AppColors.surface1 : AppColors.surface0;
            return _tableRow(
              date: DateFormat('dd/MM').format(row.date),
              dineIn: row.dineIn,
              delivery: row.delivery,
              total: row.total,
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
        ],
      ),
    );
  }

  Widget _tableRow({
    required String date,
    required double dineIn,
    required double delivery,
    required double total,
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
