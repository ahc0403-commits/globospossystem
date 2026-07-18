// ignore_for_file: unused_element

import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:intl/intl.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../core/services/daily_closing_service.dart';
import '../../../core/ui/pos_design_tokens.dart';
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

String _formatVnd(NumberFormat currency, num amount) {
  return '${currency.format(amount)} VND';
}

class _ReportsTabState extends ConsumerState<ReportsTab> {
  DateTime? _pendingStart;
  DateTime? _pendingEnd;
  String? _initializedRestaurantId;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final storeId = ref.watch(authProvider).storeId;
    final reportState = ref.watch(reportProvider);
    final reportNotifier = ref.read(reportProvider.notifier);
    final currency = NumberFormat('#,###', 'vi_VN');
    final dateFormat = DateFormat('dd/MM/yyyy');
    final summary = reportState.summary;
    final hasOperationalData = summary != null && summary.totalOrders > 0;

    if (_pendingStart == null || _pendingEnd == null) {
      _pendingStart ??= reportState.startDate;
      _pendingEnd ??= reportState.endDate;
    }

    if (storeId != null && _initializedRestaurantId != storeId) {
      _initializedRestaurantId = storeId;
      Future.microtask(() => reportNotifier.loadReport(storeId));
    }

    final compactHeader = _buildReportsCommandHeader(
      storeId: storeId,
      reportState: reportState,
      reportNotifier: reportNotifier,
      summary: summary,
      currency: currency,
      dateFormat: dateFormat,
    );

    void applyQuickRange(DateTime start, DateTime end) {
      if (storeId == null) return;
      setState(() {
        _pendingStart = start;
        _pendingEnd = end;
      });
      reportNotifier.setDateRange(start, end, storeId);
    }

    Widget quickRangesCard() {
      return PosActionCard(
        title: l10n.reportsQuickRanges,
        subtitle: l10n.reportsQuickRangesSubtitle,
        action: storeId == null
            ? null
            : PosSecondaryButton(
                label: l10n.refresh,
                icon: Icons.refresh_rounded,
                onPressed: () => reportNotifier.loadReport(storeId),
              ),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _quickRangeChip(
              l10n.today,
              onTap: storeId == null
                  ? null
                  : () {
                      final now = DateTime.now();
                      applyQuickRange(
                        DateTime(now.year, now.month, now.day),
                        now,
                      );
                    },
            ),
            _quickRangeChip(
              l10n.thisWeek,
              onTap: storeId == null
                  ? null
                  : () {
                      final now = DateTime.now();
                      final start = DateTime(
                        now.year,
                        now.month,
                        now.day,
                      ).subtract(Duration(days: now.weekday - 1));
                      applyQuickRange(start, now);
                    },
            ),
            _quickRangeChip(
              l10n.thisMonth,
              onTap: storeId == null
                  ? null
                  : () {
                      final now = DateTime.now();
                      applyQuickRange(DateTime(now.year, now.month, 1), now);
                    },
            ),
          ],
        ),
      );
    }

    Widget compactReportBody() {
      if (reportState.isLoading) {
        return SizedBox(
          height: 320,
          child: ToastOperationalLoadingState(
            label: PosLoadingCopy.loadingReport(context.l10n),
          ),
        );
      }

      if (reportState.error != null) {
        return ToastWorkSurface(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                reportState.error!,
                style: AppFonts.system(
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
                child: Text(l10n.retry),
              ),
            ],
          ),
        );
      }

      if (!hasOperationalData) {
        return PosActionCard(
          title: l10n.reportsNoDataTitle,
          subtitle: l10n.reportsNoDataSubtitle,
          action: storeId == null
              ? null
              : PosPrimaryButton(
                  label: l10n.reportsReloadToday,
                  icon: Icons.play_arrow_rounded,
                  onPressed: () {
                    final now = DateTime.now();
                    applyQuickRange(
                      DateTime(now.year, now.month, now.day),
                      now,
                    );
                  },
                ),
          child: Text(
            l10n.reportsNoDataBody,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: PosColors.textSecondary,
              height: 1.45,
            ),
          ),
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PosDataPanel(
            title: l10n.reportsHourlyOrderFocus,
            subtitle: l10n.reportsHourlyOrderFocusSubtitle,
            child: _ReportsHourlyOverview(summary: summary, currency: currency),
          ),
          const SizedBox(height: 12),
          PosActionCard(
            title: l10n.reportsImmediateSignals,
            subtitle: l10n.reportsImmediateSignalsSubtitle,
            badge: ToastStatusBadge(
              label:
                  summary.failedEinvoiceJobsCount > 0 ||
                      summary.missingProofPhotosCount > 0
                  ? l10n.reportsNeedsReviewShort
                  : l10n.reportsHealthyShort,
              color:
                  summary.failedEinvoiceJobsCount > 0 ||
                      summary.missingProofPhotosCount > 0
                  ? PosColors.warning
                  : PosColors.success,
              compact: true,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ReportsOperationalSignalsDetail(summary: summary),
                const SizedBox(height: 12),
                _ReportsBreakdownPanel(
                  summary: summary,
                  currency: currency,
                  scrollable: false,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          quickRangesCard(),
          const SizedBox(height: 12),
          PosDataPanel(
            title: l10n.reportsDailySalesTitle,
            subtitle: l10n.reportsDailySalesSubtitle,
            child: _DailyTable(summary: summary, currency: currency),
          ),
        ],
      );
    }

    final usesLargeText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    if (MediaQuery.sizeOf(context).width < 1080 || usesLargeText) {
      return Scaffold(
        key: const Key('reports_root'),
        backgroundColor: AppColors.surface0,
        body: ToastResponsiveScrollBody(
          key: const Key('reports_compact_scroll'),
          maxWidth: 1460,
          padding: const EdgeInsets.all(16),
          children: [
            compactHeader,
            if (summary != null) ...[
              const SizedBox(height: 12),
              _ReportsInsightRow(summary: summary),
            ],
            const SizedBox(height: 12),
            compactReportBody(),
            if (storeId != null) ...[
              const SizedBox(height: 12),
              _DailyClosingSection(storeId: storeId),
            ],
          ],
        ),
      );
    }

    return Scaffold(
      key: const Key('reports_root'),
      backgroundColor: AppColors.surface0,
      body: ToastResponsiveBody(
        maxWidth: 1460,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildReportsCommandHeader(
              storeId: storeId,
              reportState: reportState,
              reportNotifier: reportNotifier,
              summary: summary,
              currency: currency,
              dateFormat: dateFormat,
            ),
            const SizedBox(height: 12),
            if (summary != null) ...[
              _ReportsInsightRow(summary: summary),
              const SizedBox(height: 12),
            ],
            if (storeId != null) ...[
              _DailyClosingSection(storeId: storeId),
              const SizedBox(height: 12),
            ],
            Expanded(
              child: reportState.isLoading
                  ? ToastOperationalLoadingState(
                      label: PosLoadingCopy.loadingReport(context.l10n),
                    )
                  : reportState.error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            reportState.error!,
                            style: AppFonts.system(
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
                            child: Text(l10n.retry),
                          ),
                        ],
                      ),
                    )
                  : (hasOperationalData
                        ? LayoutBuilder(
                            builder: (context, reportConstraints) {
                              const compactReportHeight =
                                  520.0 + 12.0 + 520.0 + 12.0 + 272.0;
                              final content = Column(
                                children: [
                                  Expanded(
                                    child: PosSplitContent(
                                      primary: PosDataPanel(
                                        title: l10n.reportsHourlyOrderFocus,
                                        subtitle: l10n
                                            .reportsHourlyOrderFocusSubtitle,
                                        child: _ReportsHourlyOverview(
                                          summary: summary,
                                          currency: currency,
                                        ),
                                      ),
                                      secondary: Column(
                                        children: [
                                          Expanded(
                                            child: PosActionCard(
                                              title:
                                                  l10n.reportsImmediateSignals,
                                              subtitle: l10n
                                                  .reportsImmediateSignalsSubtitle,
                                              badge: ToastStatusBadge(
                                                label:
                                                    summary.failedEinvoiceJobsCount >
                                                            0 ||
                                                        summary.missingProofPhotosCount >
                                                            0
                                                    ? l10n.reportsNeedsReviewShort
                                                    : l10n.reportsHealthyShort,
                                                color:
                                                    summary.failedEinvoiceJobsCount >
                                                            0 ||
                                                        summary.missingProofPhotosCount >
                                                            0
                                                    ? PosColors.warning
                                                    : PosColors.success,
                                                compact: true,
                                              ),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.stretch,
                                                children: [
                                                  _ReportsOperationalSignalsDetail(
                                                    summary: summary,
                                                  ),
                                                  const SizedBox(height: 12),
                                                  Expanded(
                                                    child:
                                                        _ReportsBreakdownPanel(
                                                          summary: summary,
                                                          currency: currency,
                                                        ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          PosActionCard(
                                            title: l10n.reportsQuickRanges,
                                            subtitle:
                                                l10n.reportsQuickRangesSubtitle,
                                            action: storeId == null
                                                ? null
                                                : PosSecondaryButton(
                                                    label: l10n.refresh,
                                                    icon: Icons.refresh_rounded,
                                                    onPressed: () {
                                                      reportNotifier.loadReport(
                                                        storeId,
                                                      );
                                                    },
                                                  ),
                                            child: Wrap(
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: [
                                                _quickRangeChip(
                                                  l10n.today,
                                                  onTap: storeId == null
                                                      ? null
                                                      : () {
                                                          final now =
                                                              DateTime.now();
                                                          final start =
                                                              DateTime(
                                                                now.year,
                                                                now.month,
                                                                now.day,
                                                              );
                                                          setState(() {
                                                            _pendingStart =
                                                                start;
                                                            _pendingEnd = now;
                                                          });
                                                          reportNotifier
                                                              .setDateRange(
                                                                start,
                                                                now,
                                                                storeId,
                                                              );
                                                        },
                                                ),
                                                _quickRangeChip(
                                                  l10n.thisWeek,
                                                  onTap: storeId == null
                                                      ? null
                                                      : () {
                                                          final now =
                                                              DateTime.now();
                                                          final weekdayOffset =
                                                              now.weekday - 1;
                                                          final start =
                                                              DateTime(
                                                                now.year,
                                                                now.month,
                                                                now.day,
                                                              ).subtract(
                                                                Duration(
                                                                  days:
                                                                      weekdayOffset,
                                                                ),
                                                              );
                                                          setState(() {
                                                            _pendingStart =
                                                                start;
                                                            _pendingEnd = now;
                                                          });
                                                          reportNotifier
                                                              .setDateRange(
                                                                start,
                                                                now,
                                                                storeId,
                                                              );
                                                        },
                                                ),
                                                _quickRangeChip(
                                                  l10n.thisMonth,
                                                  onTap: storeId == null
                                                      ? null
                                                      : () {
                                                          final now =
                                                              DateTime.now();
                                                          final start =
                                                              DateTime(
                                                                now.year,
                                                                now.month,
                                                                1,
                                                              );
                                                          setState(() {
                                                            _pendingStart =
                                                                start;
                                                            _pendingEnd = now;
                                                          });
                                                          reportNotifier
                                                              .setDateRange(
                                                                start,
                                                                now,
                                                                storeId,
                                                              );
                                                        },
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                      spacing: 12,
                                      compactSecondaryHeight: 520,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    height: 272,
                                    child: PosDataPanel(
                                      title:
                                          context.l10n.reportsDailySalesTitle,
                                      subtitle: context
                                          .l10n
                                          .reportsDailySalesSubtitle,
                                      child: _DailyTable(
                                        summary: summary,
                                        currency: currency,
                                      ),
                                    ),
                                  ),
                                ],
                              );

                              if (reportConstraints.maxWidth < 1080 ||
                                  reportConstraints.maxHeight <
                                      compactReportHeight) {
                                return ListView(
                                  key: const Key('reports_compact_scroll'),
                                  keyboardDismissBehavior:
                                      ScrollViewKeyboardDismissBehavior.onDrag,
                                  children: [
                                    SizedBox(
                                      height: compactReportHeight,
                                      child: content,
                                    ),
                                  ],
                                );
                              }

                              return content;
                            },
                          )
                        : _ReportsEmptyWorkspace(
                            onReloadToday: storeId == null
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
                          )),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReportsCommandHeader({
    required String? storeId,
    required ReportState reportState,
    required ReportNotifier reportNotifier,
    required ReportSummary? summary,
    required NumberFormat currency,
    required DateFormat dateFormat,
  }) {
    final l10n = context.l10n;
    final totalRevenue = summary == null
        ? '—'
        : _formatVnd(currency, summary.totalRevenue);
    final averageOrder = summary == null || summary.totalOrders == 0
        ? '—'
        : _formatVnd(currency, summary.totalRevenue / summary.totalOrders);
    final cancellationTone = summary == null || summary.cancelledOrders == 0
        ? PosColors.textSecondary
        : PosColors.warning;
    final hasException =
        (summary?.failedEinvoiceJobsCount ?? 0) > 0 ||
        (summary?.missingProofPhotosCount ?? 0) > 0 ||
        (summary?.cancelledOrders ?? 0) > 0;

    return ToastWorkSurface(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      backgroundColor: AppColors.surface1,
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
                      l10n.reports,
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.reportsScreenSubtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PosColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              ToastStatusBadge(
                label: hasException
                    ? l10n.reportsNeedsReviewShort
                    : l10n.reportsHealthyShort,
                color: hasException ? PosColors.warning : PosColors.success,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 14),
          KeyedSubtree(
            key: const Key('reports_order_accuracy_metrics'),
            child: ToastMetricStrip(
              metrics: [
                ToastMetric(label: l10n.reportsTotalSales, value: totalRevenue),
                ToastMetric(
                  label: l10n.reportsTotalOrders,
                  value: summary == null ? '—' : '${summary.totalOrders}',
                  tone: PosColors.info,
                ),
                ToastMetric(
                  label: l10n.pending,
                  value: summary == null ? '—' : '${summary.openOrders}',
                  tone: (summary?.openOrders ?? 0) > 0
                      ? PosColors.warning
                      : PosColors.textSecondary,
                ),
                ToastMetric(
                  label: l10n.reportsAverageOrderAmount,
                  value: averageOrder,
                  tone: PosColors.success,
                ),
                ToastMetric(
                  label: l10n.reportsCanceledAmount,
                  value: summary == null
                      ? '—'
                      : l10n.countCases(summary.cancelledOrders),
                  tone: cancellationTone,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
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
                icon: const Icon(Icons.event_outlined, size: 16),
                label: Text(
                  '${l10n.from} ${dateFormat.format(_pendingStart ?? reportState.startDate)}',
                ),
              ),
              OutlinedButton.icon(
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
                icon: const Icon(Icons.event_available_outlined, size: 16),
                label: Text(
                  '${l10n.to} ${dateFormat.format(_pendingEnd ?? reportState.endDate)}',
                ),
              ),
              FilledButton.icon(
                onPressed: storeId == null
                    ? null
                    : () {
                        final start = _pendingStart ?? reportState.startDate;
                        final end = _pendingEnd ?? reportState.endDate;
                        reportNotifier.setDateRange(start, end, storeId);
                      },
                icon: const Icon(Icons.search, size: 16),
                label: Text(l10n.lookup),
              ),
              OutlinedButton.icon(
                onPressed: summary == null
                    ? null
                    : () => _exportReport(reportNotifier),
                icon: const Icon(Icons.download_rounded, size: 16),
                label: Text(l10n.reportsDownload),
              ),
            ],
          ),
        ],
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
      ).showSnackBar(SnackBar(content: Text(context.l10n.reportsSaved)));
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
          style: AppFonts.system(
            color: AppColors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

String _shareLabel(double amount, double total) {
  if (total <= 0) {
    return '0%';
  }
  return '${((amount / total) * 100).round()}%';
}

String _cancelRateLabel(ReportSummary summary) {
  if (summary.totalOrders == 0) {
    return '0%';
  }
  final rate = (summary.cancelledOrders / summary.totalOrders) * 100;
  return '${rate.toStringAsFixed(rate >= 10 ? 0 : 1)}%';
}

String _peakHourLabel(BuildContext context, ReportSummary summary) {
  if (summary.hourlyBreakdown.isEmpty) {
    return context.l10n.reportsPeakHourUnavailable;
  }
  final peak = summary.hourlyBreakdown.reduce(
    (current, next) => current.amount >= next.amount ? current : next,
  );
  return context.l10n.reportsHourLabel(peak.hour.toString().padLeft(2, '0'));
}

class _ReportsInsightRow extends StatelessWidget {
  const _ReportsInsightRow({required this.summary});

  final ReportSummary summary;

  @override
  Widget build(BuildContext context) {
    final signals = <_ReportsInsightData>[
      _ReportsInsightData(
        title: _peakHourLabel(context, summary),
        body: context.l10n.reportsInsightPeakBody,
        tone: PosColors.accent,
        icon: Icons.schedule_rounded,
      ),
      _ReportsInsightData(
        title: summary.cancelledOrders > 0
            ? context.l10n.reportsInsightCancelledOrders(
                summary.cancelledOrders,
              )
            : context.l10n.reportsInsightCancelStable,
        body: summary.cancelledOrders > 0
            ? context.l10n.reportsInsightCancelNeedsReview(
                _cancelRateLabel(summary),
              )
            : context.l10n.reportsInsightCancelHealthy,
        tone: summary.cancelledOrders > 0
            ? PosColors.warning
            : PosColors.success,
        icon: Icons.warning_amber_rounded,
      ),
      _ReportsInsightData(
        title: summary.failedEinvoiceJobsCount > 0
            ? context.l10n.reportsInsightFailedEinvoice(
                summary.failedEinvoiceJobsCount,
              )
            : summary.missingProofPhotosCount > 0
            ? context.l10n.reportsInsightMissingProof(
                summary.missingProofPhotosCount,
              )
            : context.l10n.reportsInsightPaymentHealthy,
        body: summary.failedEinvoiceJobsCount > 0
            ? context.l10n.reportsInsightRetryBeforeClose
            : summary.missingProofPhotosCount > 0
            ? context.l10n.reportsInsightProofFirst
            : context.l10n.reportsInsightSettlementHealthy,
        tone:
            summary.failedEinvoiceJobsCount > 0 ||
                summary.missingProofPhotosCount > 0
            ? PosColors.danger
            : PosColors.info,
        icon: Icons.monitor_heart_outlined,
      ),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: signals
          .map((signal) => _ReportsInsightTile(data: signal))
          .toList(),
    );
  }
}

class _ReportsInsightData {
  const _ReportsInsightData({
    required this.title,
    required this.body,
    required this.tone,
    required this.icon,
  });

  final String title;
  final String body;
  final Color tone;
  final IconData icon;
}

class _ReportsInsightTile extends StatelessWidget {
  const _ReportsInsightTile({required this.data});

  final _ReportsInsightData data;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 280,
      child: ToastWorkSurface(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        backgroundColor: PosColors.surface,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: data.tone.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(data.icon, size: 18, color: data.tone),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: PosColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    data.body,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.textSecondary,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportsEmptyWorkspace extends StatelessWidget {
  const _ReportsEmptyWorkspace({this.onReloadToday});

  final VoidCallback? onReloadToday;

  @override
  Widget build(BuildContext context) {
    final noDataCard = SizedBox(
      height: 180,
      child: PosActionCard(
        title: context.l10n.reportsNoDataTitle,
        subtitle: context.l10n.reportsNoDataSubtitle,
        action: onReloadToday == null
            ? null
            : PosPrimaryButton(
                label: context.l10n.reportsReloadToday,
                icon: Icons.play_arrow_rounded,
                onPressed: onReloadToday,
              ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: PosColors.accentMuted,
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(
                Icons.insights_outlined,
                color: PosColors.accent,
                size: 28,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                context.l10n.reportsNoDataBody,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: PosColors.textSecondary,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final signalTiles = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _ReportsInsightTile(
          data: _ReportsInsightData(
            title: context.l10n.reportsPeakHourUnavailable,
            body: context.l10n.reportsEmptyPeakBody,
            tone: PosColors.info,
            icon: Icons.schedule_rounded,
          ),
        ),
        _ReportsInsightTile(
          data: _ReportsInsightData(
            title: context.l10n.reportsEmptyNoCancelOrFailure,
            body: context.l10n.reportsEmptyNoCancelOrFailureBody,
            tone: PosColors.success,
            icon: Icons.check_circle_outline_rounded,
          ),
        ),
        _ReportsInsightTile(
          data: _ReportsInsightData(
            title: context.l10n.reportsEmptyProofWaiting,
            body: context.l10n.reportsEmptyProofWaitingBody,
            tone: PosColors.warning,
            icon: Icons.receipt_long_rounded,
          ),
        ),
      ],
    );
    final liveSignalPanel = PosDataPanel(
      title: context.l10n.reportsLiveSignalsReady,
      subtitle: context.l10n.reportsLiveSignalsReadySubtitle,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: EdgeInsets.zero,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 520),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: PosColors.mutedSurface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: PosColors.border),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.wifi_tethering_rounded,
                        color: PosColors.textMuted,
                        size: 24,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        context.l10n.reportsWaitingLiveSignals,
                        style: Theme.of(context).textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        context.l10n.reportsWaitingLiveSignalsBody,
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.hasBoundedHeight && constraints.maxHeight < 640) {
          return ListView(
            padding: EdgeInsets.zero,
            children: [
              noDataCard,
              const SizedBox(height: 12),
              signalTiles,
              const SizedBox(height: 12),
              SizedBox(height: 220, child: liveSignalPanel),
            ],
          );
        }

        return Column(
          children: [
            noDataCard,
            const SizedBox(height: 12),
            signalTiles,
            const SizedBox(height: 12),
            Expanded(child: liveSignalPanel),
          ],
        );
      },
    );
  }
}

class _ReportsHourlyOverview extends StatelessWidget {
  const _ReportsHourlyOverview({required this.summary, required this.currency});

  final ReportSummary summary;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    if (summary.hourlyBreakdown.isEmpty) {
      return Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: PosColors.mutedSurface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: PosColors.border),
          ),
          child: PosEmptyState(
            title: context.l10n.reportsNoDataTitle,
            subtitle: context.l10n.reportsNoDataSubtitle,
            icon: Icons.timeline_outlined,
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final chart = _HourlyRevenueSection(
          summary: summary,
          currency: currency,
        );
        return Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _ReportsInlineMetric(
                    label: context.l10n.reportsDineInRevenue,
                    value: _formatVnd(currency, summary.dineInRevenue),
                    tone: PosColors.textPrimary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ReportsInlineMetric(
                    label: context.l10n.reportsDeliveryRevenue,
                    value: _formatVnd(currency, summary.deliveryRevenue),
                    tone: PosColors.accent,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ReportsInlineMetric(
                    label: context.l10n.reportsServiceExpenses,
                    value: _formatVnd(currency, summary.serviceTotal),
                    tone: PosColors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (constraints.hasBoundedHeight) Expanded(child: chart) else chart,
          ],
        );
      },
    );
  }
}

class _ReportsInlineMetric extends StatelessWidget {
  const _ReportsInlineMetric({
    required this.label,
    required this.value,
    required this.tone,
  });

  final String label;
  final String value;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: PosColors.mutedSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PosColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: PosColors.textSecondary,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: tone,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReportsBreakdownPanel extends StatelessWidget {
  const _ReportsBreakdownPanel({
    required this.summary,
    required this.currency,
    this.scrollable = true,
  });

  final ReportSummary summary;
  final NumberFormat currency;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ReportsSectionTitle(
          title: context.l10n.reportsChannelMix,
          action: Text(
            context.l10n.reportsOrderCount(summary.totalOrders),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: PosColors.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _ReportsInlineMetric(
                label: context.l10n.dineIn,
                value: _formatVnd(currency, summary.dineInRevenue),
                tone: PosColors.textPrimary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ReportsInlineMetric(
                label: context.l10n.delivery,
                value: _formatVnd(currency, summary.deliveryRevenue),
                tone: PosColors.accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _ReportsSectionTitle(title: context.l10n.cashierPaymentMethod),
        const SizedBox(height: 10),
        if (summary.paymentMethodBreakdown.isEmpty)
          PosEmptyState(
            title: context.l10n.reportsNoPaymentMethodData,
            subtitle: context.l10n.reportsNoPaymentMethodDataSubtitle,
            icon: Icons.payments_outlined,
          )
        else
          ...summary.paymentMethodBreakdown.map(
            (method) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: PosColors.mutedSurface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: PosColors.border),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        method.method,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      context.l10n.reportsOrderCount(method.count),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PosColors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 132,
                      child: Text(
                        _formatVnd(currency, method.totalAmount),
                        textAlign: TextAlign.right,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 16),
        _ReportsSectionTitle(title: context.l10n.reportsOperationalExceptions),
        const SizedBox(height: 10),
        _ReportsExceptionRow(
          label: context.l10n.reportsMissingProof,
          value: context.l10n.reportsOrderCount(
            summary.missingProofPhotosCount,
          ),
          tone: summary.missingProofPhotosCount > 0
              ? PosColors.warning
              : PosColors.success,
        ),
        const SizedBox(height: 8),
        _ReportsExceptionRow(
          label: context.l10n.reportsFailedEinvoice,
          value: context.l10n.reportsOrderCount(
            summary.failedEinvoiceJobsCount,
          ),
          tone: summary.failedEinvoiceJobsCount > 0
              ? PosColors.danger
              : PosColors.success,
        ),
        const SizedBox(height: 8),
        _ReportsExceptionRow(
          label: context.l10n.reportsProofCompletion,
          value: '${summary.proofCompletePercent.toStringAsFixed(0)}%',
          tone: summary.proofCompletePercent < 100
              ? PosColors.warning
              : PosColors.success,
        ),
        const SizedBox(height: 8),
        _ReportsExceptionRow(
          label: context.l10n.reportsWt08Reported,
          value: context.l10n.reportsOrderCount(summary.wetaxReportedCount),
          tone: PosColors.info,
        ),
      ],
    );

    if (!scrollable) {
      return content;
    }

    return SingleChildScrollView(child: content);
  }
}

class _ReportsSectionTitle extends StatelessWidget {
  const _ReportsSectionTitle({required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const Spacer(),
        if (action != null) action!,
      ],
    );
  }
}

class _ReportsExceptionRow extends StatelessWidget {
  const _ReportsExceptionRow({
    required this.label,
    required this.value,
    required this.tone,
  });

  final String label;
  final String value;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tone.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: PosColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: tone,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
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
    final l10n = context.l10n;
    final data = summary;
    if (data == null) {
      return _noData(context);
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
              title: l10n.dineIn,
              value: _formatVnd(currency, data.dineInRevenue),
              valueColor: AppColors.amber500,
              valueFontSize: 28,
            ),
            _summaryCard(
              title: l10n.delivery,
              value: _formatVnd(currency, data.deliveryRevenue),
              valueColor: AppColors.statusAvailable,
              valueFontSize: 28,
            ),
            _summaryCard(
              title: l10n.reportsServiceExpensesHint,
              value: _formatVnd(currency, data.serviceTotal),
              valueColor: AppColors.textSecondary,
              valueFontSize: 28,
            ),
            _summaryCard(
              title: l10n.reportsTotalSales,
              value: _formatVnd(currency, data.totalRevenue),
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
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.surface3),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            title,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: AppFonts.system(
              color: valueColor,
              fontSize: valueFontSize,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _noData(BuildContext context) {
    return Container(
      height: 130,
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(16),
      ),
      alignment: Alignment.center,
      child: Text(
        context.l10n.reportsNoDataSelectedPeriod,
        style: AppFonts.system(color: AppColors.textSecondary),
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
    final l10n = context.l10n;
    final data = summary;
    if (data == null || data.dailyBreakdown.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Text(
            l10n.reportsNoDataSelectedPeriod,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 14,
            ),
          ),
        ),
      );
    }

    String vnd(double v) => _formatVnd(currency, v);

    return ToastDenseDataTable(
      columns: [
        ToastDenseColumn(label: l10n.date, flex: 2),
        ToastDenseColumn(label: l10n.dineIn),
        ToastDenseColumn(label: l10n.delivery),
        ToastDenseColumn(label: l10n.total),
        ToastDenseColumn(label: l10n.cash),
        ToastDenseColumn(label: l10n.cashierCardMethod),
        ToastDenseColumn(label: l10n.pay),
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
          l10n.total,
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
    final l10n = context.l10n;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Text(
            l10n.reportsOrdersCount(summary.totalOrders),
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            l10n.reportsDoneCount(summary.completedOrders),
            style: AppFonts.system(
              color: AppColors.statusAvailable,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (summary.totalOrders >
              summary.completedOrders + summary.cancelledOrders) ...[
            const SizedBox(width: 12),
            Text(
              l10n.reportsInProgressCount(
                summary.totalOrders -
                    summary.completedOrders -
                    summary.cancelledOrders,
              ),
              style: AppFonts.system(
                color: AppColors.amber500,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (summary.cancelledOrders > 0) ...[
            const SizedBox(width: 12),
            Text(
              l10n.reportsCancelCount(
                summary.cancelledOrders,
                summary.cancelledItems,
              ),
              style: AppFonts.system(
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
    final l10n = context.l10n;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Text(
            l10n.reportsPaymentMethod,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${l10n.cash} ${_formatVnd(currency, summary.cashTotal)}',
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${l10n.cashierCardMethod} ${_formatVnd(currency, summary.cardTotal)}',
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (summary.payTotal > 0) ...[
            const SizedBox(width: 12),
            Text(
              '${l10n.pay} ${_formatVnd(currency, summary.payTotal)}',
              style: AppFonts.system(
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

class _ReportsOperationalSignalsDetail extends StatelessWidget {
  const _ReportsOperationalSignalsDetail({required this.summary});

  final ReportSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final hasExceptions =
        summary.failedEinvoiceJobsCount > 0 ||
        summary.missingProofPhotosCount > 0;

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const Key('reports_operational_signals_detail'),
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
        leading: Icon(
          Icons.rule_folder_outlined,
          color: hasExceptions ? PosColors.warning : PosColors.success,
        ),
        title: Text(
          l10n.reportsOperationalAttentionTitle,
          style: AppFonts.system(
            color: AppColors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          l10n.reportsOperationalBoundary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppFonts.system(
            color: AppColors.textSecondary,
            fontSize: 11.5,
          ),
        ),
        trailing: ToastStatusBadge(
          label: hasExceptions
              ? l10n.reportsNeedsReviewShort
              : l10n.reportsHealthyShort,
          color: hasExceptions ? PosColors.warning : PosColors.success,
          compact: true,
        ),
        children: [_OperationalAttentionSection(summary: summary)],
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
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.reportsOperationalAttentionSubtitle,
            style: AppFonts.system(
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
            style: AppFonts.system(
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
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: AppFonts.system(
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
        style: AppFonts.system(
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
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            headline,
            style: AppFonts.system(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: AppFonts.system(
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
          style: AppFonts.system(
            color: AppColors.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
          children: [
            TextSpan(text: '$label '),
            TextSpan(
              text: value,
              style: AppFonts.system(
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
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Text(
            body,
            style: AppFonts.system(
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
      data: (summary) => _buildContent(context, summary, currency, ref),
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
    BuildContext context,
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
              context.l10n.reportsTodaysOperations,
              style: AppFonts.system(
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
                  context.l10n.reportsOrder,
                  '${summary.ordersTotal}',
                  AppColors.textPrimary,
                ),
                _metricTile(
                  context.l10n.reportsDone,
                  '${summary.ordersCompleted}',
                  AppColors.statusAvailable,
                ),
                _metricTile(
                  context.l10n.reportsInProgress,
                  '${summary.ordersPending + summary.ordersConfirmed + summary.ordersServing}',
                  AppColors.amber500,
                ),
                _metricTile(
                  context.l10n.reportsCancel,
                  context.l10n.reportsCanceledItemsSummary(
                    summary.ordersCancelled,
                    summary.itemsCancelled,
                  ),
                  AppColors.statusCancelled,
                ),
                _metricTile(
                  context.l10n.reportsPay,
                  '${summary.paymentsCount}',
                  AppColors.textPrimary,
                ),
                _metricTile(
                  context.l10n.reportsPaymentTotal,
                  _formatVnd(currency, summary.paymentsTotal),
                  AppColors.amber500,
                ),
                _metricTile(
                  context.l10n.reportsCashCard,
                  '${_formatVnd(currency, summary.paymentsCash)} / ${_formatVnd(currency, summary.paymentsCard)}',
                  AppColors.textSecondary,
                ),
                _metricTile(
                  context.l10n.table,
                  context.l10n.reportsTablesInUse(
                    summary.tablesOccupied,
                    summary.tablesTotal,
                  ),
                  AppColors.statusOccupied,
                ),
                _metricTile(
                  context.l10n.reportsLowStock,
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
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: AppFonts.system(
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
          context.l10n.reportsRevenueByHour,
          style: AppFonts.system(
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
                        style: AppFonts.system(
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
                      width: 104,
                      child: Text(
                        _formatVnd(currency, h.amount),
                        style: AppFonts.system(
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
      title: context.l10n.reportsCloseToday,
      description: context.l10n.reportsSaveClosingQuestion,
      confirmLabel: context.l10n.close,
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isClosing = true);
    try {
      await dailyClosingService.createDailyClosing(storeId: widget.storeId);
      ref.invalidate(dailyClosingHistoryProvider);
      if (mounted) {
        setState(() => _closingSucceeded = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.reportsClosingComplete)),
        );
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
              context.l10n.reportsDailyClose,
              style: AppFonts.system(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            PosActionButton(
              key: const Key('daily_closing_submit_button'),
              label: context.l10n.reportsCloseToday,
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
                  context.l10n.reportsClosingComplete,
                  style: AppFonts.system(
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
              context.l10n.reportsTodayAlreadyComplete,
              style: AppFonts.system(color: AppColors.amber500, fontSize: 12),
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
                      context.l10n.reportsNoClosingHistory,
                      style: AppFonts.system(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                )
              : Container(
                  height: 220,
                  decoration: BoxDecoration(
                    color: AppColors.surface1,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      _closingTableHeader(),
                      Expanded(
                        child: ListView(
                          children: records
                              .take(10)
                              .toList()
                              .asMap()
                              .entries
                              .map((entry) {
                                final index = entry.key;
                                final record = entry.value;
                                return _closingTableRow(
                                  record: record,
                                  currency: currency,
                                  bgColor: index.isEven
                                      ? AppColors.surface1
                                      : AppColors.surface0,
                                );
                              })
                              .toList(),
                        ),
                      ),
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
                style: AppFonts.system(
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
          _hCell(context.l10n.reportsDate, flex: 2),
          _hCell(context.l10n.reportsOrder),
          _hCell(context.l10n.reportsDone),
          _hCell(context.l10n.reportsCancel),
          _hCell(context.l10n.reportsRevenue),
          _hCell(context.l10n.reportsCash),
          _hCell(context.l10n.reportsCard),
          _hCell(context.l10n.reportsLow),
          _hCell(context.l10n.reportsAssignee),
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
          _dCell(_formatVnd(currency, record.paymentsTotal)),
          _dCell(_formatVnd(currency, record.paymentsCash)),
          _dCell(_formatVnd(currency, record.paymentsCard)),
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
        style: AppFonts.system(
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
        style: AppFonts.system(
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
      emptyMessage: context.l10n.reportsNoRecentOperations,
    );
  }
}
