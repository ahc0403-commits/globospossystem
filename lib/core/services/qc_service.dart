import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';

class QcService {
  Future<List<Map<String, dynamic>>> fetchTemplates(String storeId) async {
    final result = await supabase.rpc(
      'get_qc_templates',
      params: {'p_restaurant_id': storeId, 'p_scope': 'visible'},
    );
    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<void> createTemplate({
    required String storeId,
    required String category,
    required String criteriaText,
    String? criteriaPhotoUrl,
    int sortOrder = 0,
  }) async {
    await supabase.rpc(
      'create_qc_template',
      params: {
        'p_restaurant_id': storeId,
        'p_category': category,
        'p_criteria_text': criteriaText,
        'p_criteria_photo_url': criteriaPhotoUrl,
        'p_sort_order': sortOrder,
        'p_is_global': false,
      },
    );
  }

  Future<void> createGlobalTemplate({
    required String category,
    required String criteriaText,
    String? criteriaPhotoUrl,
    int sortOrder = 0,
  }) async {
    await supabase.rpc(
      'create_qc_template',
      params: {
        'p_restaurant_id': null,
        'p_category': category,
        'p_criteria_text': criteriaText,
        'p_criteria_photo_url': criteriaPhotoUrl,
        'p_sort_order': sortOrder,
        'p_is_global': true,
      },
    );
  }

  Future<List<Map<String, dynamic>>> fetchGlobalTemplates() async {
    final result = await supabase.rpc(
      'get_qc_templates',
      params: {'p_restaurant_id': null, 'p_scope': 'global'},
    );
    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<void> updateTemplate(String id, Map<String, dynamic> data) async {
    await supabase.rpc(
      'update_qc_template',
      params: {'p_template_id': id, 'p_patch': data},
    );
  }

  Future<void> deactivateTemplate(String id) async {
    await supabase.rpc('deactivate_qc_template', params: {'p_template_id': id});
  }

  Future<List<Map<String, dynamic>>> fetchChecks({
    required String storeId,
    required DateTime from,
    required DateTime to,
  }) async {
    final result = await supabase.rpc(
      'get_qc_checks',
      params: {
        'p_restaurant_id': storeId,
        'p_from': from.toIso8601String().substring(0, 10),
        'p_to': to.toIso8601String().substring(0, 10),
      },
    );
    return List<Map<String, dynamic>>.from(result as List).map((row) {
      final map = Map<String, dynamic>.from(row);
      return {
        'id': map['check_id'],
        'restaurant_id': map['restaurant_id'],
        'template_id': map['template_id'],
        'check_date': map['check_date'],
        'checked_by': map['checked_by'],
        'result': map['result'],
        'evidence_photo_url': map['evidence_photo_url'],
        'note': map['note'],
        'created_at': map['created_at'],
        'qc_templates': {
          'id': map['template_id'],
          'category': map['template_category'],
          'criteria_text': map['template_criteria_text'],
          'criteria_photo_url': map['template_criteria_photo_url'],
          'is_global': map['template_is_global'],
        },
      };
    }).toList();
  }

  Future<void> upsertCheck({
    required String storeId,
    required String templateId,
    required String checkDate,
    required String result,
    String? evidencePhotoUrl,
    String? note,
    String? checkedBy,
  }) async {
    await supabase.rpc(
      'upsert_qc_check',
      params: {
        'p_restaurant_id': storeId,
        'p_template_id': templateId,
        'p_check_date': checkDate,
        'p_result': result,
        'p_evidence_photo_url': evidencePhotoUrl,
        'p_note': note,
        'p_checked_by': checkedBy,
      },
    );
  }

  Future<String?> uploadQcPhoto({
    required String storeId,
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
        ? '$storeId/templates/$templateId.jpg'
        : '$storeId/checks/$checkDate/$templateId.jpg';

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
    final result = await supabase.rpc(
      'get_qc_superadmin_summary',
      params: {'p_week_start': weekStart.toIso8601String().substring(0, 10)},
    );
    return List<Map<String, dynamic>>.from(result as List);
  }

  // ─── Follow-up ──────────────────────────────────

  Future<void> createFollowup({
    required String storeId,
    required String sourceCheckId,
    String? assignedToName,
  }) async {
    await supabase.rpc(
      'create_qc_followup',
      params: {
        'p_restaurant_id': storeId,
        'p_source_check_id': sourceCheckId,
        'p_assigned_to_name': assignedToName,
      },
    );
  }

  Future<void> updateFollowupStatus({
    required String followupId,
    required String storeId,
    required String status,
    String? resolutionNotes,
  }) async {
    await supabase.rpc(
      'update_qc_followup_status',
      params: {
        'p_followup_id': followupId,
        'p_restaurant_id': storeId,
        'p_status': status,
        'p_resolution_notes': resolutionNotes,
      },
    );
  }

  Future<List<Map<String, dynamic>>> fetchFollowups({
    required String storeId,
    String? statusFilter,
  }) async {
    final result = await supabase.rpc(
      'get_qc_followups',
      params: {
        'p_restaurant_id': storeId,
        'p_status_filter': statusFilter,
      },
    );
    return List<Map<String, dynamic>>.from(result as List);
  }

  // ─── Analytics ──────────────────────────────────

  Future<Map<String, dynamic>> fetchAnalytics({
    required String storeId,
    required DateTime from,
    required DateTime to,
  }) async {
    final result = await supabase.rpc(
      'get_qc_analytics',
      params: {
        'p_restaurant_id': storeId,
        'p_from': from.toIso8601String().substring(0, 10),
        'p_to': to.toIso8601String().substring(0, 10),
      },
    );
    final list = result as List;
    if (list.isEmpty) {
      return {
        'total_checks': 0,
        'pass_count': 0,
        'fail_count': 0,
        'na_count': 0,
        'pass_rate': 0,
        'template_count': 0,
        'coverage': 0,
        'open_followups': 0,
      };
    }
    return Map<String, dynamic>.from(list.first);
  }
}

final qcService = QcService();
