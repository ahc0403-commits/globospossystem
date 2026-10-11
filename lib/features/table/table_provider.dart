import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/tables_service.dart';
import '../../core/services/operational_day_service.dart';
import '../../core/utils/live_sync_scope.dart';
import '../../core/utils/coalesced_refresh.dart';
import '../../core/utils/polling_utils.dart';
import '../../main.dart';
import 'table_model.dart';
import 'table_order_preview.dart';

class WaiterTableState {
  const WaiterTableState({
    this.tables = const [],
    this.orderPreviewByTableId = const {},
    this.isLoading = false,
    this.error,
    this.operationalDay,
  });

  final List<PosTable> tables;
  final Map<String, TableOrderPreview> orderPreviewByTableId;
  final bool isLoading;
  final String? error;
  final OperationalDayState? operationalDay;

  WaiterTableState copyWith({
    List<PosTable>? tables,
    Map<String, TableOrderPreview>? orderPreviewByTableId,
    bool? isLoading,
    String? error,
    bool clearError = false,
    OperationalDayState? operationalDay,
  }) {
    return WaiterTableState(
      tables: tables ?? this.tables,
      orderPreviewByTableId:
          orderPreviewByTableId ?? this.orderPreviewByTableId,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      operationalDay: operationalDay ?? this.operationalDay,
    );
  }
}

class WaiterTableNotifier extends StateNotifier<WaiterTableState> {
  WaiterTableNotifier() : super(const WaiterTableState());

  static const _autoRefreshInterval = Duration(seconds: 2);
  static const _fallbackPollInterval = Duration(seconds: 30);

  RealtimeChannel? _channel;
  String? _subscribedRestaurantId;
  Timer? _pollTimer;
  Timer? _businessDayTimer;
  String? _pollStoreId;
  bool _realtimeConnected = false;

  final _refreshQueue = CoalescedRefresh();
  String? _readStoreId;
  int _readGeneration = 0;
  bool _reloadTables = false;
  bool _reloadPreviews = false;
  final _dirtyOrders = <String>{};
  final _dirtyTables = <String>{};
  Timer? _eventTimer;

  Future<void> loadTables(String storeId, {bool showLoading = true}) {
    if (!mounted) return Future.value();
    if (_readStoreId != storeId) {
      _readStoreId = storeId;
      _readGeneration++;
      _dirtyOrders.clear();
      _dirtyTables.clear();
      _eventTimer?.cancel();
      state = const WaiterTableState();
    }
    _reloadTables = true;
    _reloadPreviews = true;
    if (showLoading) state = state.copyWith(isLoading: true, clearError: true);
    return _refreshQueue.run(_drainRefresh);
  }

  Future<void> _drainRefresh() async {
    if (!mounted) return;
    final storeId = _readStoreId!;
    final generation = _readGeneration;
    final full = _reloadTables;
    _reloadTables = false;
    final fullPreviews = _reloadPreviews;
    _reloadPreviews = false;
    final ids = _dirtyOrders.toList();
    final tableIds = _dirtyTables.toList();
    _dirtyOrders.clear();
    _dirtyTables.clear();
    await _readTables(
      storeId,
      generation: generation,
      full: full,
      fullPreviews: fullPreviews,
      ids: ids,
      tableIds: tableIds,
    );
  }

  Future<void> _readTables(
    String storeId, {
    required int generation,
    required bool full,
    required bool fullPreviews,
    required List<String> ids,
    required List<String> tableIds,
  }) async {
    try {
      final operationalDay = await operationalDayService.ensureStoreDay(
        storeId,
      );
      _businessDayTimer?.cancel();
      _businessDayTimer = Timer(
        operationalDay.window.refreshDelay(DateTime.now().toUtc()),
        () {
          if (mounted && _subscribedRestaurantId == storeId) {
            unawaited(loadTables(storeId, showLoading: false));
          }
        },
      );
      final response = full ? await tablesService.fetchTables(storeId) : null;
      Map<String, TableOrderPreview> orderPreviewByTableId = Map.of(
        state.orderPreviewByTableId,
      );
      try {
        orderPreviewByTableId = fullPreviews
            ? await _fetchActiveOrderPreviews(storeId)
            : await _fetchChangedPreviews(
                storeId,
                ids,
                tableIds,
                orderPreviewByTableId,
              );
      } catch (_) {
        // Keep the floor usable even if the secondary preview query fails.
      }

      if (!mounted || generation != _readGeneration) return;
      final tables =
          (response == null
                  ? state.tables
                  : response.map<PosTable>(PosTable.fromJson))
              // An active order is the operational source of truth for occupancy.
              // This also closes the short interval where the order row is visible
              // before a delayed table-status update reaches the client.
              .map(
                (table) => orderPreviewByTableId.containsKey(table.id)
                    ? table.copyWithStatus('occupied')
                    : table,
              )
              .toList();

      state = state.copyWith(
        operationalDay: operationalDay,
        tables: _sortTables(tables),
        orderPreviewByTableId: orderPreviewByTableId,
        isLoading: false,
        clearError: true,
      );

      await subscribe(storeId);
    } catch (error) {
      if (!mounted || generation != _readGeneration) return;
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load tables: $error',
      );
    }
  }

  Future<void> refreshOrderPreviews(String storeId) {
    if (!mounted || _readStoreId != storeId) return Future.value();
    _reloadPreviews = true;
    return _refreshQueue.run(_drainRefresh);
  }

  Future<void> subscribe(String storeId) async {
    if (!mounted || _readStoreId != storeId) return;
    if (_subscribedRestaurantId == storeId && _channel != null) {
      _ensureAutoRefresh(storeId);
      return;
    }

    if (_channel != null) {
      await _channel!.unsubscribe();
      _channel = null;
    }
    if (!mounted || _readStoreId != storeId) return;
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollStoreId = null;
    _realtimeConnected = false;

    _subscribedRestaurantId = storeId;

    _channel = supabase
        .channel(LiveSyncScope.storeChannel('tables', storeId))
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'tables',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (payload) {
            final raw = payload.newRecord;
            if (!mounted || _readStoreId != storeId || raw.isEmpty) {
              return;
            }

            final updated = PosTable.fromJson(Map<String, dynamic>.from(raw));
            if (updated.storeId != storeId) {
              return;
            }

            final current = [...state.tables];
            final index = current.indexWhere((table) => table.id == updated.id);
            if (index >= 0) {
              current[index] = updated;
            } else {
              current.add(updated);
            }

            state = state.copyWith(
              tables: _sortTables(current),
              clearError: true,
            );
            unawaited(refreshOrderPreviews(storeId));
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'orders',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (payload) =>
              _refreshTablesFromRealtime(storeId, payload, false),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'order_items',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (payload) =>
              _refreshTablesFromRealtime(storeId, payload, true),
        )
        .subscribe((status, [error]) {
          final connected = status == RealtimeSubscribeStatus.subscribed;
          if (connected != _realtimeConnected) {
            _realtimeConnected = connected;
            _ensureAutoRefresh(storeId);
          }
        });
    _ensureAutoRefresh(storeId);
    Future.delayed(_autoRefreshInterval, () {
      if (mounted &&
          !_realtimeConnected &&
          _subscribedRestaurantId == storeId) {
        _ensureAutoRefresh(storeId);
      }
    });
  }

  void _refreshTablesFromRealtime(
    String storeId,
    PostgresChangePayload payload,
    bool item,
  ) {
    final row = payload.newRecord.isNotEmpty
        ? payload.newRecord
        : payload.oldRecord;
    final id = row[item ? 'order_id' : 'id']?.toString();
    if (id == null || id.isEmpty) {
      unawaited(refreshOrderPreviews(storeId));
    } else {
      queueChangedOrders(
        storeId,
        [id],
        tableIds: item
            ? const []
            : [if (row['table_id'] != null) row['table_id'].toString()],
      );
    }
  }

  void queueChangedOrders(
    String storeId,
    Iterable<String> ids, {
    Iterable<String> tableIds = const [],
  }) {
    if (!mounted || _readStoreId != storeId) return;
    _dirtyOrders.addAll(ids);
    _dirtyTables.addAll(tableIds);
    if (_dirtyOrders.length > 500 || _dirtyTables.length > 500) {
      _dirtyOrders.clear();
      _dirtyTables.clear();
      _reloadPreviews = true;
    }
    _eventTimer ??= Timer(const Duration(milliseconds: 150), () {
      _eventTimer = null;
      if (mounted) unawaited(_refreshQueue.run(_drainRefresh));
    });
  }

  Future<Map<String, TableOrderPreview>> _fetchChangedPreviews(
    String storeId,
    List<String> ids,
    List<String> explicitTables,
    Map<String, TableOrderPreview> current,
  ) async {
    final previews = Map<String, TableOrderPreview>.of(current);
    for (var start = 0; start < ids.length; start += 50) {
      final batch = ids.skip(start).take(50).toList();
      final affected = <String>{
        ...explicitTables.skip(start).take(50),
        ...current.entries
            .where((e) => batch.contains(e.value.orderId))
            .map((e) => e.key),
      };
      // A batch may include both old and new tables. Preserve the 50-table input
      // bound; other old tables are reached by their unchanged order IDs.
      if (affected.length > 50) return _fetchActiveOrderPreviews(storeId);
      final result = await supabase.rpc(
        'get_table_order_previews_delta',
        params: {
          'p_store_id': storeId,
          'p_order_ids': batch,
          'p_table_ids': affected.toList(),
        },
      );
      if (result is! Map ||
          result['version'] != 1 ||
          result['rows'] is! List ||
          (result['rows'] as List).length > 100) {
        throw const FormatException('TABLE_PREVIEW_RESPONSE_INVALID');
      }
      final rows = List<Map<String, dynamic>>.from(result['rows'] as List);
      for (final row in rows) {
        final tableId = row['table_id'] as String;
        previews.remove(tableId);
      }
      previews.addAll(_parsePreviewRows(rows.where((r) => r['id'] != null)));
    }
    return previews;
  }

  void _ensureAutoRefresh(String storeId) {
    if (_realtimeConnected) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }

    if (_pollTimer != null && _pollStoreId == storeId) {
      return;
    }

    _pollTimer?.cancel();
    _pollStoreId = storeId;
    _pollTimer = Timer(jitteredPollDelay(_fallbackPollInterval), () async {
      _pollTimer = null;
      if (mounted && _subscribedRestaurantId == storeId) {
        await loadTables(storeId, showLoading: false);
      }
      if (mounted &&
          !_realtimeConnected &&
          _subscribedRestaurantId == storeId) {
        _ensureAutoRefresh(storeId);
      }
    });
  }

  Future<Map<String, TableOrderPreview>> _fetchActiveOrderPreviews(
    String storeId,
  ) async {
    final operationalDay = await operationalDayService.ensureStoreDay(storeId);
    var query = supabase
        .from('orders')
        .select(
          'id, table_id, status, created_at, order_items(id, created_at, label, quantity, status, menu_items(name, name_ko, name_vi, name_en))',
        )
        .eq('restaurant_id', storeId)
        .not('status', 'in', '(completed,cancelled)');
    if (operationalDay.supportsClosure) {
      query = query.isFilter('operational_closed_at', null);
    }
    if (operationalDay.enabled) {
      query = query.or(
        'sales_channel.neq.dine_in,sales_channel.is.null,'
        'and(created_at.gte.${operationalDay.window.startIso8601},'
        'created_at.lt.${operationalDay.window.endIso8601})',
      );
    }
    final response = await query
        .order('created_at', ascending: false)
        .order('created_at', referencedTable: 'order_items', ascending: true)
        .order('id', referencedTable: 'order_items', ascending: true);

    return _parsePreviewRows(response.map((r) => Map<String, dynamic>.from(r)));
  }

  Map<String, TableOrderPreview> _parsePreviewRows(
    Iterable<Map<String, dynamic>> response,
  ) {
    final previews = <String, TableOrderPreview>{};
    for (final rawOrder in response) {
      final order = Map<String, dynamic>.from(rawOrder);
      final tableId = order['table_id']?.toString() ?? '';
      if (tableId.isEmpty || previews.containsKey(tableId)) {
        continue;
      }

      final rawItems = order['order_items'];
      final itemRows = rawItems is List
          ? rawItems
                .map((rawItem) => Map<String, dynamic>.from(rawItem as Map))
                .toList()
          : <Map<String, dynamic>>[];
      itemRows.sort(_compareOrderItemRowsByCreatedAt);
      final lines = itemRows
          .where((item) {
            final status = item['status']?.toString().toLowerCase();
            return status != 'cancelled';
          })
          .map((item) {
            final menuItemRaw = item['menu_items'];
            final menuItem = menuItemRaw is Map
                ? Map<String, dynamic>.from(menuItemRaw)
                : const <String, dynamic>{};
            final label =
                item['label']?.toString() ??
                menuItem['name']?.toString() ??
                'Item';
            final quantityRaw = item['quantity'];
            final quantity = switch (quantityRaw) {
              int value => value,
              num value => value.toInt(),
              String value => int.tryParse(value) ?? 0,
              _ => 0,
            };
            return TableOrderPreviewLine(
              label: label,
              quantity: quantity,
              nameKo: menuItem['name_ko']?.toString(),
              nameVi: menuItem['name_vi']?.toString(),
              nameEn: menuItem['name_en']?.toString(),
            );
          })
          .where((line) => line.quantity > 0)
          .toList();

      previews[tableId] = TableOrderPreview(
        orderId: order['id']?.toString() ?? '',
        lines: lines,
      );
    }

    return previews;
  }

  List<PosTable> _sortTables(List<PosTable> tables) {
    final sorted = [...tables];
    sorted.sort((a, b) {
      final layoutOrder = a.layoutSortOrder.compareTo(b.layoutSortOrder);
      if (layoutOrder != 0) {
        return layoutOrder;
      }
      final aNum = int.tryParse(a.tableNumber);
      final bNum = int.tryParse(b.tableNumber);
      if (aNum != null && bNum != null) {
        return aNum.compareTo(bNum);
      }
      return a.tableNumber.compareTo(b.tableNumber);
    });
    return sorted;
  }

  @override
  void dispose() {
    _businessDayTimer?.cancel();
    _readGeneration++;
    _eventTimer?.cancel();
    _refreshQueue.dispose();
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollStoreId = null;
    _channel?.unsubscribe();
    _channel = null;
    super.dispose();
  }
}

final waiterTableProvider =
    StateNotifierProvider<WaiterTableNotifier, WaiterTableState>(
      (ref) => WaiterTableNotifier(),
    );

int _compareOrderItemRowsByCreatedAt(
  Map<String, dynamic> left,
  Map<String, dynamic> right,
) {
  final leftCreatedAt = DateTime.tryParse(left['created_at']?.toString() ?? '');
  final rightCreatedAt = DateTime.tryParse(
    right['created_at']?.toString() ?? '',
  );

  if (leftCreatedAt != null && rightCreatedAt != null) {
    final createdAtComparison = leftCreatedAt.compareTo(rightCreatedAt);
    if (createdAtComparison != 0) {
      return createdAtComparison;
    }
  } else if (leftCreatedAt != null) {
    return -1;
  } else if (rightCreatedAt != null) {
    return 1;
  }

  return (left['id']?.toString() ?? '').compareTo(
    right['id']?.toString() ?? '',
  );
}
