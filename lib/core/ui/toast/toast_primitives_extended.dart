import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../i18n/locale_extensions.dart';
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

/// Wave 1.6 caller-supplied item for [ToastSidebarPanel].
///
/// Distinct from `ToastSidebarItem` in `toast_sidebar.dart` (which is
/// consumed by the full-shell `ToastSidebar` orchestrator). This item
/// shape is rail-only and accepts the fields the stash photo-ops
/// shell passes today: `icon`, `label`, optional `sectionLabel`,
/// optional `helperLabel`, optional `badge`, optional `onTap`, optional
/// `itemKey`.
class ToastSidebarPanelItem {
  const ToastSidebarPanelItem({
    required this.icon,
    required this.label,
    this.sectionLabel,
    this.helperLabel,
    this.badge,
    this.onTap,
    this.itemKey,
  });

  final IconData icon;
  final String label;

  /// Section header rendered above this item. Stash-era shells use this
  /// to group navigation entries without a wrapping `ToastSidebarGroup`.
  final String? sectionLabel;

  /// Secondary helper text rendered under the label. Stored for future
  /// renderers; today's `_PanelRailItem` does not paint it (kept slim
  /// for the initial Wave 1.6 unblock).
  final String? helperLabel;

  /// Provider-backed badge widget (e.g. a count chip). Stored for
  /// future renderers; today's `_PanelRailItem` does not paint it.
  final Widget? badge;

  final VoidCallback? onTap;
  final Key? itemKey;
}

/// Wave 1.6 rail-only sibling of the full-shell `ToastSidebar` in
/// `toast_sidebar.dart`.
///
/// Use [ToastSidebarPanel] when you need just a sidebar column to slot
/// into another shell (e.g. `ToastShell.sidebar`); use `ToastSidebar`
/// when you need the orchestrator that also renders a body and topbar.
///
/// Renders a fixed-width `Container` with a title row, an optional
/// `subtitle`, a scrollable list of items (with optional section
/// headers above each item), and optional `bottomItems` pinned at the
/// foot. Rendering style mirrors PR #43's `_SidebarRail` in
/// `web_sidebar_layout.dart` so the visual surface remains consistent.
class ToastSidebarPanel extends StatelessWidget {
  const ToastSidebarPanel({
    super.key,
    required this.title,
    this.subtitle,
    required this.items,
    required this.selectedIndex,
    required this.onItemSelected,
    this.leading,
    this.bottomItems,
  });

  final String title;
  final String? subtitle;
  final List<ToastSidebarPanelItem> items;
  final int selectedIndex;
  final ValueChanged<int> onItemSelected;
  final Widget? leading;
  final List<ToastSidebarPanelItem>? bottomItems;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: ToastShellTokens.sidebarWidth,
      decoration: BoxDecoration(
        color: PosColors.surface,
        border: Border(
          right: BorderSide(
            color: PosColors.border,
            width: ToastShellTokens.borderWidth,
          ),
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            alignment: Alignment.centerLeft,
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: PosColors.border)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    if (leading != null) ...[
                      leading!,
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.notoSansKr(
                          color: PosColors.text,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.notoSansKr(
                      color: PosColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final isSelected = selectedIndex == index;
                final header = item.sectionLabel;
                final nav = _PanelRailItem(
                  key: item.itemKey,
                  icon: item.icon,
                  label: item.label,
                  isSelected: isSelected,
                  onTap: item.onTap ?? () => onItemSelected(index),
                );
                if (header == null || header.isEmpty) return nav;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        16,
                        index == 0 ? 4 : 14,
                        16,
                        6,
                      ),
                      child: Text(
                        header.toUpperCase(),
                        style: GoogleFonts.notoSansKr(
                          color: PosColors.textMuted,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                    nav,
                  ],
                );
              },
            ),
          ),
          if (bottomItems != null && bottomItems!.isNotEmpty) ...[
            Container(height: 1, color: PosColors.border),
            ...bottomItems!.map(
              (item) => _PanelRailItem(
                icon: item.icon,
                label: item.label,
                isSelected: false,
                onTap: item.onTap ?? () {},
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _PanelRailItem extends StatelessWidget {
  const _PanelRailItem({
    super.key,
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      child: PosListRow(
        selected: isSelected,
        minHeight: ToastShellTokens.navItemHeight,
        onTap: onTap,
        child: Row(
          children: [
            Icon(
              icon,
              size: 17,
              color: isSelected ? PosColors.accent : PosColors.textMuted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.notoSansKr(
                  color: isSelected ? PosColors.text : PosColors.textSecondary,
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Wave 1.6 Bundle B — action verbs surfaced by Toast-action UI
/// (right-edge action stacks, status badges, disabled tooltips).
///
/// This enum is the canonical taxonomy of user-facing action verbs
/// the Toast shell exposes. Each variant maps 1:1 to a localized
/// label via [toastActionVerbLabel].
enum ToastActionVerb {
  open,
  retry,
  resolved,
  payNow,
  pay,
  splitBill,
  sendToKitchen,
  hold,
  move,
  openPortal,
  resendEmail,
  openProof,
  reprint,
  prep,
  ready,
  served,
  close,
  serviceNow,
  excel,
}

/// Localized label for a [ToastActionVerb]. Resolves to the active
/// locale's string via `context.l10n.*` keys. All referenced keys
/// already exist on main across `app_en.arb` / `app_ko.arb` /
/// `app_vi.arb`.
String toastActionVerbLabel(BuildContext context, ToastActionVerb verb) {
  return switch (verb) {
    ToastActionVerb.open => context.l10n.open,
    ToastActionVerb.retry => context.l10n.retry,
    ToastActionVerb.resolved => context.l10n.resolved,
    ToastActionVerb.payNow => context.l10n.cashierPayNow,
    ToastActionVerb.pay => context.l10n.orderWorkspacePay,
    ToastActionVerb.splitBill => context.l10n.cashierSplitBill,
    ToastActionVerb.sendToKitchen => context.l10n.orderWorkspaceSendToKitchen,
    ToastActionVerb.hold => context.l10n.orderWorkspaceHold,
    ToastActionVerb.move => context.l10n.orderWorkspaceMove,
    ToastActionVerb.openPortal => context.l10n.paymentDetailOpenPortal,
    ToastActionVerb.resendEmail => context.l10n.paymentDetailResendEmail,
    ToastActionVerb.openProof => context.l10n.paymentDetailOpenProof,
    ToastActionVerb.reprint => context.l10n.cashierReprint,
    ToastActionVerb.prep => context.l10n.orderStatusPreparingShort,
    ToastActionVerb.ready => context.l10n.ready,
    ToastActionVerb.served => context.l10n.orderStatusServed,
    ToastActionVerb.close => context.l10n.close,
    ToastActionVerb.serviceNow => context.l10n.cashierServiceNow,
    ToastActionVerb.excel => context.l10n.excel,
  };
}

/// Material icon for a [ToastActionVerb]. Sibling of
/// [toastActionVerbLabel]; pure function with no `context` / `l10n`
/// dependency. Exhaustive over the enum — no default arm.
IconData toastActionVerbIcon(ToastActionVerb verb) {
  return switch (verb) {
    ToastActionVerb.open => Icons.open_in_new,
    ToastActionVerb.retry => Icons.refresh,
    ToastActionVerb.resolved => Icons.check_circle,
    ToastActionVerb.payNow => Icons.payments,
    ToastActionVerb.pay => Icons.payments,
    ToastActionVerb.splitBill => Icons.call_split,
    ToastActionVerb.sendToKitchen => Icons.send_outlined,
    ToastActionVerb.hold => Icons.pause_circle,
    ToastActionVerb.move => Icons.swap_horiz,
    ToastActionVerb.openPortal => Icons.open_in_browser,
    ToastActionVerb.resendEmail => Icons.forward_to_inbox,
    ToastActionVerb.openProof => Icons.receipt_long,
    ToastActionVerb.reprint => Icons.print,
    ToastActionVerb.prep => Icons.restaurant,
    ToastActionVerb.ready => Icons.check_circle,
    ToastActionVerb.served => Icons.done_all,
    ToastActionVerb.close => Icons.close,
    ToastActionVerb.serviceNow => Icons.room_service,
    ToastActionVerb.excel => Icons.table_view,
  };
}

/// Wave 1.6 Bundle B — reasons a Toast action surface can be disabled.
///
/// Consumed today only as enum values (e.g.
/// `ToastActionDisabledReason.actionInProgress` set as the disabled
/// state of a button); the label function that maps these to human
/// strings is deliberately NOT added in this PR (see PR body for
/// rationale — current callers don't render the reason).
enum ToastActionDisabledReason {
  waitingForPayment,
  waitingForKitchen,
  kitchenBlocked,
  invoicePending,
  settlementIncomplete,
  missingProof,
  retryRequiredFirst,
  noActiveSelection,
  tableNotReady,
  actionUnavailableOffline,
  noRetryableIssue,
  kitchenNotReady,
  invoiceUnavailable,
  paymentMethodRequired,
  noItemsSelected,
  actionInProgress,
  noPendingPrep,
  openOrderRequired,
}
