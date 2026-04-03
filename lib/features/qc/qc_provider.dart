import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  Future<void> loadTemplates(String restaurantId) async {
    _restaurantId = restaurantId;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final templates = await qcService.fetchTemplates(restaurantId);
      state = state.copyWith(
        templates: templates,
        isLoading: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: '$e');
    }
  }

  Future<void> addTemplate({
    required String restaurantId,
    required String category,
    required String criteriaText,
    String? criteriaPhotoUrl,
    int sortOrder = 0,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await qcService.createTemplate(
        restaurantId: restaurantId,
        category: category,
        criteriaText: criteriaText,
        criteriaPhotoUrl: criteriaPhotoUrl,
        sortOrder: sortOrder,
      );
      await loadTemplates(restaurantId);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: '$e');
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
      final restaurantId = _restaurantId;
      if (restaurantId != null) {
        await loadTemplates(restaurantId);
      } else {
        state = state.copyWith(isLoading: false, clearError: true);
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: '$e');
    }
  }

  Future<void> updateTemplate(String id, Map<String, dynamic> data) async {
    final restaurantId = _restaurantId;
    if (restaurantId == null) return;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await qcService.updateTemplate(id, data);
      await loadTemplates(restaurantId);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: '$e');
    }
  }

  Future<void> deleteTemplate(String id) async {
    final restaurantId = _restaurantId;
    if (restaurantId == null) return;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await qcService.deactivateTemplate(id);
      await loadTemplates(restaurantId);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: '$e');
    }
  }

  Future<String?> uploadCriteriaPhoto(
    String restaurantId,
    String templateId,
    File file,
  ) {
    return qcService.uploadQcPhoto(
      restaurantId: restaurantId,
      templateId: templateId,
      file: file,
      type: 'template',
    );
  }

  String generateTemplateId() => const Uuid().v4();
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
    required String restaurantId,
    required DateTime weekStart,
  }) async {
    _restaurantId = restaurantId;
    _weekStart = DateTime(weekStart.year, weekStart.month, weekStart.day);

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final weekEnd = _weekStart!.add(const Duration(days: 6));
      final checks = await qcService.fetchChecks(
        restaurantId: restaurantId,
        from: _weekStart!,
        to: weekEnd,
      );
      state = state.copyWith(
        checks: checks,
        isLoading: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: '$e');
    }
  }

  Future<void> submitCheck({
    required String restaurantId,
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
          restaurantId: restaurantId,
          templateId: templateId,
          file: evidencePhoto,
          type: 'check',
          checkDate: checkDate,
        );
      }

      await qcService.upsertCheck(
        restaurantId: restaurantId,
        templateId: templateId,
        checkDate: checkDate,
        result: result,
        evidencePhotoUrl: evidencePhotoUrl,
        note: note,
        checkedBy: checkedBy,
      );

      if (_restaurantId == restaurantId && _weekStart != null) {
        await loadWeek(restaurantId: restaurantId, weekStart: _weekStart!);
      }
    } catch (e) {
      state = state.copyWith(error: '$e');
      rethrow;
    }
  }

  Future<void> loadDateRange({
    required String restaurantId,
    required DateTime from,
    required DateTime to,
  }) async {
    _restaurantId = restaurantId;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final checks = await qcService.fetchChecks(
        restaurantId: restaurantId,
        from: from,
        to: to,
      );
      state = state.copyWith(
        dateRangeChecks: checks,
        isLoading: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: '$e');
    }
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
