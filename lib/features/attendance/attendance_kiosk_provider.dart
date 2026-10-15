import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/attendance_service.dart';

class AttendanceKioskState {
  const AttendanceKioskState({
    this.isSubmitting = false,
    this.errorCode,
    this.lastAction,
    this.lastEmployeeNumber,
    this.needsVerification = false,
  });

  final bool isSubmitting;
  final String? errorCode;
  final String? lastAction;
  final String? lastEmployeeNumber;
  final bool needsVerification;

  AttendanceKioskState copyWith({
    bool? isSubmitting,
    String? errorCode,
    String? lastAction,
    String? lastEmployeeNumber,
    bool clearError = false,
    bool clearResult = false,
    bool? needsVerification,
  }) {
    return AttendanceKioskState(
      isSubmitting: isSubmitting ?? this.isSubmitting,
      needsVerification: needsVerification ?? this.needsVerification,
      errorCode: clearError ? null : (errorCode ?? this.errorCode),
      lastAction: clearResult ? null : (lastAction ?? this.lastAction),
      lastEmployeeNumber: clearResult
          ? null
          : (lastEmployeeNumber ?? this.lastEmployeeNumber),
    );
  }
}

class AttendanceKioskNotifier extends StateNotifier<AttendanceKioskState> {
  AttendanceKioskNotifier({AttendanceService? service})
    : _service = service ?? attendanceService,
      super(const AttendanceKioskState());

  final AttendanceService _service;
  AttendanceKioskState get currentState => state;
  (String, String, String, XFile)? _submission;
  String? _photoUrl;
  String? _uploadedPath;
  DateTime? _submittedAt;

  Future<bool> recordAttendance({
    required String employeeNumber,
    required String storeId,
    required String type,
    required XFile photoFile,
  }) async {
    if (state.isSubmitting) return false;
    final normalizedNumber = employeeNumber.trim().toUpperCase();
    final submission = (storeId, normalizedNumber, type, photoFile);
    if (_submission != submission) {
      clearResult();
      _submission = submission;
    }
    state = state.copyWith(
      isSubmitting: true,
      clearError: true,
      clearResult: true,
    );

    var savingRecord = false;
    try {
      if (state.needsVerification) {
        // An interrupted response may already have committed. This action only
        // checks the existing result; it must never submit another event.
        final rows = await _service.fetchLogs(
          storeId: storeId,
          from: _submittedAt!.subtract(const Duration(seconds: 5)),
          to: DateTime.now().toUtc().add(const Duration(seconds: 5)),
          limit: attendanceScreenRecordLimit,
        );
        final confirmed = rows.any(
          (row) =>
              row['photo_url'] == _photoUrl &&
              row['type'] == type &&
              row['employee_number']?.toString().trim().toUpperCase() ==
                  normalizedNumber,
        );
        if (!confirmed) throw StateError('ATTENDANCE_RESULT_UNCONFIRMED');
      } else {
        _photoUrl ??= _uploadedPath != null
            ? await _service.signEmployeeAttendancePhoto(_uploadedPath!)
            : await _service.uploadEmployeeAttendancePhoto(
                storeId: storeId,
                employeeNumber: normalizedNumber,
                originalFile: photoFile,
                type: type,
              );
        if (_photoUrl == null || _photoUrl!.isEmpty) {
          throw StateError('ATTENDANCE_PHOTO_UPLOAD_FAILED');
        }
        savingRecord = true;
        _submittedAt = DateTime.now().toUtc();
        await _service.recordEmployeeAttendance(
          storeId: storeId,
          employeeNumber: normalizedNumber,
          type: type,
          photoUrl: _photoUrl,
        );
      }
      if (!mounted) return false;
      state = state.copyWith(
        isSubmitting: false,
        lastAction: type,
        lastEmployeeNumber: normalizedNumber,
        clearError: true,
        needsVerification: false,
      );
      return true;
    } catch (error) {
      if (!mounted) return false;
      if (error is AttendancePhotoSigningException) {
        _uploadedPath = error.path;
      }
      final uncertain =
          state.needsVerification ||
          (savingRecord &&
              (error is! PostgrestException ||
                  !const {
                    'P0001',
                    '42501',
                    '23505',
                    '23503',
                    '22023',
                  }.contains(error.code)));
      state = state.copyWith(
        isSubmitting: false,
        needsVerification: uncertain,
        errorCode: uncertain
            ? 'ATTENDANCE_RESULT_UNCONFIRMED'
            : !savingRecord
            ? error is AttendancePhotoSigningException || _uploadedPath != null
                  ? 'ATTENDANCE_PHOTO_LINK_FAILED'
                  : error is TimeoutException || error is http.ClientException
                  ? 'ATTENDANCE_NETWORK_FAILED'
                  : 'ATTENDANCE_PHOTO_FAILED'
            : attendanceErrorCode(error),
      );
      return false;
    }
  }

  void clearResult() {
    if (state.isSubmitting) return;
    _submission = null;
    _photoUrl = null;
    _uploadedPath = null;
    _submittedAt = null;
    state = const AttendanceKioskState();
  }
}

String attendanceErrorCode(Object error) {
  final message = error is PostgrestException ? error.message : '$error';
  if (message.contains('ATTENDANCE_ALREADY_CLOCKED_IN')) {
    return 'ATTENDANCE_ALREADY_CLOCKED_IN_TODAY';
  }
  if (message.contains('ATTENDANCE_ALREADY_CLOCKED_OUT')) {
    return 'ATTENDANCE_ALREADY_CLOCKED_OUT_TODAY';
  }
  if (message.contains('ATTENDANCE_CLOCK_IN_REQUIRED')) {
    return 'ATTENDANCE_CLOCK_IN_REQUIRED';
  }
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
  if (message.contains('ATTENDANCE_PHOTO')) {
    return 'ATTENDANCE_PHOTO_FAILED';
  }
  return 'ATTENDANCE_RECORD_FAILED';
}

final attendanceKioskProvider =
    StateNotifierProvider<AttendanceKioskNotifier, AttendanceKioskState>(
      (ref) => AttendanceKioskNotifier(),
    );
