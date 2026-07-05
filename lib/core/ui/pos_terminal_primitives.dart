import 'dart:async';

import 'package:flutter/material.dart';

import 'pos_design_tokens.dart';

class PosTerminalShell extends StatelessWidget {
  const PosTerminalShell({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.leadingRail,
    required this.child,
    this.dark = false,
    this.padding = const EdgeInsets.all(16),
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? leadingRail;
  final Widget child;
  final bool dark;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = dark
        ? (
            shell: PosTerminalColors.darkShell,
            panel: PosTerminalColors.darkPanel,
            border: PosTerminalColors.darkBorder,
            text: PosTerminalColors.darkText,
            muted: PosTerminalColors.darkTextMuted,
          )
        : (
            shell: PosTerminalColors.lightShell,
            panel: PosTerminalColors.lightPanel,
            border: PosColors.borderStrong,
            text: PosColors.textPrimary,
            muted: PosColors.textSecondary,
          );

    return Container(
      decoration: BoxDecoration(
        color: colors.shell,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: dark ? PosTerminalColors.darkRail : colors.panel,
              border: Border(bottom: BorderSide(color: colors.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.muted, fontSize: 11),
                        ),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.titleLarge?.copyWith(color: colors.text),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (leadingRail != null) leadingRail!,
                Expanded(
                  child: Padding(padding: padding, child: child),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class PosStatusFilterItem {
  const PosStatusFilterItem({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color = PosColors.accent,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color color;
}

class PosStatusFilterBar extends StatelessWidget {
  const PosStatusFilterBar({super.key, required this.items, this.dark = false});

  final List<PosStatusFilterItem> items;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: PosDensity.statusFilterHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final item = items[index];
          final background = item.selected
              ? item.color
              : dark
              ? PosTerminalColors.darkPanel
              : PosColors.mutedSurface;
          final foreground = item.selected
              ? Colors.white
              : dark
              ? PosTerminalColors.darkTextMuted
              : PosColors.textSecondary;

          return Material(
            color: background,
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: item.onTap,
              child: Container(
                constraints: const BoxConstraints(minWidth: 72),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class PosMoneyBlock extends StatelessWidget {
  const PosMoneyBlock({
    super.key,
    required this.label,
    required this.amount,
    this.helper,
    this.color = PosColors.textPrimary,
    this.dark = false,
  });

  final String label;
  final String amount;
  final String? helper;
  final Color color;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final muted = dark
        ? PosTerminalColors.darkTextMuted
        : PosColors.textSecondary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: muted,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          amount,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: PosMoneyText.amountDue.copyWith(color: color),
        ),
        if (helper != null) ...[
          const SizedBox(height: 4),
          Text(
            helper!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: muted, fontSize: 11),
          ),
        ],
      ],
    );
  }
}

class PosActionPadItem {
  const PosActionPadItem({
    required this.label,
    required this.onTap,
    this.icon,
    this.selected = false,
    this.enabled = true,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool selected;
  final bool enabled;
}

class PosActionPad extends StatelessWidget {
  const PosActionPad({
    super.key,
    required this.items,
    this.columns = 2,
    this.dark = false,
  });

  final List<PosActionPadItem> items;
  final int columns;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio:
            PosDensity.paymentMethodTileWidth /
            PosDensity.paymentMethodTileHeight,
      ),
      itemBuilder: (context, index) {
        final item = items[index];
        final selected = item.selected;
        final background = selected
            ? PosColors.accent
            : dark
            ? PosTerminalColors.darkPanel
            : PosColors.surface;
        final foreground = selected
            ? Colors.white
            : dark
            ? PosTerminalColors.darkText
            : PosColors.textPrimary;

        return Material(
          color: item.enabled ? background : PosColors.disabledSurface,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: item.enabled ? item.onTap : null,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (item.icon != null) ...[
                    Icon(item.icon, size: 16, color: foreground),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(color: foreground),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class PosTicketLine {
  const PosTicketLine({required this.quantity, required this.label});

  final String quantity;
  final String label;
}

class PosTicketCard extends StatelessWidget {
  const PosTicketCard({
    super.key,
    required this.orderLabel,
    required this.tableLabel,
    required this.elapsedLabel,
    required this.statusLabel,
    required this.statusColor,
    required this.lines,
    this.actionLabel,
    this.onAction,
  });

  final String orderLabel;
  final String tableLabel;
  final String elapsedLabel;
  final String statusLabel;
  final Color statusColor;
  final List<PosTicketLine> lines;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(
        minHeight: PosDensity.kdsTicketMinHeight,
      ),
      decoration: BoxDecoration(
        color: PosTerminalColors.ticketPaper,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PosTerminalColors.darkBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 42,
            color: statusColor,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Text(
                  orderLabel,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    tableLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  elapsedLabel,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Text(
              statusLabel,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PosColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ...lines.map(
            (line) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      line.quantity,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      line.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          if (actionLabel != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ),
        ],
      ),
    );
  }
}

class PosDataGridRow extends StatelessWidget {
  const PosDataGridRow({
    super.key,
    required this.cells,
    this.selected = false,
    this.onTap,
    this.statusColor,
  });

  final List<Widget> cells;
  final bool selected;
  final VoidCallback? onTap;
  final Color? statusColor;

  @override
  Widget build(BuildContext context) {
    final borderColor = selected ? PosColors.accent : PosColors.border;
    return Material(
      color: selected ? PosColors.selectedRow : PosColors.surface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(
            minHeight: PosDensity.dataGridRowHeight,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: statusColor ?? borderColor,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              for (var i = 0; i < cells.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(child: cells[i]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class PosInspectorPanel extends StatelessWidget {
  const PosInspectorPanel({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
    this.primaryAction,
    this.dark = false,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final Widget? primaryAction;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final background = dark ? PosTerminalColors.darkShell : PosColors.surface;
    final foreground = dark
        ? PosTerminalColors.darkText
        : PosColors.textPrimary;
    final muted = dark
        ? PosTerminalColors.darkTextMuted
        : PosColors.textSecondary;

    return Container(
      width: PosDensity.inspectorWidth,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: dark ? PosTerminalColors.darkBorder : PosColors.borderStrong,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(color: foreground),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
          const SizedBox(height: 16),
          Expanded(
            child: ListView(padding: EdgeInsets.zero, children: children),
          ),
          if (primaryAction != null) ...[
            const SizedBox(height: 12),
            primaryAction!,
          ],
        ],
      ),
    );
  }
}

class PosFloorMapSurface extends StatelessWidget {
  const PosFloorMapSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
    this.editMode = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool editMode;

  @override
  Widget build(BuildContext context) {
    final baseFill = editMode
        ? Color.alphaBlend(
            PosColors.warning.withValues(alpha: 0.08),
            PosTerminalColors.floorCanvas,
          )
        : PosTerminalColors.floorCanvas;
    final borderColor = editMode ? PosColors.warning : PosColors.borderStrong;

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: baseFill,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderColor, width: editMode ? 2 : 1),
      ),
      child: CustomPaint(painter: _PosFloorGridPainter(), child: child),
    );
  }
}

class _PosFloorGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = PosTerminalColors.floorGrid
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 72) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y < size.height; y += 58) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// Phase 0 V2 primitives — presentation-only, no provider imports
// ---------------------------------------------------------------------------

enum PosActionTileState { idle, selected, disabled, processing, offlineBlocked }

enum PosActionTileTone { normal, destructive }

class PosActionTile extends StatefulWidget {
  const PosActionTile({
    super.key,
    required this.label,
    this.helper,
    this.icon,
    this.state = PosActionTileState.idle,
    this.tone = PosActionTileTone.normal,
    this.allowOfflineBlockedTap = false,
    this.onTap,
  });

  final String label;
  final String? helper;
  final IconData? icon;
  final PosActionTileState state;
  final PosActionTileTone tone;
  final bool allowOfflineBlockedTap;
  final VoidCallback? onTap;

  @override
  State<PosActionTile> createState() => _PosActionTileState();
}

class _PosActionTileState extends State<PosActionTile> {
  bool _pressed = false;

  bool get _interactive =>
      widget.state == PosActionTileState.idle ||
      widget.state == PosActionTileState.selected ||
      (widget.state == PosActionTileState.offlineBlocked &&
          widget.allowOfflineBlockedTap);

  PosSurfaceRole get _role {
    switch (widget.state) {
      case PosActionTileState.selected:
        return PosSurfaceRole.selected;
      case PosActionTileState.disabled:
        return PosSurfaceRole.disabled;
      case PosActionTileState.processing:
        return PosSurfaceRole.processing;
      case PosActionTileState.offlineBlocked:
        return PosSurfaceRole.disabled;
      case PosActionTileState.idle:
        return widget.tone == PosActionTileTone.destructive
            ? PosSurfaceRole.danger
            : PosSurfaceRole.action;
    }
  }

  @override
  Widget build(BuildContext context) {
    final role = _role;
    final opacity = widget.state == PosActionTileState.offlineBlocked
        ? PosTouchStateTokens.offlineBlockedOpacity
        : widget.state == PosActionTileState.disabled
        ? PosTouchStateTokens.disabledOpacity
        : 1.0;

    return Opacity(
      opacity: opacity,
      child: GestureDetector(
        onTapDown: _interactive ? (_) => setState(() => _pressed = true) : null,
        onTapUp: _interactive ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: _interactive
            ? () => setState(() => _pressed = false)
            : null,
        onTap: _interactive ? widget.onTap : null,
        child: AnimatedContainer(
          duration: PosTouchStateTokens.pressedDuration,
          constraints: const BoxConstraints(
            minHeight: PosDensity.touchTargetMin,
            minWidth: PosDensity.actionTileMinWidth,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: _pressed
                ? Color.alphaBlend(
                    Colors.black.withValues(
                      alpha: PosTouchStateTokens.pressedOverlayOpacity,
                    ),
                    role.fill,
                  )
                : role.fill,
            borderRadius: ToastRadiusTokens.sm,
            border: Border.all(
              color: role.stroke,
              width: widget.state == PosActionTileState.selected
                  ? PosTouchStateTokens.selectedBorderWidth
                  : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.state == PosActionTileState.processing) ...[
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: role.text,
                  ),
                ),
                const SizedBox(width: 8),
              ] else if (widget.icon != null) ...[
                Icon(widget.icon, size: 18, color: role.text),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(color: role.text),
                    ),
                    if (widget.helper != null)
                      Text(
                        widget.helper!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: role.helper,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PosAmountAnchor extends StatelessWidget {
  const PosAmountAnchor({
    super.key,
    required this.label,
    required this.amount,
    this.helper,
    this.role,
    this.amountStyle,
  });

  final String label;
  final String amount;
  final String? helper;
  final PosSurfaceRole? role;
  final TextStyle? amountStyle;

  @override
  Widget build(BuildContext context) {
    final r = role ?? PosSurfaceRole.operating;
    final style = amountStyle ?? PosNumericText.amountHero;

    return Container(
      constraints: const BoxConstraints(
        minHeight: PosDensity.amountAnchorMinHeight,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: r.fill,
        borderRadius: ToastRadiusTokens.md,
        border: Border.all(color: r.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: r.helper,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            amount,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style.copyWith(color: r.text),
          ),
          if (helper != null) ...[
            const SizedBox(height: 4),
            Text(
              helper!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: r.helper, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

class PosDestructiveButton extends StatefulWidget {
  const PosDestructiveButton({
    super.key,
    required this.idleLabel,
    required this.armedLabel,
    required this.onConfirm,
    this.icon,
  });

  final String idleLabel;
  final String armedLabel;
  final VoidCallback onConfirm;
  final IconData? icon;

  @override
  State<PosDestructiveButton> createState() => _PosDestructiveButtonState();
}

class _PosDestructiveButtonState extends State<PosDestructiveButton> {
  bool _armed = false;
  Timer? _disarmTimer;

  void _handleTap() {
    if (_armed) {
      _disarmTimer?.cancel();
      _disarmTimer = null;
      setState(() => _armed = false);
      widget.onConfirm();
    } else {
      setState(() => _armed = true);
      _disarmTimer = Timer(PosTouchStateTokens.destructiveConfirmTimeout, () {
        if (mounted) setState(() => _armed = false);
      });
    }
  }

  @override
  void dispose() {
    _disarmTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final role = _armed ? PosSurfaceRole.danger : PosSurfaceRole.action;
    return GestureDetector(
      onTap: _handleTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        constraints: const BoxConstraints(minHeight: PosDensity.touchTargetMin),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: role.fill,
          borderRadius: ToastRadiusTokens.sm,
          border: Border.all(
            color: role.stroke,
            width: _armed ? PosTouchStateTokens.destructiveArmedBorderWidth : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (widget.icon != null) ...[
              Icon(widget.icon, size: 18, color: role.text),
              const SizedBox(width: 8),
            ],
            Text(
              _armed ? widget.armedLabel : widget.idleLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: role.text,
                fontWeight: _armed ? FontWeight.w800 : FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
