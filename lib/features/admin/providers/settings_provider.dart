import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/store_service.dart';
import '../../../core/services/staff_service.dart';
import '../../../main.dart';

class SettingsState {
  const SettingsState({
    this.isLoading = false,
    this.isSavingRestaurant = false,
    this.isSavingProfile = false,
    this.error,
    this.storeId,
    this.restaurantName = '',
    this.address = '',
    this.operationMode = 'standard',
    this.perPersonCharge,
    this.fullName = '',
    this.role = '',
  });

  final bool isLoading;
  final bool isSavingRestaurant;
  final bool isSavingProfile;
  final String? error;
  final String? storeId;
  final String restaurantName;
  final String address;
  final String operationMode;
  final double? perPersonCharge;
  final String fullName;
  final String role;

  SettingsState copyWith({
    bool? isLoading,
    bool? isSavingRestaurant,
    bool? isSavingProfile,
    String? error,
    String? storeId,
    String? restaurantName,
    String? address,
    String? operationMode,
    double? perPersonCharge,
    String? fullName,
    String? role,
    bool clearError = false,
  }) {
    return SettingsState(
      isLoading: isLoading ?? this.isLoading,
      isSavingRestaurant: isSavingRestaurant ?? this.isSavingRestaurant,
      isSavingProfile: isSavingProfile ?? this.isSavingProfile,
      error: clearError ? null : (error ?? this.error),
      storeId: storeId ?? this.storeId,
      restaurantName: restaurantName ?? this.restaurantName,
      address: address ?? this.address,
      operationMode: operationMode ?? this.operationMode,
      perPersonCharge: perPersonCharge ?? this.perPersonCharge,
      fullName: fullName ?? this.fullName,
      role: role ?? this.role,
    );
  }
}

class SettingsNotifier extends StateNotifier<SettingsState> {
  SettingsNotifier() : super(const SettingsState());

  String _mapSettingsError(Object error, String fallback) {
    if (error is! PostgrestException) {
      return fallback;
    }

    final message = error.message;
    if (message.contains('RESTAURANT_NAME_REQUIRED')) {
      return 'Enter a store name.';
    }
    if (message.contains('RESTAURANT_OPERATION_MODE_REQUIRED')) {
      return 'Re-select operation mode.';
    }
    if (message.contains('RESTAURANT_NOT_FOUND')) {
      return 'Store info not found. Please reload.';
    }
    if (message.contains('ADMIN_MUTATION_FORBIDDEN')) {
      return 'No permission to change store settings.';
    }
    if (message.contains('USER_FULL_NAME_REQUIRED')) {
      return 'Enter a name.';
    }
    if (message.contains('USER_PROFILE_UPDATE_FORBIDDEN')) {
      return 'No permission to edit profile.';
    }

    return fallback;
  }

  Future<void> loadSettings(String storeId, String authUid) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final restaurantData = await supabase
          .from('restaurants')
          .select()
          .eq('id', storeId)
          .single();

      final userData = await supabase
          .from('users')
          .select('full_name, role')
          .eq('auth_id', authUid)
          .single();

      final rawCharge = restaurantData['per_person_charge'];
      final charge = switch (rawCharge) {
        num value => value.toDouble(),
        String value => double.tryParse(value),
        _ => null,
      };

      state = state.copyWith(
        isLoading: false,
        storeId: restaurantData['id']?.toString(),
        restaurantName: restaurantData['name']?.toString() ?? '',
        address: restaurantData['address']?.toString() ?? '',
        operationMode:
            restaurantData['operation_mode']?.toString().toLowerCase() ??
            'standard',
        perPersonCharge: charge,
        fullName: userData['full_name']?.toString() ?? '',
        role: userData['role']?.toString() ?? '',
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(isLoading: false, error: 'Failed to load settings.');
    }
  }

  Future<bool> saveRestaurant({
    required String name,
    required String address,
    required String operationMode,
    required double? perPersonCharge,
  }) async {
    final storeId = state.storeId;
    if (storeId == null) {
      state = state.copyWith(error: 'Store is not available.');
      return false;
    }

    final normalizedName = name.trim();
    final normalizedAddress = address.trim();
    final normalizedMode = operationMode.toLowerCase();
    final currentAddress = state.address.trim();
    final currentMode = state.operationMode.toLowerCase();
    final currentCharge = state.perPersonCharge;

    if (normalizedName.isEmpty) {
      state = state.copyWith(error: 'Enter a store name.');
      return false;
    }

    final hasChanges =
        normalizedName != state.restaurantName.trim() ||
        normalizedAddress != currentAddress ||
        normalizedMode != currentMode ||
        perPersonCharge != currentCharge;

    if (!hasChanges) {
      state = state.copyWith(error: 'No store setting changes.');
      return false;
    }

    state = state.copyWith(isSavingRestaurant: true, clearError: true);
    try {
      await restaurantService.updateRestaurantSettings(
        id: storeId,
        name: normalizedName,
        operationMode: normalizedMode,
        address: normalizedAddress.isEmpty ? null : normalizedAddress,
        perPersonCharge: perPersonCharge,
      );

      state = state.copyWith(
        isSavingRestaurant: false,
        restaurantName: normalizedName,
        address: normalizedAddress,
        operationMode: normalizedMode,
        perPersonCharge: perPersonCharge,
        clearError: true,
      );
      return true;
    } catch (error) {
      state = state.copyWith(
        isSavingRestaurant: false,
        error: _mapSettingsError(error, 'Failed to save store settings.'),
      );
      return false;
    }
  }

  Future<bool> updateFullName(String fullName) async {
    final normalized = fullName.trim();
    if (normalized.isEmpty) {
      state = state.copyWith(error: 'Enter a name.');
      return false;
    }

    if (normalized == state.fullName.trim()) {
      state = state.copyWith(error: 'No name change.');
      return false;
    }

    state = state.copyWith(isSavingProfile: true, clearError: true);
    try {
      await staffService.updateMyFullName(normalized);

      state = state.copyWith(
        isSavingProfile: false,
        fullName: normalized,
        clearError: true,
      );
      return true;
    } catch (error) {
      state = state.copyWith(
        isSavingProfile: false,
        error: _mapSettingsError(error, 'Failed to save profile.'),
      );
      return false;
    }
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, SettingsState>(
  (ref) => SettingsNotifier(),
);
