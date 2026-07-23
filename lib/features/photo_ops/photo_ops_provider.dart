import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_provider.dart';
import 'photo_ops_service.dart';

class PhotoOpsState {
  const PhotoOpsState({
    this.isLoading = false,
    this.data,
    this.error,
    this.lastLoadedStoreId,
    this.salesStartDate,
    this.salesEndDate,
  });

  final bool isLoading;
  final PhotoOpsDashboardData? data;
  final String? error;
  final String? lastLoadedStoreId;
  final DateTime? salesStartDate;
  final DateTime? salesEndDate;

  PhotoOpsState copyWith({
    bool? isLoading,
    PhotoOpsDashboardData? data,
    String? error,
    String? lastLoadedStoreId,
    DateTime? salesStartDate,
    DateTime? salesEndDate,
    bool clearError = false,
  }) {
    return PhotoOpsState(
      isLoading: isLoading ?? this.isLoading,
      data: data ?? this.data,
      error: clearError ? null : (error ?? this.error),
      lastLoadedStoreId: lastLoadedStoreId ?? this.lastLoadedStoreId,
      salesStartDate: salesStartDate ?? this.salesStartDate,
      salesEndDate: salesEndDate ?? this.salesEndDate,
    );
  }
}

class PhotoOpsNotifier extends StateNotifier<PhotoOpsState> {
  PhotoOpsNotifier(this._ref)
    : super(
        PhotoOpsState(
          salesStartDate: _photoOpsDefaultSalesStart(),
          salesEndDate: _photoOpsToday(),
        ),
      );

  final Ref _ref;

  Future<void> setSalesDateRange(DateTime start, DateTime end) async {
    final normalizedStart = DateTime(start.year, start.month, start.day);
    final normalizedEnd = DateTime(end.year, end.month, end.day);
    if (normalizedEnd.isBefore(normalizedStart)) return;
    state = state.copyWith(
      salesStartDate: normalizedStart,
      salesEndDate: normalizedEnd,
      clearError: true,
    );
    await load();
  }

  Future<void> load() async {
    final auth = _ref.read(authProvider);
    final activeStoreId = auth.storeId;
    final accessibleStoreIds = auth.accessibleStores
        .map((store) => store.id)
        .toList();

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
      final data = auth.role == 'photo_objet_store_operator'
          ? await photoOpsService.loadOperatorDashboard(
              activeStoreId: activeStoreId,
            )
          : await photoOpsService.loadDashboard(
              activeStoreId: activeStoreId,
              accessibleStoreIds: accessibleStoreIds,
              salesStartDate:
                  state.salesStartDate ?? _photoOpsDefaultSalesStart(),
              salesEndDate: state.salesEndDate ?? _photoOpsToday(),
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

final photoOpsProvider = StateNotifierProvider<PhotoOpsNotifier, PhotoOpsState>(
  (ref) => PhotoOpsNotifier(ref),
);

DateTime _photoOpsToday() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

DateTime _photoOpsDefaultSalesStart() =>
    _photoOpsToday().subtract(const Duration(days: 6));
