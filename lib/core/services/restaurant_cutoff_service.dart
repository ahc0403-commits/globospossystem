import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../main.dart';

class RestaurantCutoffState {
  const RestaurantCutoffState({
    required this.isRestaurant,
    required this.phase,
    required this.canCreateOrder,
    required this.canCompletePayment,
    this.observedAt,
  });

  const RestaurantCutoffState.unrestricted()
    : isRestaurant = false,
      phase = 'not_applicable',
      canCreateOrder = true,
      canCompletePayment = true,
      observedAt = null;

  final bool isRestaurant;
  final String phase;
  final bool canCreateOrder;
  final bool canCompletePayment;
  final DateTime? observedAt;

  factory RestaurantCutoffState.fromJson(Map<String, dynamic> json) {
    return RestaurantCutoffState(
      isRestaurant: json['is_restaurant'] == true,
      phase: json['phase']?.toString() ?? 'not_applicable',
      canCreateOrder: json['can_create_order'] != false,
      canCompletePayment: json['can_complete_payment'] != false,
      observedAt: DateTime.tryParse(json['observed_at']?.toString() ?? ''),
    );
  }
}

class RestaurantCutoffService {
  Future<RestaurantCutoffState> fetchState(String storeId) async {
    final response = await supabase.rpc(
      'get_restaurant_cutoff_state',
      params: {'p_store_id': storeId},
    );
    return RestaurantCutoffState.fromJson(
      Map<String, dynamic>.from(response as Map),
    );
  }
}

final restaurantCutoffService = RestaurantCutoffService();

final restaurantCutoffStateProvider = StreamProvider.autoDispose
    .family<RestaurantCutoffState, String>((ref, storeId) async* {
      while (true) {
        try {
          yield await restaurantCutoffService.fetchState(storeId);
        } catch (_) {
          // Advisory only: database mutation guards remain authoritative.
          yield const RestaurantCutoffState.unrestricted();
        }
        await Future<void>.delayed(const Duration(seconds: 15));
      }
    });
