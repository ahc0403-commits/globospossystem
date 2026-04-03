import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../core/layout/platform_info.dart';
import '../../core/utils/permission_utils.dart';
import '../../core/utils/time_utils.dart';
import '../../main.dart';
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

  Future<void> _initialize(String restaurantId) async {
    await ref.read(qcTemplateProvider.notifier).loadTemplates(restaurantId);
    await ref
        .read(qcCheckProvider.notifier)
        .loadWeek(
          restaurantId: restaurantId,
          weekStart: _startOfWeek(_todayVn),
        );
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
        draft.photoFile = File(picked.path);
        draft.existingPhotoUrl = null;
      });
    } catch (e) {
      if (!mounted) return;
      showErrorToast(context, '사진 첨부 실패: $e');
    }
  }

  Future<void> _submitAll({
    required String restaurantId,
    required String? checkedBy,
  }) async {
    final notifier = ref.read(qcCheckProvider.notifier);
    final checkDate = DateFormat('yyyy-MM-dd').format(_todayVn);

    final toSubmit = <MapEntry<String, _CheckDraft>>[];
    for (final entry in _drafts.entries) {
      if (entry.value.result == null) continue;
      toSubmit.add(entry);
    }

    if (toSubmit.isEmpty) {
      showErrorToast(context, '선택된 점검 항목이 없습니다');
      return;
    }

    try {
      for (final entry in toSubmit) {
        await notifier.submitCheck(
          restaurantId: restaurantId,
          templateId: entry.key,
          checkDate: checkDate,
          result: entry.value.result!,
          evidencePhoto: entry.value.photoFile,
          note: entry.value.noteController.text.trim().isEmpty
              ? null
              : entry.value.noteController.text.trim(),
          checkedBy: checkedBy,
        );
      }

      if (!mounted) return;
      showSuccessToast(context, '저장 완료');
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      showErrorToast(context, '저장 실패: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final restaurantId = auth.restaurantId;
    final canAccess = PermissionUtils.canDoQcCheck(
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
          showErrorToast(context, '권한이 없습니다. 관리자에게 문의하세요.');
          final homeRoute = switch (auth.role) {
            'waiter' => '/waiter',
            'kitchen' => '/kitchen',
            'cashier' => '/cashier',
            'super_admin' => '/super-admin',
            _ => '/admin',
          };
          context.go(homeRoute);
        });
      }
      return Scaffold(
        backgroundColor: AppColors.surface0,
        body: Center(
          child: Text(
            '권한이 없습니다. 관리자에게 문의하세요.',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 14,
            ),
          ),
        ),
      );
    }

    if (restaurantId != null && _initializedRestaurantId != restaurantId) {
      _initializedRestaurantId = restaurantId;
      _didPrepopulate = false;
      Future.microtask(() => _initialize(restaurantId));
    }

    _prepopulateFromExistingChecks(checkState.checks);

    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final t in templateState.templates) {
      final category = t['category']?.toString() ?? '기타';
      grouped.putIfAbsent(category, () => []).add(t);
    }

    return Scaffold(
      backgroundColor: AppColors.surface0,
      appBar: AppBar(
        backgroundColor: AppColors.surface0,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '오늘의 품질 점검',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              DateFormat('yyyy-MM-dd').format(_todayVn),
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      body: templateState.isLoading || checkState.isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.amber500),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final category in grouped.keys) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.amber500.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 4,
                          height: 16,
                          color: AppColors.amber500,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          category,
                          style: GoogleFonts.notoSansKr(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  ...grouped[category]!.map((template) {
                    final templateId = template['id']?.toString() ?? '';
                    final draft = _drafts.putIfAbsent(
                      templateId,
                      () => _CheckDraft(),
                    );
                    final criteriaPhotoUrl = template['criteria_photo_url']
                        ?.toString();

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.surface1,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.surface2),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '기준: ${template['criteria_text'] ?? '-'}',
                            style: GoogleFonts.notoSansKr(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (criteriaPhotoUrl != null &&
                              criteriaPhotoUrl.isNotEmpty)
                            Row(
                              children: [
                                const Text('기준사진: '),
                                GestureDetector(
                                  onTap: () =>
                                      _showImageDialog(criteriaPhotoUrl),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(
                                      criteriaPhotoUrl,
                                      width: 40,
                                      height: 40,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _resultButton(
                                label: '✅ 통과',
                                selected: draft.result == 'pass',
                                onTap: () =>
                                    setState(() => draft.result = 'pass'),
                              ),
                              _resultButton(
                                label: '❌ 불합격',
                                selected: draft.result == 'fail',
                                onTap: () =>
                                    setState(() => draft.result = 'fail'),
                              ),
                              _resultButton(
                                label: '— 해당없음',
                                selected: draft.result == 'na',
                                onTap: () =>
                                    setState(() => draft.result = 'na'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => _pickEvidencePhoto(templateId),
                                icon: const Icon(Icons.photo_camera),
                                label: const Text('사진 첨부'),
                              ),
                              const SizedBox(width: 8),
                              if (draft.photoFile != null)
                                GestureDetector(
                                  onTap: () => _showImageDialog(
                                    draft.photoFile!.path,
                                    isFile: true,
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.file(
                                      draft.photoFile!,
                                      width: 40,
                                      height: 40,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                )
                              else if (draft.existingPhotoUrl != null)
                                GestureDetector(
                                  onTap: () =>
                                      _showImageDialog(draft.existingPhotoUrl!),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(
                                      draft.existingPhotoUrl!,
                                      width: 40,
                                      height: 40,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: draft.noteController,
                            style: GoogleFonts.notoSansKr(
                              color: AppColors.textPrimary,
                              fontSize: 13,
                            ),
                            decoration: const InputDecoration(
                              hintText: '메모 입력 (선택)',
                              border: OutlineInputBorder(),
                            ),
                            maxLines: 2,
                          ),
                        ],
                      ),
                    );
                  }),
                ],
                const SizedBox(height: 8),
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: restaurantId == null
                        ? null
                        : () => _submitAll(
                            restaurantId: restaurantId,
                            checkedBy: auth.user?.id,
                          ),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.amber500,
                      foregroundColor: AppColors.surface0,
                    ),
                    child: Text(
                      '저장 완료',
                      style: GoogleFonts.notoSansKr(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _resultButton({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.amber500.withValues(alpha: 0.20)
              : AppColors.surface0,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.amber500 : AppColors.surface2,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.notoSansKr(
            color: selected ? AppColors.amber500 : AppColors.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Future<void> _showImageDialog(String path, {bool isFile = false}) async {
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
                  child: isFile
                      ? Image.file(File(path), fit: BoxFit.contain)
                      : Image.network(path, fit: BoxFit.contain),
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

class _CheckDraft {
  _CheckDraft();

  String? result;
  File? photoFile;
  String? existingPhotoUrl;
  final TextEditingController noteController = TextEditingController();
}
