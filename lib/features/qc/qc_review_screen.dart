import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/services/qc_service.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast_primitives_extended.dart';
import '../../core/utils/number_input_utils.dart';
import '../../core/utils/permission_utils.dart';
import '../../core/utils/role_routes.dart';
import '../../core/utils/time_utils.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/error_toast.dart';
import '../auth/auth_provider.dart';
import 'qc_provider.dart';

class QcReviewScreen extends ConsumerStatefulWidget {
  const QcReviewScreen({super.key, this.qcServiceOverride});

  final QcService? qcServiceOverride;

  @override
  ConsumerState<QcReviewScreen> createState() => _QcReviewScreenState();
}

class _QcReviewScreenState extends ConsumerState<QcReviewScreen> {
  String? _initializedRestaurantId;
  bool _didHandleUnauthorized = false;
  String _filter = 'pending';
  DateTime _weekStart = _startOfWeek(TimeUtils.nowVietnam());

  QcService get _qcService => widget.qcServiceOverride ?? qcService;

  static DateTime _startOfWeek(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  Future<void> _initialize(String storeId) async {
    await ref.read(qcTemplateProvider.notifier).loadTemplates(storeId);
    await ref
        .read(qcCheckProvider.notifier)
        .loadWeek(storeId: storeId, weekStart: _weekStart);
  }

  Future<void> _loadWeek(String storeId, DateTime start) async {
    setState(() => _weekStart = start);
    await ref
        .read(qcCheckProvider.notifier)
        .loadWeek(storeId: storeId, weekStart: start);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final storeId = auth.storeId;
    final canReview = PermissionUtils.canDoQcVisitReview(
      auth.role,
      auth.extraPermissions,
    );
    final checkState = ref.watch(qcCheckProvider);

    if (!canReview) {
      if (!_didHandleUnauthorized) {
        _didHandleUnauthorized = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          showErrorToast(context, context.l10n.qscNoReviewPermission);
          context.go(homeRouteForRole(auth.role));
        });
      }
      return Scaffold(
        key: const Key('qc_review_root'),
        backgroundColor: PosColors.canvas,
        body: Center(
          child: Text(
            context.l10n.qscNoReviewPermission,
            style: AppFonts.system(color: PosColors.text, fontSize: 14),
          ),
        ),
      );
    }

    if (storeId != null && _initializedRestaurantId != storeId) {
      _initializedRestaurantId = storeId;
      Future.microtask(() => _initialize(storeId));
    }

    final reviewChecks =
        checkState.checks.where((check) {
          final status = _effectiveSvStatus(check);
          final matchesFilter = switch (_filter) {
            'pending' => status == 'pending',
            'reviewed' => status == 'reviewed',
            'rejected' => status == 'rejected',
            'all' => true,
            _ => true,
          };
          return status != 'not_required' && matchesFilter;
        }).toList()..sort((a, b) {
          final aStatus = _effectiveSvStatus(a) == 'pending' ? 0 : 1;
          final bStatus = _effectiveSvStatus(b) == 'pending' ? 0 : 1;
          if (aStatus != bStatus) return aStatus.compareTo(bStatus);
          final aDate = a['check_date']?.toString() ?? '';
          final bDate = b['check_date']?.toString() ?? '';
          return bDate.compareTo(aDate);
        });

    final pendingCount = checkState.checks
        .where((check) => _effectiveSvStatus(check) == 'pending')
        .length;
    final reviewedCount = checkState.checks
        .where((check) => _effectiveSvStatus(check) == 'reviewed')
        .length;
    final rejectedCount = checkState.checks
        .where((check) => _effectiveSvStatus(check) == 'rejected')
        .length;

    return Scaffold(
      key: const Key('qc_review_root'),
      backgroundColor: PosColors.canvas,
      appBar: AppBar(
        backgroundColor: PosColors.topbarSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 1,
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: AppNavBar()),
          ),
        ],
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.qscReviewTitle,
              style: AppFonts.system(
                color: PosColors.text,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              _weekLabel(),
              style: AppFonts.system(color: PosColors.textMuted, fontSize: 12),
            ),
          ],
        ),
      ),
      body: checkState.isLoading
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
                        context.l10n.qscReviewHeader,
                        style: AppFonts.system(
                          color: PosColors.text,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        context.l10n.qscReviewSubtitle,
                        style: AppFonts.system(
                          color: PosColors.textMuted,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _summaryChip(
                            context.l10n.qscPendingCount(pendingCount),
                            PosColors.accent,
                          ),
                          _summaryChip(
                            context.l10n.qscReviewedCount(reviewedCount),
                            PosColors.success,
                          ),
                          _summaryChip(
                            context.l10n.qscRejectedCount(rejectedCount),
                            PosColors.danger,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    IconButton(
                      onPressed: storeId == null
                          ? null
                          : () => _loadWeek(
                              storeId,
                              _weekStart.subtract(const Duration(days: 7)),
                            ),
                      icon: const Icon(
                        Icons.chevron_left,
                        color: PosColors.text,
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          _weekLabel(),
                          style: AppFonts.system(
                            color: PosColors.text,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: storeId == null
                          ? null
                          : () => _loadWeek(
                              storeId,
                              _weekStart.add(const Duration(days: 7)),
                            ),
                      icon: const Icon(
                        Icons.chevron_right,
                        color: PosColors.text,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _filterChip('pending', context.l10n.qscPending),
                      const SizedBox(width: 8),
                      _filterChip('reviewed', context.l10n.qscReviewed),
                      const SizedBox(width: 8),
                      _filterChip('rejected', context.l10n.qscRejected),
                      const SizedBox(width: 8),
                      _filterChip('all', context.l10n.all),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (checkState.error != null) ...[
                  Text(
                    checkState.error!,
                    style: AppFonts.system(
                      color: PosColors.danger,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                if (reviewChecks.isEmpty)
                  ToastWorkSurface(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      context.l10n.qscNoSvReviewTargets,
                      style: AppFonts.system(color: PosColors.textMuted),
                    ),
                  )
                else
                  ...reviewChecks.map(
                    (check) => _reviewCard(context, auth, check),
                  ),
                const SizedBox(height: 16),
              ],
            ),
    );
  }

  Widget _reviewCard(
    BuildContext context,
    dynamic auth,
    Map<String, dynamic> check,
  ) {
    final template = check['qc_templates'] as Map<String, dynamic>?;
    final effectiveStatus = _effectiveSvStatus(check);
    final photoUrl = check['evidence_photo_url']?.toString();
    final uploadedPhotoCount = _readInt(check['photo_uploaded_count']) ?? 0;
    final requiredPhotoCount = _readInt(check['photo_required_count']) ?? 0;
    final note = check['note']?.toString();
    final svScore = check['sv_score']?.toString();
    final svNote = check['sv_note']?.toString();

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
              Expanded(
                child: Text(
                  template?['criteria_text']?.toString() ?? '-',
                  style: AppFonts.system(
                    color: PosColors.text,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ),
              _statusChip(
                _svStatusLabel(effectiveStatus),
                _svStatusColor(effectiveStatus),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _statusChip(
                template?['category']?.toString() ??
                    context.l10n.qcCategoryOther,
                PosColors.textMuted,
              ),
              _statusChip(
                _domainLabel(template?['qsc_domain']?.toString()),
                PosColors.info,
              ),
              _statusChip(
                'Photo $uploadedPhotoCount/$requiredPhotoCount',
                uploadedPhotoCount < requiredPhotoCount
                    ? PosColors.accent
                    : PosColors.success,
              ),
              _statusChip(
                check['submission_status']?.toString() ?? 'submitted',
                PosColors.textMuted,
              ),
            ],
          ),
          if (photoUrl != null && photoUrl.isNotEmpty) ...[
            const SizedBox(height: 10),
            GestureDetector(
              key: ValueKey('qc_review_photo_${check['id']}'),
              onTap: () => _openPhotoGallery(check),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  photoUrl,
                  height: 160,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      _imageLoadFallback(height: 160, width: double.infinity),
                ),
              ),
            ),
            if (uploadedPhotoCount > 1) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => _openPhotoGallery(check),
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(context.l10n.qscViewAllPhotos(uploadedPhotoCount)),
              ),
            ],
          ],
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: 10),
            _fieldLabel(context.l10n.qscStaffNote),
            const SizedBox(height: 4),
            Text(note, style: AppFonts.system(color: PosColors.text)),
          ],
          if (svScore != null && svScore.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              context.l10n.qscSvScoreValue(svScore),
              style: AppFonts.system(
                color: PosColors.text,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          if (svNote != null && svNote.isNotEmpty) ...[
            const SizedBox(height: 8),
            _fieldLabel(context.l10n.qscSvNote),
            const SizedBox(height: 4),
            Text(svNote, style: AppFonts.system(color: PosColors.text)),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _openReviewSheet(
                    context: context,
                    auth: auth,
                    check: check,
                    status: 'rejected',
                  ),
                  icon: const Icon(Icons.error_outline),
                  label: Text(context.l10n.qscNeedsFollowUp),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  key: ValueKey('qc_review_approve_${check['id']}'),
                  onPressed: () => _openReviewSheet(
                    context: context,
                    auth: auth,
                    check: check,
                    status: 'reviewed',
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: PosColors.accent,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.verified_outlined),
                  label: Text(context.l10n.qscMarkReviewed),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openReviewSheet({
    required BuildContext context,
    required dynamic auth,
    required Map<String, dynamic> check,
    required String status,
  }) async {
    final scoreController = TextEditingController(
      text: check['sv_score']?.toString() ?? '',
    );
    final noteController = TextEditingController(
      text: check['sv_note']?.toString() ?? '',
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: PosColors.panelStrong,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: Column(
            key: const Key('qc_review_sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                status == 'reviewed'
                    ? context.l10n.qscMarkReviewed
                    : context.l10n.qscNeedsFollowUp,
                style: AppFonts.system(
                  color: PosColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: scoreController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: AppFonts.system(color: PosColors.text),
                decoration: InputDecoration(labelText: context.l10n.qscSvScore),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: noteController,
                minLines: 2,
                maxLines: 4,
                style: AppFonts.system(color: PosColors.text),
                decoration: InputDecoration(labelText: context.l10n.qscSvNote),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    final storeId = auth.storeId;
                    final checkId = check['id']?.toString();
                    if (storeId == null || checkId == null || checkId.isEmpty) {
                      return;
                    }
                    try {
                      await ref
                          .read(qcCheckProvider.notifier)
                          .submitVisitReview(
                            storeId: storeId,
                            checkIds: [checkId],
                            svReviewStatus: status,
                            svScore: parseDecimalInput(scoreController.text),
                            svNote: noteController.text.trim().isEmpty
                                ? null
                                : noteController.text.trim(),
                            visitSessionId: const Uuid().v4(),
                            reviewedAt: DateTime.now(),
                            reviewedBy: auth.user?.id,
                          );
                      if (!context.mounted) return;
                      Navigator.of(context).pop();
                      showSuccessToast(context, context.l10n.qscReviewSaved);
                    } catch (e) {
                      if (!context.mounted) return;
                      showErrorToast(context, e.toString());
                    }
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: PosColors.accent,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(context.l10n.qscSaveReview),
                ),
              ),
            ],
          ),
        );
      },
    );

    await Future<void>.delayed(kThemeAnimationDuration);
    scoreController.dispose();
    noteController.dispose();
  }

  Future<void> _openPhotoGallery(Map<String, dynamic> check) async {
    final checkId = check['id']?.toString();
    if (checkId == null || checkId.isEmpty) return;

    late final List<Map<String, dynamic>> photos;
    try {
      photos = await _qcService.fetchCheckPhotos(
        checkId: checkId,
        fallbackPhotoUrl: check['evidence_photo_url']?.toString(),
      );
    } catch (_) {
      if (!mounted) return;
      showErrorToast(context, context.l10n.qscFailedLoadPhotos);
      return;
    }

    if (!mounted) return;
    if (photos.isEmpty) {
      showErrorToast(context, context.l10n.qscNoPhotosAvailable);
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          key: const Key('qc_review_photo_gallery_dialog'),
          backgroundColor: Colors.black,
          insetPadding: const EdgeInsets.all(20),
          child: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(context).size.height * 0.72,
            child: Stack(
              children: [
                PageView(
                  children: photos.map((photo) {
                    final url = photo['photo_url']?.toString();
                    return InteractiveViewer(
                      minScale: 0.8,
                      maxScale: 4,
                      child: url == null || url.isEmpty
                          ? const SizedBox.shrink()
                          : Image.network(
                              url,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => _imageLoadFallback(
                                color: Colors.white.withValues(alpha: 0.78),
                              ),
                            ),
                    );
                  }).toList(),
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
          ),
        );
      },
    );
  }

  Widget _filterChip(String value, String label) {
    final selected = _filter == value;
    return InkWell(
      onTap: () => setState(() => _filter = value),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? PosColors.accent.withValues(alpha: 0.16)
              : PosColors.panelStrong,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? PosColors.accent : PosColors.border,
          ),
        ),
        child: Text(
          label,
          style: AppFonts.system(
            color: selected ? PosColors.accent : PosColors.textMuted,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _summaryChip(String label, Color color) {
    return ToastStatusBadge(label: label, color: color);
  }

  Widget _statusChip(String label, Color color) {
    return ToastStatusBadge(label: label, color: color);
  }

  Widget _fieldLabel(String value) {
    return Text(
      value,
      style: AppFonts.system(
        color: PosColors.textMuted,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
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

  String _weekLabel() {
    final end = _weekStart.add(const Duration(days: 6));
    return '${DateFormat('MM/dd').format(_weekStart)} - ${DateFormat('MM/dd').format(end)}';
  }

  String _effectiveSvStatus(Map<String, dynamic> check) {
    final template = check['qc_templates'] as Map<String, dynamic>?;
    final isRequired = template?['is_sv_required'] == true;
    if (!isRequired) return 'not_required';
    final status = check['sv_review_status']?.toString();
    if (status == null || status.isEmpty) return 'pending';
    return status;
  }

  String _svStatusLabel(String status) {
    switch (status) {
      case 'reviewed':
        return context.l10n.qscSvStatusReviewed;
      case 'rejected':
        return context.l10n.qscSvStatusRejected;
      case 'not_required':
        return context.l10n.qscSvStatusNotRequired;
      case 'pending':
      default:
        return context.l10n.qscSvStatusPending;
    }
  }

  Color _svStatusColor(String status) {
    switch (status) {
      case 'reviewed':
        return PosColors.success;
      case 'rejected':
        return PosColors.danger;
      case 'not_required':
        return PosColors.textMuted;
      case 'pending':
      default:
        return PosColors.accent;
    }
  }

  String _domainLabel(String? value) {
    switch (value) {
      case 'service':
        return context.l10n.qscDomainService;
      case 'cleanliness':
        return context.l10n.qscDomainCleanliness;
      case 'quality':
      default:
        return context.l10n.qscDomainQuality;
    }
  }

  int? _readInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}');
  }
}
