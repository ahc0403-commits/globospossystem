import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../core/ui/pos_design_tokens.dart';
import '../../../core/ui/toast/toast.dart';
import '../../../core/utils/number_input_utils.dart';
import '../../../main.dart';
import '../../../widgets/error_toast.dart';
import '../../auth/auth_provider.dart';
import '../../order/order_provider.dart';
import '../../table/floor_layout.dart';
import '../../table/table_model.dart';
import '../providers/admin_audit_provider.dart';
import '../providers/tables_provider.dart';
import '../widgets/admin_audit_trace_panel.dart';

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
    setState(() {
      _selectedTable = resolvedTable;
      _showOrderPanel = false;
    });
  }

  List<PosTable> _layoutTables(List<Map<String, dynamic>> tables) {
    final merged = tables
        .map((row) => PosTable.fromJson(Map<String, dynamic>.from(row)))
        .map((table) {
          final draft = _draftLayoutByTableId[table.id];
          return draft == null ? table : table.copyWithLayout(draft);
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
      _layoutEditMode = false;
    });
    showSuccessToast(context, context.l10n.tablesLayoutSaved);
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
      return draft == null ? resolved : resolved.copyWithLayout(draft);
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
              style: GoogleFonts.notoSansKr(
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
                    final floor = SizedBox(
                      height: needsScroll
                          ? minimumCanvasHeight
                          : constraints.maxHeight,
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
                                setState(() {
                                  _selectedTable = table.copyWithLayout(rect);
                                  _draftLayoutByTableId[table.id] = rect;
                                });
                              },
                      ),
                    );

                    if (!needsScroll) {
                      return floor;
                    }

                    return SingleChildScrollView(child: floor);
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
    final hasDraft = _draftLayoutByTableId.isNotEmpty;
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
                FilledButton.icon(
                  onPressed: hasDraft
                      ? () =>
                            _saveDraftLayout(tablesNotifier, tablesState.tables)
                      : null,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: Text(l10n.tablesSaveLayout),
                ),
              if (_layoutEditMode)
                OutlinedButton.icon(
                  onPressed: hasDraft
                      ? () {
                          setState(() {
                            _draftLayoutByTableId.clear();
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
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          l10n.tablesRecentChangesHint,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.notoSansKr(
            color: AppColors.textSecondary,
            fontSize: 12,
          ),
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

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface1,
          title: Text(
            l10n.tablesAddTitle,
            style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: tableController,
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                decoration: InputDecoration(labelText: l10n.tablesTableNumber),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: seatController,
                keyboardType: TextInputType.number,
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                decoration: InputDecoration(labelText: l10n.tablesSeatCount),
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
                if (tableNumber.isEmpty ||
                    seatCount == null ||
                    seatCount <= 0) {
                  showErrorToast(context, l10n.tablesInvalidTableAndSeat);
                  return;
                }

                final success = await tablesNotifier.addTable(
                  tableNumber,
                  seatCount,
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
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l10n.waiterTableLabel(table.tableNumber),
                      style: GoogleFonts.notoSansKr(
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
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.tablesNoActiveOrderSubtitle(table.tableNumber),
            textAlign: TextAlign.center,
            style: GoogleFonts.notoSansKr(
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
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          subtitle: Text(
            l10n.tablesReadOnlyOrderSubtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.notoSansKr(
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
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'x$quantity · $status',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '${amount.toStringAsFixed(0)} VND',
            style: GoogleFonts.notoSansKr(
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
          style: GoogleFonts.notoSansKr(
            color: AppColors.statusCancelled,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
