import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';
import 'rpc_compat.dart';

const attendanceScreenRecordLimit = 10;

class AttendanceService {
  Future<Map<String, dynamic>> recordEmployeeAttendance({
    required String storeId,
    required String employeeNumber,
    required String type,
    String? photoUrl,
  }) async {
    final response = await supabase.rpc(
      photoUrl == null
          ? 'record_employee_attendance'
          : 'record_employee_attendance_with_photo',
      params: {
        'p_store_id': storeId,
        'p_employee_number': employeeNumber.trim().toUpperCase(),
        'p_type': type,
        if (photoUrl != null) 'p_photo_url': photoUrl,
      },
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<String?> uploadEmployeeAttendancePhoto({
    required String storeId,
    required String employeeNumber,
    required XFile originalFile,
    required String type,
  }) async {
    return _uploadAttendancePhotoBytes(
      storeId: storeId,
      subjectId: employeeNumber.trim().toUpperCase(),
      bytes: await originalFile.readAsBytes(),
      type: type,
    );
  }

  Future<String?> uploadAttendancePhoto({
    required String storeId,
    required String userId,
    required File originalFile,
    required String type,
  }) async {
    return _uploadAttendancePhotoBytes(
      storeId: storeId,
      subjectId: userId,
      bytes: await originalFile.readAsBytes(),
      type: type,
    );
  }

  Future<String?> _uploadAttendancePhotoBytes({
    required String storeId,
    required String subjectId,
    required Uint8List bytes,
    required String type,
  }) async {
    final original = img.decodeImage(bytes);
    if (original == null) {
      return null;
    }

    final widthDominant = original.width >= original.height;
    final resized = img.copyResize(
      original,
      width: widthDominant ? 800 : null,
      height: widthDominant ? null : 800,
    );

    final compressed = Uint8List.fromList(img.encodeJpg(resized, quality: 70));

    final now = DateTime.now().toUtc();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final ts = now.millisecondsSinceEpoch;
    final safeSubjectId = subjectId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final path = '$storeId/$safeSubjectId/$dateStr/${ts}_$type.jpg';

    await supabase.storage
        .from('attendance-photos')
        .uploadBinary(
          path,
          compressed,
          fileOptions: const FileOptions(contentType: 'image/jpeg'),
        );

    final signedUrl = await supabase.storage
        .from('attendance-photos')
        .createSignedUrl(path, 60 * 60 * 24 * 365 * 10);

    return signedUrl;
  }

  Future<void> upsertFingerprintTemplate({
    required String userId,
    required String storeId,
    required String templateData,
    int fingerIndex = 0,
  }) async {
    throw UnsupportedError(
      'Fingerprint attendance is dormant and disabled by default.',
    );
  }

  Future<void> logAttendance({
    required String storeId,
    required String userId,
    required String type,
    String? photoUrl,
  }) async {
    await runRpcWithStoreCompat<dynamic>(
      fnName: 'record_attendance_event',
      params: {
        'p_store_id': storeId,
        'p_user_id': userId,
        'p_type': type,
        'p_photo_url': photoUrl,
        'p_photo_thumbnail_url': photoUrl,
      },
      invoke: (params) =>
          supabase.rpc('record_attendance_event', params: params),
    );
  }

  Future<List<Map<String, dynamic>>> fetchLogs({
    required String storeId,
    required DateTime from,
    required DateTime to,
    int limit = 500,
  }) async {
    if (limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'must be at least 1');
    }
    final result = await supabase.rpc(
      'get_attendance_logs_with_names',
      params: {
        'p_store_id': storeId,
        'p_from': from.toUtc().toIso8601String(),
        'p_to': to.toUtc().toIso8601String(),
        'p_limit': limit,
      },
    );

    return List<Map<String, dynamic>>.from(
      result,
    ).map(normalizeAttendanceLogRow).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> fetchStaffList(String storeId) async {
    final result = await supabase
        .from('store_employees')
        .select('id, employee_number, full_name, employment_role')
        .eq('store_id', storeId)
        .eq('is_active', true)
        .order('employee_number');
    return List<Map<String, dynamic>>.from(result)
        .map(
          (row) => {
            'user_id': row['id'],
            'employee_number': row['employee_number'],
            'full_name': row['full_name'],
            'role': row['employment_role'],
          },
        )
        .toList(growable: false);
  }

  Future<Map<String, dynamic>?> fetchWageConfig({
    required String storeId,
    required String userId,
  }) async {
    final result = await supabase
        .from('staff_wage_configs')
        .select()
        .eq('restaurant_id', storeId)
        .eq('user_id', userId)
        .eq('is_active', true)
        .order('effective_from', ascending: false)
        .limit(1)
        .maybeSingle();

    if (result == null) {
      return null;
    }
    return Map<String, dynamic>.from(result);
  }

  Future<Map<String, dynamic>?> fetchHourlyPayRule({
    required String storeId,
    required String employeeId,
  }) async {
    final result = await supabase
        .from('employee_hourly_pay_rules')
        .select()
        .eq('store_id', storeId)
        .eq('employee_id', employeeId)
        .maybeSingle();
    return result == null ? null : Map<String, dynamic>.from(result);
  }

  Future<Set<DateTime>> fetchVietnamPublicHolidays({
    required DateTime from,
    required DateTime to,
  }) async {
    final result = await supabase
        .from('vietnam_public_holidays')
        .select('holiday_date')
        .eq('is_active', true)
        .gte('holiday_date', from.toIso8601String().substring(0, 10))
        .lte('holiday_date', to.toIso8601String().substring(0, 10));
    return List<Map<String, dynamic>>.from(result)
        .map((row) => DateTime.tryParse(row['holiday_date']?.toString() ?? ''))
        .whereType<DateTime>()
        .map((date) => DateTime(date.year, date.month, date.day))
        .toSet();
  }

  Future<void> upsertWageConfig({
    required String storeId,
    required String userId,
    required String wageType,
    double? hourlyRate,
    List<Map<String, dynamic>> shiftRates = const [],
  }) async {
    await supabase.rpc(
      'upsert_staff_wage_config',
      params: {
        'p_store_id': storeId,
        'p_user_id': userId,
        'p_wage_type': wageType,
        'p_hourly_rate': hourlyRate,
        'p_shift_rates': shiftRates,
        'p_effective_from': DateTime.now().toUtc().toIso8601String().substring(
          0,
          10,
        ),
      },
    );
  }
}

Map<String, dynamic> normalizeAttendanceLogRow(Map<String, dynamic> row) {
  final employee = row['employee'] is Map
      ? Map<String, dynamic>.from(row['employee'] as Map)
      : const <String, dynamic>{};
  final legacyUser = row['legacy_user'] is Map
      ? Map<String, dynamic>.from(row['legacy_user'] as Map)
      : const <String, dynamic>{};
  final employeeId = row['employee_id']?.toString();
  final legacyUserId = row['user_id']?.toString();
  final personId = employeeId?.isNotEmpty == true ? employeeId : legacyUserId;
  final fullName =
      _nonEmptyAttendanceValue(row['person_name']) ??
      _nonEmptyAttendanceValue(employee['full_name']) ??
      _nonEmptyAttendanceValue(legacyUser['full_name']) ??
      _nonEmptyAttendanceValue(employee['employee_number']) ??
      '-';
  final role =
      _nonEmptyAttendanceValue(row['person_role']) ??
      _nonEmptyAttendanceValue(employee['employment_role']) ??
      _nonEmptyAttendanceValue(legacyUser['role']) ??
      'staff';

  return {
    'id': row['id'],
    'restaurant_id': row['restaurant_id'],
    'user_id': personId,
    'employee_id': employeeId,
    'employee_number': row['employee_number'] ?? employee['employee_number'],
    'type': row['type'],
    'photo_url': row['photo_url'],
    'photo_thumbnail_url': row['photo_thumbnail_url'],
    'logged_at': row['logged_at'],
    'created_at': row['created_at'],
    'users': {'id': personId, 'full_name': fullName, 'role': role},
  };
}

String? _nonEmptyAttendanceValue(dynamic value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

final attendanceService = AttendanceService();
