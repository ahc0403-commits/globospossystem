import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../main.dart';

class SettingsState {
  const SettingsState({
    this.isLoading = false,
    this.isSavingRestaurant = false,
    this.isSavingProfile = false,
    this.error,
    this.restaurantId,
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
  final String? restaurantId;
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
    String? restaurantId,
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
      restaurantId: restaurantId ?? this.restaurantId,
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

  Future<void> loadSettings(String restaurantId, String authUid) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final restaurantData = await supabase
          .from('restaurants')
          .select()
          .eq('id', restaurantId)
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
        restaurantId: restaurantData['id']?.toString(),
        restaurantName: restaurantData['name']?.toString() ?? '',
        address: restaurantData['address']?.toString() ?? '',
        operationMode: restaurantData['operation_mode']?.toString().toLowerCase() ?? 'standard',
        perPersonCharge: charge,
        fullName: userData['full_name']?.toString() ?? '',
        role: userData['role']?.toString() ?? '',
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load settings: $error',
      );
    }
  }

  Future<bool> saveRestaurant({
    required String name,
    required String address,
    required String operationMode,
    required double? perPersonCharge,
  }) async {
    final restaurantId = state.restaurantId;
    if (restaurantId == null) {
      state = state.copyWith(error: 'Restaurant is not available.');
      return false;
    }

    state = state.copyWith(isSavingRestaurant: true, clearError: true);
    try {
      await supabase
          .from('restaurants')
          .update({
            'name': name,
            'address': address.isEmpty ? null : address,
            'operation_mode': operationMode.toLowerCase(),
            'per_person_charge': perPersonCharge,
          })
          .eq('id', restaurantId);

      state = state.copyWith(
        isSavingRestaurant: false,
        restaurantName: name,
        address: address,
        operationMode: operationMode.toLowerCase(),
        perPersonCharge: perPersonCharge,
        clearError: true,
      );
      return true;
    } catch (error) {
      state = state.copyWith(
        isSavingRestaurant: false,
        error: 'Failed to update restaurant: $error',
      );
      return false;
    }
  }

  Future<bool> updateFullName(String authUid, String fullName) async {
    state = state.copyWith(isSavingProfile: true, clearError: true);
    try {
      await supabase
          .from('users')
          .update({'full_name': fullName})
          .eq('auth_id', authUid);

      state = state.copyWith(
        isSavingProfile: false,
        fullName: fullName,
        clearError: true,
      );
      return true;
    } catch (error) {
      state = state.copyWith(
        isSavingProfile: false,
        error: 'Failed to update profile: $error',
      );
      return false;
    }
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, SettingsState>(
  (ref) => SettingsNotifier(),
);
