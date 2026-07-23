// Toast operational UX primitives (Phase 1).
//
// These are added ALONGSIDE the existing `App*` primitives in
// `app_primitives.dart`. No `App*` primitive is replaced or deleted.
// Screens are not migrated in this phase.
//
// Direction (per handoff): workflow-first, queue-first, urgency-first,
// active context persistence, action rail consistency, operational
// signal visibility. Dense but calm. Stronger selected state than
// non-selected.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';

import '../../i18n/locale_extensions.dart';
import '../app_theme.dart';
import '../pos_design_tokens.dart';
import 'toast_vocabulary.dart';

// =============================================================================
// ToastSplitPane — queue (left) stays visible while detail/action (right)
// stays active. Persistent selected context is the caller's responsibility.
// =============================================================================
class ToastSplitPane extends StatelessWidget {
  const ToastSplitPane({
    super.key,
    required this.queue,
    required this.detail,
    this.queueWidth = 420,
    this.divider = true,
  });

  final Widget queue;
  final Widget detail;
  final double queueWidth;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: queueWidth, child: queue),
        if (divider) Container(width: 1, color: AppColors.surface3),
        Expanded(child: detail),
      ],
    );
  }
}

// =============================================================================
// ToastQueueTable — primary-only scanning, dense rows, strong selected state.
// =============================================================================
class ToastQueueColumn {
  const ToastQueueColumn({
    required this.label,
    this.flex = 1,
    this.align = TextAlign.left,
  });
  final String label;
  final int flex;
  final TextAlign align;
}

class ToastQueueRow {
  const ToastQueueRow({
    required this.id,
    required this.cells,
    this.urgent = false,
    this.muted = false,
  });
  final String id;
  final List<Widget> cells;
  final bool urgent;
  final bool muted;
}

class ToastQueueTable extends StatelessWidget {
  const ToastQueueTable({
    super.key,
    required this.columns,
    required this.rows,
    this.selectedId,
    this.onSelect,
  });

  final List<ToastQueueColumn> columns;
  final List<ToastQueueRow> rows;
  final String? selectedId;
  final ValueChanged<String>? onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        Expanded(
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, i) => _row(rows[i]),
          ),
        ),
      ],
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadius.md,
      ),
      child: Row(
        children: columns
            .map(
              (c) => Expanded(
                flex: c.flex,
                child: Text(
                  c.label.toUpperCase(),
                  textAlign: c.align,
                  style: AppFonts.system(
                    color: AppColors.textSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _row(ToastQueueRow r) {
    final selected = r.id == selectedId;
    return InkWell(
      onTap: onSelect == null ? null : () => onSelect!(r.id),
      hoverColor: PosColors.selectedRow.withValues(alpha: 0.72),
      child: Container(
        decoration: BoxDecoration(
          color: selected ? PosColors.selectedRow : Colors.transparent,
          borderRadius: AppRadius.md,
          border: Border(
            left: BorderSide(
              color: selected ? AppColors.amber500 : Colors.transparent,
              width: 4,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Opacity(
          opacity: r.muted ? 0.55 : 1.0,
          child: Row(
            children: [
              for (var i = 0; i < r.cells.length; i++)
                Expanded(flex: columns[i].flex, child: r.cells[i]),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// ToastDenseList — light-weight dense list (when full table is overkill).
// =============================================================================
class ToastDenseList extends StatelessWidget {
  const ToastDenseList({
    super.key,
    required this.children,
    this.padding = EdgeInsets.zero,
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: padding,
      itemCount: children.length,
      separatorBuilder: (_, __) =>
          const Divider(height: 1, color: AppColors.surface3),
      itemBuilder: (_, i) => children[i],
    );
  }
}

// =============================================================================
// ToastMetricStrip — compact, supporting-only weight, calm.
// =============================================================================
class ToastMetric {
  const ToastMetric({required this.label, required this.value, this.tone});
  final String label;
  final String value;
  final Color? tone;
}

class ToastMetricStrip extends StatelessWidget {
  const ToastMetricStrip({
    super.key,
    required this.metrics,
    this.maxColumns = 4,
    this.dense = true,
  });
  final List<ToastMetric> metrics;
  final int maxColumns;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.maxWidth.isFinite) {
          final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.5;
          final tileWidth = largeText ? 220.0 : 160.0;
          return Container(
            decoration: BoxDecoration(
              color: AppColors.surface0,
              borderRadius: AppRadius.lg,
              border: Border.all(color: AppColors.surface3),
            ),
            padding: const EdgeInsets.all(6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var index = 0; index < metrics.length; index++) ...[
                  SizedBox(
                    width: tileWidth,
                    child: _tile(metrics[index], compactPhone: false),
                  ),
                  if (index != metrics.length - 1) const SizedBox(width: 8),
                ],
              ],
            ),
          );
        }

        final compactPhone = constraints.maxWidth < 420;
        final columns = compactPhone
            ? 1
            : _metricColumnsForWidth(
                constraints.maxWidth,
                metrics.length,
                maxColumns,
              );
        final gap = compactPhone ? 6.0 : 8.0;
        final rows = <List<ToastMetric>>[];
        for (var index = 0; index < metrics.length; index += columns) {
          rows.add(
            metrics.sublist(index, math.min(index + columns, metrics.length)),
          );
        }

        return Container(
          decoration: BoxDecoration(
            color: AppColors.surface0,
            borderRadius: AppRadius.lg,
            border: Border.all(color: AppColors.surface3),
          ),
          padding: dense
              ? const EdgeInsets.all(2)
              : EdgeInsets.symmetric(
                  horizontal: compactPhone ? 5 : 6,
                  vertical: compactPhone ? 5 : 6,
                ),
          child: Column(
            children: [
              for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) ...[
                Row(
                  children: [
                    for (
                      var columnIndex = 0;
                      columnIndex < columns;
                      columnIndex++
                    ) ...[
                      Expanded(
                        child: columnIndex < rows[rowIndex].length
                            ? _tile(
                                rows[rowIndex][columnIndex],
                                compactPhone: compactPhone,
                              )
                            : const SizedBox.shrink(),
                      ),
                      if (columnIndex != columns - 1) SizedBox(width: gap),
                    ],
                  ],
                ),
                if (rowIndex != rows.length - 1) SizedBox(height: gap),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _tile(ToastMetric m, {required bool compactPhone}) {
    final tone = m.tone;
    if (dense) {
      return Container(
        constraints: const BoxConstraints(minHeight: 26),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.surface1,
          borderRadius: AppRadius.md,
          border: Border.all(color: AppColors.surface3),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                m.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.system(
                  color: AppColors.textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              m.value,
              maxLines: 1,
              style: AppFonts.system(
                color: tone ?? AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: AppRadius.md,
        border: Border.all(color: AppColors.surface3),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compactPhone ? 9 : 10,
          vertical: compactPhone ? 8 : 10,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              m.label.toUpperCase(),
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: compactPhone ? 9.5 : 10,
                fontWeight: FontWeight.w800,
                letterSpacing: compactPhone ? 0.25 : 0.55,
              ),
            ),
            SizedBox(height: compactPhone ? 6 : 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  m.value,
                  maxLines: 1,
                  style: AppFonts.system(
                    color: tone ?? AppColors.textPrimary,
                    fontSize: compactPhone ? 20 : 22,
                    fontWeight: FontWeight.w800,
                    height: 1.05,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// ToastSelectedContextHeader — what is selected, why it matters now.
// =============================================================================
class ToastSelectedContextHeader extends StatelessWidget {
  const ToastSelectedContextHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.urgentReason,
    this.noteColor = PosColors.info,
    this.noteBackgroundColor = PosColors.infoMuted,
    this.noteIcon = Icons.info_outline_rounded,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final String? urgentReason;
  final Color noteColor;
  final Color noteBackgroundColor;
  final IconData noteIcon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: PosSurfaceTints.tone(AppColors.amber500, alpha: 0.05),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
        border: Border(
          bottom: BorderSide(color: AppColors.surface3.withValues(alpha: 0.9)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: AppColors.amber500,
              borderRadius: AppRadius.pill,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppFonts.system(
                    color: AppColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    subtitle!,
                    style: AppFonts.system(
                      color: AppColors.textSecondary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w400,
                      height: 1.35,
                    ),
                  ),
                ],
                if (urgentReason != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: noteBackgroundColor,
                      borderRadius: AppRadius.pill,
                      border: Border.all(
                        color: noteColor.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(noteIcon, size: 13, color: noteColor),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            urgentReason!,
                            style: AppFonts.system(
                              color: noteColor,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            Flexible(
              child: Align(alignment: Alignment.topRight, child: trailing!),
            ),
          ],
        ],
      ),
    );
  }
}

int _metricColumnsForWidth(double width, int itemCount, int maxColumns) {
  if (itemCount <= 1) {
    return 1;
  }
  if (width < 420) {
    return 1;
  }
  if (width < 760) {
    return math.min(2, itemCount);
  }
  if (width < 1080) {
    return math.min(3, itemCount);
  }
  return math.min(maxColumns, itemCount);
}

// =============================================================================
// ToastIssueActionSection — first detail block: issue + recovery action.
// =============================================================================
class ToastIssueActionSection extends StatelessWidget {
  const ToastIssueActionSection({
    super.key,
    required this.issue,
    this.detail,
    this.action,
  });

  final String issue;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: PosColors.infoMuted,
        border: Border.all(color: PosColors.info.withValues(alpha: 0.18)),
        borderRadius: AppRadius.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            issue,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (detail != null) ...[
            const SizedBox(height: 4),
            Text(
              detail!,
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    );
  }
}

// =============================================================================
// PosActionButton — normalized verb / tone / icon / disabled language.
// =============================================================================
class PosActionButton extends StatelessWidget {
  const PosActionButton({
    super.key,
    required this.label,
    required this.tone,
    this.icon,
    this.onPressed,
    this.disabledReason,
    this.loading = false,
    this.loadingLabel,
    this.compact = false,
  });

  final String label;
  final PosActionTone tone;
  final IconData? icon;
  final VoidCallback? onPressed;
  final PosActionDisabledReason? disabledReason;

  /// When true, shows an inline spinner in the icon slot and disables the
  /// button. Layout does not jump: the spinner reuses the icon slot's
  /// width/height. If [icon] was null, a slot is reserved so the button
  /// width does not change between idle and loading.
  final bool loading;

  /// Optional label to render while [loading] is true. Falls back to
  /// [label] so the button does not change width unexpectedly.
  final String? loadingLabel;

  /// Compact density for inline action rows (e.g. card footers). Reduces
  /// vertical padding (10 → 6) and horizontal padding (14 → 10), and
  /// shrinks the typographic weight one notch. Icon and spinner alignment
  /// are preserved. Default callers see no change.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null || loading;
    final bg = toneBackground(tone);
    final fg = toneForeground(tone);
    final tooltip = disabled && !loading && disabledReason != null
        ? PosDisabledCopy.forReason(context.l10n, disabledReason!)
        : null;

    final showIconSlot = icon != null || loading;
    final iconSize = compact ? 14.0 : 16.0;
    final iconSlot = loading
        ? SizedBox(
            width: iconSize,
            height: iconSize,
            child: CircularProgressIndicator(
              strokeWidth: compact ? 1.5 : 2,
              color: fg,
            ),
          )
        : (icon != null ? Icon(icon, size: iconSize, color: fg) : null);

    final child = LayoutBuilder(
      builder: (context, constraints) {
        final labelText = loading ? (loadingLabel ?? label) : label;
        final gapWidth = showIconSlot ? (compact ? 6.0 : 8.0) : 0.0;
        final leadingWidth = showIconSlot ? iconSize + gapWidth : 0.0;
        final boundedLabel =
            constraints.hasBoundedWidth && constraints.maxWidth.isFinite;
        final labelMaxWidth = boundedLabel
            ? math.max(0.0, constraints.maxWidth - leadingWidth)
            : double.infinity;
        final labelWidget = Text(
          labelText,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: AppFonts.system(
            color: fg,
            fontSize: compact ? 12 : 13,
            fontWeight: compact ? FontWeight.w700 : FontWeight.w800,
          ),
        );

        return Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showIconSlot) ...[
                SizedBox(
                  width: iconSize,
                  height: iconSize,
                  child: Center(child: iconSlot),
                ),
                SizedBox(width: gapWidth),
              ],
              boundedLabel
                  ? ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: labelMaxWidth),
                      child: labelWidget,
                    )
                  : labelWidget,
            ],
          ),
        );
      },
    );

    final childBackground = tone == PosActionTone.secondary
        ? AppColors.surface2
        : bg;
    final childBorder = tone == PosActionTone.secondary
        ? AppColors.surface3
        : bg.withValues(alpha: 0.92);

    final btn = Opacity(
      opacity: disabled ? 0.5 : 1.0,
      child: InkWell(
        onTap: disabled ? null : onPressed,
        borderRadius: AppRadius.lg,
        child: Container(
          constraints: BoxConstraints(
            minHeight: compact
                ? PosMetrics.buttonCompactHeight
                : PosMetrics.buttonHeight,
          ),
          padding: compact
              ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
              : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: childBackground,
            borderRadius: AppRadius.lg,
            border: Border.all(color: childBorder),
            boxShadow: !disabled && tone == PosActionTone.primary
                ? PosShadows.low
                : ToastElevationTokens.none,
          ),
          child: child,
        ),
      ),
    );

    return tooltip == null ? btn : Tooltip(message: tooltip, child: btn);
  }
}

// =============================================================================
// ToastActionRail — consistent right-edge action stack.
// =============================================================================
class ToastActionRail extends StatelessWidget {
  const ToastActionRail({
    super.key,
    required this.actions,
    this.padding = const EdgeInsets.all(12),
  });

  final List<Widget> actions;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: PosSurfaceTints.tone(AppColors.surface2, alpha: 0.4),
        border: const Border(top: BorderSide(color: AppColors.surface3)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.end,
        children: actions,
      ),
    );
  }
}

// =============================================================================
// ToastStatusChip — shared status pill for operational state.
// Phase 3 extraction: was previously duplicated as `_OrderItemStatusChip`,
// `_StatusChip` (kitchen), and `_OrderStatusBadge` (cashier). Caller
// supplies the resolved color + label so domain meaning stays explicit.
// =============================================================================
class ToastStatusChip extends StatelessWidget {
  const ToastStatusChip({
    super.key,
    required this.label,
    required this.color,
    this.solid = false,
  });

  final String label;
  final Color color;

  /// When true, renders solid filled (used by kitchen item rows).
  /// When false, renders translucent fill + outline (used by order/cashier).
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final fg = solid
        ? (color.computeLuminance() > 0.5
              ? AppColors.surface0
              : AppColors.textPrimary)
        : color;
    final bg = solid ? color : color.withValues(alpha: 0.15);
    final border = solid ? color : color.withValues(alpha: 0.7);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Text(
        label.toUpperCase(),
        style: AppFonts.system(
          color: fg,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

// =============================================================================
// ToastOperationalEmptyState — operational disclosure (not decorative).
// =============================================================================
class ToastOperationalEmptyState extends StatelessWidget {
  const ToastOperationalEmptyState({
    super.key,
    required this.headline,
    this.helper,
    this.icon = Icons.check_circle_outline,
  });

  final String headline;
  final String? helper;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight.isFinite
            ? constraints.maxHeight < 120
            : false;
        final content = Padding(
          padding: EdgeInsets.all(compact ? 8 : 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: compact ? 22 : 28, color: AppColors.textMuted),
              SizedBox(height: compact ? 8 : 12),
              Text(
                headline,
                textAlign: TextAlign.center,
                maxLines: compact ? 2 : null,
                overflow: compact ? TextOverflow.ellipsis : null,
                style: AppFonts.system(
                  color: AppColors.textPrimary,
                  fontSize: compact ? 14 : 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (helper != null) ...[
                SizedBox(height: compact ? 4 : 6),
                Text(
                  helper!,
                  textAlign: TextAlign.center,
                  maxLines: compact ? 2 : null,
                  overflow: compact ? TextOverflow.ellipsis : null,
                  style: AppFonts.system(
                    color: AppColors.textSecondary,
                    fontSize: compact ? 12 : 13,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        );

        if (!constraints.maxHeight.isFinite) {
          return Center(child: content);
        }

        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: content),
          ),
        );
      },
    );
  }
}

// =============================================================================
// ToastFilterChip — operational filter chip with amber-fill selected state.
// Canonical look matches `delivery_settlement_tab.dart`'s `_filterChip` and
// `qc_tab.dart`'s `_followupFilterChip`: amber fill on selected, surface1
// outlined on unselected, optional `(count)` badge appended to the label.
// =============================================================================
class ToastFilterChip extends StatelessWidget {
  const ToastFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  /// Optional count badge. When provided, renders as `label (count)`.
  final int? count;

  @override
  Widget build(BuildContext context) {
    final display = count != null ? '$label ($count)' : label;
    return Semantics(
      button: true,
      enabled: true,
      selected: selected,
      label: display,
      child: InkWell(
        onTap: onSelected,
        borderRadius: ToastRadiusTokens.pill,
        child: Container(
          constraints: const BoxConstraints(
            minHeight: PosDensity.touchTargetMin,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? PosColors.accent : PosColors.surface,
            borderRadius: ToastRadiusTokens.pill,
            border: Border.all(
              color: selected ? PosColors.accent : PosColors.border,
            ),
          ),
          child: Text(
            display,
            style: AppFonts.system(
              color: selected ? Colors.white : PosColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// ToastDenseDataTable — compact operational table.
// Matches `_DailyTable` / daily-closing history table density: surface1
// container with 16px radius, header row with bottom border, alternating
// surface1/surface0 row bg, optional totals/footer row with top border.
// Caller supplies columns + rows; primitive does not own state, sorting,
// or pagination.
// =============================================================================
class ToastDenseColumn {
  const ToastDenseColumn({required this.label, this.flex = 1});
  final String label;
  final int flex;
}

class ToastDenseRow {
  const ToastDenseRow({required this.cells, this.bold = false});
  final List<String> cells;

  /// When true, renders cell text in bold (used for totals row).
  final bool bold;
}

class ToastDenseDataTable extends StatelessWidget {
  const ToastDenseDataTable({
    super.key,
    required this.columns,
    required this.rows,
    this.totalsRow,
  }) : compact = false;

  /// Compact variant — fontSize 11, header padding 12/10, row padding 12/8.
  /// Used by deep history / admin tables that need to surface more rows
  /// without scrolling. Same striping and totals semantics as default.
  const ToastDenseDataTable.compact({
    super.key,
    required this.columns,
    required this.rows,
    this.totalsRow,
  }) : compact = true;

  final List<ToastDenseColumn> columns;
  final List<ToastDenseRow> rows;

  /// Optional totals/footer row rendered with top border and bold cells.
  final ToastDenseRow? totalsRow;

  final bool compact;

  double get _fontSize => compact ? 11 : 12;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(compact ? 12 : 16),
      ),
      child: Column(
        children: [
          _header(),
          ...rows.asMap().entries.map((entry) {
            final i = entry.key;
            final row = entry.value;
            final bg = i.isEven ? AppColors.surface1 : AppColors.surface0;
            return _row(row, bg);
          }),
          if (totalsRow != null) _footer(totalsRow!),
        ],
      ),
    );
  }

  Widget _header() {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 12,
        vertical: compact ? 10 : 12,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.surface2)),
      ),
      child: Row(
        children: [
          for (final c in columns)
            Expanded(
              flex: c.flex,
              child: Text(
                c.label,
                style: AppFonts.system(
                  color: AppColors.textPrimary,
                  fontSize: _fontSize,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(ToastDenseRow row, Color bg) {
    return Container(
      color: bg,
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: compact ? 8 : 10),
      child: Row(
        children: [
          for (var i = 0; i < row.cells.length; i++)
            Expanded(
              flex: i < columns.length ? columns[i].flex : 1,
              child: Text(
                row.cells[i],
                style: AppFonts.system(
                  color: AppColors.textPrimary,
                  fontSize: _fontSize,
                  fontWeight: row.bold ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _footer(ToastDenseRow row) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 12,
        vertical: compact ? 10 : 12,
      ),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.surface2)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < row.cells.length; i++)
            Expanded(
              flex: i < columns.length ? columns[i].flex : 1,
              child: Text(
                row.cells[i],
                style: AppFonts.system(
                  color: AppColors.textPrimary,
                  fontSize: _fontSize,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// ToastConfirmDialog — Cancel + primary/destructive confirm wrapper around
// `showDialog`. Uses `PosActionButton` so the loading-confirm state shares
// the same visual language as the rest of the action rail.
// =============================================================================
class ToastConfirmDialog {
  ToastConfirmDialog._();

  /// Shows a confirmation dialog and resolves to `true` if confirmed,
  /// `false` if cancelled, `null` if dismissed (escape / outside tap).
  ///
  /// [destructive] swaps the confirm button to `PosActionTone.destructive`.
  /// [confirmTone] (when non-null) overrides the confirm tone — useful when
  /// the calling surface uses a non-standard confirm color (e.g. green
  /// `statusAvailable` deposit confirms). Default is `PosActionTone.primary`.
  static Future<bool?> show({
    required BuildContext context,
    required String title,
    String? description,
    String confirmLabel = 'Confirm',
    String cancelLabel = 'Cancel',
    bool destructive = false,
    PosActionTone? confirmTone,
    IconData? icon,
  }) {
    final tone = destructive
        ? PosActionTone.destructive
        : (confirmTone ?? PosActionTone.primary);

    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: PosColors.surface,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, color: PosColors.accent, size: 20),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                title,
                style: AppFonts.system(
                  color: PosColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        content: description == null
            ? null
            : Text(
                description,
                style: AppFonts.system(color: PosColors.textSecondary),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              cancelLabel,
              style: AppFonts.system(color: PosColors.textSecondary),
            ),
          ),
          SizedBox(
            width: 140,
            height: 48,
            child: PosActionButton(
              key: const Key('toast_confirm_dialog_confirm'),
              label: confirmLabel,
              tone: tone,
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ),
        ],
      ),
    );
  }

  /// Same shape as [show], but the dialog body is an arbitrary [content]
  /// widget instead of a plain `description` string. Used for
  /// title + form-fields + Cancel + Confirm dialogs where the caller reads
  /// values from controllers after the future resolves.
  ///
  /// Design choice: this variant has no `description` slot — the caller
  /// composes any prose into [content]. Keeps the API additive and the
  /// two call shapes orthogonal.
  ///
  /// If the content widget needs internal state (e.g. checkbox toggles),
  /// pass a `StatefulBuilder` as [content] — the primitive does not need
  /// to know about it.
  static Future<bool?> withContent({
    required BuildContext context,
    required String title,
    required Widget content,
    String confirmLabel = 'Confirm',
    String cancelLabel = 'Cancel',
    bool destructive = false,
    PosActionTone? confirmTone,
    IconData? icon,
  }) {
    final tone = destructive
        ? PosActionTone.destructive
        : (confirmTone ?? PosActionTone.primary);

    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, color: AppColors.amber500, size: 20),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                title,
                style: AppFonts.system(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        content: content,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              cancelLabel,
              style: AppFonts.system(color: AppColors.textSecondary),
            ),
          ),
          SizedBox(
            width: 140,
            height: 48,
            child: PosActionButton(
              key: const Key('toast_confirm_dialog_confirm'),
              label: confirmLabel,
              tone: tone,
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// ToastOperationalLoadingState — calm, no decoration.
// =============================================================================
class ToastOperationalLoadingState extends StatelessWidget {
  const ToastOperationalLoadingState({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final effectiveLabel = label ?? PosLoadingCopy.loadingQueue(context.l10n);
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            effectiveLabel,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
