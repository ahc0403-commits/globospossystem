import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/store_service.dart';
import '../../main.dart';
import '../auth/auth_provider.dart';

class OnboardingState {
  const OnboardingState({
    this.step = 0,
    this.isLoading = false,
    this.error,
    this.createdStoreId,
    this.createdStoreName,
  });

  final int step;
  final bool isLoading;
  final String? error;
  final String? createdStoreId;
  final String? createdStoreName;

  OnboardingState copyWith({
    int? step,
    bool? isLoading,
    String? error,
    String? createdStoreId,
    String? createdStoreName,
    bool clearError = false,
  }) {
    return OnboardingState(
      step: step ?? this.step,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      createdStoreId: createdStoreId ?? this.createdStoreId,
      createdStoreName: createdStoreName ?? this.createdStoreName,
    );
  }
}

class OnboardingNotifier extends StateNotifier<OnboardingState> {
  OnboardingNotifier(this.ref) : super(const OnboardingState());

  final Ref ref;

  Future<void> createStore(
    String name,
    String address,
    String operationMode,
    double? perPersonCharge,
  ) async {
    final authState = ref.read(authProvider);
    if (authState.role != 'super_admin') {
      state = state.copyWith(error: 'Only super_admin can create stores');
      return;
    }
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final inserted = await storeService.createStore(
        name: name,
        slug: '',
        operationMode: operationMode,
        address: address.isEmpty ? null : address,
        perPersonCharge: perPersonCharge,
      );

      state = state.copyWith(
        isLoading: false,
        step: 1,
        createdStoreId: inserted['id']?.toString(),
        createdStoreName: inserted['name']?.toString(),
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to create store: $error',
      );
    }
  }

  Future<void> createAdminAccount(String fullName, String role) async {
    final authState = ref.read(authProvider);
    final user = authState.user;
    final storeId = state.createdStoreId;
    if (user == null || storeId == null) {
      state = state.copyWith(
        error: 'Missing user or store setup information.',
      );
      return;
    }

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await supabase.rpc(
        'complete_onboarding_account_setup',
        params: {
          'p_store_id': storeId,
          'p_full_name': fullName,
          'p_role': role,
        },
      );

      state = state.copyWith(isLoading: false, step: 2, clearError: true);
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to update profile: $error',
      );
    }
  }

  Future<void> finish() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await ref.read(authProvider.notifier).refreshProfile();
      state = state.copyWith(isLoading: false, clearError: true);
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to finalize onboarding: $error',
      );
    }
  }
}

final onboardingProvider =
    StateNotifierProvider<OnboardingNotifier, OnboardingState>(
      (ref) => OnboardingNotifier(ref),
    );
