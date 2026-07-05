import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/tables_service.dart';
import '../../core/utils/live_sync_scope.dart';
import '../../main.dart';
import 'table_model.dart';
import 'table_order_preview.dart';

class WaiterTableState {
  const WaiterTableState({
    this.tables = const [],
    this.orderPreviewByTableId = const {},
    this.isLoading = false,
    this.error,
  });

  final List<PosTable> tables;
  final Map<String, TableOrderPreview> orderPreviewByTableId;
  final bool isLoading;
  final String? error;

  WaiterTableState copyWith({
    List<PosTable>? tables,
    Map<String, TableOrderPreview>? orderPreviewByTableId,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return WaiterTableState(
      tables: tables ?? this.tables,
      orderPreviewByTableId:
          orderPreviewByTableId ?? this.orderPreviewByTableId,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class WaiterTableNotifier extends StateNotifier<WaiterTableState> {
  WaiterTableNotifier() : super(const WaiterTableState());

  static const _autoRefreshInterval = Duration(seconds: 2);
  static const _fallbackPollInterval = Duration(seconds: 15);

  RealtimeChannel? _channel;
  String? _subscribedRestaurantId;
  Timer? _pollTimer;
  String? _pollStoreId;
  bool _realtimeConnected = false;

  Future<void> loadTables(String storeId, {bool showLoading = true}) async {
    if (showLoading) {
      state = state.copyWith(isLoading: true, clearError: true);
    }
    try {
      final response = await tablesService.fetchTables(storeId);
      Map<String, TableOrderPreview> orderPreviewByTableId = const {};
      try {
        orderPreviewByTableId = await _fetchActiveOrderPreviews(storeId);
      } catch (_) {
        // Keep the floor usable even if the secondary preview query fails.
      }

      final tables = response
          .map<PosTable>((row) => PosTable.fromJson(row))
          .toList();

      state = state.copyWith(
        tables: _sortTables(tables),
        orderPreviewByTableId: orderPreviewByTableId,
        isLoading: false,
        clearError: true,
      );

      await subscribe(storeId);
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load tables: $error',
      );
    }
  }

  Future<void> refreshOrderPreviews(String storeId) async {
    try {
      final orderPreviewByTableId = await _fetchActiveOrderPreviews(storeId);
      if (!mounted) {
        return;
      }
      state = state.copyWith(
        orderPreviewByTableId: orderPreviewByTableId,
        clearError: true,
      );
    } catch (_) {
      // Keep the floor usable even if the secondary preview query fails.
    }
  }

  Future<void> subscribe(String storeId) async {
    if (_subscribedRestaurantId == storeId && _channel != null) {
      _ensureAutoRefresh(storeId);
      return;
    }

    if (_channel != null) {
      await _channel!.unsubscribe();
      _channel = null;
    }
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
            if (raw.isEmpty) {
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
          callback: (_) => _refreshTablesFromRealtime(storeId),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'order_items',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => _refreshTablesFromRealtime(storeId),
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

  void _refreshTablesFromRealtime(String storeId) {
    if (!mounted) {
      return;
    }
    unawaited(loadTables(storeId, showLoading: false));
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
    _pollTimer = Timer.periodic(_fallbackPollInterval, (_) {
      if (mounted && _subscribedRestaurantId == storeId) {
        unawaited(loadTables(storeId, showLoading: false));
      }
    });
  }

  Future<Map<String, TableOrderPreview>> _fetchActiveOrderPreviews(
    String storeId,
  ) async {
    final response = await supabase
        .from('orders')
        .select(
          'id, table_id, status, created_at, order_items(id, created_at, label, quantity, status, menu_items(name))',
        )
        .eq('restaurant_id', storeId)
        .not('status', 'in', '(completed,cancelled)')
        .order('created_at', ascending: false)
        .order('created_at', referencedTable: 'order_items', ascending: true)
        .order('id', referencedTable: 'order_items', ascending: true);

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
            return TableOrderPreviewLine(label: label, quantity: quantity);
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
