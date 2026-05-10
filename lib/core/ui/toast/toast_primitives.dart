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

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app_theme.dart';
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
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.surface3)),
      ),
      child: Row(
        children: columns
            .map(
              (c) => Expanded(
                flex: c.flex,
                child: Text(
                  c.label.toUpperCase(),
                  textAlign: c.align,
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textMuted,
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
    final bg = selected
        ? AppColors.amber500.withValues(alpha: 0.12)
        : Colors.transparent;
    return InkWell(
      onTap: onSelect == null ? null : () => onSelect!(r.id),
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          border: Border(
            left: BorderSide(
              color: selected ? AppColors.amber500 : Colors.transparent,
              width: 3,
            ),
            bottom: const BorderSide(color: AppColors.surface3),
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
  const ToastMetricStrip({super.key, required this.metrics});
  final List<ToastMetric> metrics;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: AppRadius.sm,
        border: Border.all(color: AppColors.surface3),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          for (var i = 0; i < metrics.length; i++) ...[
            if (i > 0)
              Container(
                width: 1,
                height: 24,
                color: AppColors.surface3,
                margin: const EdgeInsets.symmetric(horizontal: 12),
              ),
            Expanded(child: _tile(metrics[i])),
          ],
        ],
      ),
    );
  }

  Widget _tile(ToastMetric m) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          m.label.toUpperCase(),
          style: GoogleFonts.notoSansKr(
            color: AppColors.textMuted,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          m.value,
          style: GoogleFonts.notoSansKr(
            color: m.tone ?? AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
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
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final String? urgentReason;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.surface3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
                if (urgentReason != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    urgentReason!,
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.statusReady,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
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
        color: AppColors.statusInfo.withValues(alpha: 0.08),
        border: Border.all(color: AppColors.statusInfo.withValues(alpha: 0.4)),
        borderRadius: AppRadius.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            issue,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (detail != null) ...[
            const SizedBox(height: 4),
            Text(
              detail!,
              style: GoogleFonts.notoSansKr(
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
        ? PosDisabledCopy.forReason(disabledReason!)
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

    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showIconSlot) ...[
          SizedBox(
            width: iconSize,
            height: iconSize,
            child: Center(child: iconSlot),
          ),
          SizedBox(width: compact ? 6 : 8),
        ],
        Text(
          loading ? (loadingLabel ?? label) : label,
          style: GoogleFonts.notoSansKr(
            color: fg,
            fontSize: compact ? 12 : 13,
            fontWeight: compact ? FontWeight.w700 : FontWeight.w800,
          ),
        ),
      ],
    );

    final btn = Opacity(
      opacity: disabled ? 0.5 : 1.0,
      child: InkWell(
        onTap: disabled ? null : onPressed,
        borderRadius: AppRadius.sm,
        child: Container(
          padding: compact
              ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
              : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: tone == PosActionTone.secondary ? AppColors.surface2 : bg,
            borderRadius: AppRadius.sm,
            border: Border.all(
              color: tone == PosActionTone.secondary ? AppColors.surface3 : bg,
            ),
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
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.surface3)),
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
        style: GoogleFonts.notoSansKr(
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 28, color: AppColors.textMuted),
          const SizedBox(height: 10),
          Text(
            headline,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (helper != null) ...[
            const SizedBox(height: 4),
            Text(
              helper!,
              style: GoogleFonts.notoSansKr(
                color: AppColors.textMuted,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
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
    return InkWell(
      onTap: onSelected,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.amber500 : AppColors.surface1,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.amber500 : AppColors.surface2,
          ),
        ),
        child: Text(
          display,
          style: GoogleFonts.notoSansKr(
            color: selected ? AppColors.surface0 : AppColors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
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
                style: GoogleFonts.notoSansKr(
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
                style: GoogleFonts.notoSansKr(
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
                style: GoogleFonts.notoSansKr(
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
                style: GoogleFonts.notoSansKr(
                  color: AppColors.textPrimary,
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
                style: GoogleFonts.notoSansKr(color: AppColors.textSecondary),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              cancelLabel,
              style: GoogleFonts.notoSansKr(color: AppColors.textSecondary),
            ),
          ),
          PosActionButton(
            label: confirmLabel,
            tone: tone,
            onPressed: () => Navigator.pop(ctx, true),
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
                style: GoogleFonts.notoSansKr(
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
              style: GoogleFonts.notoSansKr(color: AppColors.textSecondary),
            ),
          ),
          PosActionButton(
            label: confirmLabel,
            tone: tone,
            onPressed: () => Navigator.pop(ctx, true),
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
  const ToastOperationalLoadingState({
    super.key,
    this.label = PosLoadingCopy.loadingQueue,
  });

  final String label;

  @override
  Widget build(BuildContext context) {
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
            label,
            style: GoogleFonts.notoSansKr(
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
