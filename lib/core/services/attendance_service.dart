import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';

class AttendanceService {
  Future<String?> uploadAttendancePhoto({
    required String restaurantId,
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
    final path = '$restaurantId/$userId/$dateStr/${ts}_$type.jpg';

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

  Future<void> logAttendance({
    required String restaurantId,
    required String userId,
    required String type,
    String? photoUrl,
  }) async {
    await supabase.from('attendance_logs').insert({
      'restaurant_id': restaurantId,
      'user_id': userId,
      'type': type,
      'photo_url': photoUrl,
      'photo_thumbnail_url': photoUrl,
      'logged_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> fetchLogs({
    required String restaurantId,
    required DateTime from,
    required DateTime to,
  }) async {
    final result = await supabase
        .from('attendance_logs')
        .select('*, users(id, full_name, role)')
        .eq('restaurant_id', restaurantId)
        .gte('logged_at', from.toUtc().toIso8601String())
        .lte('logged_at', to.toUtc().toIso8601String())
        .order('logged_at', ascending: false);
    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<List<Map<String, dynamic>>> fetchStaffList(String restaurantId) async {
    final result = await supabase
        .from('users')
        .select('id, full_name, role')
        .eq('restaurant_id', restaurantId)
        .eq('is_active', true)
        .order('full_name');
    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<Map<String, dynamic>?> fetchWageConfig({
    required String restaurantId,
    required String userId,
  }) async {
    final result = await supabase
        .from('staff_wage_configs')
        .select()
        .eq('restaurant_id', restaurantId)
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
    required String restaurantId,
    required String userId,
    required String wageType,
    double? hourlyRate,
    List<Map<String, dynamic>> shiftRates = const [],
  }) async {
    await supabase.from('staff_wage_configs').upsert({
      'restaurant_id': restaurantId,
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
