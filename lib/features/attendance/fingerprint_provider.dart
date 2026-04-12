import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/attendance_service.dart';
import '../../core/hardware/zkteco_fingerprint_service.dart';
import '../../main.dart';

class FingerprintState {
  const FingerprintState({
    this.isInitialized = false,
    this.isCapturing = false,
    this.isEnrolling = false,
    this.lastIdentifiedUserId,
    this.lastIdentifiedUserName,
    this.attendanceType,
    this.error,
    this.successMessage,
  });

  final bool isInitialized;
  final bool isCapturing;
  final bool isEnrolling;
  final String? lastIdentifiedUserId;
  final String? lastIdentifiedUserName;
  final String? attendanceType;
  final String? error;
  final String? successMessage;

  FingerprintState copyWith({
    bool? isInitialized,
    bool? isCapturing,
    bool? isEnrolling,
    String? lastIdentifiedUserId,
    String? lastIdentifiedUserName,
    String? attendanceType,
    String? error,
    String? successMessage,
    bool clearResult = false,
    bool clearError = false,
    bool clearSuccess = false,
  }) {
    return FingerprintState(
      isInitialized: isInitialized ?? this.isInitialized,
      isCapturing: isCapturing ?? this.isCapturing,
      isEnrolling: isEnrolling ?? this.isEnrolling,
      lastIdentifiedUserId: clearResult
          ? null
          : (lastIdentifiedUserId ?? this.lastIdentifiedUserId),
      lastIdentifiedUserName: clearResult
          ? null
          : (lastIdentifiedUserName ?? this.lastIdentifiedUserName),
      attendanceType: clearResult
          ? null
          : (attendanceType ?? this.attendanceType),
      error: clearError ? null : (error ?? this.error),
      successMessage: clearSuccess
          ? null
          : (successMessage ?? this.successMessage),
    );
  }
}

class FingerprintNotifier extends StateNotifier<FingerprintState> {
  FingerprintNotifier() : super(const FingerprintState());

  final _service = createFingerprintService();

  Future<void> initialize() async {
    state = state.copyWith(
      isInitialized: false,
      error: 'Fingerprint attendance is currently disabled.',
      clearSuccess: true,
    );
  }

  Future<bool> enrollFingerprint({
    required String userId,
    required String storeId,
    required int fingerIndex,
  }) async {
    state = state.copyWith(
      isEnrolling: false,
      error: 'Fingerprint attendance is currently disabled.',
      clearSuccess: true,
    );
    return false;
  }

  Future<void> identifyAndRecord(String storeId) async {
    state = state.copyWith(
      isCapturing: false,
      clearResult: true,
      clearSuccess: true,
      error: 'Fingerprint attendance is currently disabled.',
    );
  }

  void clearResult() {
    state = state.copyWith(
      clearResult: true,
      clearError: true,
      clearSuccess: true,
    );
  }

  @override
  void dispose() {
    unawaited(_service.dispose());
    super.dispose();
  }
}

final fingerprintProvider =
    StateNotifierProvider<FingerprintNotifier, FingerprintState>((ref) {
      return FingerprintNotifier();
    });

final staffFingerprintCountProvider = FutureProvider.family<int, String>((
  ref,
  userId,
) async {
  return 0;
});

final restaurantNameProvider = FutureProvider.family<String, String>((
  ref,
  storeId,
) async {
  final response = await supabase
      .from('restaurants')
      .select('name')
      .eq('id', storeId)
      .single();
  final name = response['name']?.toString().trim();
  if (name == null || name.isEmpty) {
    return 'GLOBOS POS';
  }
  return name;
});

class AttendanceKioskState {
  const AttendanceKioskState({
    this.staffList = const [],
    this.isLoading = false,
    this.isUploading = false,
    this.error,
    this.lastAction,
  });

  final List<Map<String, dynamic>> staffList;
  final bool isLoading;
  final bool isUploading;
  final String? error;
  final String? lastAction;

  AttendanceKioskState copyWith({
    List<Map<String, dynamic>>? staffList,
    bool? isLoading,
    bool? isUploading,
    String? error,
    String? lastAction,
    bool clearError = false,
    bool clearLastAction = false,
  }) {
    return AttendanceKioskState(
      staffList: staffList ?? this.staffList,
      isLoading: isLoading ?? this.isLoading,
      isUploading: isUploading ?? this.isUploading,
      error: clearError ? null : (error ?? this.error),
      lastAction: clearLastAction ? null : (lastAction ?? this.lastAction),
    );
  }
}

class AttendanceKioskNotifier extends StateNotifier<AttendanceKioskState> {
  AttendanceKioskNotifier() : super(const AttendanceKioskState());

  Future<void> loadStaff(String storeId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final staff = await attendanceService.fetchStaffList(storeId);
      state = state.copyWith(
        staffList: staff,
        isLoading: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapAttendanceError(e, 'Failed to load staff list.'),
      );
    }
  }

  Future<bool> recordAttendance({
    required String userId,
    required String storeId,
    required String type,
    File? photoFile,
  }) async {
    state = state.copyWith(
      isUploading: true,
      clearError: true,
      clearLastAction: true,
    );

    String? photoUrl;
    try {
      if (photoFile != null) {
        try {
          photoUrl = await attendanceService.uploadAttendancePhoto(
            storeId: storeId,
            userId: userId,
            originalFile: photoFile,
            type: type,
          );
        } catch (_) {
          photoUrl = null;
          state = state.copyWith(error: 'PHOTO_UPLOAD_FAILED');
        }
      }

      await attendanceService.logAttendance(
        storeId: storeId,
        userId: userId,
        type: type,
        photoUrl: photoUrl,
      );

      state = state.copyWith(isUploading: false, lastAction: type);
      return true;
    } catch (e) {
      state = state.copyWith(
        isUploading: false,
        error: _mapAttendanceError(e, 'Failed to record attendance.'),
      );
      return false;
    }
  }

  String _mapAttendanceError(Object error, String fallback) {
    final message = error is PostgrestException ? error.message : '$error';

    if (message.contains('ATTENDANCE_STAFF_DIRECTORY_FORBIDDEN')) {
      return 'No permission to view attendance staff for this store.';
    }
    if (message.contains('ATTENDANCE_EVENT_FORBIDDEN')) {
      return 'No permission to record attendance events.';
    }
    if (message.contains('ATTENDANCE_EVENT_USER_REQUIRED') ||
        message.contains('ATTENDANCE_EVENT_USER_NOT_FOUND')) {
      return 'Re-select a valid employee.';
    }
    if (message.contains('ATTENDANCE_EVENT_TYPE_INVALID')) {
      return 'Only clock-in or clock-out can be recorded.';
    }

    return fallback;
  }

  void clearTransientState() {
    state = state.copyWith(clearError: true, clearLastAction: true);
  }
}

final attendanceKioskProvider =
    StateNotifierProvider<AttendanceKioskNotifier, AttendanceKioskState>((ref) {
      return AttendanceKioskNotifier();
    });
