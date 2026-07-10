import 'package:supabase_flutter/supabase_flutter.dart';

enum LiveSyncScopeMode { operational, brandDashboard }

class LiveSyncStore {
  const LiveSyncStore({required this.id, this.brandId});

  final String id;
  final String? brandId;
}

class LiveSyncScope {
  const LiveSyncScope({
    required this.role,
    required this.activeStoreId,
    required this.accessibleStores,
  });

  final String? role;
  final String? activeStoreId;
  final List<LiveSyncStore> accessibleStores;

  List<String> get accessibleStoreIds =>
      accessibleStores.map((store) => store.id).toSet().toList();

  List<String> get operationalStoreIds {
    final storeId = activeStoreId;
    if (storeId == null || storeId.isEmpty || !canAccessStore(storeId)) {
      return const [];
    }
    return [storeId];
  }

  List<String> get activeBrandStoreIds {
    final storeId = activeStoreId;
    if (storeId == null || storeId.isEmpty) {
      return const [];
    }

    final activeStore = _storeById(storeId);
    final activeBrandId = activeStore?.brandId;
    if (activeBrandId == null || activeBrandId.isEmpty) {
      return operationalStoreIds;
    }

    return accessibleStores
        .where((store) => store.brandId == activeBrandId)
        .map((store) => store.id)
        .toSet()
        .toList();
  }

  bool canAccessStore(String storeId) =>
      accessibleStores.any((store) => store.id == storeId);

  bool canSyncStore(
    String storeId, {
    LiveSyncScopeMode mode = LiveSyncScopeMode.operational,
  }) {
    return switch (mode) {
      LiveSyncScopeMode.operational => operationalStoreIds.contains(storeId),
      LiveSyncScopeMode.brandDashboard =>
        _canUseBrandScope && activeBrandStoreIds.contains(storeId),
    };
  }

  bool get _canUseBrandScope =>
      role == 'brand_admin' || role == 'super_admin' || role == 'admin';

  LiveSyncStore? _storeById(String storeId) {
    for (final store in accessibleStores) {
      if (store.id == storeId) {
        return store;
      }
    }
    return null;
  }

  static String storeChannel(String namespace, String storeId) {
    return 'public:$namespace:$storeId';
  }

  static String entityChannel(
    String namespace,
    String storeId,
    String entityId,
  ) {
    return 'public:$namespace:$storeId:$entityId';
  }

  static PostgresChangeFilter storeFilter(
    String storeId, {
    String column = 'restaurant_id',
  }) {
    return PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: column,
      value: storeId,
    );
  }

  static PostgresChangeFilter entityFilter(String column, String value) {
    return PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: column,
      value: value,
    );
  }
}
