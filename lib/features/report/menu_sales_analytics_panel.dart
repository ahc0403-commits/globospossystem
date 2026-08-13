import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import 'menu_sales_analytics.dart';

enum _MenuSalesMetric { quantity, revenue }

class MenuSalesAnalyticsPanel extends ConsumerStatefulWidget {
  const MenuSalesAnalyticsPanel({
    super.key,
    required this.params,
    required this.currency,
  });

  final MenuSalesAnalyticsParams params;
  final NumberFormat currency;

  @override
  ConsumerState<MenuSalesAnalyticsPanel> createState() =>
      _MenuSalesAnalyticsPanelState();
}

class _MenuSalesAnalyticsPanelState
    extends ConsumerState<MenuSalesAnalyticsPanel> {
  MenuSalesSort _sort = MenuSalesSort.quantity;
  _MenuSalesMetric _metric = _MenuSalesMetric.quantity;
  bool _showAll = false;
  bool _includeCombos = true;
  String? _selectedMenuKey;

  @override
  void initState() {
    super.initState();
    _includeCombos = widget.params.includeCombos;
  }

  @override
  Widget build(BuildContext context) {
    final effectiveParams = widget.params.copyWith(
      includeCombos: _includeCombos,
    );
    final analyticsAsync = ref.watch(
      menuSalesAnalyticsProvider(effectiveParams),
    );

    return PosDataPanel(
      title: context.l10n.menuSalesAnalyticsTitle,
      subtitle: context.l10n.menuSalesAnalyticsSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MenuSalesComboFilter(
            includeCombos: _includeCombos,
            onChanged: (includeCombos) {
              if (_includeCombos == includeCombos) return;
              setState(() {
                _includeCombos = includeCombos;
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
              onRetry: () =>
                  ref.invalidate(menuSalesAnalyticsProvider(effectiveParams)),
            ),
            data: (analytics) {
              if (analytics.menuRows.isEmpty) {
                return _MenuSalesEmptyState(summary: analytics.summary);
              }
              return _buildAnalytics(context, analytics);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAnalytics(BuildContext context, MenuSalesAnalytics analytics) {
    final topMenu = analytics.topMenu!;
    final summary = analytics.summary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 950;
        final phone = constraints.maxWidth < 600;
        final ranking = _MenuSalesRanking(
          analytics: analytics,
          currency: widget.currency,
          sort: _sort,
          showAll: _showAll,
          phone: phone,
          bounded: wide,
          onSortChanged: (sort) => setState(() => _sort = sort),
          onShowAllChanged: () => setState(() => _showAll = !_showAll),
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
                  label: context.l10n.menuSalesTopMenu,
                  value: topMenu.displayName,
                  detail:
                      '${context.l10n.menuSalesUnits(topMenu.soldQuantity)} · '
                      '${context.l10n.menuSalesOrders(topMenu.orderCount)} · '
                      '${widget.currency.format(topMenu.menuSalesAmount)} VND · '
                      '${context.l10n.menuSalesShare} '
                      '${topMenu.quantityShare.toStringAsFixed(1)}%',
                  tone: PosColors.accent,
                  minWidth: phone ? constraints.maxWidth : 250,
                ),
                _MenuSalesMetricCard(
                  label: context.l10n.menuSalesTotalQuantity,
                  value: '${summary.soldQuantity}',
                  detail: context.l10n.menuSalesRevenue,
                  tone: PosColors.success,
                  minWidth: phone
                      ? math.max(150, (constraints.maxWidth - 8) / 2)
                      : 180,
                ),
                _MenuSalesMetricCard(
                  label: context.l10n.menuSalesSoldMenuCount,
                  value: '${summary.soldMenuCount}',
                  detail: context.l10n.menuSalesPosOnly,
                  tone: PosColors.info,
                  minWidth: phone
                      ? math.max(150, (constraints.maxWidth - 8) / 2)
                      : 180,
                ),
                if (_includeCombos)
                  _MenuSalesMetricCard(
                    key: const Key('menu_sales_combo_summary'),
                    label: context.l10n.menuSalesComboSummary,
                    value: '${summary.comboSoldQuantity}',
                    detail: context.l10n.menuSalesComboMenuCount(
                      summary.comboSoldMenuCount,
                    ),
                    tone: PosColors.warning,
                    minWidth: phone
                        ? math.max(150, (constraints.maxWidth - 8) / 2)
                        : 180,
                  ),
                _MenuSalesMetricCard(
                  label: context.l10n.menuSalesPosOrders,
                  value: '${summary.orderCount}',
                  detail:
                      '${widget.currency.format(summary.menuSalesAmount)} VND',
                  tone: PosColors.textPrimary,
                  minWidth: phone
                      ? math.max(150, (constraints.maxWidth - 8) / 2)
                      : 210,
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

class _MenuSalesComboFilter extends StatelessWidget {
  const _MenuSalesComboFilter({
    required this.includeCombos,
    required this.onChanged,
  });

  final bool includeCombos;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('menu_sales_combo_filter'),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: PosColors.mutedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PosColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: _MenuSalesComboFilterButton(
              key: const Key('menu_sales_include_combos'),
              label: context.l10n.menuSalesIncludeCombos,
              selected: includeCombos,
              onPressed: () => onChanged(true),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _MenuSalesComboFilterButton(
              key: const Key('menu_sales_exclude_combos'),
              label: context.l10n.menuSalesExcludeCombos,
              selected: !includeCombos,
              onPressed: () => onChanged(false),
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuSalesComboFilterButton extends StatelessWidget {
  const _MenuSalesComboFilterButton({
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
    required this.minWidth,
  });

  final String label;
  final String value;
  final String detail;
  final Color tone;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: minWidth,
        maxWidth: math.max(330, minWidth),
      ),
      child: Container(
        padding: const EdgeInsets.all(12),
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
            const SizedBox(height: 6),
            Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: tone,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              detail,
              maxLines: 2,
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
  });

  final MenuSalesAnalytics analytics;
  final NumberFormat currency;
  final MenuSalesSort sort;
  final bool showAll;
  final bool phone;
  final bool bounded;
  final ValueChanged<MenuSalesSort> onSortChanged;
  final VoidCallback onShowAllChanged;

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
                context.l10n.menuSalesTopMenu,
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
  });

  final MenuSalesAnalytics analytics;
  final NumberFormat currency;
  final _MenuSalesMetric metric;
  final bool phone;
  final String? selectedMenuKey;
  final ValueChanged<_MenuSalesMetric> onMetricChanged;
  final ValueChanged<String?> onSelectedMenuChanged;

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
                context.l10n.menuSalesHourlyTitle,
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
                labelText: context.l10n.menuSalesTopMenu,
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
  const _MenuSalesEmptyState({required this.summary});

  final MenuSalesSummary summary;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('menu_sales_empty'),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: PosEmptyState(
              title: context.l10n.menuSalesNoDataTitle,
              subtitle: context.l10n.menuSalesNoDataSubtitle,
              icon: Icons.restaurant_menu_rounded,
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
