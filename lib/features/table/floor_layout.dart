import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/models/pos_table.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../main.dart';
import 'table_order_preview.dart';

typedef TableTapCallback = void Function(PosTable table);
typedef TableMoveCallback = void Function(PosTable table, Rect normalizedRect);

int _firstActionableTableIndex(List<PosTable> tables) {
  final availableIndex = tables.indexWhere((table) => table.isAvailable);
  return availableIndex == -1 ? 0 : availableIndex;
}

class FloorLayoutView extends StatefulWidget {
  const FloorLayoutView({
    super.key,
    required this.tables,
    required this.onTapTable,
    this.onTableMoved,
    this.selectedTableId,
    this.editable = false,
    this.padding = const EdgeInsets.all(20),
    this.draftLayoutByTableId,
    this.orderPreviewByTableId = const {},
  });

  final List<PosTable> tables;
  final TableTapCallback onTapTable;
  final TableMoveCallback? onTableMoved;
  final String? selectedTableId;
  final bool editable;
  final EdgeInsets padding;
  final Map<String, Rect>? draftLayoutByTableId;
  final Map<String, TableOrderPreview> orderPreviewByTableId;

  @override
  State<FloorLayoutView> createState() => _FloorLayoutViewState();
}

class _FloorLayoutViewState extends State<FloorLayoutView> {
  final Map<String, Rect> _dragRects = <String, Rect>{};

  Rect _effectiveRect(PosTable table) {
    return widget.draftLayoutByTableId?[table.id] ??
        _dragRects[table.id] ??
        table.layoutRect;
  }

  Rect _clampRect(Rect rect) {
    final width = rect.width.clamp(0.08, 0.4);
    final height = rect.height.clamp(0.08, 0.32);
    final left = rect.left.clamp(0.0, 1.0 - width);
    final top = rect.top.clamp(0.0, 1.0 - height);
    return Rect.fromLTWH(left, top, width, height);
  }

  void _handleMove({
    required PosTable table,
    required Size canvasSize,
    required DragUpdateDetails details,
  }) {
    final currentRect = _effectiveRect(table);
    final deltaX = canvasSize.width == 0
        ? 0
        : details.delta.dx / canvasSize.width;
    final deltaY = canvasSize.height == 0
        ? 0
        : details.delta.dy / canvasSize.height;
    final nextRect = _clampRect(
      Rect.fromLTWH(
        currentRect.left + deltaX,
        currentRect.top + deltaY,
        currentRect.width,
        currentRect.height,
      ),
    );
    setState(() {
      _dragRects[table.id] = nextRect;
    });
    widget.onTableMoved?.call(table, nextRect);
  }

  @override
  Widget build(BuildContext context) {
    final sortedTables = [...widget.tables]
      ..sort((a, b) {
        final sort = a.layoutSortOrder.compareTo(b.layoutSortOrder);
        if (sort != 0) return sort;
        return a.tableNumber.compareTo(b.tableNumber);
      });
    final firstActionableTableIndex = widget.editable
        ? 0
        : _firstActionableTableIndex(sortedTables);

    return Padding(
      padding: widget.padding,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: widget.editable
              ? Color.alphaBlend(
                  PosColors.warning.withValues(alpha: 0.06),
                  PosTerminalColors.floorCanvas,
                )
              : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: widget.editable
                ? PosColors.warning.withValues(alpha: 0.55)
                : Colors.transparent,
            width: widget.editable ? 1.5 : 1,
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final canvasSize = Size(
              constraints.maxWidth,
              constraints.maxHeight,
            );
            final useCompactGrid =
                !widget.editable && constraints.maxWidth < 560;

            return ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: useCompactGrid
                  ? _CompactFloorTableGrid(
                      tables: sortedTables,
                      firstActionableTableIndex: firstActionableTableIndex,
                      selectedTableId: widget.selectedTableId,
                      orderPreviewByTableId: widget.orderPreviewByTableId,
                      onTapTable: widget.onTapTable,
                    )
                  : Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(painter: _FloorGridPainter()),
                        ),
                        for (final (index, table) in sortedTables.indexed)
                          _FloorTablePositioned(
                            key: index == firstActionableTableIndex
                                ? const Key('table_first_card')
                                : ValueKey(table.id),
                            table: table,
                            rect: _effectiveRect(table),
                            canvasSize: canvasSize,
                            orderPreview:
                                widget.orderPreviewByTableId[table.id],
                            selected: widget.selectedTableId == table.id,
                            editable: widget.editable,
                            onTap: () => widget.onTapTable(table),
                            onPanUpdate:
                                widget.editable && widget.onTableMoved != null
                                ? (details) => _handleMove(
                                    table: table,
                                    canvasSize: canvasSize,
                                    details: details,
                                  )
                                : null,
                          ),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }
}

class _CompactFloorTableGrid extends StatelessWidget {
  const _CompactFloorTableGrid({
    required this.tables,
    required this.firstActionableTableIndex,
    required this.selectedTableId,
    required this.orderPreviewByTableId,
    required this.onTapTable,
  });

  final List<PosTable> tables;
  final int firstActionableTableIndex;
  final String? selectedTableId;
  final Map<String, TableOrderPreview> orderPreviewByTableId;
  final TableTapCallback onTapTable;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth < 340 ? 2 : 3;
        return GridView.builder(
          key: const Key('floor_compact_table_grid'),
          padding: const EdgeInsets.all(10),
          itemCount: tables.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: crossAxisCount == 2 ? 1.45 : 1.28,
          ),
          itemBuilder: (context, index) {
            final table = tables[index];
            return GestureDetector(
              key: index == firstActionableTableIndex
                  ? const Key('table_first_card')
                  : ValueKey<String>('compact_table_${table.id}'),
              onTap: () => onTapTable(table),
              child: _FloorTableTile(
                table: table,
                orderPreview: orderPreviewByTableId[table.id],
                selected: selectedTableId == table.id,
                editable: false,
              ),
            );
          },
        );
      },
    );
  }
}

class _FloorTablePositioned extends StatelessWidget {
  const _FloorTablePositioned({
    super.key,
    required this.table,
    required this.rect,
    required this.canvasSize,
    required this.orderPreview,
    required this.selected,
    required this.editable,
    required this.onTap,
    this.onPanUpdate,
  });

  final PosTable table;
  final Rect rect;
  final Size canvasSize;
  final TableOrderPreview? orderPreview;
  final bool selected;
  final bool editable;
  final VoidCallback onTap;
  final GestureDragUpdateCallback? onPanUpdate;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: rect.left * canvasSize.width,
      top: rect.top * canvasSize.height,
      width: math.max(rect.width * canvasSize.width, 88),
      height: math.max(rect.height * canvasSize.height, 72),
      child: GestureDetector(
        onTap: onTap,
        onPanUpdate: onPanUpdate,
        child: Transform.rotate(
          angle: table.layoutRotation * math.pi / 180,
          child: _FloorTableTile(
            table: table,
            orderPreview: orderPreview,
            selected: selected,
            editable: editable,
          ),
        ),
      ),
    );
  }
}

class _FloorTableTile extends StatelessWidget {
  const _FloorTableTile({
    required this.table,
    required this.orderPreview,
    required this.selected,
    required this.editable,
  });

  final PosTable table;
  final TableOrderPreview? orderPreview;
  final bool selected;
  final bool editable;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final occupied = table.isOccupied;
    final reserved = table.isReserved;
    final statusLabel = occupied
        ? l10n.tablesFilterOccupied
        : reserved
        ? l10n.tablesFilterReserved
        : l10n.tablesFilterEmpty;
    final statusColor = occupied
        ? PosColors.info
        : reserved
        ? PosColors.warning
        : PosColors.success;
    final borderColor = selected
        ? PosColors.accent
        : reserved
        ? PosColors.warning.withValues(alpha: 0.55)
        : occupied
        ? AppColors.statusInfo.withValues(alpha: 0.45)
        : AppColors.surface3;
    final background = selected
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: 0.42),
            PosColors.accentMuted,
          )
        : occupied
        ? AppColors.surface1
        : reserved
        ? Color.alphaBlend(
            PosColors.warning.withValues(alpha: 0.10),
            AppColors.surface0,
          )
        : AppColors.surface0;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        shape: table.layoutShape == PosTableShape.round
            ? BoxShape.circle
            : BoxShape.rectangle,
        borderRadius: table.layoutShape == PosTableShape.round
            ? null
            : BorderRadius.circular(18),
        border: Border.all(color: borderColor, width: selected ? 2.6 : 1.2),
        boxShadow: [
          BoxShadow(
            color: selected
                ? PosColors.accent.withValues(alpha: 0.18)
                : Colors.black.withValues(alpha: 0.06),
            blurRadius: selected ? 28 : 14,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxHeight < 88 || constraints.maxWidth < 112;
            final activePreview =
                orderPreview != null && orderPreview!.itemCount > 0
                ? orderPreview
                : null;

            if (compact) {
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      table.tableNumber,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: PosNumericText.tableId.copyWith(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (activePreview == null)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: _FloorStatusBadge(
                        label: statusLabel,
                        color: statusColor,
                        compact: true,
                      ),
                    )
                  else
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: _OrderCountBadge(count: activePreview.itemCount),
                    ),
                ],
              );
            }

            final previewMaxHeight = math.max(26.0, constraints.maxHeight - 74);

            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      table.tableNumber,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: PosNumericText.tableId.copyWith(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ),
                if (activePreview == null) ...[
                  const SizedBox(height: 4),
                  Text(
                    l10n.waiterSeatCount(table.seatCount ?? 0),
                    textAlign: TextAlign.center,
                    style: AppFonts.system(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                ] else
                  const SizedBox(height: 3),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: _FloorStatusBadge(
                        label: statusLabel,
                        color: statusColor,
                      ),
                    ),
                    if (editable) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.open_with_rounded,
                        size: 11,
                        color: AppColors.textSecondary,
                      ),
                    ],
                  ],
                ),
                if (activePreview != null) ...[
                  const SizedBox(height: 5),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: previewMaxHeight),
                    child: _TableOrderPreviewChip(preview: activePreview),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _FloorStatusBadge extends StatelessWidget {
  const _FloorStatusBadge({
    required this.label,
    required this.color,
    this.compact = false,
  });

  final String label;
  final Color color;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.42)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: compact ? 5 : 6,
            height: compact ? 5 : 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.system(
                color: color,
                fontSize: compact ? 9 : 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderCountBadge extends StatelessWidget {
  const _OrderCountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: PosColors.accent.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: PosColors.accent.withValues(alpha: 0.42)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.restaurant_menu, size: 11, color: PosColors.accent),
          const SizedBox(width: 3),
          Text(
            '$count',
            style: AppFonts.system(
              color: PosColors.accent,
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _TableOrderPreviewChip extends StatelessWidget {
  const _TableOrderPreviewChip({required this.preview});

  final TableOrderPreview preview;

  @override
  Widget build(BuildContext context) {
    final visibleLines = preview.lines.take(2).toList();
    final hiddenCount = preview.lines.length - visibleLines.length;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      decoration: BoxDecoration(
        color: PosColors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: PosColors.accent.withValues(alpha: 0.32)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.restaurant_menu, size: 12, color: PosColors.accent),
              const SizedBox(width: 4),
              Text(
                '${preview.itemCount}',
                style: AppFonts.system(
                  color: PosColors.accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          for (final line in visibleLines)
            Text(
              '${line.label} x${line.quantity}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.system(
                color: PosColors.textSecondary,
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (hiddenCount > 0)
            Text(
              '+$hiddenCount',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.system(
                color: PosColors.textMuted,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    );
  }
}

class _FloorGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = AppColors.surface3.withValues(alpha: 0.55)
      ..strokeWidth = 1;

    const step = 72.0;
    for (double x = step; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = step; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
