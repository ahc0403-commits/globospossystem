import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';

class QcService {
  Future<List<Map<String, dynamic>>> fetchTemplates(String storeId) async {
    final result = await supabase.rpc(
      'get_qc_templates',
      params: {'p_store_id': storeId, 'p_scope': 'visible'},
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
        'p_store_id': storeId,
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
        'p_store_id': null,
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
      params: {'p_store_id': null, 'p_scope': 'global'},
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
        'p_store_id': storeId,
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
        'p_store_id': storeId,
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
        'p_store_id': storeId,
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
        'p_store_id': storeId,
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
      params: {'p_store_id': storeId, 'p_status_filter': statusFilter},
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
        'p_store_id': storeId,
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

  Future<Map<String, dynamic>> upsertCheckV2({
    required String storeId,
    required String templateId,
    required String checkDate,
    required String result,
    String? evidencePhotoUrl,
    String? note,
    String? checkedBy,
    DateTime? submittedAt,
    String? submissionStatus,
    int? photoRequiredCount,
    int? photoUploadedCount,
    double? score,
    String? grade,
    String? svReviewStatus,
    String? svReviewedBy,
    DateTime? svReviewedAt,
    double? svScore,
    String? svNote,
    String? visitSessionId,
  }) async {
    final resultData = await supabase.rpc(
      'upsert_qc_check',
      params: {
        'p_store_id': storeId,
        'p_template_id': templateId,
        'p_check_date': checkDate,
        'p_result': result,
        'p_evidence_photo_url': evidencePhotoUrl,
        'p_note': note,
        'p_checked_by': checkedBy,
        'p_submitted_at': submittedAt?.toIso8601String(),
        'p_submission_status': submissionStatus,
        'p_photo_required_count': photoRequiredCount,
        'p_photo_uploaded_count': photoUploadedCount,
        'p_score': score,
        'p_grade': grade,
        'p_sv_review_status': svReviewStatus,
        'p_sv_reviewed_by': svReviewedBy,
        'p_sv_reviewed_at': svReviewedAt?.toIso8601String(),
        'p_sv_score': svScore,
        'p_sv_note': svNote,
        'p_visit_session_id': visitSessionId,
      },
    );
    return _asMap(resultData);
  }

  Future<Map<String, dynamic>> upsertCheckPhoto({
    required String storeId,
    required String checkId,
    required String templateId,
    required XFile file,
    required String photoRole,
    bool isPrimary = false,
    DateTime? takenAt,
    String? caption,
    bool syncLegacyPhoto = true,
  }) async {
    final upload = await _prepareQcPhotoUpload(file);
    if (upload == null) {
      throw const FormatException('QC_CHECK_PHOTO_DECODE_FAILED');
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final path = '$storeId/checks/$checkId/$templateId/$timestamp.jpg';

    await supabase.storage
        .from('qc-photos')
        .uploadBinary(
          path,
          upload.bytes,
          fileOptions: FileOptions(
            contentType: upload.contentType,
            upsert: false,
          ),
        );

    final signedUrl = await supabase.storage
        .from('qc-photos')
        .createSignedUrl(path, 60 * 60 * 24 * 365 * 10);

    final result = await supabase.rpc(
      'upsert_qc_check_photo',
      params: {
        'p_store_id': storeId,
        'p_check_id': checkId,
        'p_template_id': templateId,
        'p_photo_url': signedUrl,
        'p_storage_path': path,
        'p_photo_role': photoRole,
        'p_taken_at': takenAt?.toIso8601String(),
        'p_is_primary': isPrimary,
        'p_caption': caption,
        'p_sync_legacy_photo': syncLegacyPhoto,
      },
    );

    return _asMap(result);
  }

  Future<_QcPhotoUpload?> _prepareQcPhotoUpload(XFile file) async {
    final bytes = await file.readAsBytes();
    if (kIsWeb) {
      return _QcPhotoUpload(
        bytes: bytes,
        contentType: file.mimeType ?? 'image/jpeg',
      );
    }

    final original = img.decodeImage(bytes);
    if (original == null) return null;

    final widthDominant = original.width >= original.height;
    final resized = img.copyResize(
      original,
      width: widthDominant ? 1200 : null,
      height: widthDominant ? null : 1200,
    );
    return _QcPhotoUpload(
      bytes: Uint8List.fromList(img.encodeJpg(resized, quality: 75)),
      contentType: 'image/jpeg',
    );
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    if (value is List && value.isNotEmpty) {
      final first = value.first;
      if (first is Map<String, dynamic>) {
        return first;
      }
      if (first is Map) {
        return Map<String, dynamic>.from(first);
      }
    }
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _asMapList(dynamic value) {
    if (value is List) {
      return value
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
    }
    return const [];
  }

  Future<List<Map<String, dynamic>>> fetchCheckPhotos({
    required String checkId,
    String? fallbackPhotoUrl,
  }) async {
    try {
      final result = await supabase
          .from('qc_check_photos')
          .select(
            'id, check_id, photo_url, storage_path, photo_role, is_primary, uploaded_at, taken_at, caption',
          )
          .eq('check_id', checkId)
          .order('is_primary', ascending: false)
          .order('uploaded_at');

      final rows = _asMapList(result);
      if (rows.isNotEmpty) {
        return rows;
      }
    } on PostgrestException {
      // Fall through to legacy single-photo fallback when the QSC v2 table is
      // not available yet in the active environment.
    }

    final url = fallbackPhotoUrl?.trim();
    if (url == null || url.isEmpty) {
      return const [];
    }

    return [
      {
        'id': 'legacy-$checkId',
        'check_id': checkId,
        'photo_url': url,
        'photo_role': 'staff',
        'is_primary': true,
      },
    ];
  }

  Future<List<Map<String, dynamic>>> submitVisitReview({
    required String storeId,
    required List<String> checkIds,
    required String svReviewStatus,
    double? svScore,
    String? svNote,
    String? visitSessionId,
    DateTime? reviewedAt,
    String? reviewedBy,
  }) async {
    final result = await supabase.rpc(
      'submit_qc_visit_review',
      params: {
        'p_store_id': storeId,
        'p_check_ids': checkIds,
        'p_sv_review_status': svReviewStatus,
        'p_sv_score': svScore,
        'p_sv_note': svNote,
        'p_visit_session_id': visitSessionId,
        'p_reviewed_at': reviewedAt?.toIso8601String(),
        'p_reviewed_by': reviewedBy,
      },
    );
    return _asMapList(result);
  }
}

class _QcPhotoUpload {
  const _QcPhotoUpload({required this.bytes, required this.contentType});

  final Uint8List bytes;
  final String contentType;
}

final qcService = QcService();
