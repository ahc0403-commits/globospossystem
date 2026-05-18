import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/models/pos_table.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../main.dart';

typedef TableTapCallback = void Function(PosTable table);
typedef TableMoveCallback = void Function(PosTable table, Rect normalizedRect);

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
  });

  final List<PosTable> tables;
  final TableTapCallback onTapTable;
  final TableMoveCallback? onTableMoved;
  final String? selectedTableId;
  final bool editable;
  final EdgeInsets padding;
  final Map<String, Rect>? draftLayoutByTableId;

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

    return Padding(
      padding: widget.padding,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surface1,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppColors.surface3),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final canvasSize = Size(
              constraints.maxWidth,
              constraints.maxHeight,
            );

            return ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(painter: _FloorGridPainter()),
                  ),
                  for (final (index, table) in sortedTables.indexed)
                    _FloorTablePositioned(
                      key: index == 0
                          ? const Key('table_first_card')
                          : ValueKey(table.id),
                      table: table,
                      rect: _effectiveRect(table),
                      canvasSize: canvasSize,
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

class _FloorTablePositioned extends StatelessWidget {
  const _FloorTablePositioned({
    super.key,
    required this.table,
    required this.rect,
    required this.canvasSize,
    required this.selected,
    required this.editable,
    required this.onTap,
    this.onPanUpdate,
  });

  final PosTable table;
  final Rect rect;
  final Size canvasSize;
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
    required this.selected,
    required this.editable,
  });

  final PosTable table;
  final bool selected;
  final bool editable;

  @override
  Widget build(BuildContext context) {
    final occupied = table.isOccupied;
    final borderColor = selected
        ? PosColors.accent
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

            if (compact) {
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      table.tableNumber,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: occupied
                          ? AppColors.statusInfo
                          : AppColors.statusAvailable,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              );
            }

            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  table.tableNumber,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${table.seatCount ?? 0} seats',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: occupied
                            ? AppColors.statusInfo
                            : AppColors.statusAvailable,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        editable
                            ? (occupied
                                  ? 'Occupied · drag'
                                  : 'Available · drag')
                            : (occupied ? 'Occupied' : 'Available'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textSecondary,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
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
