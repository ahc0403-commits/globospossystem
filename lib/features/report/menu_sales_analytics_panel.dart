import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import 'menu_sales_analytics.dart';
import 'menu_sales_excel_export.dart';
import 'report_excel_file.dart';

enum _MenuSalesMetric { quantity, revenue }

class MenuSalesAnalyticsPanel extends ConsumerStatefulWidget {
  const MenuSalesAnalyticsPanel({
    super.key,
    required this.params,
    required this.currency,
    this.saveExcelFile,
  });

  final MenuSalesAnalyticsParams params;
  final NumberFormat currency;
  final ReportExcelFileSaver? saveExcelFile;

  @override
  ConsumerState<MenuSalesAnalyticsPanel> createState() =>
      _MenuSalesAnalyticsPanelState();
}

class _MenuSalesAnalyticsPanelState
    extends ConsumerState<MenuSalesAnalyticsPanel> {
  MenuSalesSort _sort = MenuSalesSort.quantity;
  _MenuSalesMetric _metric = _MenuSalesMetric.quantity;
  bool _showAll = false;
  MenuSalesScope _scope = MenuSalesScope.all;
  String? _selectedMenuKey;
  late DateTime _startDate;
  late DateTime _endDate;
  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    _scope = widget.params.scope;
    _startDate = DateUtils.dateOnly(widget.params.startDate);
    _endDate = DateUtils.dateOnly(widget.params.endDate);
  }

  @override
  void didUpdateWidget(covariant MenuSalesAnalyticsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final startDate = DateUtils.dateOnly(widget.params.startDate);
    final endDate = DateUtils.dateOnly(widget.params.endDate);
    if (oldWidget.params.storeId != widget.params.storeId ||
        DateUtils.dateOnly(oldWidget.params.startDate) != startDate ||
        DateUtils.dateOnly(oldWidget.params.endDate) != endDate) {
      _startDate = startDate;
      _endDate = endDate;
    }
    if (oldWidget.params.scope != widget.params.scope) {
      _scope = widget.params.scope;
    }
  }

  Future<void> _selectSingleDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate,
      firstDate: DateTime(2020),
      lastDate: DateUtils.dateOnly(DateTime.now()),
      helpText: _MenuSalesDateCopy.of(context).selectSingleDate,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _startDate = DateUtils.dateOnly(picked);
      _endDate = _startDate;
      _showAll = false;
      _selectedMenuKey = null;
    });
  }

  Future<void> _selectDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(start: _startDate, end: _endDate),
      firstDate: DateTime(2020),
      lastDate: DateUtils.dateOnly(DateTime.now()),
      helpText: _MenuSalesDateCopy.of(context).selectDateRange,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _startDate = DateUtils.dateOnly(picked.start);
      _endDate = DateUtils.dateOnly(picked.end);
      _showAll = false;
      _selectedMenuKey = null;
    });
  }

  Future<void> _downloadExcel(
    MenuSalesAnalyticsParams params,
    MenuSalesAnalytics analytics,
  ) async {
    if (_isExporting) return;
    setState(() => _isExporting = true);
    try {
      final bytes = buildMenuSalesAnalyticsWorkbook(
        analytics: analytics,
        params: params,
      );
      if (bytes.isEmpty) return;
      final dateFormat = DateFormat('yyyyMMdd');
      final fileName =
          'menu_sales_${dateFormat.format(params.startDate)}_${dateFormat.format(params.endDate)}_${params.scope.rpcValue}';
      final saver = widget.saveExcelFile ?? saveReportExcelFile;
      await saver(name: fileName, bytes: Uint8List.fromList(bytes));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.reportsSaved)));
      }
    } catch (error) {
      if (mounted) {
        final languageCode = Localizations.localeOf(context).languageCode;
        final message = switch (languageCode) {
          'vi' => 'Không thể tải Excel doanh số theo món',
          'en' => 'Menu sales Excel download failed',
          _ => '메뉴별 판매 Excel 다운로드에 실패했습니다',
        };
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$message: $error')));
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final effectiveParams = MenuSalesAnalyticsParams(
      storeId: widget.params.storeId,
      startDate: _startDate,
      endDate: _endDate,
      scope: _scope,
    );
    final analyticsAsync = ref.watch(
      menuSalesAnalyticsProvider(effectiveParams),
    );
    final downloadableAnalytics = analyticsAsync.asData?.value;

    return PosDataPanel(
      title: context.l10n.menuSalesAnalyticsTitle,
      subtitle: context.l10n.menuSalesAnalyticsSubtitle,
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _MenuSalesPeriodFilter(
                startDate: _startDate,
                endDate: _endDate,
                loading: analyticsAsync.isLoading,
                exporting: _isExporting,
                onSelectSingleDate: _selectSingleDate,
                onSelectDateRange: _selectDateRange,
                onDownload: downloadableAnalytics == null || _isExporting
                    ? null
                    : () => _downloadExcel(
                        effectiveParams,
                        downloadableAnalytics,
                      ),
              ),
              const SizedBox(height: 12),
              _MenuSalesScopeFilter(
                scope: _scope,
                onChanged: (scope) {
                  if (_scope == scope) return;
                  setState(() {
                    _scope = scope;
                    _showAll = false;
                    _selectedMenuKey = null;
                  });
                },
              ),
              const SizedBox(height: 12),
              analyticsAsync.when(
                loading: () => SizedBox(
                  height: 360,
                  child: ToastOperationalLoadingState(
                    label: PosLoadingCopy.loadingReport(context.l10n),
                  ),
                ),
                error: (error, stackTrace) => _MenuSalesErrorState(
                  onRetry: () => ref.invalidate(
                    menuSalesAnalyticsProvider(effectiveParams),
                  ),
                ),
                data: (analytics) {
                  if (analytics.menuRows.isEmpty) {
                    return _MenuSalesEmptyState(
                      summary: analytics.summary,
                      scope: _scope,
                    );
                  }
                  return _buildAnalytics(context, analytics);
                },
              ),
            ],
          );
          return constraints.hasBoundedHeight
              ? SingleChildScrollView(child: content)
              : content;
        },
      ),
    );
  }

  Widget _buildAnalytics(BuildContext context, MenuSalesAnalytics analytics) {
    final topMenu = analytics.topMenu!;
    final topCombo = analytics.topCombo;
    final summary = analytics.summary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 950;
        final phone = constraints.maxWidth < 600;
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final metricColumns = textScale > 1.5
            ? 1
            : phone
            ? 2
            : constraints.maxWidth < 900
            ? 3
            : ((constraints.maxWidth + 8) / 190).floor().clamp(4, 7);
        final metricWidth =
            (constraints.maxWidth - (metricColumns - 1) * 8) / metricColumns;
        final ranking = _MenuSalesRanking(
          analytics: analytics,
          currency: widget.currency,
          sort: _sort,
          showAll: _showAll,
          phone: phone,
          bounded: wide,
          onSortChanged: (sort) => setState(() => _sort = sort),
          onShowAllChanged: () => setState(() => _showAll = !_showAll),
          scope: _scope,
        );
        final hourly = _MenuSalesHourly(
          analytics: analytics,
          currency: widget.currency,
          metric: _metric,
          phone: phone,
          selectedMenuKey: _selectedMenuKey,
          onMetricChanged: (metric) => setState(() => _metric = metric),
          onSelectedMenuChanged: (key) {
            setState(() => _selectedMenuKey = key);
          },
          scope: _scope,
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MenuSalesMetricCard(
                  key: const Key('menu_sales_top_menu'),
                  label: _scope == MenuSalesScope.combo
                      ? context.l10n.menuSalesTopCombo
                      : context.l10n.menuSalesTopMenu,
                  value: topMenu.displayName,
                  detail:
                      '${context.l10n.menuSalesUnits(topMenu.soldQuantity)} · '
                      '${context.l10n.menuSalesOrders(topMenu.orderCount)} · '
                      '${widget.currency.format(topMenu.menuSalesAmount)} VND · '
                      '${context.l10n.menuSalesShare} '
                      '${topMenu.quantityShare.toStringAsFixed(1)}%',
                  tone: PosColors.accent,
                  width: metricWidth,
                ),
                _MenuSalesMetricCard(
                  key: const Key('menu_sales_total_revenue'),
                  label: _scope == MenuSalesScope.combo
                      ? context.l10n.menuSalesComboRevenue
                      : context.l10n.menuSalesTotalRevenue,
                  value:
                      '${widget.currency.format(summary.menuSalesAmount)} VND',
                  detail: context.l10n.menuSalesRevenue,
                  tone: PosColors.success,
                  width: metricWidth,
                ),
                _MenuSalesMetricCard(
                  label: context.l10n.menuSalesTotalQuantity,
                  value: '${summary.soldQuantity}',
                  detail: context.l10n.menuSalesPosOnly,
                  tone: PosColors.info,
                  width: metricWidth,
                ),
                _MenuSalesMetricCard(
                  label: context.l10n.menuSalesSoldMenuCount,
                  value: '${summary.soldMenuCount}',
                  detail: context.l10n.menuSalesPosOnly,
                  tone: PosColors.info,
                  width: metricWidth,
                ),
                if (_scope == MenuSalesScope.all)
                  _MenuSalesMetricCard(
                    key: const Key('menu_sales_combo_revenue'),
                    label: context.l10n.menuSalesComboRevenue,
                    value:
                        '${widget.currency.format(summary.comboMenuSalesAmount)} VND',
                    detail:
                        '${context.l10n.menuSalesUnits(summary.comboSoldQuantity)} · '
                        '${context.l10n.menuSalesComboMenuCount(summary.comboSoldMenuCount)}',
                    tone: PosColors.warning,
                    width: metricWidth,
                  ),
                if (_scope == MenuSalesScope.all)
                  _MenuSalesMetricCard(
                    key: const Key('menu_sales_top_combo'),
                    label: context.l10n.menuSalesTopCombo,
                    value: topCombo?.displayName ?? '—',
                    detail: topCombo == null
                        ? context.l10n.menuSalesNoComboDataTitle
                        : '${context.l10n.menuSalesUnits(topCombo.soldQuantity)} · '
                              '${widget.currency.format(topCombo.menuSalesAmount)} VND',
                    tone: PosColors.warning,
                    width: metricWidth,
                  ),
                _MenuSalesMetricCard(
                  label: context.l10n.menuSalesPosOrders,
                  value: '${summary.orderCount}',
                  detail:
                      '${widget.currency.format(summary.menuSalesAmount)} VND',
                  tone: PosColors.textPrimary,
                  width: metricWidth,
                ),
              ],
            ),
            const SizedBox(height: 10),
            _MenuSalesScopeBanner(summary: summary, currency: widget.currency),
            const SizedBox(height: 12),
            if (wide)
              SizedBox(
                height: 440,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 6, child: ranking),
                    const SizedBox(width: 12),
                    Expanded(flex: 5, child: hourly),
                  ],
                ),
              )
            else ...[
              ranking,
              const SizedBox(height: 12),
              hourly,
            ],
          ],
        );
      },
    );
  }
}

class _MenuSalesPeriodFilter extends StatelessWidget {
  const _MenuSalesPeriodFilter({
    required this.startDate,
    required this.endDate,
    required this.loading,
    required this.exporting,
    required this.onSelectSingleDate,
    required this.onSelectDateRange,
    required this.onDownload,
  });

  final DateTime startDate;
  final DateTime endDate;
  final bool loading;
  final bool exporting;
  final VoidCallback onSelectSingleDate;
  final VoidCallback onSelectDateRange;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final copy = _MenuSalesDateCopy.of(context);
    final formatter = DateFormat('yyyy.MM.dd');
    final start = formatter.format(startDate);
    final end = formatter.format(endDate);
    final period = start == end ? start : '$start – $end';
    final dateDetails = Row(
      children: [
        const Icon(
          Icons.calendar_today_outlined,
          size: 19,
          color: PosColors.textSecondary,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                copy.selectedPeriod,
                style: Theme.of(context).textTheme.labelMedium,
              ),
              Text(
                period,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
      ],
    );
    final actions = Wrap(
      spacing: 4,
      runSpacing: 4,
      alignment: WrapAlignment.end,
      children: [
        TextButton.icon(
          key: const Key('menu_sales_select_single_date'),
          onPressed: loading ? null : onSelectSingleDate,
          icon: const Icon(Icons.event_outlined, size: 18),
          label: Text(copy.singleDate),
        ),
        TextButton.icon(
          key: const Key('menu_sales_select_date_range'),
          onPressed: loading ? null : onSelectDateRange,
          icon: const Icon(Icons.date_range_outlined, size: 18),
          label: Text(copy.dateRange),
        ),
        TextButton.icon(
          key: const Key('menu_sales_excel_download'),
          onPressed: onDownload,
          icon: exporting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download_rounded, size: 18),
          label: Text(context.l10n.reportsDownload),
        ),
      ],
    );

    return Container(
      key: const Key('menu_sales_period_filter'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: PosColors.canvasAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PosColors.border),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked =
              constraints.maxWidth < 330 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.5;
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                dateDetails,
                const SizedBox(height: 4),
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: dateDetails),
              const SizedBox(width: 12),
              actions,
            ],
          );
        },
      ),
    );
  }
}

class _MenuSalesDateCopy {
  const _MenuSalesDateCopy(this.code);

  final String code;

  static _MenuSalesDateCopy of(BuildContext context) =>
      _MenuSalesDateCopy(Localizations.localeOf(context).languageCode);

  String pick(String ko, String vi, String en) => switch (code) {
    'vi' => vi,
    'en' => en,
    _ => ko,
  };

  String get selectedPeriod =>
      pick('선택 기간', 'Khoảng đã chọn', 'Selected period');
  String get singleDate => pick('특정일', 'Một ngày', 'Single date');
  String get dateRange => pick('기간', 'Khoảng ngày', 'Date range');
  String get selectSingleDate =>
      pick('조회할 날짜 선택', 'Chọn ngày cần xem', 'Select date to view');
  String get selectDateRange => pick(
    '조회할 기간 선택',
    'Chọn khoảng ngày cần xem',
    'Select date range to view',
  );
}

class _MenuSalesScopeFilter extends StatelessWidget {
  const _MenuSalesScopeFilter({required this.scope, required this.onChanged});

  final MenuSalesScope scope;
  final ValueChanged<MenuSalesScope> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('menu_sales_scope_filter'),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: PosColors.mutedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PosColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: _MenuSalesScopeFilterButton(
              key: const Key('menu_sales_scope_all'),
              label: context.l10n.menuSalesScopeAll,
              selected: scope == MenuSalesScope.all,
              onPressed: () => onChanged(MenuSalesScope.all),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _MenuSalesScopeFilterButton(
              key: const Key('menu_sales_scope_regular'),
              label: context.l10n.menuSalesScopeRegular,
              selected: scope == MenuSalesScope.regular,
              onPressed: () => onChanged(MenuSalesScope.regular),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _MenuSalesScopeFilterButton(
              key: const Key('menu_sales_scope_combo'),
              label: context.l10n.menuSalesScopeCombo,
              selected: scope == MenuSalesScope.combo,
              onPressed: () => onChanged(MenuSalesScope.combo),
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuSalesScopeFilterButton extends StatelessWidget {
  const _MenuSalesScopeFilterButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? PosColors.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: selected ? PosColors.accent : Colors.transparent,
              ),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: selected ? PosColors.accent : PosColors.textSecondary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuSalesMetricCard extends StatelessWidget {
  const _MenuSalesMetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.detail,
    required this.tone,
    required this.width,
  });

  final String label;
  final String value;
  final String detail;
  final Color tone;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Container(
        constraints: const BoxConstraints(minHeight: 92),
        padding: const EdgeInsets.all(10),
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
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: PosColors.textSecondary),
            ),
            const SizedBox(height: 3),
            Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: tone,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuSalesScopeBanner extends StatelessWidget {
  const _MenuSalesScopeBanner({required this.summary, required this.currency});

  final MenuSalesSummary summary;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    final hasAdjustments = summary.unallocatedAdjustmentCount > 0;
    return Container(
      key: const Key('menu_sales_scope_banner'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: hasAdjustments ? PosColors.warningMuted : PosColors.infoMuted,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasAdjustments ? PosColors.warning : PosColors.info,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            hasAdjustments
                ? Icons.warning_amber_rounded
                : Icons.info_outline_rounded,
            size: 18,
            color: hasAdjustments ? PosColors.warning : PosColors.info,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hasAdjustments
                  ? '${context.l10n.menuSalesUnallocatedAdjustments(summary.unallocatedAdjustmentCount, currency.format(summary.unallocatedAdjustmentAmount))}\n${context.l10n.menuSalesScopeNote}'
                  : context.l10n.menuSalesScopeNote,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PosColors.textPrimary,
                height: 1.4,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuSalesRanking extends StatelessWidget {
  const _MenuSalesRanking({
    required this.analytics,
    required this.currency,
    required this.sort,
    required this.showAll,
    required this.phone,
    required this.bounded,
    required this.onSortChanged,
    required this.onShowAllChanged,
    required this.scope,
  });

  final MenuSalesAnalytics analytics;
  final NumberFormat currency;
  final MenuSalesSort sort;
  final bool showAll;
  final bool phone;
  final bool bounded;
  final ValueChanged<MenuSalesSort> onSortChanged;
  final VoidCallback onShowAllChanged;
  final MenuSalesScope scope;

  @override
  Widget build(BuildContext context) {
    final sorted = analytics.sortedRows(sort);
    final visible = showAll ? sorted : sorted.take(10).toList(growable: false);
    final list = Column(
      children: [
        if (!phone) const _MenuSalesTableHeader(),
        for (var index = 0; index < visible.length; index++)
          Padding(
            padding: EdgeInsets.only(top: index == 0 ? 0 : 6),
            child: phone
                ? _MenuSalesPhoneRow(
                    row: visible[index],
                    displayRank: index + 1,
                    currency: currency,
                  )
                : _MenuSalesTableRow(
                    row: visible[index],
                    displayRank: index + 1,
                    currency: currency,
                  ),
          ),
      ],
    );

    return Container(
      key: const Key('menu_sales_ranking'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PosColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                switch (scope) {
                  MenuSalesScope.all => context.l10n.menuSalesTopMenu,
                  MenuSalesScope.regular =>
                    context.l10n.menuSalesRegularRanking,
                  MenuSalesScope.combo => context.l10n.menuSalesComboRanking,
                },
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              _MenuSalesSortChip(
                label: context.l10n.menuSalesSortQuantity,
                selected: sort == MenuSalesSort.quantity,
                onSelected: () => onSortChanged(MenuSalesSort.quantity),
              ),
              _MenuSalesSortChip(
                label: context.l10n.menuSalesSortRevenue,
                selected: sort == MenuSalesSort.revenue,
                onSelected: () => onSortChanged(MenuSalesSort.revenue),
              ),
              _MenuSalesSortChip(
                label: context.l10n.menuSalesSortOrders,
                selected: sort == MenuSalesSort.orders,
                onSelected: () => onSortChanged(MenuSalesSort.orders),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (bounded)
            Expanded(child: SingleChildScrollView(child: list))
          else
            list,
          if (analytics.menuRows.length > 10) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('menu_sales_show_all'),
              onPressed: onShowAllChanged,
              icon: Icon(
                showAll
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
              ),
              label: Text(
                showAll
                    ? context.l10n.menuSalesShowTop
                    : context.l10n.menuSalesShowAll,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MenuSalesSortChip extends StatelessWidget {
  const _MenuSalesSortChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
      materialTapTargetSize: MaterialTapTargetSize.padded,
      selectedColor: PosColors.accentMuted,
      side: BorderSide(color: selected ? PosColors.accent : PosColors.border),
    );
  }
}

class _MenuSalesTableHeader extends StatelessWidget {
  const _MenuSalesTableHeader();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: PosColors.textSecondary,
      fontWeight: FontWeight.w700,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      child: Row(
        children: [
          SizedBox(width: 38, child: Text('#', style: style)),
          Expanded(flex: 4, child: Text(context.l10n.menu, style: style)),
          Expanded(
            flex: 2,
            child: Text(
              context.l10n.menuSalesQuantity,
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              context.l10n.menuSalesIncludedOrders,
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              context.l10n.menuSalesRevenue,
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              context.l10n.menuSalesPeakHour,
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuSalesTableRow extends StatelessWidget {
  const _MenuSalesTableRow({
    required this.row,
    required this.displayRank,
    required this.currency,
  });

  final MenuSalesRow row;
  final int displayRank;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label:
          '${context.l10n.menuSalesRank(displayRank)}, ${row.displayName}, ${context.l10n.menuSalesUnits(row.soldQuantity)}, ${context.l10n.menuSalesOrders(row.orderCount)}',
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: displayRank == 1 ? PosColors.heroTint : PosColors.mutedSurface,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 38,
              child: Text(
                '$displayRank',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            Expanded(flex: 4, child: _MenuSalesName(row: row)),
            Expanded(
              flex: 2,
              child: Text(
                '${row.soldQuantity}',
                textAlign: TextAlign.right,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text('${row.orderCount}', textAlign: TextAlign.right),
            ),
            Expanded(
              flex: 3,
              child: Text(
                '${currency.format(row.menuSalesAmount)} VND',
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                context.l10n.menuSalesHourLabel(
                  row.peakHour.toString().padLeft(2, '0'),
                ),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuSalesPhoneRow extends StatelessWidget {
  const _MenuSalesPhoneRow({
    required this.row,
    required this.displayRank,
    required this.currency,
  });

  final MenuSalesRow row;
  final int displayRank;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 72),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: displayRank == 1 ? PosColors.heroTint : PosColors.mutedSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                constraints: const BoxConstraints(minWidth: 44, minHeight: 32),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: PosColors.surface,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  context.l10n.menuSalesRank(displayRank),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: _MenuSalesName(row: row)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 5,
            children: [
              Text(
                context.l10n.menuSalesUnits(row.soldQuantity),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              Text(context.l10n.menuSalesOrders(row.orderCount)),
              Text('${row.quantityShare.toStringAsFixed(1)}%'),
              Text(
                context.l10n.menuSalesHourLabel(
                  row.peakHour.toString().padLeft(2, '0'),
                ),
              ),
              Text(
                '${currency.format(row.menuSalesAmount)} VND',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${context.l10n.dineIn} ${row.dineInQuantity} · ${context.l10n.takeout} ${row.takeawayQuantity} · ${context.l10n.delivery} ${row.deliveryQuantity}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _MenuSalesName extends StatelessWidget {
  const _MenuSalesName({required this.row});

  final MenuSalesRow row;

  @override
  Widget build(BuildContext context) {
    final warnings = <String>[
      if (row.usesNameFallback) context.l10n.menuSalesIdentityFallback,
      if (row.nameChangedInPeriod) context.l10n.menuSalesNameChanged,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          row.displayName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        if (row.isCombo)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Container(
              key: Key('menu_sales_combo_badge_${row.menuKey}'),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: PosColors.warningMuted,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: PosColors.warning),
              ),
              child: Text(
                context.l10n.menuSalesComboBadge,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: PosColors.warning,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        if (warnings.isNotEmpty)
          Tooltip(
            message: warnings.join('\n'),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 13,
                  color: PosColors.warning,
                ),
                const SizedBox(width: 3),
                Flexible(
                  child: Text(
                    warnings.first,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: PosColors.warning),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _MenuSalesHourly extends StatelessWidget {
  const _MenuSalesHourly({
    required this.analytics,
    required this.currency,
    required this.metric,
    required this.phone,
    required this.selectedMenuKey,
    required this.onMetricChanged,
    required this.onSelectedMenuChanged,
    required this.scope,
  });

  final MenuSalesAnalytics analytics;
  final NumberFormat currency;
  final _MenuSalesMetric metric;
  final bool phone;
  final String? selectedMenuKey;
  final ValueChanged<_MenuSalesMetric> onMetricChanged;
  final ValueChanged<String?> onSelectedMenuChanged;
  final MenuSalesScope scope;

  @override
  Widget build(BuildContext context) {
    final topMenus = <String, String>{};
    for (final row in analytics.topMenuHourRows) {
      topMenus[row.menuKey] = row.displayName;
    }
    final selectedKey = topMenus.containsKey(selectedMenuKey)
        ? selectedMenuKey
        : (topMenus.isEmpty ? null : topMenus.keys.first);

    return Container(
      key: const Key('menu_sales_hourly'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PosColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                switch (scope) {
                  MenuSalesScope.all => context.l10n.menuSalesHourlyTitle,
                  MenuSalesScope.regular =>
                    context.l10n.menuSalesRegularHourlyTitle,
                  MenuSalesScope.combo =>
                    context.l10n.menuSalesComboHourlyTitle,
                },
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              _MenuSalesSortChip(
                label: context.l10n.menuSalesByQuantity,
                selected: metric == _MenuSalesMetric.quantity,
                onSelected: () => onMetricChanged(_MenuSalesMetric.quantity),
              ),
              _MenuSalesSortChip(
                label: context.l10n.menuSalesByRevenue,
                selected: metric == _MenuSalesMetric.revenue,
                onSelected: () => onMetricChanged(_MenuSalesMetric.revenue),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _MenuSalesHourChart(
            hours: analytics.hourRows,
            metric: metric,
            currency: currency,
          ),
          const SizedBox(height: 12),
          Text(
            context.l10n.menuSalesHeatmapTitle,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          if (phone) ...[
            DropdownButtonFormField<String>(
              initialValue: selectedKey,
              isExpanded: true,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: scope == MenuSalesScope.combo
                    ? context.l10n.menuSalesTopCombo
                    : context.l10n.menuSalesTopMenu,
              ),
              items: [
                for (final entry in topMenus.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text(
                      entry.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: onSelectedMenuChanged,
            ),
            const SizedBox(height: 8),
            _SelectedMenuHourChart(
              rows: analytics.topMenuHourRows
                  .where((row) => row.menuKey == selectedKey)
                  .toList(growable: false),
              metric: metric,
              currency: currency,
            ),
          ] else
            SizedBox(
              height: 130,
              child: _MenuSalesHeatmap(
                rows: analytics.topMenuHourRows,
                currency: currency,
              ),
            ),
        ],
      ),
    );
  }
}

class _MenuSalesHourChart extends StatelessWidget {
  const _MenuSalesHourChart({
    required this.hours,
    required this.metric,
    required this.currency,
  });

  final List<MenuSalesHour> hours;
  final _MenuSalesMetric metric;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    final values = hours
        .map(
          (hour) => metric == _MenuSalesMetric.quantity
              ? hour.soldQuantity.toDouble()
              : hour.menuSalesAmount,
        )
        .toList(growable: false);
    final maxValue = values.fold<double>(0, math.max);
    return SizedBox(
      height: 130,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var index = 0; index < hours.length; index++)
            Expanded(
              child: Tooltip(
                message:
                    '${hours[index].hour.toString().padLeft(2, '0')}:00 · ${metric == _MenuSalesMetric.quantity ? '${hours[index].soldQuantity}' : '${currency.format(hours[index].menuSalesAmount)} VND'}',
                child: Semantics(
                  label:
                      '${hours[index].hour}:00, ${values[index].toStringAsFixed(0)}',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              heightFactor: maxValue <= 0
                                  ? 0
                                  : (values[index] / maxValue).clamp(0.03, 1),
                              widthFactor: 0.72,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: metric == _MenuSalesMetric.quantity
                                      ? PosColors.accent
                                      : PosColors.success,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(4),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          index % 3 == 0
                              ? hours[index].hour.toString().padLeft(2, '0')
                              : '',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: PosColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MenuSalesHeatmap extends StatelessWidget {
  const _MenuSalesHeatmap({required this.rows, required this.currency});

  final List<TopMenuSalesHour> rows;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<TopMenuSalesHour>>{};
    for (final row in rows) {
      grouped.putIfAbsent(row.menuKey, () => []).add(row);
    }
    final maxValue = rows.fold<int>(
      0,
      (current, row) => math.max(current, row.soldQuantity),
    );
    return SingleChildScrollView(
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 100),
              for (var hour = 0; hour < 24; hour++)
                Expanded(
                  child: Text(
                    hour % 3 == 0 ? '$hour' : '',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: PosColors.textSecondary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          for (final entry in grouped.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                children: [
                  SizedBox(
                    width: 100,
                    child: Text(
                      entry.value.first.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  for (final row in entry.value)
                    Expanded(
                      child: Tooltip(
                        message:
                            '${row.displayName} · ${row.hour.toString().padLeft(2, '0')}:00 · '
                            '${context.l10n.menuSalesUnits(row.soldQuantity)} · '
                            '${currency.format(row.menuSalesAmount)} VND',
                        child: Semantics(
                          label:
                              '${row.displayName}, ${row.hour}:00, '
                              '${context.l10n.menuSalesUnits(row.soldQuantity)}, '
                              '${currency.format(row.menuSalesAmount)} VND',
                          child: Container(
                            height: 28,
                            margin: const EdgeInsets.symmetric(horizontal: 1),
                            decoration: BoxDecoration(
                              color: maxValue == 0
                                  ? PosColors.mutedSurface
                                  : PosColors.accent.withValues(
                                      alpha:
                                          0.08 +
                                          (row.soldQuantity / maxValue) * 0.82,
                                    ),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SelectedMenuHourChart extends StatelessWidget {
  const _SelectedMenuHourChart({
    required this.rows,
    required this.metric,
    required this.currency,
  });

  final List<TopMenuSalesHour> rows;
  final _MenuSalesMetric metric;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    final indexed = {for (final row in rows) row.hour: row};
    return _MenuSalesHourChart(
      hours: List<MenuSalesHour>.generate(24, (hour) {
        final row = indexed[hour];
        return MenuSalesHour(
          hour: hour,
          soldQuantity: row?.soldQuantity ?? 0,
          menuSalesAmount: row?.menuSalesAmount ?? 0,
          orderCount: 0,
        );
      }),
      metric: metric,
      currency: currency,
    );
  }
}

class _MenuSalesErrorState extends StatelessWidget {
  const _MenuSalesErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PosEmptyState(
              title: context.l10n.menuSalesLoadError,
              subtitle: context.l10n.menuSalesScopeNote,
              icon: Icons.bar_chart_rounded,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(context.l10n.retry),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuSalesEmptyState extends StatelessWidget {
  const _MenuSalesEmptyState({required this.summary, required this.scope});

  final MenuSalesSummary summary;
  final MenuSalesScope scope;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('menu_sales_empty'),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: PosEmptyState(
              title: scope == MenuSalesScope.combo
                  ? context.l10n.menuSalesNoComboDataTitle
                  : context.l10n.menuSalesNoDataTitle,
              subtitle: scope == MenuSalesScope.combo
                  ? context.l10n.menuSalesNoComboDataSubtitle
                  : context.l10n.menuSalesNoDataSubtitle,
              icon: scope == MenuSalesScope.combo
                  ? Icons.fastfood_rounded
                  : Icons.restaurant_menu_rounded,
            ),
          ),
          if (summary.unallocatedAdjustmentCount > 0)
            _MenuSalesScopeBanner(
              summary: summary,
              currency: NumberFormat('#,###', 'vi_VN'),
            ),
        ],
      ),
    );
  }
}
