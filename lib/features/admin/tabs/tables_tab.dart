import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../core/services/table_qr_export_service.dart';
import '../../../core/services/tables_service.dart';
import '../../../core/ui/pos_design_tokens.dart';
import '../../../core/ui/toast/toast.dart';
import '../../../core/utils/number_input_utils.dart';
import '../../../main.dart';
import '../../../l10n/app_localizations.dart';
import '../../../widgets/error_toast.dart';
import '../../auth/auth_provider.dart';
import '../../order/order_provider.dart';
import '../../table/floor_layout.dart';
import '../../table/table_model.dart';
import '../providers/admin_audit_provider.dart';
import '../providers/tables_provider.dart';
import '../widgets/admin_audit_trace_panel.dart';

typedef _LayoutAdjustmentCallback =
    void Function({double widthDelta, double heightDelta, int rotationDelta});

class TablesTab extends ConsumerStatefulWidget {
  const TablesTab({super.key});

  @override
  ConsumerState<TablesTab> createState() => _TablesTabState();
}

class _TablesTabState extends ConsumerState<TablesTab> {
  PosTable? _selectedTable;
  bool _showOrderPanel = false;
  bool _layoutEditMode = false;
  bool _showListView = false;
  String _tableFilter = 'all';
  String? _initializedRestaurantId;
  String? _lastTablesError;
  String? _lastOrderError;
  final Map<String, Rect> _draftLayoutByTableId = <String, Rect>{};
  final Map<String, int> _draftRotationByTableId = <String, int>{};

  void _ensureLoaded(String? storeId) {
    if (storeId == null || _initializedRestaurantId == storeId) {
      return;
    }
    _initializedRestaurantId = storeId;
    Future.microtask(() {
      ref.read(tablesProvider(storeId).notifier).fetchTables();
      ref.read(orderProvider.notifier).clearSession();
    });
  }

  Future<void> _onTapTable(Map<String, dynamic> table, String storeId) async {
    final resolvedTable = PosTable.fromJson(Map<String, dynamic>.from(table));
    final tableId = resolvedTable.id;
    if (tableId.isEmpty) {
      return;
    }

    setState(() {
      _selectedTable = resolvedTable.storeId.isEmpty
          ? PosTable(
              id: resolvedTable.id,
              storeId: storeId,
              tableNumber: resolvedTable.tableNumber,
              seatCount: resolvedTable.seatCount,
              status: resolvedTable.status,
              floorLabel: resolvedTable.floorLabel,
              layoutX: resolvedTable.layoutX,
              layoutY: resolvedTable.layoutY,
              layoutW: resolvedTable.layoutW,
              layoutH: resolvedTable.layoutH,
              layoutRotation: resolvedTable.layoutRotation,
              layoutShape: resolvedTable.layoutShape,
              layoutSortOrder: resolvedTable.layoutSortOrder,
            )
          : resolvedTable;
      _showOrderPanel = true;
    });

    await ref.read(orderProvider.notifier).loadActiveOrder(tableId, storeId);
  }

  void _closeOrderPanel() {
    ref.read(orderProvider.notifier).clearSession();
    setState(() {
      _showOrderPanel = false;
      _selectedTable = null;
    });
  }

  void _selectTableForLayout(Map<String, dynamic> table) {
    final resolvedTable = PosTable.fromJson(Map<String, dynamic>.from(table));
    final draftRect = _draftLayoutByTableId[resolvedTable.id];
    final draftRotation = _draftRotationByTableId[resolvedTable.id];
    setState(() {
      _selectedTable = draftRect == null && draftRotation == null
          ? resolvedTable
          : resolvedTable.copyWithLayout(
              draftRect ?? resolvedTable.layoutRect,
              layoutRotation: draftRotation,
            );
      _showOrderPanel = false;
    });
  }

  List<PosTable> _layoutTables(List<Map<String, dynamic>> tables) {
    final merged = tables
        .map((row) => PosTable.fromJson(Map<String, dynamic>.from(row)))
        .map((table) {
          final draft = _draftLayoutByTableId[table.id];
          final rotation = _draftRotationByTableId[table.id];
          return draft == null && rotation == null
              ? table
              : table.copyWithLayout(
                  draft ?? table.layoutRect,
                  layoutRotation: rotation,
                );
        })
        .toList();

    merged.sort((a, b) {
      final yCompare = a.layoutY.compareTo(b.layoutY);
      if ((a.layoutY - b.layoutY).abs() > 0.04) {
        return yCompare;
      }
      final xCompare = a.layoutX.compareTo(b.layoutX);
      if (xCompare != 0) {
        return xCompare;
      }
      return a.tableNumber.compareTo(b.tableNumber);
    });
    return merged;
  }

  Future<void> _saveDraftLayout(
    TablesNotifier tablesNotifier,
    List<Map<String, dynamic>> tables,
  ) async {
    if (_draftLayoutByTableId.isEmpty) {
      return;
    }

    final layoutTables = _layoutTables(tables);
    var success = true;
    for (final (index, table) in layoutTables.indexed) {
      success =
          await tablesNotifier.updateTableLayout(
            tableId: table.id,
            layoutX: table.layoutX,
            layoutY: table.layoutY,
            layoutW: table.layoutW,
            layoutH: table.layoutH,
            layoutRotation: table.layoutRotation,
            layoutShape: table.layoutShape.name,
            layoutSortOrder: index,
            refresh: false,
          ) &&
          success;
    }

    if (!success) {
      return;
    }

    await tablesNotifier.fetchTables();
    if (!mounted) {
      return;
    }
    setState(() {
      _draftLayoutByTableId.clear();
      _draftRotationByTableId.clear();
      _layoutEditMode = false;
    });
    showSuccessToast(context, context.l10n.tablesLayoutSaved);
  }

  Rect _clampLayoutRect(Rect rect) {
    final width = rect.width.clamp(0.08, 0.4);
    final height = rect.height.clamp(0.08, 0.32);
    final left = rect.left.clamp(0.0, 1.0 - width);
    final top = rect.top.clamp(0.0, 1.0 - height);
    return Rect.fromLTWH(left, top, width, height);
  }

  void _adjustSelectedTableLayout(
    PosTable table, {
    double widthDelta = 0,
    double heightDelta = 0,
    int rotationDelta = 0,
  }) {
    final currentRect = _draftLayoutByTableId[table.id] ?? table.layoutRect;
    final center = currentRect.center;
    final nextWidth = (currentRect.width + widthDelta).clamp(0.08, 0.4);
    final nextHeight = (currentRect.height + heightDelta).clamp(0.08, 0.32);
    final nextRect = _clampLayoutRect(
      Rect.fromCenter(
        center: center,
        width: nextWidth.toDouble(),
        height: nextHeight.toDouble(),
      ),
    );
    final baseRotation =
        _draftRotationByTableId[table.id] ?? table.layoutRotation;
    final nextRotation = PosTable.normalizeLayoutRotation(
      baseRotation + rotationDelta,
    );

    setState(() {
      _draftLayoutByTableId[table.id] = nextRect;
      _draftRotationByTableId[table.id] = nextRotation;
      _selectedTable = table.copyWithLayout(
        nextRect,
        layoutRotation: nextRotation,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final storeId = ref.watch(authProvider).storeId;
    _ensureLoaded(storeId);

    if (storeId == null) {
      return const _RestaurantMissingView();
    }

    final tablesState = ref.watch(tablesProvider(storeId));
    final tablesNotifier = ref.read(tablesProvider(storeId).notifier);
    final auditTraceAsync = ref.watch(adminAuditTraceProvider(storeId));
    final orderState = ref.watch(orderProvider);

    if (tablesState.error != null &&
        tablesState.error!.isNotEmpty &&
        tablesState.error != _lastTablesError) {
      _lastTablesError = tablesState.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showErrorToast(context, tablesState.error!);
        }
      });
    }

    if (orderState.error != null &&
        orderState.error!.isNotEmpty &&
        orderState.error != _lastOrderError) {
      _lastOrderError = orderState.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showErrorToast(context, orderState.error!);
        }
      });
    }
    final selectedTable = _resolveSelectedTable(tablesState.tables);

    return Scaffold(
      key: const Key('admin_tables_root'),
      backgroundColor: AppColors.surface0,
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: ToastResponsiveBody(
          maxWidth: 1480,
          padding: const EdgeInsets.all(16),
          child: _showOrderPanel && selectedTable != null
              ? Row(
                  key: ValueKey<String>('admin-order-${selectedTable.id}'),
                  children: [
                    Expanded(
                      flex: 5,
                      child: _buildTableGrid(
                        tablesState: tablesState,
                        tablesNotifier: tablesNotifier,
                        storeId: storeId,
                        auditTraceAsync: auditTraceAsync,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 6,
                      child: _AdminTableOperationsPanel(
                        table: selectedTable,
                        orderState: orderState,
                        onClose: _closeOrderPanel,
                      ),
                    ),
                  ],
                )
              : _buildTableGrid(
                  key: const ValueKey<String>('admin-table-grid'),
                  tablesState: tablesState,
                  tablesNotifier: tablesNotifier,
                  storeId: storeId,
                  auditTraceAsync: auditTraceAsync,
                ),
        ),
      ),
    );
  }

  PosTable? _resolveSelectedTable(List<Map<String, dynamic>> tables) {
    final selected = _selectedTable;
    if (selected == null) return null;

    for (final table in tables) {
      final id = table['id']?.toString() ?? '';
      if (id != selected.id) continue;
      final resolved = PosTable.fromJson(Map<String, dynamic>.from(table));
      final draft = _draftLayoutByTableId[id];
      final rotation = _draftRotationByTableId[id];
      return draft == null && rotation == null
          ? resolved
          : resolved.copyWithLayout(
              draft ?? resolved.layoutRect,
              layoutRotation: rotation,
            );
    }
    return selected;
  }

  bool _matchesTableFilter(PosTable table) {
    return switch (_tableFilter) {
      'occupied' => table.isOccupied,
      'reserved' => table.isReserved,
      'empty' => table.isAvailable,
      _ => true,
    };
  }

  String _tableStatusLabel(PosTable table) {
    final l10n = context.l10n;
    return switch (table.status) {
      'occupied' => l10n.tablesFilterOccupied,
      'reserved' => l10n.tablesFilterReserved,
      _ => l10n.tablesFilterEmpty,
    };
  }

  Color _tableStatusColor(PosTable table) {
    return switch (table.status) {
      'occupied' => PosColors.success,
      'reserved' => PosColors.warning,
      _ => PosColors.textSecondary,
    };
  }

  Widget _buildTableGrid({
    Key? key,
    required TablesState tablesState,
    required TablesNotifier tablesNotifier,
    required String storeId,
    required AsyncValue<List<Map<String, dynamic>>> auditTraceAsync,
  }) {
    if (tablesState.isLoading && tablesState.tables.isEmpty) {
      return ToastOperationalLoadingState(label: context.l10n.waiterLoading);
    }

    if (tablesState.error != null && tablesState.tables.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.l10n.tablesLoadFailed,
              style: AppFonts.system(
                color: AppColors.statusCancelled,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: tablesNotifier.fetchTables,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              child: Text(context.l10n.retry),
            ),
          ],
        ),
      );
    }

    if (tablesState.tables.isEmpty) {
      return ToastOperationalEmptyState(
        headline: context.l10n.tablesNoTablesTitle,
        icon: Icons.table_restaurant,
      );
    }

    final layoutTables = _layoutTables(tablesState.tables);
    final filteredTables = layoutTables.where(_matchesTableFilter).toList();
    final occupiedCount = layoutTables
        .where((table) => table.isOccupied)
        .length;
    final reservedCount = layoutTables
        .where((table) => table.isReserved)
        .length;
    final emptyCount = layoutTables.length - occupiedCount - reservedCount;
    final selectedTable = _resolveSelectedTable(tablesState.tables);

    return Column(
      key: key,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: _buildTableCommandHeader(
            totalCount: layoutTables.length,
            occupiedCount: occupiedCount,
            reservedCount: reservedCount,
            emptyCount: emptyCount,
            tablesState: tablesState,
            tablesNotifier: tablesNotifier,
            auditTraceAsync: auditTraceAsync,
          ),
        ),
        Expanded(
          child: _showListView
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: PosTableShell(
                    columns: [
                      ToastQueueColumn(label: context.l10n.table, flex: 4),
                      ToastQueueColumn(
                        label: context.l10n.tablesSeatCount,
                        flex: 2,
                      ),
                      ToastQueueColumn(label: context.l10n.status, flex: 3),
                    ],
                    rows: filteredTables
                        .map(
                          (table) => ToastQueueRow(
                            id: table.id,
                            cells: [
                              Text(
                                table.tableNumber,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              Text(
                                context.l10n.waiterSeatCount(
                                  table.seatCount ?? 0,
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: ToastStatusBadge(
                                  label: _tableStatusLabel(table),
                                  color: _tableStatusColor(table),
                                  compact: true,
                                ),
                              ),
                            ],
                          ),
                        )
                        .toList(),
                    selectedId: _selectedTable?.id,
                    onSelect: (tableId) {
                      final row = tablesState.tables.firstWhere(
                        (item) => item['id']?.toString() == tableId,
                      );
                      if (_layoutEditMode) {
                        _selectTableForLayout(row);
                      } else {
                        _onTapTable(row, storeId);
                      }
                    },
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    const minimumCanvasHeight = 320.0;
                    final needsScroll =
                        constraints.maxHeight < minimumCanvasHeight;
                    final showInspector = constraints.maxWidth >= 980;
                    final floor = SizedBox(
                      height: needsScroll
                          ? minimumCanvasHeight
                          : constraints.maxHeight,
                      child: PosFloorMapSurface(
                        editMode: _layoutEditMode,
                        padding: EdgeInsets.zero,
                        child: FloorLayoutView(
                          tables: filteredTables,
                          selectedTableId: _selectedTable?.id,
                          editable: _layoutEditMode,
                          draftLayoutByTableId: _draftLayoutByTableId,
                          onTapTable: (table) {
                            final row = tablesState.tables.firstWhere(
                              (item) => item['id']?.toString() == table.id,
                            );
                            if (_layoutEditMode) {
                              _selectTableForLayout(row);
                            } else {
                              _onTapTable(row, storeId);
                            }
                          },
                          onTableMoved: !_layoutEditMode
                              ? null
                              : (table, rect) {
                                  final rotation =
                                      _draftRotationByTableId[table.id];
                                  setState(() {
                                    _selectedTable = table.copyWithLayout(
                                      rect,
                                      layoutRotation: rotation,
                                    );
                                    _draftLayoutByTableId[table.id] = rect;
                                  });
                                },
                        ),
                      ),
                    );

                    final floorSurface = needsScroll
                        ? SingleChildScrollView(child: floor)
                        : floor;

                    if (!showInspector) {
                      return floorSurface;
                    }

                    final inspector = selectedTable == null
                        ? _AdminFloorOverviewInspector(
                            totalCount: layoutTables.length,
                            occupiedCount: occupiedCount,
                            reservedCount: reservedCount,
                            emptyCount: emptyCount,
                            occupiedTables: layoutTables
                                .where((table) => table.isOccupied)
                                .toList(),
                            onSelectTable: (table) {
                              final row = tablesState.tables.firstWhere(
                                (item) => item['id']?.toString() == table.id,
                              );
                              if (_layoutEditMode) {
                                _selectTableForLayout(row);
                              } else {
                                _onTapTable(row, storeId);
                              }
                            },
                          )
                        : _AdminFloorSelectionInspector(
                            table: selectedTable,
                            layoutEditMode: _layoutEditMode,
                            statusLabel: _tableStatusLabel(selectedTable),
                            statusColor: _tableStatusColor(selectedTable),
                            onAdjustLayout: _layoutEditMode
                                ? ({
                                    double heightDelta = 0,
                                    int rotationDelta = 0,
                                    double widthDelta = 0,
                                  }) => _adjustSelectedTableLayout(
                                    selectedTable,
                                    widthDelta: widthDelta,
                                    heightDelta: heightDelta,
                                    rotationDelta: rotationDelta,
                                  )
                                : null,
                          );

                    return Row(
                      children: [
                        Expanded(child: floorSurface),
                        const SizedBox(width: 12),
                        inspector,
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildTableCommandHeader({
    required int totalCount,
    required int occupiedCount,
    required int reservedCount,
    required int emptyCount,
    required TablesState tablesState,
    required TablesNotifier tablesNotifier,
    required AsyncValue<List<Map<String, dynamic>>> auditTraceAsync,
  }) {
    final l10n = context.l10n;
    final hasDraft =
        _draftLayoutByTableId.isNotEmpty || _draftRotationByTableId.isNotEmpty;
    final selectedTable = _selectedTable;

    return ToastWorkSurface(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      backgroundColor: AppColors.surface1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.tablesManagementTitle,
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _layoutEditMode
                          ? l10n.tablesManagementEditSubtitle
                          : l10n.tablesManagementMonitorSubtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PosColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ToastStatusBadge(
                label: _layoutEditMode
                    ? l10n.tablesLayoutEditMode
                    : l10n.tablesOperationMonitor,
                color: _layoutEditMode ? PosColors.warning : PosColors.info,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 14),
          ToastMetricStrip(
            metrics: [
              ToastMetric(label: l10n.tablesTotalTables, value: '$totalCount'),
              ToastMetric(
                label: l10n.tablesFilterOccupied,
                value: '$occupiedCount',
                tone: PosColors.success,
              ),
              ToastMetric(
                label: l10n.tablesFilterReserved,
                value: '$reservedCount',
                tone: reservedCount > 0
                    ? PosColors.warning
                    : PosColors.textSecondary,
              ),
              ToastMetric(
                label: l10n.tablesFilterEmpty,
                value: '$emptyCount',
                tone: PosColors.accent,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ToastFilterChip(
                label: l10n.all,
                selected: _tableFilter == 'all',
                count: totalCount,
                onSelected: () => setState(() => _tableFilter = 'all'),
              ),
              ToastFilterChip(
                label: l10n.tablesFilterOccupied,
                selected: _tableFilter == 'occupied',
                count: occupiedCount,
                onSelected: () => setState(() => _tableFilter = 'occupied'),
              ),
              ToastFilterChip(
                label: l10n.tablesFilterReserved,
                selected: _tableFilter == 'reserved',
                count: reservedCount,
                onSelected: () => setState(() => _tableFilter = 'reserved'),
              ),
              ToastFilterChip(
                label: l10n.tablesFilterEmpty,
                selected: _tableFilter == 'empty',
                count: emptyCount,
                onSelected: () => setState(() => _tableFilter = 'empty'),
              ),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                    value: false,
                    icon: const Icon(Icons.grid_view_rounded),
                    label: Text(l10n.tablesViewGrid),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: const Icon(Icons.view_list_rounded),
                    label: Text(l10n.tablesViewList),
                  ),
                ],
                selected: {_showListView},
                onSelectionChanged: (values) {
                  setState(() => _showListView = values.first);
                },
              ),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                    value: false,
                    icon: const Icon(Icons.visibility_outlined),
                    label: Text(l10n.tablesModeStatus),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: const Icon(Icons.edit_location_alt_outlined),
                    label: Text(l10n.tablesModeEdit),
                  ),
                ],
                selected: {_layoutEditMode},
                onSelectionChanged: (values) {
                  setState(() {
                    _layoutEditMode = values.first;
                    _draftLayoutByTableId.clear();
                    _draftRotationByTableId.clear();
                    if (_layoutEditMode) {
                      _showOrderPanel = false;
                    }
                  });
                },
              ),
              FilledButton.icon(
                onPressed: () => _showAddTableDialog(context, tablesNotifier),
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.tablesAddTitle),
              ),
              if (!_layoutEditMode)
                FilledButton.icon(
                  key: const Key('admin_tables_qr_batch_export_action'),
                  onPressed: () => _exportAllTableQrs(
                    context,
                    tablesNotifier,
                    tablesState.tables,
                  ),
                  icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                  label: Text(l10n.tablesQrBatchAction),
                ),
              if (!_layoutEditMode && selectedTable != null)
                OutlinedButton.icon(
                  key: const Key('admin_tables_edit_floor_label_action'),
                  onPressed: () => _showEditTableDialog(
                    context,
                    tablesNotifier,
                    selectedTable,
                  ),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: Text(l10n.tablesEditTable),
                ),
              if (!_layoutEditMode && selectedTable != null)
                OutlinedButton.icon(
                  key: const Key('admin_tables_generate_qr_action'),
                  onPressed: () => _showTableQrDialog(
                    context,
                    tablesNotifier,
                    selectedTable,
                  ),
                  icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                  label: Text(l10n.tablesQrCurrentAction),
                ),
              if (!_layoutEditMode &&
                  selectedTable != null &&
                  !selectedTable.isOccupied)
                OutlinedButton.icon(
                  key: const Key('admin_tables_toggle_reservation'),
                  onPressed: () async {
                    final nextStatus = selectedTable.isReserved
                        ? 'available'
                        : 'reserved';
                    final success = await tablesNotifier.updateTableStatus(
                      selectedTable.id,
                      nextStatus,
                    );
                    if (!mounted || !success) {
                      return;
                    }
                    setState(() {
                      _selectedTable = PosTable(
                        id: selectedTable.id,
                        storeId: selectedTable.storeId,
                        tableNumber: selectedTable.tableNumber,
                        seatCount: selectedTable.seatCount,
                        status: nextStatus,
                        floorLabel: selectedTable.floorLabel,
                        layoutX: selectedTable.layoutX,
                        layoutY: selectedTable.layoutY,
                        layoutW: selectedTable.layoutW,
                        layoutH: selectedTable.layoutH,
                        layoutRotation: selectedTable.layoutRotation,
                        layoutShape: selectedTable.layoutShape,
                        layoutSortOrder: selectedTable.layoutSortOrder,
                      );
                    });
                    showSuccessToast(
                      context,
                      nextStatus == 'reserved'
                          ? l10n.tablesReserved(selectedTable.tableNumber)
                          : l10n.tablesReservationCleared(
                              selectedTable.tableNumber,
                            ),
                    );
                  },
                  icon: Icon(
                    selectedTable.isReserved
                        ? Icons.event_available_outlined
                        : Icons.event_busy_outlined,
                    size: 18,
                  ),
                  label: Text(
                    selectedTable.isReserved
                        ? l10n.tablesReleaseReservation
                        : l10n.tablesReserveSelected,
                  ),
                ),
              if (_layoutEditMode)
                PosActionTile(
                  key: const Key('admin_tables_save_layout_action'),
                  label: l10n.tablesSaveLayout,
                  helper: hasDraft
                      ? l10n.tablesLayoutEditActiveTitle
                      : l10n.tablesResetDraft,
                  icon: Icons.save_outlined,
                  state: hasDraft
                      ? PosActionTileState.selected
                      : PosActionTileState.disabled,
                  onTap: hasDraft
                      ? () =>
                            _saveDraftLayout(tablesNotifier, tablesState.tables)
                      : null,
                ),
              if (_layoutEditMode)
                OutlinedButton.icon(
                  onPressed: hasDraft
                      ? () {
                          setState(() {
                            _draftLayoutByTableId.clear();
                            _draftRotationByTableId.clear();
                          });
                        }
                      : null,
                  icon: const Icon(Icons.undo_outlined, size: 18),
                  label: Text(l10n.tablesResetDraft),
                ),
              if (_layoutEditMode && selectedTable != null)
                OutlinedButton.icon(
                  onPressed: () async {
                    final selectedId = selectedTable.id;
                    final selectedNumber = selectedTable.tableNumber;
                    final success = await tablesNotifier.deleteTable(
                      selectedId,
                    );
                    if (!mounted || !success) {
                      return;
                    }
                    setState(() {
                      _draftLayoutByTableId.remove(selectedId);
                      _draftRotationByTableId.remove(selectedId);
                      _selectedTable = null;
                    });
                    showSuccessToast(
                      context,
                      l10n.tablesDeleted(selectedNumber),
                    );
                  },
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: Text(l10n.tablesDeleteSelected),
                ),
            ],
          ),
          if (_layoutEditMode) ...[
            const SizedBox(height: 12),
            PosExceptionAlert(
              label: l10n.tablesLayoutEditActiveTitle,
              detail: l10n.tablesLayoutEditActiveDetail,
              color: PosColors.info,
              icon: Icons.grid_view_rounded,
            ),
            const SizedBox(height: 10),
            _buildAdminTablesAuditDetail(auditTraceAsync),
          ],
        ],
      ),
    );
  }

  Widget _buildAdminTablesAuditDetail(
    AsyncValue<List<Map<String, dynamic>>> auditTraceAsync,
  ) {
    final l10n = context.l10n;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: ExpansionTile(
        key: const Key('admin_tables_audit_secondary_detail'),
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        iconColor: AppColors.textSecondary,
        collapsedIconColor: AppColors.textSecondary,
        title: Text(
          l10n.tablesRecentChanges,
          style: AppFonts.system(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          l10n.tablesRecentChangesHint,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppFonts.system(color: AppColors.textSecondary, fontSize: 12),
        ),
        children: [
          AdminAuditTracePanel(
            auditTraceAsync: auditTraceAsync,
            allowedEntityTypes: const {'tables'},
            maxItems: 3,
            compact: true,
            emptyMessage: l10n.tablesNoRecentChanges,
          ),
        ],
      ),
    );
  }

  Future<void> _showAddTableDialog(
    BuildContext context,
    TablesNotifier tablesNotifier,
  ) async {
    final l10n = context.l10n;
    final tableController = TextEditingController();
    final seatController = TextEditingController();
    final floorController = TextEditingController(text: '1F');

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface1,
          title: Text(
            l10n.tablesAddTitle,
            style: AppFonts.system(color: AppColors.textPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: tableController,
                style: AppFonts.system(color: AppColors.textPrimary),
                decoration: InputDecoration(labelText: l10n.tablesTableNumber),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: seatController,
                keyboardType: TextInputType.number,
                style: AppFonts.system(color: AppColors.textPrimary),
                decoration: InputDecoration(labelText: l10n.tablesSeatCount),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('admin_table_floor_label_field'),
                controller: floorController,
                textCapitalization: TextCapitalization.characters,
                style: AppFonts.system(color: AppColors.textPrimary),
                decoration: InputDecoration(labelText: l10n.tablesFloorLabel),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              onPressed: () async {
                final tableNumber = tableController.text.trim();
                final seatCount = parseIntInput(seatController.text);
                final floorLabel = floorController.text.trim();
                if (tableNumber.isEmpty ||
                    seatCount == null ||
                    seatCount <= 0 ||
                    floorLabel.isEmpty) {
                  showErrorToast(context, l10n.tablesInvalidTableAndSeat);
                  return;
                }

                final success = await tablesNotifier.addTable(
                  tableNumber,
                  seatCount,
                  floorLabel: floorLabel,
                );
                if (context.mounted) {
                  if (success) {
                    Navigator.of(context).pop();
                    showSuccessToast(context, l10n.tablesAdded(tableNumber));
                  }
                }
              },
              child: Text(l10n.add),
            ),
          ],
        );
      },
    );

    tableController.dispose();
    seatController.dispose();
    floorController.dispose();
  }

  Future<void> _showEditTableDialog(
    BuildContext context,
    TablesNotifier tablesNotifier,
    PosTable table,
  ) async {
    final l10n = context.l10n;
    final tableController = TextEditingController(text: table.tableNumber);
    final seatController = TextEditingController(
      text: (table.seatCount ?? 0).toString(),
    );
    final floorController = TextEditingController(text: table.floorLabel);

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface1,
          title: Text(
            l10n.tablesEditTable,
            style: AppFonts.system(color: AppColors.textPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: tableController,
                style: AppFonts.system(color: AppColors.textPrimary),
                decoration: InputDecoration(labelText: l10n.tablesTableNumber),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: seatController,
                keyboardType: TextInputType.number,
                style: AppFonts.system(color: AppColors.textPrimary),
                decoration: InputDecoration(labelText: l10n.tablesSeatCount),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('admin_table_edit_floor_label_field'),
                controller: floorController,
                textCapitalization: TextCapitalization.characters,
                style: AppFonts.system(color: AppColors.textPrimary),
                decoration: InputDecoration(labelText: l10n.tablesFloorLabel),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              onPressed: () async {
                final tableNumber = tableController.text.trim();
                final seatCount = parseIntInput(seatController.text);
                final floorLabel = floorController.text.trim();
                if (tableNumber.isEmpty ||
                    seatCount == null ||
                    seatCount <= 0 ||
                    floorLabel.isEmpty) {
                  showErrorToast(context, l10n.tablesInvalidTableAndSeat);
                  return;
                }

                final success = await tablesNotifier.updateTableDetails(
                  tableId: table.id,
                  tableNumber: tableNumber,
                  seatCount: seatCount,
                  floorLabel: floorLabel,
                );
                if (!context.mounted || !success) {
                  return;
                }
                Navigator.of(context).pop();
                setState(() {
                  _selectedTable = PosTable(
                    id: table.id,
                    storeId: table.storeId,
                    tableNumber: tableNumber,
                    seatCount: seatCount,
                    status: table.status,
                    floorLabel: floorLabel,
                    layoutX: table.layoutX,
                    layoutY: table.layoutY,
                    layoutW: table.layoutW,
                    layoutH: table.layoutH,
                    layoutRotation: table.layoutRotation,
                    layoutShape: table.layoutShape,
                    layoutSortOrder: table.layoutSortOrder,
                  );
                });
                showSuccessToast(context, l10n.tablesUpdated);
              },
              child: Text(l10n.save),
            ),
          ],
        );
      },
    );

    tableController.dispose();
    seatController.dispose();
    floorController.dispose();
  }

  Future<void> _showTableQrDialog(
    BuildContext context,
    TablesNotifier tablesNotifier,
    PosTable table,
  ) async {
    final l10n = context.l10n;
    TableQrCardModel card;
    try {
      final rows = await tablesService.getOrCreateTableQrs(
        storeId: tablesNotifier.storeId,
        tableIds: [table.id],
      );
      if (rows.length != 1) {
        throw const FormatException('TABLE_QR_FIELD_REQUIRED:table_id');
      }
      card = tableQrExportService.cardsFromRpcRows(rows).single;
    } catch (error) {
      if (context.mounted) {
        showErrorToast(context, _tableQrErrorMessage(error, l10n));
      }
      return;
    }

    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('admin_table_qr_dialog'),
        backgroundColor: AppColors.surface1,
        title: Text(
          l10n.tablesQrDialogTitle(card.tableNumber),
          style: AppFonts.system(color: AppColors.textPrimary),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                key: const Key('admin_table_qr_preview'),
                width: 220,
                height: 220,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: PosColors.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: QrImageView(
                  data: card.orderUrl,
                  version: QrVersions.auto,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Colors.black,
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Colors.black,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.tablesQrOrderUrlLabel,
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(
              card.orderUrl,
              key: const Key('admin_table_qr_url'),
              style: AppFonts.system(
                color: AppColors.textPrimary,
                fontSize: 13,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.close),
          ),
          TextButton.icon(
            key: const Key('admin_table_qr_replace_action'),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _replaceTableQr(context, tablesNotifier, table);
            },
            icon: const Icon(Icons.sync_lock_rounded, size: 18),
            label: Text(l10n.tablesQrReplaceAction),
          ),
          TextButton.icon(
            key: const Key('admin_table_qr_pdf_action'),
            onPressed: () async {
              try {
                await tableQrExportService.savePdf([card]);
                if (context.mounted) {
                  showSuccessToast(context, l10n.tablesQrPdfSaved);
                }
              } catch (error) {
                if (context.mounted) {
                  showErrorToast(context, _tableQrErrorMessage(error, l10n));
                }
              }
            },
            icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
            label: Text(l10n.tablesQrPdfAction),
          ),
          TextButton.icon(
            key: const Key('admin_table_qr_png_action'),
            onPressed: () async {
              try {
                await tableQrExportService.savePng(card);
                if (context.mounted) {
                  showSuccessToast(context, l10n.tablesQrPngSaved);
                }
              } catch (error) {
                if (context.mounted) {
                  showErrorToast(context, _tableQrErrorMessage(error, l10n));
                }
              }
            },
            icon: const Icon(Icons.image_outlined, size: 18),
            label: Text(l10n.tablesQrPngAction),
          ),
          FilledButton.icon(
            key: const Key('admin_table_qr_copy_action'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: card.orderUrl));
              if (!context.mounted) {
                return;
              }
              showSuccessToast(context, l10n.tablesQrUrlCopied);
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: Text(l10n.tablesQrCopyAction),
          ),
        ],
      ),
    );
  }

  Future<void> _replaceTableQr(
    BuildContext context,
    TablesNotifier tablesNotifier,
    PosTable table,
  ) async {
    final l10n = context.l10n;
    final shouldRotate = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('admin_table_qr_rotate_warning_dialog'),
        backgroundColor: AppColors.surface1,
        title: Text(
          l10n.tablesQrReplaceTitle,
          style: AppFonts.system(color: AppColors.textPrimary),
        ),
        content: Text(
          l10n.tablesQrReplaceWarning,
          key: const Key('admin_table_qr_rotate_warning'),
          style: AppFonts.system(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('admin_table_qr_generate_confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.tablesQrReplaceConfirm),
          ),
        ],
      ),
    );
    if (shouldRotate != true || !context.mounted) return;

    try {
      await tablesService.generateTableQr(table.id);
      if (!context.mounted) return;
      showSuccessToast(context, l10n.tablesQrReplaced);
      await _showTableQrDialog(context, tablesNotifier, table);
    } catch (_) {
      if (context.mounted) {
        showErrorToast(context, l10n.tablesQrReplaceFailed);
      }
    }
  }

  Future<void> _exportAllTableQrs(
    BuildContext context,
    TablesNotifier tablesNotifier,
    List<Map<String, dynamic>> tables,
  ) async {
    final l10n = context.l10n;
    if (tables.isEmpty) {
      showErrorToast(context, l10n.tablesQrNoTables);
      return;
    }

    final kind = await showDialog<TableQrExportKind>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('admin_table_qr_batch_format_dialog'),
        backgroundColor: AppColors.surface1,
        title: Text(
          l10n.tablesQrBatchFormatTitle,
          style: AppFonts.system(color: AppColors.textPrimary),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.tablesQrBatchFormatMessage(tables.length),
              style: AppFonts.system(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            ListTile(
              key: const Key('admin_table_qr_batch_pdf_action'),
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: Text(l10n.tablesQrPdfAction),
              subtitle: Text(l10n.tablesQrBatchPdfDescription),
              onTap: () =>
                  Navigator.of(dialogContext).pop(TableQrExportKind.pdf),
            ),
            ListTile(
              key: const Key('admin_table_qr_batch_png_action'),
              leading: const Icon(Icons.folder_zip_outlined),
              title: Text(l10n.tablesQrPngAction),
              subtitle: Text(l10n.tablesQrBatchPngDescription),
              onTap: () =>
                  Navigator.of(dialogContext).pop(TableQrExportKind.png),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
        ],
      ),
    );
    if (kind == null || !context.mounted) return;

    final progress = ValueNotifier<TableQrExportProgress>(
      TableQrExportProgress(kind: kind, completed: 0, total: tables.length),
    );
    try {
      final cards = await tableQrProgressDialogRunner.run(
        context: context,
        notifier: progress,
        dialogBuilder: (dialogContext) => PopScope(
          canPop: false,
          child: AlertDialog(
            key: const Key('admin_table_qr_batch_progress_dialog'),
            backgroundColor: AppColors.surface1,
            content: ValueListenableBuilder<TableQrExportProgress>(
              valueListenable: progress,
              builder: (context, value, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    value.completed == 0
                        ? l10n.tablesQrExportPreparing
                        : l10n.tablesQrExportProgress(
                            value.completed,
                            value.total,
                          ),
                    style: AppFonts.system(color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: value.total == 0
                        ? null
                        : value.completed / value.total,
                  ),
                ],
              ),
            ),
          ),
        ),
        operation: () async {
          final rows = await tablesService.getOrCreateTableQrs(
            storeId: tablesNotifier.storeId,
          );
          final cards = tableQrExportService.cardsFromRpcRows(rows);
          if (cards.isEmpty) {
            throw StateError('TABLE_QR_EXPORT_EMPTY');
          }
          progress.value = TableQrExportProgress(
            kind: kind,
            completed: 0,
            total: cards.length,
          );
          void updateProgress(TableQrExportProgress value) {
            progress.value = value;
          }

          if (kind == TableQrExportKind.pdf) {
            await tableQrExportService.savePdf(
              cards,
              onProgress: updateProgress,
            );
          } else {
            await tableQrExportService.savePngZip(
              cards,
              onProgress: updateProgress,
            );
          }
          return cards;
        },
      );
      if (context.mounted) {
        showSuccessToast(context, l10n.tablesQrExportSaved(cards.length));
      }
    } catch (error) {
      if (context.mounted) {
        showErrorToast(context, _tableQrErrorMessage(error, l10n));
      }
    }
  }

  String _tableQrErrorMessage(Object error, AppLocalizations l10n) {
    final raw = error.toString();
    if (raw.contains('ADMIN_MUTATION_FORBIDDEN') ||
        raw.contains('TABLE_SCOPE_INVALID')) {
      return l10n.tablesQrPermissionDenied;
    }
    if (raw.contains('POS_PUBLIC_URL') ||
        raw.contains('TABLE_QR_PUBLIC_URL_INVALID')) {
      return l10n.tablesQrInvalidPublicUrl;
    }
    if (raw.contains('TABLE_QR_FIELD_REQUIRED') ||
        raw.contains('TABLE_NOT_FOUND')) {
      return l10n.tablesQrDataInvalid;
    }
    if (raw.contains('TABLE_QR_EXPORT_EMPTY')) {
      return l10n.tablesQrNoTables;
    }
    return l10n.tablesQrExportFailed;
  }
}

class _AdminFloorOverviewInspector extends StatelessWidget {
  const _AdminFloorOverviewInspector({
    required this.totalCount,
    required this.occupiedCount,
    required this.reservedCount,
    required this.emptyCount,
    required this.occupiedTables,
    required this.onSelectTable,
  });

  final int totalCount;
  final int occupiedCount;
  final int reservedCount;
  final int emptyCount;
  final List<PosTable> occupiedTables;
  final ValueChanged<PosTable> onSelectTable;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return PosInspectorPanel(
      title: l10n.tablesFloorOverviewTitle,
      subtitle: l10n.tablesFloorOverviewSubtitle,
      children: [
        _AdminInspectorInfoRow(
          label: l10n.tablesTotalTables,
          value: '$totalCount',
        ),
        _AdminInspectorInfoRow(
          label: l10n.tablesFilterOccupied,
          value: '$occupiedCount',
        ),
        _AdminInspectorInfoRow(
          label: l10n.tablesFilterReserved,
          value: '$reservedCount',
        ),
        _AdminInspectorInfoRow(
          label: l10n.tablesFilterEmpty,
          value: '$emptyCount',
        ),
        const SizedBox(height: 12),
        Text(
          l10n.tablesOccupiedNow,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: PosColors.textPrimary,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 8),
        if (occupiedTables.isEmpty)
          PosExceptionAlert(
            label: l10n.tablesNoOccupiedTables,
            detail: l10n.tablesManagementMonitorSubtitle,
            color: PosColors.success,
            icon: Icons.event_seat_outlined,
          )
        else
          ...occupiedTables.map(
            (table) => _AdminOccupiedTableShortcut(
              key: ValueKey<String>('admin_tables_occupied_${table.id}'),
              table: table,
              onTap: () => onSelectTable(table),
            ),
          ),
      ],
    );
  }
}

class _AdminOccupiedTableShortcut extends StatelessWidget {
  const _AdminOccupiedTableShortcut({
    super.key,
    required this.table,
    required this.onTap,
  });

  final PosTable table;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: PosSurfaceRole.action.fill,
        borderRadius: ToastRadiusTokens.sm,
        child: InkWell(
          borderRadius: ToastRadiusTokens.sm,
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(
              minHeight: PosDensity.touchTargetMin,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: ToastRadiusTokens.sm,
              border: Border.all(color: PosSurfaceRole.action.stroke),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.waiterTableLabel(table.tableNumber),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: PosNumericText.tableId.copyWith(
                      color: PosColors.textPrimary,
                      fontSize: 17,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ToastStatusBadge(
                  label: l10n.tablesFilterOccupied,
                  color: PosColors.info,
                  compact: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AdminFloorSelectionInspector extends StatelessWidget {
  const _AdminFloorSelectionInspector({
    required this.table,
    required this.layoutEditMode,
    required this.statusLabel,
    required this.statusColor,
    required this.onAdjustLayout,
  });

  final PosTable table;
  final bool layoutEditMode;
  final String statusLabel;
  final Color statusColor;
  final _LayoutAdjustmentCallback? onAdjustLayout;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return PosInspectorPanel(
      title: l10n.waiterTableLabel(table.tableNumber),
      subtitle: layoutEditMode
          ? l10n.tablesLayoutEditMode
          : l10n.tablesSelectedStatusTitle,
      children: [
        _AdminInspectorInfoRow(
          label: l10n.tablesTableNumber,
          value: table.tableNumber,
        ),
        _AdminInspectorInfoRow(
          label: l10n.tablesSeatCount,
          value: l10n.waiterSeatCount(table.seatCount ?? 0),
        ),
        _AdminInspectorInfoRow(
          label: l10n.tablesFloorLabel,
          value: table.floorLabel,
        ),
        _AdminInspectorInfoRow(
          label: l10n.status,
          trailing: ToastStatusBadge(
            label: statusLabel,
            color: statusColor,
            compact: true,
          ),
        ),
        if (layoutEditMode && onAdjustLayout != null) ...[
          const SizedBox(height: 2),
          _AdminLayoutAdjustControls(
            table: table,
            onAdjustLayout: onAdjustLayout!,
          ),
        ],
        const SizedBox(height: 12),
        PosExceptionAlert(
          label: layoutEditMode
              ? l10n.tablesLayoutEditActiveTitle
              : l10n.tablesRoleBoundaryTitle,
          detail: layoutEditMode
              ? l10n.tablesLayoutEditActiveDetail
              : l10n.tablesRoleBoundaryDetail,
          color: layoutEditMode ? PosColors.warning : PosColors.info,
          icon: layoutEditMode
              ? Icons.edit_location_alt_outlined
              : Icons.admin_panel_settings_outlined,
        ),
      ],
    );
  }
}

class _AdminLayoutAdjustControls extends StatelessWidget {
  const _AdminLayoutAdjustControls({
    required this.table,
    required this.onAdjustLayout,
  });

  final PosTable table;
  final _LayoutAdjustmentCallback onAdjustLayout;

  @override
  Widget build(BuildContext context) {
    final label =
        'W ${(table.layoutW * 100).round()} / '
        'H ${(table.layoutH * 100).round()} / '
        'R ${table.layoutRotation}';

    return Container(
      key: const Key('admin_table_layout_adjust_controls'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: PosSurfaceRole.action.fill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PosSurfaceRole.action.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: PosColors.textSecondary,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _LayoutIconButton(
                keyName: 'admin_table_layout_width_decrease',
                icon: Icons.swap_horiz_rounded,
                onPressed: () => onAdjustLayout(widthDelta: -0.02),
              ),
              _LayoutIconButton(
                keyName: 'admin_table_layout_width_increase',
                icon: Icons.open_in_full_rounded,
                onPressed: () => onAdjustLayout(widthDelta: 0.02),
              ),
              _LayoutIconButton(
                keyName: 'admin_table_layout_height_decrease',
                icon: Icons.swap_vert_rounded,
                onPressed: () => onAdjustLayout(heightDelta: -0.02),
              ),
              _LayoutIconButton(
                keyName: 'admin_table_layout_height_increase',
                icon: Icons.unfold_more_rounded,
                onPressed: () => onAdjustLayout(heightDelta: 0.02),
              ),
              _LayoutIconButton(
                keyName: 'admin_table_layout_rotate_left',
                icon: Icons.rotate_left_rounded,
                onPressed: () => onAdjustLayout(rotationDelta: -15),
              ),
              _LayoutIconButton(
                keyName: 'admin_table_layout_rotate_right',
                icon: Icons.rotate_right_rounded,
                onPressed: () => onAdjustLayout(rotationDelta: 15),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LayoutIconButton extends StatelessWidget {
  const _LayoutIconButton({
    required this.keyName,
    required this.icon,
    required this.onPressed,
  });

  final String keyName;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.outlined(
      key: Key(keyName),
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      style: IconButton.styleFrom(
        minimumSize: const Size(
          PosDensity.touchTargetMin,
          PosDensity.touchTargetMin,
        ),
        foregroundColor: PosColors.accent,
        side: BorderSide(color: PosSurfaceRole.action.stroke),
      ),
    );
  }
}

class _AdminInspectorInfoRow extends StatelessWidget {
  const _AdminInspectorInfoRow({
    required this.label,
    this.value,
    this.trailing,
  });

  final String label;
  final String? value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: PosColors.mutedSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PosColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PosColors.textSecondary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (trailing != null)
            trailing!
          else
            Text(
              value ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: PosColors.textPrimary,
                fontWeight: FontWeight.w900,
              ),
            ),
        ],
      ),
    );
  }
}

class _AdminTableOperationsPanel extends StatelessWidget {
  const _AdminTableOperationsPanel({
    required this.table,
    required this.orderState,
    required this.onClose,
  });

  final PosTable table;
  final OrderState orderState;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final activeOrder = orderState.activeOrder;
    final itemCount =
        activeOrder?.items.fold<int>(0, (sum, item) => sum + item.quantity) ??
        0;
    final total =
        activeOrder?.items.fold<double>(
          0,
          (sum, item) => sum + (item.unitPrice * item.quantity),
        ) ??
        0;

    return ToastWorkSurface(
      backgroundColor: AppColors.surface1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.tablesSelectedStatusTitle,
                      style: AppFonts.system(
                        color: AppColors.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l10n.waiterTableLabel(table.tableNumber),
                      style: AppFonts.system(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              ToastStatusBadge(
                label: _statusLabel(context, table),
                color: _statusColor(table),
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 16),
          ToastMetricStrip(
            metrics: [
              ToastMetric(
                label: l10n.tablesSeatCount,
                value: l10n.waiterSeatCount(table.seatCount ?? 0),
              ),
              ToastMetric(
                label: l10n.tablesOrderItemsMetric,
                value: '$itemCount',
                tone: itemCount > 0 ? PosColors.accent : PosColors.textMuted,
              ),
              ToastMetric(
                label: l10n.tablesOrderTotalMetric,
                value: '${total.toStringAsFixed(0)} VND',
                tone: total > 0 ? PosColors.success : PosColors.textMuted,
              ),
            ],
          ),
          const SizedBox(height: 16),
          PosExceptionAlert(
            label: l10n.tablesRoleBoundaryTitle,
            detail: l10n.tablesRoleBoundaryDetail,
            color: PosColors.info,
            icon: Icons.admin_panel_settings_outlined,
          ),
          const SizedBox(height: 16),
          Expanded(
            child: activeOrder == null
                ? _AdminTableEmptyOrder(table: table)
                : _AdminTableOrderSummary(
                    orderId: activeOrder.id,
                    status: activeOrder.status,
                    items: activeOrder.items
                        .map(
                          (item) => _AdminTableOrderLine(
                            label:
                                item.label ?? l10n.orderWorkspaceItemFallback,
                            quantity: item.quantity,
                            status: item.status,
                            amount: item.unitPrice * item.quantity,
                          ),
                        )
                        .toList(),
                  ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: PosSecondaryButton(
              label: l10n.close,
              icon: Icons.close_rounded,
              onPressed: onClose,
            ),
          ),
        ],
      ),
    );
  }

  String _statusLabel(BuildContext context, PosTable table) {
    final l10n = context.l10n;
    return switch (table.status) {
      'occupied' => l10n.tablesFilterOccupied,
      'reserved' => l10n.tablesFilterReserved,
      _ => l10n.tablesFilterEmpty,
    };
  }

  static Color _statusColor(PosTable table) {
    return switch (table.status) {
      'occupied' => PosColors.success,
      'reserved' => PosColors.warning,
      _ => PosColors.textSecondary,
    };
  }
}

class _AdminTableEmptyOrder extends StatelessWidget {
  const _AdminTableEmptyOrder({required this.table});

  final PosTable table;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.receipt_long_outlined,
            color: AppColors.textSecondary,
            size: 40,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.tablesNoActiveOrderTitle,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.tablesNoActiveOrderSubtitle(table.tableNumber),
            textAlign: TextAlign.center,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminTableOrderSummary extends StatelessWidget {
  const _AdminTableOrderSummary({
    required this.orderId,
    required this.status,
    required this.items,
  });

  final String orderId;
  final String status;
  final List<_AdminTableOrderLine> items;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final shortId = orderId.length >= 8 ? orderId.substring(0, 8) : orderId;

    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface1,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.surface2),
        ),
        child: ExpansionTile(
          key: const Key('admin_table_order_secondary_detail'),
          initiallyExpanded: false,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          iconColor: AppColors.textSecondary,
          collapsedIconColor: AppColors.textSecondary,
          title: Text(
            l10n.tablesActiveOrderTitle(shortId),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          subtitle: Text(
            l10n.tablesReadOnlyOrderSubtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          trailing: ToastStatusBadge(
            label: status,
            color: _orderStatusColor(status),
            compact: true,
          ),
          children: [
            SizedBox(
              height: 220,
              child: items.isEmpty
                  ? PosEmptyState(
                      title: l10n.tablesNoOrderItemsTitle,
                      subtitle: l10n.tablesNoOrderItemsSubtitle,
                      icon: Icons.receipt_long_outlined,
                    )
                  : ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, __) => Divider(
                        height: 1,
                        color: AppColors.surface3.withValues(alpha: 0.5),
                      ),
                      itemBuilder: (context, index) => items[index],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static Color _orderStatusColor(String status) {
    return switch (status.toLowerCase()) {
      'completed' || 'paid' => PosColors.success,
      'cancelled' || 'canceled' => PosColors.danger,
      'pending' => PosColors.warning,
      _ => PosColors.info,
    };
  }
}

class _AdminTableOrderLine extends StatelessWidget {
  const _AdminTableOrderLine({
    required this.label,
    required this.quantity,
    required this.status,
    required this.amount,
  });

  final String label;
  final int quantity;
  final String status;
  final double amount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppFonts.system(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'x$quantity · $status',
                  style: AppFonts.system(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '${amount.toStringAsFixed(0)} VND',
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _RestaurantMissingView extends StatelessWidget {
  const _RestaurantMissingView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: Center(
        child: Text(
          context.l10n.noLinkedStoreMessage,
          style: AppFonts.system(
            color: AppColors.statusCancelled,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
