import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/toast/toast.dart';
import '../../main.dart';
import '../report/menu_sales_analytics.dart';
import '../report/menu_sales_analytics_panel.dart';
import '../report/report_provider.dart';
import 'widgets/paperless_operations_dashboard.dart';
import 'widgets/sales_revenue_analysis_dashboard.dart';

EdgeInsets _analysisPagePadding(BuildContext context) =>
    EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 8 : 12);

class PaperlessOperationsAnalyticsScreen extends StatelessWidget {
  const PaperlessOperationsAnalyticsScreen({
    super.key,
    required this.storeId,
    required this.startDate,
    required this.endDate,
  });

  final String storeId;
  final DateTime startDate;
  final DateTime endDate;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('paperless_operations_analytics_screen'),
      backgroundColor: AppColors.surface0,
      appBar: AppBar(
        title: Text(paperlessOperationsTitle(context)),
        backgroundColor: AppColors.surface0,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        child: ToastResponsiveScrollBody(
          key: const Key('paperless_operations_analytics_scroll'),
          maxWidth: 1460,
          padding: _analysisPagePadding(context),
          children: [
            PaperlessOperationsDashboard(
              storeId: storeId,
              startDate: startDate,
              endDate: endDate,
            ),
          ],
        ),
      ),
    );
  }
}

class MenuSalesAnalyticsScreen extends StatelessWidget {
  const MenuSalesAnalyticsScreen({super.key, required this.params});

  final MenuSalesAnalyticsParams params;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('menu_sales_analytics_screen'),
      backgroundColor: AppColors.surface0,
      appBar: AppBar(
        title: Text(context.l10n.menuSalesAnalyticsTitle),
        backgroundColor: AppColors.surface0,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        child: ToastResponsiveScrollBody(
          key: const Key('menu_sales_analytics_scroll'),
          maxWidth: 1460,
          padding: _analysisPagePadding(context),
          children: [
            MenuSalesAnalyticsPanel(
              params: params,
              currency: NumberFormat('#,###', 'vi_VN'),
            ),
          ],
        ),
      ),
    );
  }
}

class SalesRevenueAnalyticsScreen extends ConsumerStatefulWidget {
  const SalesRevenueAnalyticsScreen({
    super.key,
    required this.storeId,
    required this.startDate,
    required this.endDate,
  });

  final String storeId;
  final DateTime startDate;
  final DateTime endDate;

  @override
  ConsumerState<SalesRevenueAnalyticsScreen> createState() =>
      _SalesRevenueAnalyticsScreenState();
}

class _SalesRevenueAnalyticsScreenState
    extends ConsumerState<SalesRevenueAnalyticsScreen> {
  late DateTime _pendingStart;
  late DateTime _pendingEnd;

  @override
  void initState() {
    super.initState();
    _pendingStart = widget.startDate;
    _pendingEnd = widget.endDate;
  }

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _pendingStart,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _pendingStart = picked;
      if (_pendingEnd.isBefore(picked)) _pendingEnd = picked;
    });
  }

  Future<void> _pickEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _pendingEnd,
      firstDate: _pendingStart,
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) return;
    setState(() => _pendingEnd = picked);
  }

  void _applyQuickRange(int days) {
    final now = DateTime.now();
    final end = DateTime(now.year, now.month, now.day);
    final start = end.subtract(Duration(days: days - 1));
    setState(() {
      _pendingStart = start;
      _pendingEnd = end;
    });
    ref.read(reportProvider.notifier).setDateRange(start, end, widget.storeId);
  }

  void _applyCustomRange() {
    ref
        .read(reportProvider.notifier)
        .setDateRange(_pendingStart, _pendingEnd, widget.storeId);
  }

  @override
  Widget build(BuildContext context) {
    final reportState = ref.watch(reportProvider);
    return Scaffold(
      key: const Key('sales_revenue_analytics_screen'),
      backgroundColor: AppColors.surface0,
      appBar: AppBar(
        title: Text(salesRevenueAnalysisTitle(context)),
        backgroundColor: AppColors.surface0,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        child: ToastResponsiveScrollBody(
          key: const Key('sales_revenue_analytics_scroll'),
          maxWidth: 1460,
          padding: _analysisPagePadding(context),
          children: [
            SalesRevenueAnalysisDashboard(
              summary: reportState.summary,
              startDate: _pendingStart,
              endDate: _pendingEnd,
              isLoading: reportState.isLoading,
              error: reportState.error,
              onQuickRangeSelected: _applyQuickRange,
              onStartDatePressed: _pickStartDate,
              onEndDatePressed: _pickEndDate,
              onApplyCustomRange: _applyCustomRange,
              onRetry: () =>
                  ref.read(reportProvider.notifier).loadReport(widget.storeId),
            ),
          ],
        ),
      ),
    );
  }
}
