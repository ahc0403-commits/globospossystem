import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../i18n/locale_extensions.dart';
import '../app_theme.dart';
import '../pos_design_tokens.dart';
import 'toast_primitives.dart';
import 'toast_vocabulary.dart';

LinearGradient _workSurfaceGradient(Color backgroundColor) {
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color.alphaBlend(Colors.white.withValues(alpha: 0.14), backgroundColor),
      backgroundColor,
      Color.alphaBlend(
        ToastColorTokens.canvas.withValues(alpha: 0.06),
        backgroundColor,
      ),
    ],
    stops: const [0, 0.7, 1],
  );
}

List<BoxShadow> _workSurfaceShadow(Color borderColor) {
  if (borderColor == Colors.transparent) {
    return ToastElevationTokens.none;
  }
  return PosShadows.low;
}

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
        gradient: _workSurfaceGradient(backgroundColor),
        borderRadius: ToastRadiusTokens.lg,
        border: Border.all(color: borderColor),
        boxShadow: _workSurfaceShadow(borderColor),
      ),
      padding: padding,
      child: child,
    );
  }
}

class ToastOperationalQueuePane extends StatelessWidget {
  const ToastOperationalQueuePane({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.headerBottom,
    this.padding = const EdgeInsets.all(ToastSpacingTokens.lg),
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;
  final Widget? headerBottom;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ToastWorkSurface(
      padding: padding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final body = constraints.hasBoundedHeight
              ? Expanded(child: child)
              : child;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.only(bottom: ToastSpacingTokens.md),
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  border: Border(
                    bottom: BorderSide(
                      color: ToastColorTokens.border.withValues(alpha: 0.86),
                    ),
                  ),
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
                              color: ToastColorTokens.textPrimary,
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              height: 1.12,
                              letterSpacing: -0.4,
                            ),
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: ToastSpacingTokens.sm),
                            Text(
                              subtitle!,
                              style: GoogleFonts.notoSansKr(
                                color: ToastColorTokens.textSecondary,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w400,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: ToastSpacingTokens.md),
                      trailing!,
                    ],
                  ],
                ),
              ),
              if (headerBottom != null) ...[
                const SizedBox(height: ToastSpacingTokens.md),
                headerBottom!,
              ],
              const SizedBox(height: ToastSpacingTokens.md),
              body,
            ],
          );
        },
      ),
    );
  }
}

class ToastPrimaryActionZone extends StatelessWidget {
  const ToastPrimaryActionZone({
    super.key,
    required this.actions,
    this.supporting,
    this.padding = const EdgeInsets.only(top: ToastSpacingTokens.lg),
    this.alignment = WrapAlignment.end,
  });

  final List<Widget> actions;
  final Widget? supporting;
  final EdgeInsetsGeometry padding;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border(
          top: BorderSide(
            color: ToastColorTokens.border.withValues(alpha: 0.86),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: ToastSpacingTokens.sm,
            runSpacing: ToastSpacingTokens.sm,
            alignment: alignment,
            children: actions,
          ),
          if (supporting != null) ...[
            const SizedBox(height: ToastSpacingTokens.sm),
            supporting!,
          ],
        ],
      ),
    );
  }
}

class ToastViewportScroll extends StatefulWidget {
  const ToastViewportScroll({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.physics = const AlwaysScrollableScrollPhysics(
      parent: ClampingScrollPhysics(),
    ),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final ScrollPhysics physics;

  @override
  State<ToastViewportScroll> createState() => _ToastViewportScrollState();
}

class _ToastViewportScrollState extends State<ToastViewportScroll> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      child: ListView(
        controller: _scrollController,
        physics: widget.physics,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: widget.padding,
        children: [widget.child],
      ),
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
        color: backgroundColor ?? color.withValues(alpha: 0.1),
        borderRadius: ToastRadiusTokens.pill,
        border: Border.all(color: color.withValues(alpha: 0.16)),
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
              fontSize: compact ? 11 : 11.5,
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

EdgeInsets _toastResponsivePagePadding(double width) {
  if (width < 560) {
    return const EdgeInsets.all(12);
  }
  if (width < 960) {
    return const EdgeInsets.all(16);
  }
  return const EdgeInsets.all(20);
}

const double _toastSingleScrollOwnerBreakpoint = 1120;
const double _toastCompactPageMinHeight = 1600;

class ToastResponsiveBody extends StatelessWidget {
  const ToastResponsiveBody({
    super.key,
    required this.child,
    this.maxWidth = 1360,
    this.padding,
    this.alignment = Alignment.topCenter,
    this.minHeight = 720,
    this.fitToViewportWhenNarrow = false,
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry? padding;
  final Alignment alignment;
  final double minHeight;
  final bool fitToViewportWhenNarrow;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final resolvedPadding =
            padding ?? _toastResponsivePagePadding(constraints.maxWidth);
        final insets = resolvedPadding.resolve(Directionality.of(context));
        final availableWidth = math.max(
          0.0,
          constraints.maxWidth - insets.horizontal,
        );
        final availableHeight = math.max(
          0.0,
          constraints.maxHeight - insets.vertical,
        );
        final resolvedWidth = math.min(maxWidth, availableWidth);
        final narrowLayout =
            constraints.maxWidth < _toastSingleScrollOwnerBreakpoint;
        final preferredHeight = narrowLayout && !fitToViewportWhenNarrow
            ? math.max(
                math.max(availableHeight, minHeight),
                _toastCompactPageMinHeight,
              )
            : math.max(availableHeight, minHeight);
        final useSingleScrollOwner = fitToViewportWhenNarrow && narrowLayout;
        final effectiveHeight = useSingleScrollOwner
            ? availableHeight
            : preferredHeight;
        final body = Align(
          alignment: alignment,
          child: SizedBox(
            width: resolvedWidth,
            height: effectiveHeight,
            child: child,
          ),
        );

        if (!narrowLayout && effectiveHeight <= availableHeight) {
          return Padding(padding: resolvedPadding, child: body);
        }

        return ToastViewportScroll(padding: resolvedPadding, child: body);
      },
    );
  }
}

class ToastResponsiveScrollBody extends StatelessWidget {
  const ToastResponsiveScrollBody({
    super.key,
    required this.children,
    this.maxWidth = 1360,
    this.padding,
    this.controller,
    this.physics,
  });

  final List<Widget> children;
  final double maxWidth;
  final EdgeInsetsGeometry? padding;
  final ScrollController? controller;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final resolvedPadding =
            padding ?? _toastResponsivePagePadding(constraints.maxWidth);
        final insets = resolvedPadding.resolve(Directionality.of(context));
        final availableWidth = math.max(
          0.0,
          constraints.maxWidth - insets.horizontal,
        );
        final resolvedWidth = math.min(maxWidth, availableWidth);

        return ListView(
          controller: controller,
          physics:
              physics ??
              const AlwaysScrollableScrollPhysics(
                parent: ClampingScrollPhysics(),
              ),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: resolvedPadding,
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: resolvedWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ],
        );
      },
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
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: ToastColorTokens.topbarSurface,
        border: Border(
          bottom: BorderSide(
            color: ToastColorTokens.border.withValues(alpha: 0.86),
          ),
        ),
      ),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: AppSpacing.sm),
          ],
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.notoSansKr(
                color: ToastColorTokens.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
          ),
          ...actions.expand(
            (action) => [const SizedBox(width: AppSpacing.sm), action],
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.md),
            Flexible(
              fit: FlexFit.loose,
              child: Align(alignment: Alignment.centerRight, child: trailing!),
            ),
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
    final accent = statusColor ?? ToastColorTokens.accent;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: selected ? ToastColorTokens.selectedRow : Colors.transparent,
        borderRadius: ToastRadiusTokens.md,
        border: Border.all(
          color: selected ? accent.withValues(alpha: 0.22) : Colors.transparent,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: ToastRadiusTokens.md,
          hoverColor: ToastColorTokens.selectedRow.withValues(alpha: 0.62),
          focusColor: accent.withValues(alpha: 0.08),
          splashFactory: NoSplash.splashFactory,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: selected ? 4 : 0,
                  color: selected ? accent : Colors.transparent,
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

class PosPageHeader extends StatelessWidget {
  const PosPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.bottom,
    this.padding = const EdgeInsets.fromLTRB(0, 0, 0, 18),
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? bottom;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: PosColors.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 16), trailing!],
            ],
          ),
          if (bottom != null) ...[const SizedBox(height: 16), bottom!],
        ],
      ),
    );
  }
}

class PosStatCard extends StatelessWidget {
  const PosStatCard({
    super.key,
    required this.label,
    required this.value,
    this.supporting,
    this.tone,
    this.trailing,
  });

  final String label;
  final String value;
  final String? supporting;
  final Color? tone;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final accent = tone ?? PosColors.textPrimary;
    return ToastWorkSurface(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      backgroundColor: PosColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: PosColors.textSecondary,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.displayMedium?.copyWith(fontSize: 26, color: accent),
          ),
          if (supporting != null) ...[
            const SizedBox(height: 6),
            Text(
              supporting!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

class PosToolbar extends StatelessWidget {
  const PosToolbar({super.key, required this.children, this.trailing});

  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ToastWorkSurface(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: children,
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );
  }
}

class PosDataPanel extends StatelessWidget {
  const PosDataPanel({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.all(18),
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ToastWorkSurface(
      padding: padding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final body = constraints.hasBoundedHeight
              ? Expanded(child: child)
              : child;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(
                            context,
                          ).textTheme.titleLarge?.copyWith(fontSize: 20),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            subtitle!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 12),
                    trailing!,
                  ],
                ],
              ),
              const SizedBox(height: 16),
              body,
            ],
          );
        },
      ),
    );
  }
}

class PosSplitContent extends StatelessWidget {
  const PosSplitContent({
    super.key,
    required this.primary,
    required this.secondary,
    this.primaryFlex = 7,
    this.secondaryFlex = 4,
    this.breakpoint = 1080,
    this.spacing = 16,
    this.compactPrimaryHeight = 520,
    this.compactSecondaryHeight = 320,
  });

  final Widget primary;
  final Widget secondary;
  final int primaryFlex;
  final int secondaryFlex;
  final double breakpoint;
  final double spacing;
  final double compactPrimaryHeight;
  final double compactSecondaryHeight;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < breakpoint) {
          final stackedHeight =
              compactPrimaryHeight + spacing + compactSecondaryHeight;
          final stackedChildren = [
            SizedBox(height: compactPrimaryHeight, child: primary),
            SizedBox(height: spacing),
            SizedBox(height: compactSecondaryHeight, child: secondary),
          ];

          if (constraints.hasBoundedHeight &&
              constraints.maxHeight < stackedHeight) {
            return ListView(
              padding: EdgeInsets.zero,
              physics: const AlwaysScrollableScrollPhysics(
                parent: ClampingScrollPhysics(),
              ),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: stackedChildren,
            );
          }

          return Column(children: stackedChildren);
        }
        return Row(
          children: [
            Expanded(flex: primaryFlex, child: primary),
            SizedBox(width: spacing),
            Expanded(flex: secondaryFlex, child: secondary),
          ],
        );
      },
    );
  }
}

class PosActionCard extends StatelessWidget {
  const PosActionCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.action,
    this.badge,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? action;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    return ToastWorkSurface(
      padding: const EdgeInsets.all(18),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final body = constraints.hasBoundedHeight
              ? Expanded(child: child)
              : child;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            subtitle!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (badge != null) badge!,
                ],
              ),
              const SizedBox(height: 16),
              body,
              if (action != null) ...[
                const SizedBox(height: 16),
                SizedBox(width: double.infinity, child: action!),
              ],
            ],
          );
        },
      ),
    );
  }
}

class PosPrimaryButton extends StatelessWidget {
  const PosPrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    if (icon == null) {
      return FilledButton(onPressed: onPressed, child: Text(label));
    }
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}

class PosSecondaryButton extends StatelessWidget {
  const PosSecondaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    if (icon == null) {
      return OutlinedButton(onPressed: onPressed, child: Text(label));
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}

class PosTableShell extends StatelessWidget {
  const PosTableShell({
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
    return ToastWorkSurface(
      padding: const EdgeInsets.all(12),
      child: ToastQueueTable(
        columns: columns,
        rows: rows,
        selectedId: selectedId,
        onSelect: onSelect,
      ),
    );
  }
}

class PosSelectedRow extends StatelessWidget {
  const PosSelectedRow({
    super.key,
    required this.child,
    this.selected = false,
    this.onTap,
    this.statusColor,
  });

  final Widget child;
  final bool selected;
  final VoidCallback? onTap;
  final Color? statusColor;

  @override
  Widget build(BuildContext context) {
    return PosListRow(
      selected: selected,
      onTap: onTap,
      statusColor: statusColor,
      child: child,
    );
  }
}

class PosEmptyState extends StatelessWidget {
  const PosEmptyState({
    super.key,
    required this.title,
    this.subtitle,
    this.icon = Icons.inbox_outlined,
  });

  final String title;
  final String? subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: PosColors.textMuted, size: 28),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class PosExceptionAlert extends StatelessWidget {
  const PosExceptionAlert({
    super.key,
    required this.label,
    this.detail,
    this.color = PosColors.warning,
    this.icon = Icons.warning_amber_rounded,
  });

  final String label;
  final String? detail;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: ToastRadiusTokens.md,
        border: Border.all(color: color.withValues(alpha: 0.16)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (detail != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    detail!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = _metricItemColumnsForWidth(
          constraints.maxWidth,
          items.length,
        );
        final rows = <List<ToastMetricItem>>[];
        for (var index = 0; index < items.length; index += columns) {
          rows.add(
            items.sublist(index, math.min(index + columns, items.length)),
          );
        }

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
                            ? _ToastMetricCell(
                                item: rows[rowIndex][columnIndex],
                                compact: compact,
                                muted: muted,
                              )
                            : const SizedBox.shrink(),
                      ),
                      if (columnIndex != columns - 1)
                        SizedBox(
                          height: compact ? 28 : 36,
                          child: VerticalDivider(
                            color: muted
                                ? ToastColorTokens.border.withValues(
                                    alpha: 0.42,
                                  )
                                : ToastColorTokens.border.withValues(
                                    alpha: 0.72,
                                  ),
                          ),
                        ),
                    ],
                  ],
                ),
                if (rowIndex != rows.length - 1)
                  SizedBox(height: compact ? 6 : 8),
              ],
            ],
          ),
        );
      },
    );
  }
}

int _metricItemColumnsForWidth(double width, int itemCount) {
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
  return math.min(4, itemCount);
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

  /// Secondary helper text rendered under the label.
  final String? helperLabel;

  /// Provider-backed badge widget (e.g. a count chip).
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
        color: PosColors.sidebarSurface,
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
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: PosColors.sidebarSurface,
              border: const Border(bottom: BorderSide(color: PosColors.border)),
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
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
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
                      letterSpacing: 0.15,
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
                  helperLabel: item.helperLabel,
                  badge: item.badge,
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
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
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
                helperLabel: item.helperLabel,
                badge: item.badge,
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
    this.helperLabel,
    this.badge,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final String? helperLabel;
  final Widget? badge;

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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: isSelected ? PosColors.accent : PosColors.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.notoSansKr(
                  color: isSelected ? PosColors.text : PosColors.textSecondary,
                  fontSize: 13.5,
                  fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
            if (badge != null) ...[
              const SizedBox(width: AppSpacing.xs),
              badge!,
            ],
          ],
        ),
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

/// Wave 1.6 Phase 3.6 — declarative item for [ToastActionStack].
///
/// Pairs with [toastActionVerbLabel] and [toastActionVerbIcon]:
/// callers describe an action as a [ToastActionVerb] with optional
/// label/icon overrides; this widget renders the button. The
/// `disabledReason` / `disabledSeverity` fields are forward-compat
/// storage — today's renderer applies only the boolean `disabled`
/// flag (opacity + null `onTap`). A follow-up tick can wire the
/// reason/severity into an inline status row without API breakage.
///
/// Distinct from main's `PosActionButton` in `toast_primitives.dart`
/// (which uses the simpler legacy taxonomy). Use [ToastActionStackItem]
/// when you want the Wave 1.6 `ToastActionVerb` shape; keep
/// `PosActionButton` for the legacy tone/disabledReason flow.
class ToastActionStackItem extends StatelessWidget {
  const ToastActionStackItem({
    super.key,
    required this.label,
    required this.verb,
    this.icon,
    this.onTap,
    this.disabled = false,
    this.disabledReason,
    this.disabledSeverity,
  });

  /// Build from a [ToastActionVerb] alone. Label defaults to the
  /// localized verb label via [toastActionVerbLabel]. Mirrors the
  /// stash `PosActionButton.verb` factory shape.
  factory ToastActionStackItem.verb({
    Key? key,
    required BuildContext context,
    required ToastActionVerb verb,
    required VoidCallback? onTap,
    IconData? icon,
    bool disabled = false,
    ToastActionDisabledReason? disabledReason,
    PosActionTone? disabledSeverity,
  }) {
    return ToastActionStackItem(
      key: key,
      label: toastActionVerbLabel(context, verb),
      verb: verb,
      icon: icon,
      onTap: onTap,
      disabled: disabled,
      disabledReason: disabledReason,
      disabledSeverity: disabledSeverity,
    );
  }

  final String label;
  final ToastActionVerb verb;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool disabled;
  final ToastActionDisabledReason? disabledReason;
  final PosActionTone? disabledSeverity;

  @override
  Widget build(BuildContext context) {
    final isDisabled = disabled || onTap == null;
    final effectiveIcon = icon ?? toastActionVerbIcon(verb);
    return Opacity(
      opacity: isDisabled ? 0.5 : 1.0,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isDisabled ? null : onTap,
          borderRadius: ToastRadiusTokens.sm,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: PosColors.surface,
              borderRadius: ToastRadiusTokens.sm,
              border: Border.all(color: PosColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(effectiveIcon, size: 16, color: PosColors.text),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  label,
                  style: GoogleFonts.notoSansKr(
                    color: PosColors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Wave 1.6 Phase 3.6 — linear sibling of the legacy `ToastActionRail`
/// in `toast_primitives.dart`.
///
/// The two surfaces coexist without overlap:
/// - `ToastActionRail({actions: List<Widget>, padding:})` — legacy,
///   used by `order_workspace.dart`. Wraps via `Wrap`.
/// - `ToastActionStack({children:, axis:, alignment:})` — Wave 1.6.
///   Linear [Flex] rail with axis control and uniform [AppSpacing.sm]
///   gaps. Accepts any `Widget` in `children`, including
///   [ToastActionStackItem] or pre-built `PosActionButton`s.
///
/// Mirrors PR #55's `ToastSidebarPanel` precedent: distinct class
/// name so the legacy widget and its existing callers stay
/// untouched; consumers pick by use case.
class ToastActionStack extends StatelessWidget {
  const ToastActionStack({
    super.key,
    required this.children,
    this.axis = Axis.vertical,
    this.alignment = MainAxisAlignment.start,
  });

  final List<Widget> children;
  final Axis axis;
  final MainAxisAlignment alignment;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final separated = <Widget>[];
    for (final child in children) {
      if (separated.isNotEmpty) {
        separated.add(
          axis == Axis.vertical
              ? const SizedBox(height: AppSpacing.sm)
              : const SizedBox(width: AppSpacing.sm),
        );
      }
      separated.add(child);
    }
    return Flex(
      direction: axis,
      mainAxisAlignment: alignment,
      mainAxisSize: MainAxisSize.min,
      children: separated,
    );
  }
}

/// Wave 1.6 Phase 3.7 — additive Wave-1.6-shape sibling of the legacy
/// `PosActionButton` in `toast_primitives.dart`.
///
/// The legacy `PosActionButton({required label, required tone, …})`
/// continues to serve its existing callers and is not modified.
/// [ToastActionButton] adds the Wave 1.6 taxonomy that the migrating
/// `payment_detail_screen.dart` expects:
/// - `verb` for a `ToastActionVerb` (label and icon fallback wiring)
/// - `leading` for a custom widget that replaces the icon slot (e.g.
///   an inline spinner)
/// - `disabledReason` / `disabledVerb` / `disabledSeverity` to capture
///   why the action is blocked (stored today; renderer applies only
///   the boolean `disabled` flag — opacity + null `onPressed`)
/// - `workflowHint` / `nextStateHint` forward-compat strings stored
///   for a future tooltip or status row pass; not rendered today
///
/// Mirrors the PR #55 `ToastSidebarPanel` / PR #61 `ToastActionStack`
/// precedent: distinct class name so the existing widget's contract
/// stays untouched.
class ToastActionButton extends StatelessWidget {
  const ToastActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.leading,
    this.verb,
    this.filled,
    this.compact = false,
    this.disabled = false,
    this.disabledReason,
    this.disabledVerb,
    this.disabledSeverity,
    this.workflowHint,
    this.nextStateHint,
  });

  /// Build from a [ToastActionVerb] alone. Label defaults to the
  /// localized verb label via [toastActionVerbLabel]; icon defaults
  /// to [toastActionVerbIcon] when none is provided.
  factory ToastActionButton.verb({
    Key? key,
    required BuildContext context,
    required ToastActionVerb verb,
    required VoidCallback? onPressed,
    IconData? icon,
    Widget? leading,
    bool? filled,
    bool compact = false,
    bool disabled = false,
    ToastActionDisabledReason? disabledReason,
    ToastActionVerb? disabledVerb,
    PosActionTone? disabledSeverity,
    String? workflowHint,
    String? nextStateHint,
  }) {
    return ToastActionButton(
      key: key,
      label: toastActionVerbLabel(context, verb),
      onPressed: onPressed,
      icon: icon,
      leading: leading,
      verb: verb,
      filled: filled,
      compact: compact,
      disabled: disabled,
      disabledReason: disabledReason,
      disabledVerb: disabledVerb,
      disabledSeverity: disabledSeverity,
      workflowHint: workflowHint,
      nextStateHint: nextStateHint,
    );
  }

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Widget? leading;
  final ToastActionVerb? verb;
  final bool? filled;
  final bool compact;
  final bool disabled;
  final ToastActionDisabledReason? disabledReason;
  final ToastActionVerb? disabledVerb;

  /// Disabled severity expressed in main's existing [PosActionTone]
  /// vocabulary (from `toast_vocabulary.dart`). Stored for a future
  /// status-row pass; today's renderer does not paint a tone-tinted
  /// outline.
  final PosActionTone? disabledSeverity;

  /// Forward-compat: short label that explains where this action sits
  /// in the workflow. Stored only; not rendered today.
  final String? workflowHint;

  /// Forward-compat: short label that previews the resulting state
  /// after this action fires. Stored only; not rendered today.
  final String? nextStateHint;

  @override
  Widget build(BuildContext context) {
    final isDisabled = disabled || onPressed == null;
    final isFilled = filled ?? false;
    final effectiveLeading =
        leading ??
        ((icon != null || verb != null)
            ? Icon(
                icon ?? toastActionVerbIcon(verb!),
                size: compact ? 14 : 16,
                color: isFilled ? PosColors.canvas : PosColors.text,
              )
            : null);

    final background = isFilled ? PosColors.accent : PosColors.surface;
    final foreground = isFilled ? PosColors.canvas : PosColors.text;
    final borderColor = isFilled ? PosColors.accent : PosColors.border;

    return Opacity(
      opacity: isDisabled ? 0.5 : 1.0,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isDisabled ? null : onPressed,
          borderRadius: ToastRadiusTokens.sm,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 10 : 14,
              vertical: compact ? 6 : 10,
            ),
            decoration: BoxDecoration(
              color: background,
              borderRadius: ToastRadiusTokens.sm,
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (effectiveLeading != null) ...[
                  effectiveLeading,
                  SizedBox(width: compact ? AppSpacing.xs : AppSpacing.sm),
                ],
                Text(
                  label,
                  style: GoogleFonts.notoSansKr(
                    color: foreground,
                    fontSize: compact ? 12.5 : 13.5,
                    fontWeight: compact ? FontWeight.w700 : FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
