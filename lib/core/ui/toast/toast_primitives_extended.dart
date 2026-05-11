import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app_theme.dart';
import '../pos_design_tokens.dart';

/// Additive Toast-style primitives that are NOT yet defined under
/// `lib/core/ui/app_primitives.dart` or the existing `toast/` files.
///
/// This file is intentionally minimal — it only seeds the foundation that
/// later screen-migration PRs will build on. Do not add widgets here that
/// would shadow or replace existing `App*` / `Toast*` widgets already on
/// main; introduce them in dedicated follow-up PRs as their callers land.
class ToastWorkSurface extends StatelessWidget {
  const ToastWorkSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(ToastSpacingTokens.lg),
    this.backgroundColor = ToastColorTokens.surface,
    this.borderColor = ToastColorTokens.border,
    this.clip = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color backgroundColor;
  final Color borderColor;
  final bool clip;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: clip ? Clip.antiAlias : Clip.none,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: ToastRadiusTokens.md,
        border: Border.all(color: borderColor),
        boxShadow: ToastElevationTokens.none,
      ),
      padding: padding,
      child: child,
    );
  }
}

enum ToastStatusDomain { order, payment, kitchen, inventory, staff }

Color _toastStatusColor(String status, ToastStatusDomain domain) {
  final normalized = status.toLowerCase().trim();
  return switch (domain) {
    ToastStatusDomain.order => switch (normalized) {
      'open' || 'new' => ToastStatusTokens.orderOpen,
      'pending' => ToastStatusTokens.orderPending,
      'preparing' => ToastStatusTokens.orderPreparing,
      'ready' => ToastStatusTokens.orderReady,
      'served' => ToastStatusTokens.orderServed,
      'completed' || 'paid' => ToastStatusTokens.orderCompleted,
      'cancelled' || 'void' => ToastStatusTokens.orderCancelled,
      _ => ToastColorTokens.textSecondary,
    },
    ToastStatusDomain.payment => switch (normalized) {
      'unpaid' || 'pending' => ToastStatusTokens.paymentUnpaid,
      'partial' || 'partially_paid' => ToastStatusTokens.paymentPartial,
      'paid' || 'completed' => ToastStatusTokens.paymentPaid,
      'refunded' => ToastStatusTokens.paymentRefunded,
      'failed' || 'cancelled' => ToastStatusTokens.paymentFailed,
      _ => ToastColorTokens.textSecondary,
    },
    ToastStatusDomain.kitchen => switch (normalized) {
      'new' || 'pending' => ToastColorTokens.info,
      'preparing' || 'in_progress' => ToastColorTokens.warning,
      'ready' || 'completed' => ToastColorTokens.success,
      'cancelled' || 'void' => ToastColorTokens.danger,
      _ => ToastColorTokens.textSecondary,
    },
    ToastStatusDomain.inventory => switch (normalized) {
      'in_stock' || 'available' => ToastStatusTokens.inventoryInStock,
      'low' || 'low_stock' => ToastStatusTokens.inventoryLow,
      'out' || 'out_of_stock' || 'sold_out' => ToastStatusTokens.inventoryOut,
      'pending' || 'ordered' => ToastStatusTokens.inventoryPending,
      _ => ToastColorTokens.textSecondary,
    },
    ToastStatusDomain.staff => switch (normalized) {
      'active' || 'clocked_in' || 'present' => ToastColorTokens.success,
      'late' || 'break' => ToastColorTokens.warning,
      'inactive' || 'absent' || 'clocked_out' => ToastColorTokens.textSecondary,
      'blocked' || 'deleted' => ToastColorTokens.danger,
      _ => ToastColorTokens.textSecondary,
    },
  };
}

class ToastStatusBadge extends StatelessWidget {
  const ToastStatusBadge({
    super.key,
    required this.label,
    required this.color,
    this.foregroundColor,
    this.backgroundColor,
    this.icon,
    this.compact = false,
  });

  factory ToastStatusBadge.order({
    Key? key,
    required String label,
    required String status,
  }) {
    return ToastStatusBadge(
      key: key,
      label: label,
      color: _toastStatusColor(status, ToastStatusDomain.order),
    );
  }

  factory ToastStatusBadge.payment({
    Key? key,
    required String label,
    required String status,
  }) {
    return ToastStatusBadge(
      key: key,
      label: label,
      color: _toastStatusColor(status, ToastStatusDomain.payment),
    );
  }

  factory ToastStatusBadge.kitchen({
    Key? key,
    required String label,
    required String status,
  }) {
    return ToastStatusBadge(
      key: key,
      label: label,
      color: _toastStatusColor(status, ToastStatusDomain.kitchen),
    );
  }

  factory ToastStatusBadge.inventory({
    Key? key,
    required String label,
    required String status,
  }) {
    return ToastStatusBadge(
      key: key,
      label: label,
      color: _toastStatusColor(status, ToastStatusDomain.inventory),
    );
  }

  factory ToastStatusBadge.staff({
    Key? key,
    required String label,
    required String status,
  }) {
    return ToastStatusBadge(
      key: key,
      label: label,
      color: _toastStatusColor(status, ToastStatusDomain.staff),
    );
  }

  final String label;
  final Color color;
  final Color? foregroundColor;
  final Color? backgroundColor;
  final IconData? icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final textColor = foregroundColor ?? color;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: backgroundColor ?? color.withValues(alpha: 0.12),
        borderRadius: ToastRadiusTokens.pill,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: compact ? 13 : 15, color: textColor),
            const SizedBox(width: AppSpacing.xs),
          ],
          Text(
            label,
            style: GoogleFonts.notoSansKr(
              color: textColor,
              fontSize: compact ? 10.5 : 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class ToastShell extends StatelessWidget {
  const ToastShell({
    super.key,
    required this.child,
    this.sidebar,
    this.topbar,
    this.contentPadding = const EdgeInsets.all(AppSpacing.lg),
    this.safeArea = true,
  });

  final Widget child;
  final Widget? sidebar;
  final Widget? topbar;
  final EdgeInsetsGeometry contentPadding;
  final bool safeArea;

  @override
  Widget build(BuildContext context) {
    final content = Row(
      children: [
        if (sidebar != null) sidebar!,
        Expanded(
          child: Column(
            children: [
              if (topbar != null) topbar!,
              Expanded(
                child: Padding(padding: contentPadding, child: child),
              ),
            ],
          ),
        ),
      ],
    );

    return ColoredBox(
      color: ToastColorTokens.canvas,
      child: safeArea ? SafeArea(child: content) : content,
    );
  }
}

class ToastTopbar extends StatelessWidget {
  const ToastTopbar({
    super.key,
    required this.title,
    this.leading,
    this.trailing,
    this.actions = const [],
    this.height = ToastShellTokens.topbarHeight,
  });

  final String title;
  final Widget? leading;
  final Widget? trailing;
  final List<Widget> actions;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      decoration: BoxDecoration(
        color: ToastColorTokens.surface,
        border: Border(
          bottom: BorderSide(
            color: ToastColorTokens.border.withValues(alpha: 0.82),
          ),
        ),
      ),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: AppSpacing.md),
          ],
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.notoSansKr(
                color: ToastColorTokens.textPrimary,
                fontSize: 15.5,
                fontWeight: FontWeight.w900,
                height: 1.2,
              ),
            ),
          ),
          ...actions.expand(
            (action) => [const SizedBox(width: AppSpacing.sm), action],
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.md),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _ToastDenseListRow extends StatelessWidget {
  const _ToastDenseListRow({
    required this.child,
    this.onTap,
    this.selected = false,
    this.minHeight = PosMetrics.tableRowHeight,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.md,
      vertical: AppSpacing.sm,
    ),
    this.statusColor,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool selected;
  final double minHeight;
  final EdgeInsetsGeometry padding;
  final Color? statusColor;

  @override
  Widget build(BuildContext context) {
    final accent = statusColor ?? ToastColorTokens.border;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: selected
            ? ToastColorTokens.selectedRow
            : ToastColorTokens.surface,
        borderRadius: ToastRadiusTokens.xs,
        border: Border.all(
          color: selected
              ? accent.withValues(alpha: 0.44)
              : ToastColorTokens.border.withValues(alpha: 0.78),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: ToastRadiusTokens.xs,
          hoverColor: ToastColorTokens.selectedRow.withValues(alpha: 0.42),
          focusColor: accent.withValues(alpha: 0.08),
          splashFactory: NoSplash.splashFactory,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: selected ? 4 : 3,
                  color: statusColor ?? Colors.transparent,
                ),
                Expanded(
                  child: Padding(padding: padding, child: child),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PosListRow extends StatelessWidget {
  const PosListRow({
    super.key,
    required this.child,
    this.onTap,
    this.selected = false,
    this.minHeight = PosMetrics.tableRowHeight,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.md,
      vertical: AppSpacing.sm,
    ),
    this.statusColor,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool selected;
  final double minHeight;
  final EdgeInsetsGeometry padding;
  final Color? statusColor;

  @override
  Widget build(BuildContext context) {
    return _ToastDenseListRow(
      onTap: onTap,
      selected: selected,
      minHeight: minHeight,
      padding: padding,
      statusColor: statusColor,
      child: child,
    );
  }
}

/// Wave 1.6 caller-supplied metric tile. Pairs with [ToastMetricItemStrip].
///
/// Distinct from the existing `ToastMetric` / `ToastMetricStrip` in
/// `toast_primitives.dart` (which uses `metrics:` + `tone`). This shape
/// carries an optional `status` widget for inline badges and a
/// per-item `color` for value emphasis.
class ToastMetricItem {
  const ToastMetricItem({
    required this.label,
    required this.value,
    this.status,
    this.color = ToastColorTokens.textPrimary,
  });

  final String label;
  final String value;
  final Widget? status;
  final Color color;
}

/// Wave 1.6 sibling of the existing `ToastMetricStrip` in
/// `toast_primitives.dart`. Renders a row of [ToastMetricItem]s inside
/// a [ToastWorkSurface] with vertical dividers.
///
/// Named with a distinct class so the two strips can coexist:
/// - `ToastMetricStrip(metrics: List<ToastMetric>)` — legacy, dark-theme,
///   in `toast_primitives.dart`.
/// - `ToastMetricItemStrip(items: List<ToastMetricItem>)` — Wave 1.6,
///   Toast-theme, supports per-item color + inline status widget.
class ToastMetricItemStrip extends StatelessWidget {
  const ToastMetricItemStrip({
    super.key,
    required this.items,
    this.compact = false,
    this.muted = false,
  });

  final List<ToastMetricItem> items;
  final bool compact;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return ToastWorkSurface(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : AppSpacing.lg,
        vertical: compact ? 7 : 10,
      ),
      backgroundColor: muted
          ? ToastColorTokens.mutedSurface
          : ToastColorTokens.surface,
      borderColor: muted
          ? ToastColorTokens.border.withValues(alpha: 0.58)
          : ToastColorTokens.border,
      child: Row(
        children: [
          for (var index = 0; index < items.length; index++) ...[
            Expanded(
              child: _ToastMetricCell(
                item: items[index],
                compact: compact,
                muted: muted,
              ),
            ),
            if (index != items.length - 1)
              SizedBox(
                height: compact ? 28 : 36,
                child: VerticalDivider(
                  color: muted
                      ? ToastColorTokens.border.withValues(alpha: 0.42)
                      : ToastColorTokens.border.withValues(alpha: 0.72),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ToastMetricCell extends StatelessWidget {
  const _ToastMetricCell({
    required this.item,
    required this.compact,
    required this.muted,
  });

  final ToastMetricItem item;
  final bool compact;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final valueColor = muted ? item.color.withValues(alpha: 0.78) : item.color;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? AppSpacing.xs : AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.notoSansKr(
                    color: ToastColorTokens.textMuted,
                    fontSize: compact ? 9.8 : 10.8,
                    fontWeight: FontWeight.w700,
                    height: 1.12,
                  ),
                ),
              ),
              if (item.status != null) item.status!,
            ],
          ),
          SizedBox(height: compact ? 3 : 5),
          Text(
            item.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.notoSansKr(
              color: valueColor,
              fontSize: compact ? 12.5 : 16,
              fontWeight: compact ? FontWeight.w800 : FontWeight.w900,
              height: 1.04,
            ),
          ),
        ],
      ),
    );
  }
}
