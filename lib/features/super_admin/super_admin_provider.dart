import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../main.dart';

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
  });

  final String id;
  final String name;
  final String slug;
  final String address;
  final String operationMode;
  final double? perPersonCharge;
  final bool isActive;
  final DateTime createdAt;

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
      operationMode: json['operation_mode']?.toString().toLowerCase() ?? 'standard',
      perPersonCharge: charge,
      isActive: json['is_active'] == true,
      createdAt: createdAtRaw != null
          ? DateTime.tryParse(createdAtRaw) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

class SuperAdminRestaurantReport {
  const SuperAdminRestaurantReport({
    required this.restaurantId,
    required this.restaurantName,
    required this.dineIn,
    required this.delivery,
    required this.total,
  });

  final String restaurantId;
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
    this.selectedRestaurant,
    this.reportSummary,
    required this.reportStart,
    required this.reportEnd,
    this.isLoading = false,
    this.error,
  });

  final List<SuperRestaurant> restaurants;
  final SuperRestaurant? selectedRestaurant;
  final SuperAdminReportSummary? reportSummary;
  final DateTime reportStart;
  final DateTime reportEnd;
  final bool isLoading;
  final String? error;

  SuperAdminState copyWith({
    List<SuperRestaurant>? restaurants,
    SuperRestaurant? selectedRestaurant,
    SuperAdminReportSummary? reportSummary,
    DateTime? reportStart,
    DateTime? reportEnd,
    bool? isLoading,
    String? error,
    bool clearSelectedRestaurant = false,
    bool clearReportSummary = false,
    bool clearError = false,
  }) {
    return SuperAdminState(
      restaurants: restaurants ?? this.restaurants,
      selectedRestaurant: clearSelectedRestaurant
          ? null
          : (selectedRestaurant ?? this.selectedRestaurant),
      reportSummary: clearReportSummary ? null : (reportSummary ?? this.reportSummary),
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
      final response = await supabase.from('restaurants').select().order('created_at', ascending: false);
      final restaurants = response
          .map<SuperRestaurant>((row) => SuperRestaurant.fromJson(Map<String, dynamic>.from(row)))
          .toList();
      state = state.copyWith(restaurants: restaurants, isLoading: false, clearError: true);
    } catch (error) {
      state = state.copyWith(isLoading: false, error: 'Failed to load restaurants: $error');
    }
  }

  Future<bool> addRestaurant({
    required String name,
    required String address,
    required String slug,
    required String operationMode,
    required double? perPersonCharge,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await supabase.from('restaurants').insert({
        'name': name,
        'address': address.isEmpty ? null : address,
        'slug': slug,
        'operation_mode': operationMode.toLowerCase(),
        'per_person_charge': perPersonCharge,
        'is_active': true,
      });
      await loadAllRestaurants();
      return true;
    } catch (error) {
      state = state.copyWith(isLoading: false, error: 'Failed to create restaurant: $error');
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
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await supabase
          .from('restaurants')
          .update({
            'name': name,
            'address': address.isEmpty ? null : address,
            'slug': slug,
            'operation_mode': operationMode.toLowerCase(),
            'per_person_charge': perPersonCharge,
          })
          .eq('id', id);
      await loadAllRestaurants();
      return true;
    } catch (error) {
      state = state.copyWith(isLoading: false, error: 'Failed to update restaurant: $error');
      return false;
    }
  }

  Future<bool> deactivateRestaurant(String id) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await supabase.from('restaurants').update({'is_active': false}).eq('id', id);
      await loadAllRestaurants();
      return true;
    } catch (error) {
      state = state.copyWith(isLoading: false, error: 'Failed to deactivate restaurant: $error');
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
          restaurantId: restaurant.id,
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
            .select('amount, sales_channel, orders(sales_channel)')
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
          String channel = payment['sales_channel']?.toString() ?? '';
          final orderRaw = payment['orders'];
          if (channel.isEmpty && orderRaw is Map<String, dynamic>) {
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

      final reportRows = accumulators.values
          .map(
            (value) => SuperAdminRestaurantReport(
              restaurantId: value.restaurantId,
              restaurantName: value.restaurantName,
              dineIn: value.dineIn,
              delivery: value.delivery,
              total: value.dineIn + value.delivery,
            ),
          )
          .toList()
        ..sort((a, b) => b.total.compareTo(a.total));

      final dineInTotal = reportRows.fold<double>(0, (sum, row) => sum + row.dineIn);
      final deliveryTotal = reportRows.fold<double>(0, (sum, row) => sum + row.delivery);

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
      state = state.copyWith(isLoading: false, error: 'Failed to load reports: $error');
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
  _Accumulator({required this.restaurantId, required this.restaurantName});
  final String restaurantId;
  final String restaurantName;
  double dineIn = 0;
  double delivery = 0;
}

final superAdminProvider = StateNotifierProvider<SuperAdminNotifier, SuperAdminState>(
  (ref) => SuperAdminNotifier(),
);
