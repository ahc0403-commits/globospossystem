import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_provider.dart';
import 'photo_ops_service.dart';

class PhotoOpsState {
  const PhotoOpsState({
    this.isLoading = false,
    this.data,
    this.error,
    this.lastLoadedStoreId,
  });

  final bool isLoading;
  final PhotoOpsDashboardData? data;
  final String? error;
  final String? lastLoadedStoreId;

  PhotoOpsState copyWith({
    bool? isLoading,
    PhotoOpsDashboardData? data,
    String? error,
    String? lastLoadedStoreId,
    bool clearError = false,
  }) {
    return PhotoOpsState(
      isLoading: isLoading ?? this.isLoading,
      data: data ?? this.data,
      error: clearError ? null : (error ?? this.error),
      lastLoadedStoreId: lastLoadedStoreId ?? this.lastLoadedStoreId,
    );
  }
}

class PhotoOpsNotifier extends StateNotifier<PhotoOpsState> {
  PhotoOpsNotifier(this._ref) : super(const PhotoOpsState());

  final Ref _ref;

  Future<void> load() async {
    final auth = _ref.read(authProvider);
    final activeStoreId = auth.storeId;
    final accessibleStoreIds =
        auth.accessibleStores.map((store) => store.id).toList();

    if (activeStoreId == null || accessibleStoreIds.isEmpty) {
      state = state.copyWith(
        isLoading: false,
        data: null,
        error: 'No active store is available for Photo Objet.',
        lastLoadedStoreId: null,
      );
      return;
    }

    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final data = await photoOpsService.loadDashboard(
        activeStoreId: activeStoreId,
        accessibleStoreIds: accessibleStoreIds,
      );
      state = state.copyWith(
        isLoading: false,
        data: data,
        lastLoadedStoreId: activeStoreId,
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load Photo Objet dashboard: $error',
      );
    }
  }
}

final photoOpsProvider =
    StateNotifierProvider<PhotoOpsNotifier, PhotoOpsState>(
      (ref) => PhotoOpsNotifier(ref),
    );
