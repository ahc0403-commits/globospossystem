import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';

class QcService {
  Future<List<Map<String, dynamic>>> fetchTemplates(String restaurantId) async {
    final result = await supabase
        .from('qc_templates')
        .select()
        .or('is_global.eq.true,restaurant_id.eq.$restaurantId')
        .eq('is_active', true)
        .order('is_global', ascending: false)
        .order('category')
        .order('sort_order');
    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<void> createTemplate({
    required String restaurantId,
    required String category,
    required String criteriaText,
    String? criteriaPhotoUrl,
    int sortOrder = 0,
  }) async {
    await supabase.from('qc_templates').insert({
      'is_global': false,
      'restaurant_id': restaurantId,
      'category': category,
      'criteria_text': criteriaText,
      'criteria_photo_url': criteriaPhotoUrl,
      'sort_order': sortOrder,
    });
  }

  Future<void> createGlobalTemplate({
    required String category,
    required String criteriaText,
    String? criteriaPhotoUrl,
    int sortOrder = 0,
  }) async {
    await supabase.from('qc_templates').insert({
      'is_global': true,
      'restaurant_id': null,
      'category': category,
      'criteria_text': criteriaText,
      'criteria_photo_url': criteriaPhotoUrl,
      'sort_order': sortOrder,
    });
  }

  Future<List<Map<String, dynamic>>> fetchGlobalTemplates() async {
    final result = await supabase
        .from('qc_templates')
        .select()
        .eq('is_global', true)
        .eq('is_active', true)
        .order('category')
        .order('sort_order');
    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<void> updateTemplate(String id, Map<String, dynamic> data) async {
    await supabase.from('qc_templates').update(data).eq('id', id);
  }

  Future<void> deactivateTemplate(String id) async {
    await supabase
        .from('qc_templates')
        .update({'is_active': false})
        .eq('id', id);
  }

  Future<List<Map<String, dynamic>>> fetchChecks({
    required String restaurantId,
    required DateTime from,
    required DateTime to,
  }) async {
    final result = await supabase
        .from('qc_checks')
        .select(
          '*, qc_templates(id, category, criteria_text, criteria_photo_url, is_global)',
        )
        .eq('restaurant_id', restaurantId)
        .gte('check_date', from.toIso8601String().substring(0, 10))
        .lte('check_date', to.toIso8601String().substring(0, 10))
        .order('check_date', ascending: false);
    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<void> upsertCheck({
    required String restaurantId,
    required String templateId,
    required String checkDate,
    required String result,
    String? evidencePhotoUrl,
    String? note,
    String? checkedBy,
  }) async {
    await supabase.from('qc_checks').upsert({
      'restaurant_id': restaurantId,
      'template_id': templateId,
      'check_date': checkDate,
      'result': result,
      'evidence_photo_url': evidencePhotoUrl,
      'note': note,
      'checked_by': checkedBy,
    }, onConflict: 'template_id,check_date');
  }

  Future<String?> uploadQcPhoto({
    required String restaurantId,
    required String templateId,
    required File file,
    required String type,
    String? checkDate,
  }) async {
    final bytes = await file.readAsBytes();
    final original = img.decodeImage(bytes);
    if (original == null) return null;

    final widthDominant = original.width >= original.height;
    final resized = img.copyResize(
      original,
      width: widthDominant ? 1200 : null,
      height: widthDominant ? null : 1200,
    );
    final compressed = Uint8List.fromList(img.encodeJpg(resized, quality: 75));

    final path = type == 'template'
        ? '$restaurantId/templates/$templateId.jpg'
        : '$restaurantId/checks/$checkDate/$templateId.jpg';

    await supabase.storage
        .from('qc-photos')
        .uploadBinary(
          path,
          compressed,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: true,
          ),
        );

    return supabase.storage
        .from('qc-photos')
        .createSignedUrl(path, 60 * 60 * 24 * 365 * 10);
  }

  Future<List<Map<String, dynamic>>> fetchSuperAdminSummary({
    required DateTime weekStart,
  }) async {
    final weekEnd = weekStart.add(const Duration(days: 6));

    final restaurantsRaw = await supabase
        .from('restaurants')
        .select('id, name')
        .eq('is_active', true)
        .order('name');
    final restaurants = List<Map<String, dynamic>>.from(restaurantsRaw as List);

    final templateRaw = await supabase
        .from('qc_templates')
        .select('restaurant_id, is_global')
        .eq('is_active', true);
    final templateRows = List<Map<String, dynamic>>.from(templateRaw as List);

    final checkRaw = await supabase
        .from('qc_checks')
        .select('restaurant_id, check_date, result')
        .gte('check_date', weekStart.toIso8601String().substring(0, 10))
        .lte('check_date', weekEnd.toIso8601String().substring(0, 10));
    final checkRows = List<Map<String, dynamic>>.from(checkRaw as List);

    final templateCountByRestaurant = <String, int>{};
    var globalTemplateCount = 0;
    for (final row in templateRows) {
      final isGlobal = row['is_global'] == true;
      if (isGlobal) {
        globalTemplateCount += 1;
        continue;
      }
      final id = row['restaurant_id']?.toString() ?? '';
      if (id.isEmpty) continue;
      templateCountByRestaurant[id] = (templateCountByRestaurant[id] ?? 0) + 1;
    }

    final checksByRestaurant = <String, List<Map<String, dynamic>>>{};
    for (final row in checkRows) {
      final id = row['restaurant_id']?.toString() ?? '';
      if (id.isEmpty) continue;
      checksByRestaurant.putIfAbsent(id, () => []).add(row);
    }

    final summary = <Map<String, dynamic>>[];

    for (final restaurant in restaurants) {
      final restaurantId = restaurant['id']?.toString() ?? '';
      if (restaurantId.isEmpty) continue;

      final templateCount =
          (templateCountByRestaurant[restaurantId] ?? 0) + globalTemplateCount;
      final checks = checksByRestaurant[restaurantId] ?? const [];
      final checkedCount = checks.length;
      final failCount = checks
          .where((e) => e['result']?.toString() == 'fail')
          .length;

      final totalExpected = templateCount * 7;
      final coverage = totalExpected == 0
          ? 0.0
          : (checkedCount / totalExpected) * 100.0;

      String? latestDate;
      for (final c in checks) {
        final d = c['check_date']?.toString();
        if (d == null) continue;
        if (latestDate == null || d.compareTo(latestDate) > 0) {
          latestDate = d;
        }
      }

      summary.add({
        'restaurant_id': restaurantId,
        'restaurant_name': restaurant['name']?.toString() ?? '-',
        'coverage': coverage,
        'fail_count': failCount,
        'latest_check_date': latestDate,
      });
    }

    return summary;
  }
}

final qcService = QcService();
