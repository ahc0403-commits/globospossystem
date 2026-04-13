import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';

class AttendanceService {
  Future<String?> uploadAttendancePhoto({
    required String storeId,
    required String userId,
    required File originalFile,
    required String type,
  }) async {
    final bytes = await originalFile.readAsBytes();
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
    final path = '$storeId/$userId/$dateStr/${ts}_$type.jpg';

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
    await supabase.rpc(
      'record_attendance_event',
      params: {
        'p_restaurant_id': storeId,
        'p_user_id': userId,
        'p_type': type,
        'p_photo_url': photoUrl,
        'p_photo_thumbnail_url': photoUrl,
      },
    );
  }

  Future<List<Map<String, dynamic>>> fetchLogs({
    required String storeId,
    required DateTime from,
    required DateTime to,
  }) async {
    final result = await supabase.rpc(
      'get_attendance_log_view',
      params: {
        'p_restaurant_id': storeId,
        'p_from': from.toUtc().toIso8601String(),
        'p_to': to.toUtc().toIso8601String(),
        'p_user_id': null,
      },
    );

    return List<Map<String, dynamic>>.from(result as List).map((row) {
      final map = Map<String, dynamic>.from(row);
      return {
        'id': map['attendance_log_id'],
        'restaurant_id': map['restaurant_id'],
        'user_id': map['user_id'],
        'type': map['attendance_type'],
        'photo_url': map['photo_url'],
        'photo_thumbnail_url': map['photo_thumbnail_url'],
        'logged_at': map['logged_at'],
        'created_at': map['created_at'],
        'users': {
          'id': map['user_id'],
          'full_name': map['user_full_name'],
          'role': map['user_role'],
        },
      };
    }).toList();
  }

  Future<List<Map<String, dynamic>>> fetchStaffList(String storeId) async {
    final result = await supabase.rpc(
      'get_attendance_staff_directory',
      params: {'p_restaurant_id': storeId},
    );
    return List<Map<String, dynamic>>.from(result as List);
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

  Future<void> upsertWageConfig({
    required String storeId,
    required String userId,
    required String wageType,
    double? hourlyRate,
    List<Map<String, dynamic>> shiftRates = const [],
  }) async {
    await supabase.from('staff_wage_configs').upsert({
      'restaurant_id': storeId,
      'user_id': userId,
      'wage_type': wageType,
      'hourly_rate': hourlyRate,
      'shift_rates': shiftRates,
      'effective_from': DateTime.now().toUtc().toIso8601String().substring(
        0,
        10,
      ),
      'is_active': true,
    });
  }
}

final attendanceService = AttendanceService();
