import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/attendance_service.dart';

class AttendanceKioskState {
  const AttendanceKioskState({
    this.isSubmitting = false,
    this.errorCode,
    this.lastAction,
    this.lastEmployeeNumber,
  });

  final bool isSubmitting;
  final String? errorCode;
  final String? lastAction;
  final String? lastEmployeeNumber;

  AttendanceKioskState copyWith({
    bool? isSubmitting,
    String? errorCode,
    String? lastAction,
    String? lastEmployeeNumber,
    bool clearError = false,
    bool clearResult = false,
  }) {
    return AttendanceKioskState(
      isSubmitting: isSubmitting ?? this.isSubmitting,
      errorCode: clearError ? null : (errorCode ?? this.errorCode),
      lastAction: clearResult ? null : (lastAction ?? this.lastAction),
      lastEmployeeNumber: clearResult
          ? null
          : (lastEmployeeNumber ?? this.lastEmployeeNumber),
    );
  }
}

class AttendanceKioskNotifier extends StateNotifier<AttendanceKioskState> {
  AttendanceKioskNotifier() : super(const AttendanceKioskState());

  Future<bool> recordAttendance({
    required String employeeNumber,
    required String storeId,
    required String type,
  }) async {
    state = state.copyWith(
      isSubmitting: true,
      clearError: true,
      clearResult: true,
    );

    final normalizedNumber = employeeNumber.trim().toUpperCase();
    try {
      await attendanceService.recordEmployeeAttendance(
        storeId: storeId,
        employeeNumber: normalizedNumber,
        type: type,
      );
      state = state.copyWith(
        isSubmitting: false,
        lastAction: type,
        lastEmployeeNumber: normalizedNumber,
        clearError: true,
      );
      return true;
    } catch (error) {
      state = state.copyWith(
        isSubmitting: false,
        errorCode: _attendanceErrorCode(error),
      );
      return false;
    }
  }

  void clearResult() {
    state = state.copyWith(clearError: true, clearResult: true);
  }
}

String _attendanceErrorCode(Object error) {
  final message = error is PostgrestException ? error.message : '$error';
  if (message.contains('EMPLOYEE_NUMBER') ||
      message.contains('EMPLOYEE_NOT_FOUND')) {
    return 'EMPLOYEE_NOT_FOUND';
  }
  if (message.contains('EMPLOYEE_INACTIVE')) {
    return 'EMPLOYEE_INACTIVE';
  }
  if (message.contains('ATTENDANCE_TYPE') || message.contains('TYPE_INVALID')) {
    return 'ATTENDANCE_TYPE_INVALID';
  }
  if (message.contains('FORBIDDEN')) {
    return 'ATTENDANCE_FORBIDDEN';
  }
  return 'ATTENDANCE_RECORD_FAILED';
}

final attendanceKioskProvider =
    StateNotifierProvider<AttendanceKioskNotifier, AttendanceKioskState>(
      (ref) => AttendanceKioskNotifier(),
    );
