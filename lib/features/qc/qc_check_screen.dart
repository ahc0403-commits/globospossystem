import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/layout/platform_info.dart';
import '../../core/utils/permission_utils.dart';
import '../../core/utils/role_routes.dart';
import '../../core/utils/time_utils.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast_primitives_extended.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/error_toast.dart';
import '../auth/auth_provider.dart';
import 'qc_provider.dart';

class QcCheckScreen extends ConsumerStatefulWidget {
  const QcCheckScreen({super.key});

  @override
  ConsumerState<QcCheckScreen> createState() => _QcCheckScreenState();
}

class _QcCheckScreenState extends ConsumerState<QcCheckScreen> {
  final ImagePicker _picker = ImagePicker();
  final Map<String, _CheckDraft> _drafts = {};

  String? _initializedRestaurantId;
  bool _didPrepopulate = false;
  bool _didHandleUnauthorized = false;

  DateTime get _todayVn {
    final now = TimeUtils.nowVietnam();
    return DateTime(now.year, now.month, now.day);
  }

  DateTime _startOfWeek(DateTime date) {
    final day = DateTime(date.year, date.month, date.day);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  @override
  void dispose() {
    for (final draft in _drafts.values) {
      draft.noteController.dispose();
    }
    super.dispose();
  }

  Future<void> _initialize(String storeId) async {
    await ref.read(qcTemplateProvider.notifier).loadTemplates(storeId);
    await ref
        .read(qcCheckProvider.notifier)
        .loadWeek(storeId: storeId, weekStart: _startOfWeek(_todayVn));
  }

  void _prepopulateFromExistingChecks(List<Map<String, dynamic>> checks) {
    if (_didPrepopulate) return;

    final today = DateFormat('yyyy-MM-dd').format(_todayVn);
    for (final check in checks) {
      final checkDate = check['check_date']?.toString();
      if (checkDate != today) continue;
      final templateId = check['template_id']?.toString();
      if (templateId == null || templateId.isEmpty) continue;

      final draft = _drafts.putIfAbsent(templateId, () => _CheckDraft());
      draft.result = check['result']?.toString();
      draft.noteController.text = check['note']?.toString() ?? '';
      draft.existingPhotoUrl = check['evidence_photo_url']?.toString();
      draft.submissionStatus = check['submission_status']?.toString();
      draft.photoUploadedCount = _readInt(check['photo_uploaded_count']);
      draft.photoRequiredCount = _readInt(check['photo_required_count']);
      draft.svReviewStatus = check['sv_review_status']?.toString();
      draft.grade = check['grade']?.toString();
      draft.completed =
          draft.submissionStatus == 'submitted' ||
          draft.result != null ||
          draft.attachedPhotoCount > 0 ||
          draft.noteController.text.trim().isNotEmpty;
    }

    _didPrepopulate = true;
  }

  Future<void> _pickEvidencePhoto(String templateId) async {
    try {
      final source = PlatformInfo.isAndroid
          ? ImageSource.camera
          : ImageSource.gallery;
      final picked = await _picker.pickImage(source: source, imageQuality: 90);
      if (picked == null) return;

      final draft = _drafts.putIfAbsent(templateId, () => _CheckDraft());
      setState(() {
        draft.photoFiles.add(picked);
        draft.existingPhotoUrl = null;
      });
    } catch (e) {
      if (!mounted) return;
      showErrorToast(context, context.l10n.qcPhotoAttachmentFailed('$e'));
    }
  }

  void _removeEvidencePhoto(String templateId, int index) {
    final draft = _drafts[templateId];
    if (draft == null) return;
    if (index < 0 || index >= draft.photoFiles.length) return;
    setState(() {
      draft.photoFiles.removeAt(index);
    });
  }

  Future<void> _submitAll({
    required String storeId,
    required String? checkedBy,
  }) async {
    final notifier = ref.read(qcCheckProvider.notifier);
    final templateState = ref.read(qcTemplateProvider);
    final checkDate = DateFormat('yyyy-MM-dd').format(_todayVn);
    final submittedAt = DateTime.now();
    final templatesById = <String, Map<String, dynamic>>{
      for (final template in templateState.templates)
        if ((template['id']?.toString() ?? '').isNotEmpty)
          template['id'].toString(): template,
    };

    final toSubmit = <MapEntry<String, _CheckDraft>>[];
    for (final entry in _drafts.entries) {
      if (!entry.value.hasInput) continue;
      toSubmit.add(entry);
    }

    if (toSubmit.isEmpty) {
      showErrorToast(context, context.l10n.qcNoInspectionItems);
      return;
    }

    for (final entry in toSubmit) {
      final template = templatesById[entry.key];
      final templateName =
          template?['criteria_text']?.toString() ??
          context.l10n.qcCategoryOther;
      final requiresPhoto = template?['requires_photo'] != false;
      final requiredPhotoCount = template?['required_photo_count'] is num
          ? (template!['required_photo_count'] as num).toInt()
          : (requiresPhoto ? 1 : 0);
      final attachedPhotoCount = entry.value.attachedPhotoCount;

      if (requiresPhoto && attachedPhotoCount < requiredPhotoCount) {
        showErrorToast(
          context,
          context.l10n.qscPhotoRequiredBeforeSaving(templateName),
        );
        return;
      }
    }

    try {
      for (final entry in toSubmit) {
        final template = templatesById[entry.key];
        final existingPhotoUrl = entry.value.existingPhotoUrl;
        final localFiles = entry.value.photoFiles;
        final uploadedPhotoCount = entry.value.attachedPhotoCount;
        final requiredPhotoCount = template?['required_photo_count'] is num
            ? (template!['required_photo_count'] as num).toInt()
            : null;

        await notifier.submitCheckV2(
          storeId: storeId,
          templateId: entry.key,
          checkDate: checkDate,
          result: entry.value.result ?? 'na',
          evidencePhoto: localFiles.isNotEmpty ? localFiles.first : null,
          evidencePhotos: localFiles.isNotEmpty ? localFiles : null,
          evidencePhotoUrl: localFiles.isEmpty ? existingPhotoUrl : null,
          note: entry.value.noteController.text.trim().isEmpty
              ? null
              : entry.value.noteController.text.trim(),
          checkedBy: checkedBy,
          submittedAt: submittedAt,
          submissionStatus: 'submitted',
          photoRequiredCount: requiredPhotoCount,
          photoUploadedCount: uploadedPhotoCount,
        );
      }

      if (!mounted) return;
      showSuccessToast(context, context.l10n.qcSaved);
      final navigator = Navigator.of(context);
      if (navigator.canPop()) {
        navigator.pop();
      } else {
        context.go(homeRouteForRole(ref.read(authProvider).role));
      }
    } catch (e) {
      if (!mounted) return;
      showErrorToast(context, context.l10n.qcSaveFailed('$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final storeId = auth.storeId;
    final canAccess = PermissionUtils.canDoQcCheck(
      auth.role,
      auth.extraPermissions,
    );
    final canReview = PermissionUtils.canDoQcVisitReview(
      auth.role,
      auth.extraPermissions,
    );
    final templateState = ref.watch(qcTemplateProvider);
    final checkState = ref.watch(qcCheckProvider);

    if (!canAccess) {
      if (!_didHandleUnauthorized) {
        _didHandleUnauthorized = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          showErrorToast(context, context.l10n.qcNoPermission);
          context.go(homeRouteForRole(auth.role));
        });
      }
      return Scaffold(
        key: const Key('qc_check_root'),
        backgroundColor: PosColors.canvas,
        body: Center(
          child: Text(
            context.l10n.qcNoPermission,
            style: AppFonts.system(color: PosColors.text, fontSize: 14),
          ),
        ),
      );
    }

    if (storeId != null && _initializedRestaurantId != storeId) {
      _initializedRestaurantId = storeId;
      _didPrepopulate = false;
      Future.microtask(() => _initialize(storeId));
    }

    _prepopulateFromExistingChecks(checkState.checks);

    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final t in templateState.templates) {
      final category =
          t['category']?.toString() ?? context.l10n.qcCategoryOther;
      grouped.putIfAbsent(category, () => []).add(t);
    }
    final isInitialTemplateLoad =
        templateState.isLoading && templateState.templates.isEmpty;
    final draftPreviewTemplates = templateState.templates
        .where((template) {
          final templateId = template['id']?.toString() ?? '';
          final draft = _drafts[templateId];
          return draft != null && draft.hasInput;
        })
        .toList(growable: false);

    return Scaffold(
      key: const Key('qc_check_root'),
      backgroundColor: PosColors.canvas,
      appBar: AppBar(
        backgroundColor: PosColors.topbarSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 1,
        actions: [
          if (canReview)
            IconButton(
              tooltip: context.l10n.qscReview,
              onPressed: () => context.push('/qc-review'),
              icon: const Icon(
                Icons.verified_outlined,
                color: PosColors.accent,
              ),
            ),
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: AppNavBar()),
          ),
        ],
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.qcTitle,
              style: AppFonts.system(
                color: PosColors.text,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              DateFormat('yyyy-MM-dd').format(_todayVn),
              style: AppFonts.system(color: PosColors.textMuted, fontSize: 12),
            ),
          ],
        ),
      ),
      body: isInitialTemplateLoad
          ? const Center(
              child: CircularProgressIndicator(color: PosColors.accent),
            )
          : ToastResponsiveScrollBody(
              maxWidth: 760,
              children: [
                ToastWorkSurface(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.qcTitle,
                        style: AppFonts.system(
                          color: PosColors.text,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${DateFormat('yyyy-MM-dd').format(_todayVn)} · ${context.l10n.qcScopeHint}',
                        style: AppFonts.system(
                          color: PosColors.textMuted,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                      if (checkState.isLoading) ...[
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: const LinearProgressIndicator(
                            minHeight: 3,
                            backgroundColor: PosColors.border,
                            color: PosColors.accent,
                          ),
                        ),
                      ],
                      if (templateState.error != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          templateState.error!,
                          style: AppFonts.system(
                            color: PosColors.danger,
                            fontSize: 13,
                          ),
                        ),
                      ],
                      if (checkState.error != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          checkState.error!,
                          style: AppFonts.system(
                            color: PosColors.danger,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (draftPreviewTemplates.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _QcDraftPreview(
                    templates: draftPreviewTemplates,
                    drafts: _drafts,
                    resultLabel: (value) => _qcResultLabel(context, value),
                  ),
                ],
                const SizedBox(height: 12),
                for (final category in grouped.keys) ...[
                  ToastWorkSurface(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: PosColors.accent.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 4,
                                height: 16,
                                color: PosColors.accent,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                category,
                                style: AppFonts.system(
                                  color: PosColors.text,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        ...grouped[category]!.map((template) {
                          final templateId = template['id']?.toString() ?? '';
                          final draft = _drafts.putIfAbsent(
                            templateId,
                            () => _CheckDraft(),
                          );
                          final criteriaPhotoUrl =
                              template['criteria_photo_url']?.toString();
                          final qscDomain = template['qsc_domain']?.toString();
                          final requiresPhoto =
                              template['requires_photo'] != false;
                          final requiredPhotoCount =
                              template['required_photo_count'] is num
                              ? (template['required_photo_count'] as num)
                                    .toInt()
                              : (requiresPhoto ? 1 : 0);
                          final isSvRequired =
                              template['is_sv_required'] == true;

                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: PosColors.panelStrong,
                              borderRadius: ToastRadiusTokens.xs,
                              border: Border.all(color: PosColors.border),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.assignment_outlined,
                                      color: PosColors.accent,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        template['criteria_text']?.toString() ??
                                            '-',
                                        style: AppFonts.system(
                                          color: PosColors.text,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 15,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                if (criteriaPhotoUrl != null &&
                                    criteriaPhotoUrl.isNotEmpty)
                                  GestureDetector(
                                    onTap: () =>
                                        _showImageDialog(criteriaPhotoUrl),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: PosColors.accent.withValues(
                                            alpha: 0.5,
                                          ),
                                        ),
                                      ),
                                      child: Column(
                                        children: [
                                          ClipRRect(
                                            borderRadius:
                                                const BorderRadius.vertical(
                                                  top: Radius.circular(8),
                                                ),
                                            child: Image.network(
                                              criteriaPhotoUrl,
                                              height: 100,
                                              width: double.infinity,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) =>
                                                  _imageLoadFallback(
                                                    height: 100,
                                                    width: double.infinity,
                                                  ),
                                            ),
                                          ),
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 4,
                                            ),
                                            child: Text(
                                              context.l10n.qcReferencePhoto,
                                              style: AppFonts.system(
                                                color: PosColors.accent,
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    _statusChip(
                                      switch (qscDomain) {
                                        'service' => 'S',
                                        'cleanliness' => 'C',
                                        _ => 'Q',
                                      },
                                      switch (qscDomain) {
                                        'service' => PosColors.info,
                                        'cleanliness' => PosColors.warning,
                                        _ => PosColors.info,
                                      },
                                    ),
                                    _statusChip(
                                      requiresPhoto
                                          ? context.l10n.qscPhotoCount(
                                              requiredPhotoCount,
                                            )
                                          : context.l10n.qscNoPhoto,
                                      requiresPhoto
                                          ? PosColors.info
                                          : PosColors.textMuted,
                                    ),
                                    if (isSvRequired)
                                      _statusChip(
                                        context.l10n.qscSvRequired,
                                        PosColors.accent,
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  key: ValueKey<String>(
                                    'qc_result_selector_$templateId',
                                  ),
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    _qcResultChip(
                                      context,
                                      label: context.l10n.qcResultPass,
                                      selected: draft.result == 'pass',
                                      color: PosColors.success,
                                      onSelected: () => setState(() {
                                        draft.result = 'pass';
                                        draft.completed = true;
                                      }),
                                    ),
                                    _qcResultChip(
                                      context,
                                      label: context.l10n.qcResultFail,
                                      selected: draft.result == 'fail',
                                      color: PosColors.danger,
                                      onSelected: () => setState(() {
                                        draft.result = 'fail';
                                        draft.completed = true;
                                      }),
                                    ),
                                    _qcResultChip(
                                      context,
                                      label: context.l10n.qcResultNa,
                                      selected: draft.result == 'na',
                                      color: PosColors.textMuted,
                                      onSelected: () => setState(() {
                                        draft.result = 'na';
                                        draft.completed = true;
                                      }),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        draft.completed
                                            ? context.l10n.qscInputComplete
                                            : context.l10n.qscInputCompleteHint,
                                        style: AppFonts.system(
                                          color: draft.completed
                                              ? PosColors.success
                                              : PosColors.textMuted,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    OutlinedButton.icon(
                                      key: Key('qc_complete_$templateId'),
                                      onPressed: () => setState(
                                        () =>
                                            draft.completed = !draft.completed,
                                      ),
                                      icon: Icon(
                                        draft.completed
                                            ? Icons.check_circle
                                            : Icons.radio_button_unchecked,
                                      ),
                                      label: Text(context.l10n.complete),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: () =>
                                          _pickEvidencePhoto(templateId),
                                      icon: const Icon(Icons.photo_camera),
                                      label: Text(context.l10n.qcAttachPhoto),
                                    ),
                                    const SizedBox(width: 8),
                                    if (draft.existingPhotoUrl != null &&
                                        draft.photoFiles.isEmpty)
                                      GestureDetector(
                                        onTap: () => _showImageDialog(
                                          draft.existingPhotoUrl!,
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          child: Image.network(
                                            draft.existingPhotoUrl!,
                                            width: 40,
                                            height: 40,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) =>
                                                _imageLoadFallback(
                                                  width: 40,
                                                  height: 40,
                                                ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                if (draft.photoFiles.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  SizedBox(
                                    height: 56,
                                    child: ListView.separated(
                                      scrollDirection: Axis.horizontal,
                                      itemCount: draft.photoFiles.length,
                                      separatorBuilder: (_, __) =>
                                          const SizedBox(width: 8),
                                      itemBuilder: (context, index) {
                                        final file = draft.photoFiles[index];
                                        return Stack(
                                          children: [
                                            GestureDetector(
                                              onTap: () =>
                                                  _showPickedImageDialog(file),
                                              child: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                child: _pickedImagePreview(
                                                  file,
                                                ),
                                              ),
                                            ),
                                            Positioned(
                                              top: -6,
                                              right: -6,
                                              child: IconButton(
                                                visualDensity:
                                                    VisualDensity.compact,
                                                padding: EdgeInsets.zero,
                                                constraints:
                                                    const BoxConstraints(
                                                      minWidth: 24,
                                                      minHeight: 24,
                                                    ),
                                                onPressed: () =>
                                                    _removeEvidencePhoto(
                                                      templateId,
                                                      index,
                                                    ),
                                                icon: const CircleAvatar(
                                                  radius: 10,
                                                  backgroundColor:
                                                      PosColors.danger,
                                                  child: Icon(
                                                    Icons.close,
                                                    size: 12,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                                ],
                                if (draft.hasQscStatus) ...[
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      if (draft.submissionStatus != null)
                                        _statusChip(
                                          _submissionStatusLabel(
                                            context,
                                            draft.submissionStatus!,
                                          ),
                                          PosColors.accent,
                                        ),
                                      if (draft.photoUploadedCount != null ||
                                          draft.photoRequiredCount != null)
                                        _statusChip(
                                          'Photo ${draft.photoUploadedCount ?? 0}/${draft.photoRequiredCount ?? 0}',
                                          PosColors.textMuted,
                                        ),
                                      if (draft.svReviewStatus != null)
                                        _statusChip(
                                          _svReviewStatusLabel(
                                            context,
                                            draft.svReviewStatus!,
                                          ),
                                          PosColors.success,
                                        ),
                                      if (draft.grade != null &&
                                          draft.grade!.isNotEmpty)
                                        _statusChip(
                                          draft.grade!.toUpperCase(),
                                          _gradeColor(draft.grade!),
                                        ),
                                    ],
                                  ),
                                ],
                                const SizedBox(height: 8),
                                TextField(
                                  controller: draft.noteController,
                                  style: AppFonts.system(
                                    color: PosColors.text,
                                    fontSize: 13,
                                  ),
                                  decoration: InputDecoration(
                                    hintText: context.l10n.qcMemoHint,
                                    border: const OutlineInputBorder(),
                                  ),
                                  onChanged: (_) => setState(() {}),
                                  maxLines: 2,
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ],
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    key: const Key('qc_save_all'),
                    onPressed: storeId == null
                        ? null
                        : () => _submitAll(
                            storeId: storeId,
                            checkedBy: auth.user?.id,
                          ),
                    style: FilledButton.styleFrom(
                      backgroundColor: PosColors.accent,
                      foregroundColor: Colors.white,
                    ),
                    child: Text(
                      context.l10n.qcSaveButton,
                      style: AppFonts.system(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
    );
  }

  Widget _statusChip(String label, Color color) {
    return ToastStatusBadge(label: label, color: color);
  }

  Widget _qcResultChip(
    BuildContext context, {
    required String label,
    required bool selected,
    required Color color,
    required VoidCallback onSelected,
  }) {
    return ChoiceChip(
      label: Text(
        label,
        style: AppFonts.system(
          color: selected ? color : PosColors.text,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
      selected: selected,
      selectedColor: color.withValues(alpha: 0.14),
      backgroundColor: PosColors.panelStrong,
      side: BorderSide(color: selected ? color : PosColors.border),
      onSelected: (_) => onSelected(),
    );
  }

  String _qcResultLabel(BuildContext context, String? value) {
    return switch (value) {
      'pass' => context.l10n.qcResultPass,
      'fail' => context.l10n.qcResultFail,
      'na' => context.l10n.qcResultNa,
      _ => context.l10n.qscInputCompleteHint,
    };
  }

  String _submissionStatusLabel(BuildContext context, String value) {
    switch (value) {
      case 'pending':
        return '${context.l10n.qcTitle} Pending';
      case 'overdue':
        return '${context.l10n.qcTitle} Overdue';
      case 'submitted':
      default:
        return '${context.l10n.qcTitle} Submitted';
    }
  }

  String _svReviewStatusLabel(BuildContext context, String value) {
    switch (value) {
      case 'pending':
        return 'SV Pending';
      case 'reviewed':
        return 'SV Reviewed';
      case 'rejected':
        return 'SV Rejected';
      case 'not_required':
      default:
        return 'SV N/A';
    }
  }

  Color _gradeColor(String grade) {
    switch (grade) {
      case 'good':
        return PosColors.success;
      case 'caution':
        return PosColors.accent;
      case 'risk':
        return PosColors.danger;
      default:
        return PosColors.textMuted;
    }
  }

  int? _readInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}');
  }

  Future<void> _showImageDialog(String path) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.black,
          insetPadding: const EdgeInsets.all(20),
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 4,
                  child: Image.network(
                    path,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => _imageLoadFallback(
                      color: Colors.white.withValues(alpha: 0.78),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: Colors.white),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _pickedImagePreview(XFile file) {
    return FutureBuilder<Uint8List>(
      future: file.readAsBytes(),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) {
          return const SizedBox(
            width: 56,
            height: 56,
            child: Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        return Image.memory(bytes, width: 56, height: 56, fit: BoxFit.cover);
      },
    );
  }

  Widget _imageLoadFallback({
    double? width,
    double? height,
    Color color = PosColors.textMuted,
  }) {
    return Container(
      width: width,
      height: height,
      color: PosColors.canvasAlt,
      child: Center(
        child: Icon(Icons.broken_image_outlined, color: color, size: 22),
      ),
    );
  }

  Future<void> _showPickedImageDialog(XFile file) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.black,
          insetPadding: const EdgeInsets.all(20),
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 4,
                  child: FutureBuilder<Uint8List>(
                    future: file.readAsBytes(),
                    builder: (context, snapshot) {
                      final bytes = snapshot.data;
                      if (bytes == null) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      return Image.memory(bytes, fit: BoxFit.contain);
                    },
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: Colors.white),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _QcDraftPreview extends StatelessWidget {
  const _QcDraftPreview({
    required this.templates,
    required this.drafts,
    required this.resultLabel,
  });

  final List<Map<String, dynamic>> templates;
  final Map<String, _CheckDraft> drafts;
  final String Function(String?) resultLabel;

  @override
  Widget build(BuildContext context) {
    final visibleTemplates = templates
        .where((template) {
          final templateId = template['id']?.toString() ?? '';
          final draft = drafts[templateId];
          return draft != null && draft.hasInput;
        })
        .toList(growable: false);

    if (visibleTemplates.isEmpty) return const SizedBox.shrink();

    return ToastWorkSurface(
      key: const Key('pending_qc_draft_preview'),
      padding: const EdgeInsets.all(12),
      backgroundColor: PosColors.panelStrong,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.fact_check_outlined,
                size: 18,
                color: PosColors.accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${context.l10n.selected} ${context.l10n.qcTitle}',
                  style: AppFonts.system(
                    color: PosColors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              ToastStatusBadge(
                label: '${visibleTemplates.length}',
                color: PosColors.accent,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 76,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: visibleTemplates.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final template = visibleTemplates[index];
                final templateId = template['id']?.toString() ?? '';
                final draft = drafts[templateId]!;
                final photoCount = draft.attachedPhotoCount;
                return Container(
                  key: ValueKey<String>('pending_qc_draft_item_$templateId'),
                  width: 220,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: PosColors.canvasAlt,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: PosColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        template['criteria_text']?.toString() ?? '-',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.system(
                          color: PosColors.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          ToastStatusBadge(
                            label: resultLabel(draft.result),
                            color: _resultColor(draft.result),
                            compact: true,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              photoCount > 0
                                  ? '${context.l10n.qcAttachPhoto} $photoCount'
                                  : context.l10n.qscNoPhoto,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppFonts.system(
                                color: PosColors.textMuted,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Color _resultColor(String? value) {
    return switch (value) {
      'pass' => PosColors.success,
      'fail' => PosColors.danger,
      _ => PosColors.textMuted,
    };
  }
}

class _CheckDraft {
  _CheckDraft();

  String? result;
  bool completed = false;
  final List<XFile> photoFiles = [];
  String? existingPhotoUrl;
  String? submissionStatus;
  int? photoUploadedCount;
  int? photoRequiredCount;
  String? svReviewStatus;
  String? grade;
  final TextEditingController noteController = TextEditingController();

  int get attachedPhotoCount {
    if (photoFiles.isNotEmpty || existingPhotoUrl != null) {
      return photoFiles.length + (existingPhotoUrl != null ? 1 : 0);
    }
    return photoUploadedCount ?? 0;
  }

  bool get hasQscStatus =>
      submissionStatus != null ||
      photoUploadedCount != null ||
      photoRequiredCount != null ||
      svReviewStatus != null ||
      (grade != null && grade!.isNotEmpty);

  bool get hasInput =>
      completed ||
      result != null ||
      photoFiles.isNotEmpty ||
      existingPhotoUrl != null ||
      noteController.text.trim().isNotEmpty;
}
