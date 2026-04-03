import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    if (!_service.isSupported) {
      state = state.copyWith(
        isInitialized: false,
        error: '이 기기에서는 지문 인식기를 지원하지 않습니다.',
      );
      return;
    }

    final ok = await _service.init();
    state = state.copyWith(
      isInitialized: ok,
      error: ok ? null : 'ZK9500 연결 실패. USB 케이블을 확인해주세요.',
      clearSuccess: true,
    );
  }

  Future<bool> enrollFingerprint({
    required String userId,
    required String restaurantId,
    required int fingerIndex,
  }) async {
    state = state.copyWith(
      isEnrolling: true,
      clearError: true,
      clearSuccess: true,
    );

    try {
      final template = await _service.captureTemplate();
      if (template == null || template.isEmpty) {
        state = state.copyWith(
          isEnrolling: false,
          error: '지문 인식 실패. 다시 시도해주세요.',
        );
        return false;
      }

      await supabase.from('fingerprint_templates').upsert({
        'user_id': userId,
        'restaurant_id': restaurantId,
        'template_data': template,
        'finger_index': fingerIndex,
      }, onConflict: 'user_id,finger_index');

      state = state.copyWith(
        isEnrolling: false,
        successMessage: '지문 등록 완료!',
        clearError: true,
      );
      return true;
    } catch (error) {
      state = state.copyWith(isEnrolling: false, error: error.toString());
      return false;
    }
  }

  Future<void> identifyAndRecord(String restaurantId) async {
    if (!state.isInitialized) {
      state = state.copyWith(error: '지문 인식기가 연결되지 않았습니다.');
      return;
    }

    state = state.copyWith(
      isCapturing: true,
      clearError: true,
      clearResult: true,
      clearSuccess: true,
    );

    try {
      final capturedTemplate = await _service.captureTemplate();
      if (capturedTemplate == null || capturedTemplate.isEmpty) {
        state = state.copyWith(
          isCapturing: false,
          error: '지문 인식 실패. 다시 시도해주세요.',
        );
        return;
      }

      final rows = await supabase
          .from('fingerprint_templates')
          .select('user_id, template_data, users(full_name)')
          .eq('restaurant_id', restaurantId);

      String? matchedUserId;
      String? matchedUserName;

      for (final row in rows) {
        final map = Map<String, dynamic>.from(row);
        final storedTemplate = map['template_data']?.toString() ?? '';
        if (storedTemplate.isEmpty) {
          continue;
        }

        final isMatch = await _service.matchTemplate(
          capturedTemplate,
          storedTemplate,
        );
        if (!isMatch) {
          continue;
        }

        matchedUserId = map['user_id']?.toString();
        final userData = map['users'];
        if (userData is Map<String, dynamic>) {
          matchedUserName = userData['full_name']?.toString();
        }
        break;
      }

      if (matchedUserId == null) {
        state = state.copyWith(isCapturing: false, error: '등록되지 않은 지문입니다.');
        return;
      }

      final lastLog = await supabase
          .from('attendance_logs')
          .select('type')
          .eq('restaurant_id', restaurantId)
          .eq('user_id', matchedUserId)
          .order('logged_at', ascending: false)
          .limit(1)
          .maybeSingle();

      final lastType = lastLog?['type']?.toString();
      final newType = lastType == 'clock_in' ? 'clock_out' : 'clock_in';

      await supabase.from('attendance_logs').insert({
        'restaurant_id': restaurantId,
        'user_id': matchedUserId,
        'type': newType,
        'logged_at': DateTime.now().toUtc().toIso8601String(),
      });

      final safeName = matchedUserName ?? '스태프';
      state = state.copyWith(
        isCapturing: false,
        lastIdentifiedUserId: matchedUserId,
        lastIdentifiedUserName: safeName,
        attendanceType: newType,
        successMessage: newType == 'clock_in'
            ? '출근 완료: $safeName'
            : '퇴근 완료: $safeName',
      );

      await Future<void>.delayed(const Duration(seconds: 3));
      if (mounted) {
        state = state.copyWith(
          clearResult: true,
          clearSuccess: true,
          clearError: true,
        );
      }
    } catch (error) {
      state = state.copyWith(isCapturing: false, error: error.toString());
    }
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
  final response = await supabase
      .from('fingerprint_templates')
      .select('id')
      .eq('user_id', userId);
  return response.length;
});

final restaurantNameProvider = FutureProvider.family<String, String>((
  ref,
  restaurantId,
) async {
  final response = await supabase
      .from('restaurants')
      .select('name')
      .eq('id', restaurantId)
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

  Future<void> loadStaff(String restaurantId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final staff = await attendanceService.fetchStaffList(restaurantId);
      state = state.copyWith(
        staffList: staff,
        isLoading: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: '$e');
    }
  }

  Future<bool> recordAttendance({
    required String userId,
    required String restaurantId,
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
            restaurantId: restaurantId,
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
        restaurantId: restaurantId,
        userId: userId,
        type: type,
        photoUrl: photoUrl,
      );

      state = state.copyWith(isUploading: false, lastAction: type);
      return true;
    } catch (e) {
      state = state.copyWith(isUploading: false, error: '$e');
      return false;
    }
  }

  void clearTransientState() {
    state = state.copyWith(clearError: true, clearLastAction: true);
  }
}

final attendanceKioskProvider =
    StateNotifierProvider<AttendanceKioskNotifier, AttendanceKioskState>((ref) {
      return AttendanceKioskNotifier();
    });
