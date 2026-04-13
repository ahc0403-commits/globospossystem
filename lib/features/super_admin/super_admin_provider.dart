import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/store_service.dart';
import '../../main.dart';

const kUnclassifiedBrandFilter = '__unclassified__';

class SuperRestaurant {
  const SuperRestaurant({
    required this.id,
    required this.name,
    required this.slug,
    required this.address,
    required this.operationMode,
    required this.perPersonCharge,
    required this.isActive,
    required this.createdAt,
    this.storeType = 'direct',
    this.brandId,
    this.brandName,
    this.brandCode,
  });

  final String id;
  final String name;
  final String slug;
  final String address;
  final String operationMode;
  final double? perPersonCharge;
  final bool isActive;
  final DateTime createdAt;
  final String storeType;
  final String? brandId;
  final String? brandName;
  final String? brandCode;

  bool get isDirect => storeType == 'direct';
  bool get isExternal => storeType == 'external';

  factory SuperRestaurant.fromJson(Map<String, dynamic> json) {
    final rawCharge = json['per_person_charge'];
    final charge = switch (rawCharge) {
      num value => value.toDouble(),
      String value => double.tryParse(value),
      _ => null,
    };
    final createdAtRaw = json['created_at']?.toString();
    return SuperRestaurant(
      id: json['id'].toString(),
      name: json['name']?.toString() ?? '',
      slug: json['slug']?.toString() ?? '',
      address: json['address']?.toString() ?? '',
      operationMode:
          json['operation_mode']?.toString().toLowerCase() ?? 'standard',
      perPersonCharge: charge,
      isActive: json['is_active'] == true,
      createdAt: createdAtRaw != null
          ? DateTime.tryParse(createdAtRaw) ?? DateTime.now()
          : DateTime.now(),
      storeType: json['store_type']?.toString() ?? 'direct',
      brandId: json['brand_id']?.toString(),
      brandName: (json['brands'] as Map<String, dynamic>?)?['name']?.toString(),
      brandCode: (json['brands'] as Map<String, dynamic>?)?['code']?.toString(),
    );
  }
}

class SuperAdminRestaurantReport {
  const SuperAdminRestaurantReport({
    required this.storeId,
    required this.restaurantName,
    required this.dineIn,
    required this.delivery,
    required this.total,
  });

  final String storeId;
  final String restaurantName;
  final double dineIn;
  final double delivery;
  final double total;
}

class SuperAdminReportSummary {
  const SuperAdminReportSummary({
    required this.totalRevenue,
    required this.dineInRevenue,
    required this.deliveryRevenue,
    required this.rows,
  });

  final double totalRevenue;
  final double dineInRevenue;
  final double deliveryRevenue;
  final List<SuperAdminRestaurantReport> rows;
}

class SuperAdminState {
  const SuperAdminState({
    this.restaurants = const [],
    this.brands = const [],
    this.selectedBrandId,
    this.selectedStoreType,
    this.selectedRestaurant,
    this.reportSummary,
    required this.reportStart,
    required this.reportEnd,
    this.isLoading = false,
    this.error,
  });

  final List<SuperRestaurant> restaurants;
  final List<Map<String, dynamic>> brands;
  final String? selectedBrandId;
  final String? selectedStoreType; // null=All, 'direct', 'external'
  final SuperRestaurant? selectedRestaurant;
  final SuperAdminReportSummary? reportSummary;
  final DateTime reportStart;
  final DateTime reportEnd;
  final bool isLoading;
  final String? error;

  /// Returns restaurants filtered by selected brand and store type
  List<SuperRestaurant> get filteredRestaurants {
    var list = restaurants;

    // Store type filter
    if (selectedStoreType != null) {
      list = list.where((r) => r.storeType == selectedStoreType).toList();
    }

    // Brand filter
    if (selectedBrandId == null) return list;
    if (selectedBrandId == kUnclassifiedBrandFilter) {
      return list
          .where((r) => r.brandId == null || r.brandId!.isEmpty)
          .toList();
    }
    return list.where((r) => r.brandId == selectedBrandId).toList();
  }

  SuperAdminState copyWith({
    List<SuperRestaurant>? restaurants,
    List<Map<String, dynamic>>? brands,
    String? selectedBrandId,
    String? selectedStoreType,
    SuperRestaurant? selectedRestaurant,
    SuperAdminReportSummary? reportSummary,
    DateTime? reportStart,
    DateTime? reportEnd,
    bool? isLoading,
    String? error,
    bool clearSelectedRestaurant = false,
    bool clearReportSummary = false,
    bool clearError = false,
    bool clearBrandFilter = false,
    bool clearStoreTypeFilter = false,
  }) {
    return SuperAdminState(
      restaurants: restaurants ?? this.restaurants,
      brands: brands ?? this.brands,
      selectedBrandId: clearBrandFilter
          ? null
          : (selectedBrandId ?? this.selectedBrandId),
      selectedStoreType: clearStoreTypeFilter
          ? null
          : (selectedStoreType ?? this.selectedStoreType),
      selectedRestaurant: clearSelectedRestaurant
          ? null
          : (selectedRestaurant ?? this.selectedRestaurant),
      reportSummary: clearReportSummary
          ? null
          : (reportSummary ?? this.reportSummary),
      reportStart: reportStart ?? this.reportStart,
      reportEnd: reportEnd ?? this.reportEnd,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class SuperAdminNotifier extends StateNotifier<SuperAdminState> {
  SuperAdminNotifier()
    : super(
        SuperAdminState(
          reportStart: DateTime(DateTime.now().year, DateTime.now().month, 1),
          reportEnd: DateTime.now(),
        ),
      );

  Future<void> loadAllRestaurants() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final response = await supabase
          .from('restaurants')
          .select('*, brands(name, code)')
          .order('created_at', ascending: false);
      final restaurants = response
          .map<SuperRestaurant>(
            (row) => SuperRestaurant.fromJson(Map<String, dynamic>.from(row)),
          )
          .toList();
      state = state.copyWith(
        restaurants: restaurants,
        isLoading: false,
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load restaurants: $error',
      );
    }
  }

  Future<void> loadBrands() async {
    try {
      final response = await supabase
          .from('brands')
          .select('id, code, name')
          .order('name', ascending: true);
      state = state.copyWith(brands: List<Map<String, dynamic>>.from(response));
    } catch (_) {
      // brands 로드 실패는 치명적이지 않음 — 필터 없이 계속
    }
  }

  void setBrandFilter(String? brandId) {
    state = state.copyWith(
      selectedBrandId: brandId,
      clearBrandFilter: brandId == null,
    );
  }

  void setStoreTypeFilter(String? storeType) {
    state = state.copyWith(
      selectedStoreType: storeType,
      clearStoreTypeFilter: storeType == null,
    );
  }

  Future<bool> addRestaurant({
    required String name,
    required String address,
    required String slug,
    required String operationMode,
    required double? perPersonCharge,
    String? brandId,
    String storeType = 'direct',
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await restaurantService.createRestaurant(
        name: name,
        slug: slug,
        operationMode: operationMode,
        address: address.isEmpty ? null : address,
        perPersonCharge: perPersonCharge,
        brandId: brandId,
        storeType: storeType,
      );
      await loadAllRestaurants();
      return true;
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to create restaurant: $error',
      );
      return false;
    }
  }

  Future<bool> updateRestaurant({
    required String id,
    required String name,
    required String address,
    required String slug,
    required String operationMode,
    required double? perPersonCharge,
    String? brandId,
    String storeType = 'direct',
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await restaurantService.updateRestaurant(
        id: id,
        name: name,
        slug: slug,
        operationMode: operationMode,
        address: address.isEmpty ? null : address,
        perPersonCharge: perPersonCharge,
        brandId: brandId,
        storeType: storeType,
      );
      await loadAllRestaurants();
      return true;
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to update restaurant: $error',
      );
      return false;
    }
  }

  Future<bool> deactivateRestaurant(String id) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await restaurantService.deactivateRestaurant(id);
      await loadAllRestaurants();
      return true;
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to deactivate restaurant: $error',
      );
      return false;
    }
  }

  void selectRestaurant(SuperRestaurant? restaurant) {
    state = state.copyWith(
      selectedRestaurant: restaurant,
      clearSelectedRestaurant: restaurant == null,
      clearError: true,
    );
  }

  Future<void> setReportRange(DateTime start, DateTime end) async {
    state = state.copyWith(
      reportStart: DateTime(start.year, start.month, start.day),
      reportEnd: DateTime(end.year, end.month, end.day, 23, 59, 59, 999),
      clearError: true,
    );
    await loadAllReports(selectedRestaurantId: state.selectedRestaurant?.id);
  }

  Future<void> loadAllReports({String? selectedRestaurantId}) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final restaurants = state.restaurants;
      final Map<String, _Accumulator> accumulators = {};
      final sourceRestaurants = selectedRestaurantId == null
          ? restaurants
          : restaurants.where((r) => r.id == selectedRestaurantId).toList();

      for (final restaurant in sourceRestaurants) {
        accumulators[restaurant.id] = _Accumulator(
          storeId: restaurant.id,
          restaurantName: restaurant.name,
        );
      }

      if (sourceRestaurants.isEmpty) {
        state = state.copyWith(
          reportSummary: const SuperAdminReportSummary(
            totalRevenue: 0,
            dineInRevenue: 0,
            deliveryRevenue: 0,
            rows: [],
          ),
          isLoading: false,
          clearError: true,
        );
        return;
      }

      final startIso = state.reportStart.toIso8601String();
      final endIso = state.reportEnd.toIso8601String();

      for (final restaurant in sourceRestaurants) {
        final payments = await supabase
            .from('payments')
            .select('amount, orders(sales_channel)')
            .eq('restaurant_id', restaurant.id)
            .eq('is_revenue', true)
            .gte('created_at', startIso)
            .lte('created_at', endIso);

        final externalSales = await supabase
            .from('external_sales')
            .select('net_amount')
            .eq('restaurant_id', restaurant.id)
            .eq('is_revenue', true)
            .eq('order_status', 'completed')
            .gte('completed_at', startIso)
            .lte('completed_at', endIso);

        final accumulator = accumulators[restaurant.id]!;

        for (final row in payments) {
          final payment = Map<String, dynamic>.from(row);
          final amount = _toDouble(payment['amount']);
          String channel = '';
          final orderRaw = payment['orders'];
          if (orderRaw is Map<String, dynamic>) {
            channel = orderRaw['sales_channel']?.toString() ?? '';
          }
          if (channel.toLowerCase() == 'delivery') {
            accumulator.delivery += amount;
          } else {
            accumulator.dineIn += amount;
          }
        }

        for (final row in externalSales) {
          final sale = Map<String, dynamic>.from(row);
          accumulator.delivery += _toDouble(sale['net_amount']);
        }
      }

      final reportRows =
          accumulators.values
              .map(
                (value) => SuperAdminRestaurantReport(
                  storeId: value.storeId,
                  restaurantName: value.restaurantName,
                  dineIn: value.dineIn,
                  delivery: value.delivery,
                  total: value.dineIn + value.delivery,
                ),
              )
              .toList()
            ..sort((a, b) => b.total.compareTo(a.total));

      final dineInTotal = reportRows.fold<double>(
        0,
        (sum, row) => sum + row.dineIn,
      );
      final deliveryTotal = reportRows.fold<double>(
        0,
        (sum, row) => sum + row.delivery,
      );

      state = state.copyWith(
        reportSummary: SuperAdminReportSummary(
          totalRevenue: dineInTotal + deliveryTotal,
          dineInRevenue: dineInTotal,
          deliveryRevenue: deliveryTotal,
          rows: reportRows,
        ),
        isLoading: false,
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load reports: $error',
      );
    }
  }
}

double _toDouble(dynamic value) {
  return switch (value) {
    num v => v.toDouble(),
    String v => double.tryParse(v) ?? 0,
    _ => 0,
  };
}

class _Accumulator {
  _Accumulator({required this.storeId, required this.restaurantName});
  final String storeId;
  final String restaurantName;
  double dineIn = 0;
  double delivery = 0;
}

final superAdminProvider =
    StateNotifierProvider<SuperAdminNotifier, SuperAdminState>(
      (ref) => SuperAdminNotifier(),
    );
