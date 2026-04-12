import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/services/qc_service.dart';

class QcTemplateState {
  const QcTemplateState({
    this.templates = const [],
    this.isLoading = false,
    this.error,
  });

  final List<Map<String, dynamic>> templates;
  final bool isLoading;
  final String? error;

  QcTemplateState copyWith({
    List<Map<String, dynamic>>? templates,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return QcTemplateState(
      templates: templates ?? this.templates,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class QcTemplateNotifier extends StateNotifier<QcTemplateState> {
  QcTemplateNotifier() : super(const QcTemplateState());

  String? _restaurantId;

  Future<void> loadTemplates(String storeId) async {
    _restaurantId = storeId;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final templates = await qcService.fetchTemplates(storeId);
      state = state.copyWith(
        templates: templates,
        isLoading: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapQcTemplateError(e, 'Failed to load QC templates.'),
      );
    }
  }

  Future<void> addTemplate({
    required String storeId,
    required String category,
    required String criteriaText,
    String? criteriaPhotoUrl,
    int sortOrder = 0,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await qcService.createTemplate(
        storeId: storeId,
        category: category,
        criteriaText: criteriaText,
        criteriaPhotoUrl: criteriaPhotoUrl,
        sortOrder: sortOrder,
      );
      await loadTemplates(storeId);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapQcTemplateError(e, 'Failed to save QC template.'),
      );
    }
  }

  Future<void> addGlobalTemplate({
    required String category,
    required String criteriaText,
    String? criteriaPhotoUrl,
    int sortOrder = 0,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await qcService.createGlobalTemplate(
        category: category,
        criteriaText: criteriaText,
        criteriaPhotoUrl: criteriaPhotoUrl,
        sortOrder: sortOrder,
      );
      final storeId = _restaurantId;
      if (storeId != null) {
        await loadTemplates(storeId);
      } else {
        state = state.copyWith(isLoading: false, clearError: true);
      }
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapQcTemplateError(e, 'Failed to save shared QC template.'),
      );
    }
  }

  Future<void> updateTemplate(String id, Map<String, dynamic> data) async {
    final storeId = _restaurantId;
    if (storeId == null) return;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await qcService.updateTemplate(id, data);
      await loadTemplates(storeId);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapQcTemplateError(e, 'Failed to update QC template.'),
      );
    }
  }

  Future<void> deleteTemplate(String id) async {
    final storeId = _restaurantId;
    if (storeId == null) return;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await qcService.deactivateTemplate(id);
      await loadTemplates(storeId);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapQcTemplateError(e, 'Failed to deactivate QC template.'),
      );
    }
  }

  Future<String?> uploadCriteriaPhoto(
    String storeId,
    String templateId,
    File file,
  ) {
    return qcService.uploadQcPhoto(
      storeId: storeId,
      templateId: templateId,
      file: file,
      type: 'template',
    );
  }

  String generateTemplateId() => const Uuid().v4();

  String _mapQcTemplateError(Object error, String fallback) {
    final message = error is PostgrestException ? error.message : '$error';

    if (message.contains('QC_TEMPLATE_READ_FORBIDDEN') ||
        message.contains('QC_TEMPLATE_WRITE_FORBIDDEN')) {
      return 'No permission to view or modify QC templates.';
    }
    if (message.contains('QC_TEMPLATE_SCOPE_INVALID')) {
      return 'Re-select the QC template scope.';
    }
    if (message.contains('QC_TEMPLATE_RESTAURANT_REQUIRED')) {
      return 'Reload store info and try again.';
    }
    if (message.contains('QC_TEMPLATE_CATEGORY_REQUIRED')) {
      return 'Enter a category.';
    }
    if (message.contains('QC_TEMPLATE_TEXT_REQUIRED')) {
      return 'Enter the criterion details.';
    }
    if (message.contains('QC_TEMPLATE_SORT_INVALID')) {
      return 'Order must be a number 0 or greater.';
    }
    if (message.contains('QC_TEMPLATE_PATCH_INVALID') ||
        message.contains('QC_TEMPLATE_PATCH_EMPTY') ||
        message.contains('QC_TEMPLATE_PATCH_UNSUPPORTED')) {
      return 'Only editable QC template items can be changed.';
    }
    if (message.contains('QC_TEMPLATE_NOT_FOUND')) {
      return 'Reload QC templates and try again.';
    }

    return fallback;
  }
}

final qcTemplateProvider =
    StateNotifierProvider<QcTemplateNotifier, QcTemplateState>(
      (ref) => QcTemplateNotifier(),
    );

class QcCheckState {
  const QcCheckState({
    this.checks = const [],
    this.dateRangeChecks = const [],
    this.isLoading = false,
    this.error,
  });

  final List<Map<String, dynamic>> checks;
  final List<Map<String, dynamic>> dateRangeChecks;
  final bool isLoading;
  final String? error;

  QcCheckState copyWith({
    List<Map<String, dynamic>>? checks,
    List<Map<String, dynamic>>? dateRangeChecks,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return QcCheckState(
      checks: checks ?? this.checks,
      dateRangeChecks: dateRangeChecks ?? this.dateRangeChecks,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class QcCheckNotifier extends StateNotifier<QcCheckState> {
  QcCheckNotifier() : super(const QcCheckState());

  String? _restaurantId;
  DateTime? _weekStart;

  Future<void> loadWeek({
    required String storeId,
    required DateTime weekStart,
  }) async {
    _restaurantId = storeId;
    _weekStart = DateTime(weekStart.year, weekStart.month, weekStart.day);

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final weekEnd = _weekStart!.add(const Duration(days: 6));
      final checks = await qcService.fetchChecks(
        storeId: storeId,
        from: _weekStart!,
        to: weekEnd,
      );
      state = state.copyWith(
        checks: checks,
        isLoading: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapQcCheckError(e, 'Failed to load QC inspection status.'),
      );
    }
  }

  Future<void> submitCheck({
    required String storeId,
    required String templateId,
    required String checkDate,
    required String result,
    File? evidencePhoto,
    String? note,
    String? checkedBy,
  }) async {
    try {
      String? evidencePhotoUrl;
      if (evidencePhoto != null) {
        evidencePhotoUrl = await qcService.uploadQcPhoto(
          storeId: storeId,
          templateId: templateId,
          file: evidencePhoto,
          type: 'check',
          checkDate: checkDate,
        );
      }

      await qcService.upsertCheck(
        storeId: storeId,
        templateId: templateId,
        checkDate: checkDate,
        result: result,
        evidencePhotoUrl: evidencePhotoUrl,
        note: note,
        checkedBy: checkedBy,
      );

      if (_restaurantId == storeId && _weekStart != null) {
        await loadWeek(storeId: storeId, weekStart: _weekStart!);
      }
    } catch (e) {
      state = state.copyWith(error: _mapQcCheckError(e, 'Failed to save QC inspection.'));
      rethrow;
    }
  }

  Future<void> loadDateRange({
    required String storeId,
    required DateTime from,
    required DateTime to,
  }) async {
    _restaurantId = storeId;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final checks = await qcService.fetchChecks(
        storeId: storeId,
        from: from,
        to: to,
      );
      state = state.copyWith(
        dateRangeChecks: checks,
        isLoading: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapQcCheckError(e, 'Failed to load QC inspection search results.'),
      );
    }
  }

  String _mapQcCheckError(Object error, String fallback) {
    final message = error is PostgrestException ? error.message : '$error';

    if (message.contains('QC_CHECK_READ_FORBIDDEN') ||
        message.contains('QC_CHECK_WRITE_FORBIDDEN')) {
      return 'No permission to view or record QC inspections.';
    }
    if (message.contains('QC_CHECK_RANGE_REQUIRED') ||
        message.contains('QC_CHECK_RANGE_INVALID')) {
      return 'Re-select the inspection query period.';
    }
    if (message.contains('QC_CHECK_TEMPLATE_REQUIRED') ||
        message.contains('QC_CHECK_TEMPLATE_NOT_FOUND')) {
      return 'Re-select a valid QC criterion.';
    }
    if (message.contains('QC_CHECK_DATE_REQUIRED')) {
      return 'Re-select the inspection date.';
    }
    if (message.contains('QC_CHECK_RESULT_INVALID')) {
      return 'Select one of Pass, Fail, or N/A.';
    }
    if (message.contains('QC_CHECK_ACTOR_INVALID')) {
      return 'QC inspections can only be recorded by the current logged-in user.';
    }

    return fallback;
  }
}

final qcCheckProvider = StateNotifierProvider<QcCheckNotifier, QcCheckState>(
  (ref) => QcCheckNotifier(),
);

final superAdminQcSummaryProvider = FutureProvider.family
    .autoDispose<List<Map<String, dynamic>>, DateTime>((ref, weekStart) async {
      return qcService.fetchSuperAdminSummary(weekStart: weekStart);
    });

final globalQcTemplatesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      return qcService.fetchGlobalTemplates();
    });

// ─── Follow-up ────────────────────────────────────

class QcFollowupState {
  const QcFollowupState({
    this.followups = const [],
    this.isLoading = false,
    this.error,
  });

  final List<Map<String, dynamic>> followups;
  final bool isLoading;
  final String? error;

  QcFollowupState copyWith({
    List<Map<String, dynamic>>? followups,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return QcFollowupState(
      followups: followups ?? this.followups,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class QcFollowupNotifier extends StateNotifier<QcFollowupState> {
  QcFollowupNotifier() : super(const QcFollowupState());

  Future<void> load(String storeId, {String? statusFilter}) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final followups = await qcService.fetchFollowups(
        storeId: storeId,
        statusFilter: statusFilter,
      );
      state = state.copyWith(
        followups: followups,
        isLoading: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapFollowupError(e, 'Failed to load follow-ups.'),
      );
    }
  }

  Future<bool> createFollowup({
    required String storeId,
    required String sourceCheckId,
    String? assignedToName,
  }) async {
    try {
      await qcService.createFollowup(
        storeId: storeId,
        sourceCheckId: sourceCheckId,
        assignedToName: assignedToName,
      );
      await load(storeId);
      return true;
    } catch (e) {
      state = state.copyWith(
        error: _mapFollowupError(e, 'Failed to create follow-up.'),
      );
      return false;
    }
  }

  Future<bool> updateStatus({
    required String followupId,
    required String storeId,
    required String status,
    String? resolutionNotes,
  }) async {
    try {
      await qcService.updateFollowupStatus(
        followupId: followupId,
        storeId: storeId,
        status: status,
        resolutionNotes: resolutionNotes,
      );
      await load(storeId);
      return true;
    } catch (e) {
      state = state.copyWith(
        error: _mapFollowupError(e, 'Failed to change follow-up status.'),
      );
      return false;
    }
  }

  /// Check if a followup exists for a given check ID
  Map<String, dynamic>? followupForCheck(String checkId) {
    for (final f in state.followups) {
      if (f['source_check_id']?.toString() == checkId) return f;
    }
    return null;
  }

  String _mapFollowupError(Object error, String fallback) {
    final message = error is PostgrestException ? error.message : '$error';

    if (message.contains('QC_FOLLOWUP_WRITE_FORBIDDEN') ||
        message.contains('QC_FOLLOWUP_READ_FORBIDDEN')) {
      return 'No permission to manage follow-ups.';
    }
    if (message.contains('QC_FOLLOWUP_CHECK_NOT_FOUND')) {
      return 'Inspection record not found.';
    }
    if (message.contains('QC_FOLLOWUP_NOT_FAILED_CHECK')) {
      return 'Follow-ups can only be created for failed inspections.';
    }
    if (message.contains('QC_FOLLOWUP_ALREADY_EXISTS')) {
      return 'A follow-up already exists for this inspection.';
    }
    if (message.contains('QC_FOLLOWUP_STATUS_INVALID')) {
      return 'Invalid status.';
    }
    if (message.contains('QC_FOLLOWUP_NOT_FOUND')) {
      return 'Follow-up not found.';
    }

    return fallback;
  }
}

final qcFollowupProvider =
    StateNotifierProvider<QcFollowupNotifier, QcFollowupState>(
      (ref) => QcFollowupNotifier(),
    );

// ─── Analytics ────────────────────────────────────

class QcAnalyticsParams {
  const QcAnalyticsParams({
    required this.storeId,
    required this.from,
    required this.to,
  });

  final String storeId;
  final DateTime from;
  final DateTime to;

  @override
  bool operator ==(Object other) =>
      other is QcAnalyticsParams &&
      other.storeId == storeId &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(storeId, from, to);
}

final qcAnalyticsProvider = FutureProvider.family
    .autoDispose<Map<String, dynamic>, QcAnalyticsParams>(
      (ref, params) async {
        return qcService.fetchAnalytics(
          storeId: params.storeId,
          from: params.from,
          to: params.to,
        );
      },
    );
