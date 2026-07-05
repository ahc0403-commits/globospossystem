import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../core/ui/pos_design_tokens.dart';
import '../../../core/ui/toast/toast.dart';
import '../../../core/utils/number_input_utils.dart';
import '../../../main.dart';
import '../../../widgets/error_toast.dart';
import '../../auth/auth_provider.dart';
import '../../qc/qc_provider.dart';

const _qcDefaultPageMinHeight = 720.0;
const _qcWeeklyBoardPageMinHeight = 940.0;
const _qcWeeklyBoardScrollPadding = EdgeInsets.only(bottom: 96);
const _qcWeeklyBoardScrollPhysics = AlwaysScrollableScrollPhysics(
  parent: ClampingScrollPhysics(),
);

class QcTab extends ConsumerStatefulWidget {
  const QcTab({super.key});

  @override
  ConsumerState<QcTab> createState() => _QcTabState();
}

class _QcTabState extends ConsumerState<QcTab>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 3,
    vsync: this,
  );
  final ImagePicker _picker = ImagePicker();

  String? _initializedRestaurantId;
  DateTime _weekStart = _startOfWeek(DateTime.now());
  int _selectedSurfaceIndex = 0;

  static DateTime _startOfWeek(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  @override
  void initState() {
    super.initState();
    _selectedSurfaceIndex = _tabController.index;
    _tabController.addListener(() {
      if (!mounted) return;
      if (_selectedSurfaceIndex != _tabController.index) {
        setState(() => _selectedSurfaceIndex = _tabController.index);
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _initData(String storeId) async {
    await ref.read(qcTemplateProvider.notifier).loadTemplates(storeId);
    await ref
        .read(qcCheckProvider.notifier)
        .loadWeek(storeId: storeId, weekStart: _weekStart);
    await ref.read(qcFollowupProvider.notifier).load(storeId);
  }

  Future<void> _loadWeek(String storeId, DateTime weekStart) async {
    setState(() => _weekStart = weekStart);
    await ref
        .read(qcCheckProvider.notifier)
        .loadWeek(storeId: storeId, weekStart: weekStart);
  }

  @override
  Widget build(BuildContext context) {
    final storeId = ref.watch(authProvider).storeId;
    final templateState = ref.watch(qcTemplateProvider);
    final checkState = ref.watch(qcCheckProvider);
    final followupState = ref.watch(qcFollowupProvider);
    final failedChecks = checkState.checks
        .where((check) => check['result']?.toString() == 'fail')
        .length;
    final openFollowups = followupState.followups.where((followup) {
      final status = followup['status']?.toString();
      return status == 'open' || status == 'in_progress';
    }).length;
    final surfaces = const [
      'Follow-ups',
      'Weekly Inspection Status',
      'Template Management',
    ];

    if (storeId != null && _initializedRestaurantId != storeId) {
      _initializedRestaurantId = storeId;
      Future.microtask(() => _initData(storeId));
    }

    return Scaffold(
      key: const Key('qc_root'),
      backgroundColor: PosColors.canvas,
      body: ToastResponsiveBody(
        maxWidth: 1460,
        minHeight: _selectedSurfaceIndex == 1
            ? _qcWeeklyBoardPageMinHeight
            : _qcDefaultPageMinHeight,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildQcExceptionHeader(
              templateCount: templateState.templates.length,
              weeklyCheckCount: checkState.checks.length,
              failedCheckCount: failedChecks,
              openFollowupCount: openFollowups,
              currentSurface: surfaces[_selectedSurfaceIndex],
            ),
            const SizedBox(height: 12),
            _buildQcWorkflowControls(surfaces: surfaces),
            const SizedBox(height: 12),
            _QcWorkflowSummary(
              label: _qcSurfaceLabel(surfaces[_selectedSurfaceIndex]),
              summary: _qcSurfaceSummary(surfaces[_selectedSurfaceIndex]),
              color: _qcSurfaceColor(surfaces[_selectedSurfaceIndex]),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ToastWorkSurface(
                padding: EdgeInsets.zero,
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _FollowupTab(storeId: storeId),
                    _WeeklyViewTab(
                      storeId: storeId,
                      weekStart: _weekStart,
                      onPrevWeek: storeId == null
                          ? null
                          : () => _loadWeek(
                              storeId,
                              _weekStart.subtract(const Duration(days: 7)),
                            ),
                      onNextWeek: storeId == null
                          ? null
                          : () => _loadWeek(
                              storeId,
                              _weekStart.add(const Duration(days: 7)),
                            ),
                    ),
                    _TemplateManagementTab(
                      picker: _picker,
                      storeId: storeId,
                      role: ref.watch(authProvider).role,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQcExceptionHeader({
    required int templateCount,
    required int weeklyCheckCount,
    required int failedCheckCount,
    required int openFollowupCount,
    required String currentSurface,
  }) {
    final l10n = context.l10n;
    final needsReview = openFollowupCount > 0 || failedCheckCount > 0;

    return ToastWorkSurface(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      backgroundColor: PosColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.qcManagementTitle,
                      style: Theme.of(
                        context,
                      ).textTheme.headlineLarge?.copyWith(letterSpacing: 0),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.qcSurfaceFollowUpSummary,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PosColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ToastStatusBadge(
                label: _qcSurfaceLabel(currentSurface),
                color: needsReview ? PosColors.danger : PosColors.success,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 14),
          ToastMetricStrip(
            metrics: [
              ToastMetric(
                label: l10n.qcOpenActions,
                value: '$openFollowupCount',
                tone: openFollowupCount > 0
                    ? PosColors.danger
                    : PosColors.success,
              ),
              ToastMetric(
                label: l10n.qcFailedItems,
                value: '$failedCheckCount',
                tone: failedCheckCount > 0
                    ? PosColors.warning
                    : PosColors.success,
              ),
              ToastMetric(
                label: l10n.qcWeeklyChecks,
                value: '$weeklyCheckCount',
                tone: PosColors.info,
              ),
              ToastMetric(label: l10n.qcTemplates, value: '$templateCount'),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              ToastStatusBadge(
                label: needsReview
                    ? l10n.reportsNeedsReviewShort
                    : l10n.staffNoIssues,
                color: needsReview ? PosColors.warning : PosColors.success,
                compact: true,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  needsReview
                      ? l10n.qcSurfaceFollowUpSummary
                      : l10n.qcSurfaceDefaultSummary,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQcWorkflowControls({required List<String> surfaces}) {
    return ToastWorkSurface(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      backgroundColor: PosColors.surface,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var index = 0; index < surfaces.length; index++)
            _QcSurfaceTab(
              label: _qcSurfaceDisplayLabel(surfaces[index]),
              selected: index == _selectedSurfaceIndex,
              onTap: () => _tabController.animateTo(index),
            ),
        ],
      ),
    );
  }

  String _qcSurfaceDisplayLabel(String tab) {
    switch (tab) {
      case 'Template Management':
        return context.l10n.qcTemplates;
      case 'Weekly Inspection Status':
        return context.l10n.qcWeeklyBoard;
      case 'Follow-ups':
        return context.l10n.followUp;
      default:
        return tab;
    }
  }

  String _qcSurfaceLabel(String tab) {
    final l10n = context.l10n;
    switch (tab) {
      case 'Follow-ups':
        return l10n.qcExceptionQueue;
      case 'Weekly Inspection Status':
        return l10n.qcLiveReview;
      default:
        return l10n.adminWorkflowBackOffice;
    }
  }

  String _qcSurfaceSummary(String tab) {
    switch (tab) {
      case 'Template Management':
        return context.l10n.qcSurfaceTemplateSummary;
      case 'Weekly Inspection Status':
        return context.l10n.qcSurfaceWeeklySummary;
      case 'Follow-ups':
        return context.l10n.qcSurfaceFollowUpSummary;
      default:
        return context.l10n.qcSurfaceDefaultSummary;
    }
  }

  Color _qcSurfaceColor(String tab) {
    switch (tab) {
      case 'Follow-ups':
        return PosColors.danger;
      case 'Weekly Inspection Status':
        return PosColors.accent;
      default:
        return PosColors.textSecondary;
    }
  }
}

class _QcWorkflowSummary extends StatelessWidget {
  const _QcWorkflowSummary({
    required this.label,
    required this.summary,
    required this.color,
  });

  final String label;
  final String summary;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ToastWorkSurface(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      backgroundColor: PosColors.surface,
      child: Row(
        children: [
          ToastStatusBadge(label: label, color: color, compact: true),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              summary,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PosColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TemplateManagementTab extends ConsumerWidget {
  const _TemplateManagementTab({
    required this.picker,
    required this.storeId,
    required this.role,
  });

  final ImagePicker picker;
  final String? storeId;
  final String? role;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(qcTemplateProvider);
    final notifier = ref.read(qcTemplateProvider.notifier);
    final isSuperAdmin = role == 'super_admin';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          Row(
            children: [
              Text(
                context.l10n.qcTemplateBoardTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: storeId == null
                    ? null
                    : () => _showTemplateSheet(context, ref, picker, storeId!),
                icon: const Icon(Icons.add),
                label: Text(context.l10n.qcAdminAddCriterion),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              context.l10n.qcTemplateBoardSubtitle,
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (state.error != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                state.error!,
                style: AppFonts.system(
                  color: AppColors.statusCancelled,
                  fontSize: 13,
                ),
              ),
            ),
          if (state.error != null) const SizedBox(height: 8),
          if (state.isLoading && state.templates.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: CircularProgressIndicator(color: AppColors.amber500),
              ),
            )
          else if (state.templates.isEmpty)
            Center(
              child: Text(
                context.l10n.qcNoTemplatesRegistered,
                style: AppFonts.system(color: AppColors.textSecondary),
              ),
            )
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: state.templates.length,
              onReorder: (oldIndex, newIndex) async {
                if (newIndex > oldIndex) {
                  newIndex -= 1;
                }
                final copied = [...state.templates];
                final item = copied.removeAt(oldIndex);
                copied.insert(newIndex, item);

                for (var i = 0; i < copied.length; i++) {
                  final template = copied[i];
                  final isGlobal = template['is_global'] == true;
                  if (isGlobal && !isSuperAdmin) {
                    continue;
                  }
                  final id = copied[i]['id']?.toString() ?? '';
                  if (id.isEmpty) continue;
                  await notifier.updateTemplate(id, {'sort_order': i});
                }
              },
              itemBuilder: (context, index) {
                final template = state.templates[index];
                final id = template['id']?.toString() ?? '';
                final category =
                    template['category']?.toString() ??
                    context.l10n.qcCategoryOther;
                final text = template['criteria_text']?.toString() ?? '-';
                final photo = template['criteria_photo_url']?.toString();
                final isGlobal = template['is_global'] == true;
                final canEdit = !isGlobal || isSuperAdmin;

                return Container(
                  key: ValueKey(id),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: AppColors.surface1,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.surface2),
                  ),
                  child: ListTile(
                    leading: photo == null || photo.isEmpty
                        ? const Icon(
                            Icons.image_not_supported_outlined,
                            color: AppColors.textSecondary,
                          )
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              photo,
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                            ),
                          ),
                    title: Text(
                      text,
                      style: AppFonts.system(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: PosColors.accentMuted,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              category,
                              style: AppFonts.system(
                                color: PosColors.accent,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Text(
                            context.l10n.qcSortOrder(
                              template['sort_order'] ?? 0,
                            ),
                            style: AppFonts.system(
                              color: AppColors.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                          if (isGlobal)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.amber500.withValues(
                                  alpha: 0.16,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                context.l10n.qcSharedByHeadOffice,
                                style: AppFonts.system(
                                  color: AppColors.amber500,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    trailing: SizedBox(
                      width: 110,
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: !canEdit || storeId == null
                                ? null
                                : () => _showTemplateSheet(
                                    context,
                                    ref,
                                    picker,
                                    storeId!,
                                    initial: template,
                                  ),
                            icon: const Icon(Icons.edit_outlined),
                            color: AppColors.textSecondary,
                          ),
                          IconButton(
                            onPressed: !canEdit
                                ? null
                                : () async {
                                    await notifier.deleteTemplate(id);
                                    if (!context.mounted) return;
                                    showSuccessToast(
                                      context,
                                      context.l10n.deleted,
                                    );
                                  },
                            icon: const Icon(Icons.delete_outline),
                            color: AppColors.statusCancelled,
                          ),
                          if (canEdit)
                            const Icon(
                              Icons.drag_handle,
                              color: AppColors.textSecondary,
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Future<void> _showTemplateSheet(
    BuildContext context,
    WidgetRef ref,
    ImagePicker picker,
    String storeId, {
    Map<String, dynamic>? initial,
  }) async {
    final notifier = ref.read(qcTemplateProvider.notifier);
    final isEdit = initial != null;

    final categoryController = TextEditingController(
      text: initial?['category']?.toString() ?? '',
    );
    final criteriaController = TextEditingController(
      text: initial?['criteria_text']?.toString() ?? '',
    );
    final sortController = TextEditingController(
      text: '${initial?['sort_order'] ?? 0}',
    );

    XFile? selectedFile;
    Uint8List? selectedPreviewBytes;
    String? existingUrl = initial?['criteria_photo_url']?.toString();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface1,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isEdit
                        ? context.l10n.qcEditCriterionTitle
                        : context.l10n.qcAddCriterionTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: categoryController,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: context.l10n.qcAdminCategory,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: criteriaController,
                    minLines: 2,
                    maxLines: 4,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: context.l10n.qcAdminCriterionText,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: sortController,
                    keyboardType: TextInputType.number,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: context.l10n.qcAdminOrder,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          final picked = await picker.pickImage(
                            source: ImageSource.gallery,
                          );
                          if (picked == null) return;
                          final previewBytes = await picked.readAsBytes();
                          setModalState(() {
                            selectedFile = picked;
                            selectedPreviewBytes = previewBytes;
                            existingUrl = null;
                          });
                        },
                        icon: const Icon(Icons.photo_library_outlined),
                        label: Text(context.l10n.qcAdminUploadPhoto),
                      ),
                      const SizedBox(width: 8),
                      if (selectedFile != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            selectedPreviewBytes!,
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                          ),
                        )
                      else if (existingUrl != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            existingUrl!,
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () async {
                        final category = categoryController.text.trim();
                        final criteria = criteriaController.text.trim();
                        final sortOrder =
                            parseIntInput(sortController.text) ?? 0;
                        if (category.isEmpty || criteria.isEmpty) return;

                        String? photoUrl = existingUrl;
                        if (selectedFile != null) {
                          final templateId = isEdit
                              ? initial['id'].toString()
                              : notifier.generateTemplateId();
                          photoUrl = await notifier.uploadCriteriaPhoto(
                            storeId,
                            templateId,
                            selectedFile!,
                          );
                        }

                        if (isEdit) {
                          await notifier
                              .updateTemplate(initial['id'].toString(), {
                                'category': category,
                                'criteria_text': criteria,
                                'criteria_photo_url': photoUrl,
                                'sort_order': sortOrder,
                              });
                        } else {
                          await notifier.addTemplate(
                            storeId: storeId,
                            category: category,
                            criteriaText: criteria,
                            criteriaPhotoUrl: photoUrl,
                            sortOrder: sortOrder,
                          );
                        }

                        if (!context.mounted) return;
                        showSuccessToast(context, context.l10n.qcSaved);
                        Navigator.of(context).pop();
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.amber500,
                        foregroundColor: AppColors.surface0,
                      ),
                      child: Text(context.l10n.save),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    categoryController.dispose();
    criteriaController.dispose();
    sortController.dispose();
  }
}

class _QcSurfaceTab extends StatelessWidget {
  const _QcSurfaceTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.lg,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? PosColors.accentMuted : PosColors.surface,
          borderRadius: AppRadius.lg,
          border: Border.all(
            color: selected ? PosColors.accent : PosColors.border,
          ),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: selected ? PosColors.accent : PosColors.textSecondary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _WeeklyViewTab extends ConsumerStatefulWidget {
  const _WeeklyViewTab({
    required this.storeId,
    required this.weekStart,
    required this.onPrevWeek,
    required this.onNextWeek,
  });

  final String? storeId;
  final DateTime weekStart;
  final VoidCallback? onPrevWeek;
  final VoidCallback? onNextWeek;

  @override
  ConsumerState<_WeeklyViewTab> createState() => _WeeklyViewTabState();
}

class _WeeklyViewTabState extends ConsumerState<_WeeklyViewTab> {
  bool _rangeMode = false;
  DateTime _from = DateTime.now().subtract(const Duration(days: 6));
  DateTime _to = DateTime.now();
  String _resultFilter = 'all';
  String _categoryFilter = 'all';

  Future<void> _searchByRange() async {
    final storeId = widget.storeId;
    if (storeId == null) return;
    await ref
        .read(qcCheckProvider.notifier)
        .loadDateRange(storeId: storeId, from: _from, to: _to);
  }

  @override
  Widget build(BuildContext context) {
    final templates = ref.watch(qcTemplateProvider).templates;
    final checkState = ref.watch(qcCheckProvider);
    final weekDays = List.generate(
      7,
      (i) => widget.weekStart.add(Duration(days: i)),
    );

    final checksByKey = <String, Map<String, dynamic>>{};
    for (final check in checkState.checks) {
      final templateId = check['template_id']?.toString();
      final date = check['check_date']?.toString();
      if (templateId == null || date == null) continue;
      checksByKey['$templateId|$date'] = check;
    }

    final rows = _buildRows(templates);
    final categoryOptions = <String>{
      'all',
      ...templates.map(
        (e) => e['category']?.toString() ?? context.l10n.qcCategoryOther,
      ),
    }.toList();

    final filteredRangeChecks = checkState.dateRangeChecks.where((check) {
      final result = check['result']?.toString() ?? '';
      final template = check['qc_templates'] as Map<String, dynamic>?;
      final category =
          template?['category']?.toString() ?? context.l10n.qcCategoryOther;
      final matchesResult = switch (_resultFilter) {
        'pass' => result == 'pass',
        'fail' => result == 'fail',
        'na' => result == 'na',
        _ => true,
      };
      final matchesCategory =
          _categoryFilter == 'all' || category == _categoryFilter;
      return matchesResult && matchesCategory;
    }).toList();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              context.l10n.qcWeeklyScopeHint,
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment<bool>(
                    value: false,
                    label: Text(context.l10n.qcAdminWeeklyView),
                  ),
                  ButtonSegment<bool>(
                    value: true,
                    label: Text(context.l10n.qcAdminPeriodSearch),
                  ),
                ],
                selected: {_rangeMode},
                onSelectionChanged: (selection) {
                  setState(() => _rangeMode = selection.first);
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (checkState.error != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                checkState.error!,
                style: AppFonts.system(
                  color: AppColors.statusCancelled,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (_rangeMode)
            _buildRangeSearchSection(
              context: context,
              categoryOptions: categoryOptions,
              checks: filteredRangeChecks,
              isLoading: checkState.isLoading,
            )
          else
            Expanded(
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: widget.onPrevWeek,
                        icon: const Icon(Icons.chevron_left),
                        color: AppColors.textPrimary,
                      ),
                      Text(
                        '${DateFormat('yyyy-MM-dd').format(widget.weekStart)} ~ '
                        '${DateFormat('yyyy-MM-dd').format(widget.weekStart.add(const Duration(days: 6)))}',
                        style: AppFonts.system(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      IconButton(
                        onPressed: widget.onNextWeek,
                        icon: const Icon(Icons.chevron_right),
                        color: AppColors.textPrimary,
                      ),
                      const Spacer(),
                      _legendItem('✅', AppColors.statusAvailable),
                      const SizedBox(width: 8),
                      _legendItem('❌', AppColors.statusCancelled),
                      const SizedBox(width: 8),
                      _legendItem('—', AppColors.textSecondary),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (checkState.isLoading)
                    const Expanded(
                      child: Center(
                        child: CircularProgressIndicator(
                          color: AppColors.amber500,
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: Row(
                        key: const Key('qc_weekly_board_table'),
                        children: [
                          SizedBox(
                            width: 160,
                            child: Column(
                              children: [
                                Container(
                                  height: 56,
                                  alignment: Alignment.centerLeft,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  color: AppColors.surface2,
                                  child: Text(
                                    context.l10n.qcCriterionShort,
                                    style: AppFonts.system(
                                      color: AppColors.textSecondary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: ListView.builder(
                                    primary: false,
                                    physics: _qcWeeklyBoardScrollPhysics,
                                    padding: _qcWeeklyBoardScrollPadding,
                                    itemCount: rows.length,
                                    itemBuilder: (context, index) {
                                      final row = rows[index];
                                      if (row.isCategory) {
                                        return Container(
                                          height: 42,
                                          alignment: Alignment.centerLeft,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                          color: AppColors.amber500.withValues(
                                            alpha: 0.2,
                                          ),
                                          child: Text(
                                            '[${row.category}]',
                                            style: AppFonts.system(
                                              color: AppColors.amber500,
                                              fontWeight: FontWeight.w700,
                                              fontSize: 12,
                                            ),
                                          ),
                                        );
                                      }

                                      return Container(
                                        height: 48,
                                        alignment: Alignment.centerLeft,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                        ),
                                        decoration: const BoxDecoration(
                                          border: Border(
                                            bottom: BorderSide(
                                              color: AppColors.surface2,
                                            ),
                                          ),
                                        ),
                                        child: Text(
                                          row.criteria,
                                          style: AppFonts.system(
                                            color: AppColors.textPrimary,
                                            fontSize: 12,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              physics: _qcWeeklyBoardScrollPhysics,
                              child: SizedBox(
                                width: 64.0 * 7,
                                child: Column(
                                  children: [
                                    Row(
                                      children: weekDays
                                          .map(
                                            (day) => Container(
                                              width: 64,
                                              height: 56,
                                              alignment: Alignment.center,
                                              color: AppColors.surface2,
                                              child: Column(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Text(
                                                    DateFormat(
                                                      'E',
                                                      'ko',
                                                    ).format(day),
                                                    style:
                                                        AppFonts.system(
                                                          color: AppColors
                                                              .textSecondary,
                                                          fontSize: 11,
                                                        ),
                                                  ),
                                                  Text(
                                                    DateFormat(
                                                      'M/d',
                                                    ).format(day),
                                                    style:
                                                        AppFonts.system(
                                                          color: AppColors
                                                              .textPrimary,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                          fontSize: 12,
                                                        ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          )
                                          .toList(),
                                    ),
                                    Expanded(
                                      child: ListView.builder(
                                        primary: false,
                                        physics: _qcWeeklyBoardScrollPhysics,
                                        padding: _qcWeeklyBoardScrollPadding,
                                        itemCount: rows.length,
                                        itemBuilder: (context, index) {
                                          final row = rows[index];
                                          if (row.isCategory) {
                                            return Container(
                                              height: 42,
                                              width: 64.0 * 7,
                                              color: AppColors.amber500
                                                  .withValues(alpha: 0.2),
                                            );
                                          }

                                          return Row(
                                            children: weekDays.map((day) {
                                              final dayStr = DateFormat(
                                                'yyyy-MM-dd',
                                              ).format(day);
                                              final check =
                                                  checksByKey['${row.templateId}|$dayStr'];
                                              final result = check?['result']
                                                  ?.toString();

                                              final (
                                                bg,
                                                label,
                                              ) = switch (result) {
                                                'pass' => (
                                                  AppColors.statusAvailable
                                                      .withValues(alpha: 0.18),
                                                  '✅',
                                                ),
                                                'fail' => (
                                                  AppColors.statusCancelled
                                                      .withValues(alpha: 0.20),
                                                  '❌',
                                                ),
                                                'na' => (
                                                  AppColors.surface2,
                                                  '—',
                                                ),
                                                _ => (Colors.transparent, ''),
                                              };

                                              return GestureDetector(
                                                onTap: () => _showCellDialog(
                                                  context,
                                                  day,
                                                  row,
                                                  check,
                                                ),
                                                child: Container(
                                                  width: 64,
                                                  height: 48,
                                                  alignment: Alignment.center,
                                                  decoration: BoxDecoration(
                                                    color: bg,
                                                    border: const Border(
                                                      bottom: BorderSide(
                                                        color:
                                                            AppColors.surface2,
                                                      ),
                                                      left: BorderSide(
                                                        color:
                                                            AppColors.surface2,
                                                      ),
                                                    ),
                                                  ),
                                                  child: Text(
                                                    label,
                                                    style: AppFonts.system(
                                                      color: result == 'fail'
                                                          ? AppColors
                                                                .statusCancelled
                                                          : AppColors
                                                                .textPrimary,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                ),
                                              );
                                            }).toList(),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRangeSearchSection({
    required BuildContext context,
    required List<String> categoryOptions,
    required List<Map<String, dynamic>> checks,
    required bool isLoading,
  }) {
    return Expanded(
      child: Column(
        children: [
          Row(
            children: [
              _dateButton(
                context: context,
                label: context.l10n.from,
                value: _from,
                onPicked: (picked) => setState(() => _from = picked),
              ),
              const SizedBox(width: 8),
              _dateButton(
                context: context,
                label: context.l10n.to,
                value: _to,
                onPicked: (picked) => setState(() => _to = picked),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _searchByRange,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                child: Text(context.l10n.search),
              ),
              const Spacer(),
              SizedBox(
                width: 140,
                child: DropdownButtonFormField<String>(
                  initialValue: _resultFilter,
                  dropdownColor: AppColors.surface1,
                  style: AppFonts.system(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: context.l10n.qcAdminResult,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'all',
                      child: Text(context.l10n.all),
                    ),
                    DropdownMenuItem(
                      value: 'pass',
                      child: Text(context.l10n.qcAdminPass),
                    ),
                    DropdownMenuItem(
                      value: 'fail',
                      child: Text(context.l10n.qcAdminFail),
                    ),
                    DropdownMenuItem(
                      value: 'na',
                      child: Text(context.l10n.qcAdminNa),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _resultFilter = value);
                  },
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<String>(
                  initialValue: _categoryFilter,
                  dropdownColor: AppColors.surface1,
                  style: AppFonts.system(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: context.l10n.qcAdminCategory,
                  ),
                  items: categoryOptions
                      .map(
                        (category) => DropdownMenuItem(
                          value: category,
                          child: Text(
                            category == 'all' ? context.l10n.all : category,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _categoryFilter = value);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (isLoading)
            const Expanded(
              child: Center(
                child: CircularProgressIndicator(color: AppColors.amber500),
              ),
            )
          else if (checks.isEmpty)
            Expanded(
              child: Center(
                child: Text(
                  context.l10n.qcNoSearchResults,
                  style: AppFonts.system(color: AppColors.textSecondary),
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: checks.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final row = checks[index];
                  final template = row['qc_templates'] as Map<String, dynamic>?;
                  final result = row['result']?.toString() ?? '';
                  final resultLabel = switch (result) {
                    'pass' => context.l10n.qcResultPass,
                    'fail' => context.l10n.qcResultFail,
                    'na' => context.l10n.qcResultNa,
                    _ => '-',
                  };
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.surface1,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.surface2),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 90,
                          child: Text(
                            row['check_date']?.toString() ?? '-',
                            style: AppFonts.system(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${template?['category'] ?? context.l10n.qcCategoryOther} | ${template?['criteria_text'] ?? '-'}',
                            style: AppFonts.system(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          resultLabel,
                          style: AppFonts.system(
                            color: result == 'fail'
                                ? AppColors.statusCancelled
                                : AppColors.textPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _thumbnailCell(
                          context,
                          row['evidence_photo_url']?.toString(),
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

  Widget _dateButton({
    required BuildContext context,
    required String label,
    required DateTime value,
    required ValueChanged<DateTime> onPicked,
  }) {
    return OutlinedButton.icon(
      onPressed: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value,
          firstDate: DateTime(2020),
          lastDate: DateTime.now(),
        );
        if (picked != null) {
          onPicked(DateTime(picked.year, picked.month, picked.day));
        }
      },
      icon: const Icon(Icons.event),
      label: Text('$label ${DateFormat('yyyy-MM-dd').format(value)}'),
    );
  }

  Widget _thumbnailCell(BuildContext context, String? evidencePhotoUrl) {
    if (evidencePhotoUrl == null || evidencePhotoUrl.isEmpty) {
      return const Icon(
        Icons.image_not_supported_outlined,
        color: AppColors.textSecondary,
      );
    }
    return GestureDetector(
      onTap: () => _showImageDialog(context, evidencePhotoUrl),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.network(
          evidencePhotoUrl,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  Widget _legendItem(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: AppFonts.system(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  List<_QcRow> _buildRows(List<Map<String, dynamic>> templates) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final t in templates) {
      final category =
          t['category']?.toString() ?? context.l10n.qcCategoryOther;
      grouped.putIfAbsent(category, () => []).add(t);
    }

    final rows = <_QcRow>[];
    for (final category in grouped.keys) {
      rows.add(_QcRow.category(category));
      for (final t in grouped[category]!) {
        rows.add(
          _QcRow.item(
            templateId: t['id']?.toString() ?? '',
            category: category,
            criteria: t['criteria_text']?.toString() ?? '-',
            template: t,
          ),
        );
      }
    }
    return rows;
  }

  Future<void> _showCellDialog(
    BuildContext context,
    DateTime day,
    _QcRow row,
    Map<String, dynamic>? check,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final result = check?['result']?.toString();
        final note = check?['note']?.toString();
        final evidencePhotoUrl = check?['evidence_photo_url']?.toString();
        final checkId = check?['id']?.toString();

        return Consumer(
          builder: (ctx, ref, _) {
            final followupNotifier = ref.read(qcFollowupProvider.notifier);
            final existingFollowup = checkId != null
                ? followupNotifier.followupForCheck(checkId)
                : null;

            return AlertDialog(
              backgroundColor: AppColors.surface1,
              title: Text(
                DateFormat.yMMMMEEEEd(
                  Localizations.localeOf(context).toLanguageTag(),
                ).format(day),
                style: AppFonts.system(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.qcCriterionLabel(row.criteria),
                      style: AppFonts.system(
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (check == null)
                      Text(
                        context.l10n.qcNotInspectedOnDate,
                        style: AppFonts.system(
                          color: AppColors.textSecondary,
                        ),
                      )
                    else ...[
                      Text(
                        '${context.l10n.qcAdminResult}: ${switch (result) {
                          'pass' => context.l10n.qcResultPass,
                          'fail' => context.l10n.qcResultFail,
                          'na' => context.l10n.qcResultNa,
                          _ => '-',
                        }}',
                        style: AppFonts.system(
                          color: result == 'fail'
                              ? AppColors.statusCancelled
                              : AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (evidencePhotoUrl != null &&
                          evidencePhotoUrl.isNotEmpty)
                        GestureDetector(
                          onTap: () =>
                              _showImageDialog(context, evidencePhotoUrl),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              evidencePhotoUrl,
                              height: 160,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      if (note != null && note.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          context.l10n.inventoryMemoWithValue(note),
                          style: AppFonts.system(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                      if (result == 'fail' &&
                          checkId != null &&
                          widget.storeId != null) ...[
                        const Divider(color: AppColors.surface2, height: 20),
                        if (existingFollowup != null)
                          _FollowupStatusBadge(
                            status:
                                existingFollowup['status']?.toString() ??
                                'open',
                          )
                        else
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final success = await followupNotifier
                                    .createFollowup(
                                      storeId: widget.storeId!,
                                      sourceCheckId: checkId,
                                    );
                                if (ctx.mounted) {
                                  Navigator.of(ctx).pop();
                                  if (success) {
                                    showSuccessToast(
                                      context,
                                      context.l10n.qcFollowUpCreated,
                                    );
                                  } else {
                                    final error = ref
                                        .read(qcFollowupProvider)
                                        .error;
                                    if (error != null) {
                                      showErrorToast(context, error);
                                    }
                                  }
                                }
                              },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.statusCancelled,
                                side: const BorderSide(
                                  color: AppColors.statusCancelled,
                                ),
                              ),
                              icon: const Icon(
                                Icons.assignment_late_outlined,
                                size: 16,
                              ),
                              label: Text(
                                context.l10n.qcCreateFollowUp,
                                style: AppFonts.system(fontSize: 12),
                              ),
                            ),
                          ),
                      ],
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(context.l10n.close),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showImageDialog(BuildContext context, String url) async {
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
                  child: Image.network(url, fit: BoxFit.contain),
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

class _QcRow {
  const _QcRow._({
    required this.isCategory,
    required this.category,
    required this.templateId,
    required this.criteria,
    required this.template,
  });

  factory _QcRow.category(String category) => _QcRow._(
    isCategory: true,
    category: category,
    templateId: '',
    criteria: '',
    template: const {},
  );

  factory _QcRow.item({
    required String templateId,
    required String category,
    required String criteria,
    required Map<String, dynamic> template,
  }) {
    return _QcRow._(
      isCategory: false,
      category: category,
      templateId: templateId,
      criteria: criteria,
      template: template,
    );
  }

  final bool isCategory;
  final String category;
  final String templateId;
  final String criteria;
  final Map<String, dynamic> template;
}

// ─── Follow-up Status Badge ──────────────────────

class _FollowupStatusBadge extends StatelessWidget {
  const _FollowupStatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      'open' => (context.l10n.qcUnresolved, AppColors.statusCancelled),
      'in_progress' => (
        context.l10n.reportsInProgress,
        AppColors.statusOccupied,
      ),
      'resolved' => (context.l10n.resolved, AppColors.statusAvailable),
      _ => (status, AppColors.textSecondary),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.assignment_turned_in_outlined, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            '${context.l10n.followUp}: $label',
            style: AppFonts.system(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Follow-up + Analytics Tab ───────────────────

class _FollowupTab extends ConsumerStatefulWidget {
  const _FollowupTab({required this.storeId});

  final String? storeId;

  @override
  ConsumerState<_FollowupTab> createState() => _FollowupTabState();
}

class _FollowupTabState extends ConsumerState<_FollowupTab> {
  String _statusFilter = 'active';

  DateTime _analyticsFrom = DateTime.now().subtract(const Duration(days: 6));
  DateTime _analyticsTo = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final followupState = ref.watch(qcFollowupProvider);
    final storeId = widget.storeId;

    final analyticsParams = storeId == null
        ? null
        : QcAnalyticsParams(
            storeId: storeId,
            from: _analyticsFrom,
            to: _analyticsTo,
          );
    final analyticsAsync = analyticsParams != null
        ? ref.watch(qcAnalyticsProvider(analyticsParams))
        : null;

    final filtered = _statusFilter == 'active'
        ? followupState.followups
              .where(
                (f) => f['status'] == 'open' || f['status'] == 'in_progress',
              )
              .toList()
        : _statusFilter == 'all'
        ? followupState.followups
        : followupState.followups
              .where((f) => f['status'] == _statusFilter)
              .toList();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          _buildAnalyticsSecondaryDetail(context, analyticsAsync),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                context.l10n.qcFollowupManagementTitle,
                style: AppFonts.system(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                '${filtered.length}',
                style: AppFonts.system(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _followupFilterChip(context.l10n.qcUnresolved, 'active'),
              _followupFilterChip(context.l10n.all, 'all'),
              _followupFilterChip(context.l10n.qcUnresolved, 'open'),
              _followupFilterChip(
                context.l10n.reportsInProgress,
                'in_progress',
              ),
              _followupFilterChip(context.l10n.resolved, 'resolved'),
            ],
          ),
          const SizedBox(height: 12),
          if (followupState.error != null) ...[
            Text(
              followupState.error!,
              style: AppFonts.system(
                color: AppColors.statusCancelled,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (followupState.isLoading && followupState.followups.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(color: AppColors.amber500),
              ),
            )
          else if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(
                  context.l10n.qcNoFollowUps,
                  style: AppFonts.system(color: AppColors.textSecondary),
                ),
              ),
            )
          else
            ...filtered.map((f) => _buildFollowupCard(context, f)),
        ],
      ),
    );
  }

  Widget _buildAnalyticsSecondaryDetail(
    BuildContext context,
    AsyncValue<Map<String, dynamic>>? analyticsAsync,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: PosColors.mutedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PosColors.border),
      ),
      child: ExpansionTile(
        key: const Key('qc_analytics_secondary_detail'),
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        iconColor: PosColors.textSecondary,
        collapsedIconColor: PosColors.textSecondary,
        title: Text(
          context.l10n.qcAnalyticsTitle,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: PosColors.textPrimary,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          context.l10n.qcSurfaceWeeklySummary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
        ),
        children: [
          Row(
            children: [
              _analyticsDateButton(
                context: context,
                label: context.l10n.from,
                value: _analyticsFrom,
                onPicked: (picked) => setState(() => _analyticsFrom = picked),
              ),
              const SizedBox(width: 8),
              _analyticsDateButton(
                context: context,
                label: context.l10n.to,
                value: _analyticsTo,
                onPicked: (picked) => setState(() => _analyticsTo = picked),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (analyticsAsync != null)
            analyticsAsync.when(
              data: (data) => _buildAnalyticsCard(data),
              loading: () => const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(color: AppColors.amber500),
                ),
              ),
              error: (e, _) => Text(
                context.l10n.qcAnalyticsLoadFailed('$e'),
                style: AppFonts.system(
                  color: AppColors.statusCancelled,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _analyticsDateButton({
    required BuildContext context,
    required String label,
    required DateTime value,
    required ValueChanged<DateTime> onPicked,
  }) {
    return OutlinedButton.icon(
      onPressed: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value,
          firstDate: DateTime(2020),
          lastDate: DateTime.now(),
        );
        if (picked != null) {
          onPicked(DateTime(picked.year, picked.month, picked.day));
        }
      },
      icon: const Icon(Icons.event, size: 16),
      label: Text(
        '$label ${DateFormat('yyyy-MM-dd').format(value)}',
        style: AppFonts.system(fontSize: 12),
      ),
    );
  }

  Widget _buildAnalyticsCard(Map<String, dynamic> data) {
    final totalChecks = (data['total_checks'] as num?)?.toInt() ?? 0;
    final passCount = (data['pass_count'] as num?)?.toInt() ?? 0;
    final failCount = (data['fail_count'] as num?)?.toInt() ?? 0;
    final naCount = (data['na_count'] as num?)?.toInt() ?? 0;
    final passRate = (data['pass_rate'] as num?)?.toDouble() ?? 0;
    final coverage = (data['coverage'] as num?)?.toDouble() ?? 0;
    final openFollowups = (data['open_followups'] as num?)?.toInt() ?? 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _analyticMetric(
                  context.l10n.qcAnalyticsTotalInspections,
                  '$totalChecks',
                  AppColors.textPrimary,
                ),
              ),
              Expanded(
                child: _analyticMetric(
                  context.l10n.qcAnalyticsPassRate,
                  '$passRate%',
                  passRate >= 80
                      ? AppColors.statusAvailable
                      : AppColors.statusCancelled,
                ),
              ),
              Expanded(
                child: _analyticMetric(
                  context.l10n.qcAnalyticsCoverage,
                  '$coverage%',
                  AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _analyticMetric(
                  context.l10n.qcAdminPass,
                  '$passCount',
                  AppColors.statusAvailable,
                ),
              ),
              Expanded(
                child: _analyticMetric(
                  context.l10n.qcAdminFail,
                  '$failCount',
                  AppColors.statusCancelled,
                ),
              ),
              Expanded(
                child: _analyticMetric(
                  context.l10n.qcAdminNa,
                  '$naCount',
                  AppColors.textSecondary,
                ),
              ),
              Expanded(
                child: _analyticMetric(
                  context.l10n.qcAnalyticsUnresolvedActions,
                  '$openFollowups',
                  openFollowups > 0
                      ? AppColors.statusCancelled
                      : AppColors.statusAvailable,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _analyticMetric(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppFonts.system(
            color: AppColors.textSecondary,
            fontSize: 11,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: AppFonts.system(
            color: color,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _followupFilterChip(String label, String value) {
    final isSelected = _statusFilter == value;
    return InkWell(
      onTap: () => setState(() => _statusFilter = value),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.amber500 : AppColors.surface1,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? AppColors.amber500 : AppColors.surface2,
          ),
        ),
        child: Text(
          label,
          style: AppFonts.system(
            color: isSelected ? AppColors.surface0 : AppColors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildFollowupCard(
    BuildContext context,
    Map<String, dynamic> followup,
  ) {
    final id = followup['followup_id']?.toString() ?? '';
    final status = followup['status']?.toString() ?? 'open';
    final assignedTo = followup['assigned_to_name']?.toString();
    final resolutionNotes = followup['resolution_notes']?.toString();
    final checkDate = followup['check_date']?.toString() ?? '-';
    final category =
        followup['template_category']?.toString() ??
        context.l10n.qcCategoryOther;
    final criteria = followup['template_criteria']?.toString() ?? '-';
    final createdAt = followup['created_at']?.toString();
    final resolvedAt = followup['resolved_at']?.toString();

    final (statusLabel, statusColor) = switch (status) {
      'open' => (context.l10n.qcUnresolved, AppColors.statusCancelled),
      'in_progress' => (
        context.l10n.reportsInProgress,
        AppColors.statusOccupied,
      ),
      'resolved' => (context.l10n.resolved, AppColors.statusAvailable),
      _ => (status, AppColors.textSecondary),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _FollowupStatusBadge(status: status),
              const Spacer(),
              Text(
                context.l10n.qcInspectionDate(checkDate),
                style: AppFonts.system(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$category | $criteria',
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          if (assignedTo != null && assignedTo.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              context.l10n.qcAssignee(assignedTo),
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
          if (resolutionNotes != null && resolutionNotes.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              context.l10n.qcResolutionNotes(resolutionNotes),
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
          if (createdAt != null) ...[
            const SizedBox(height: 4),
            Text(
              resolvedAt == null
                  ? context.l10n.qcCreatedAt(_formatTimestamp(createdAt))
                  : context.l10n.qcCreatedResolvedAt(
                      _formatTimestamp(createdAt),
                      _formatTimestamp(resolvedAt),
                    ),
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
          if (status != 'resolved') ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if (status == 'open')
                  OutlinedButton(
                    onPressed: () =>
                        _updateFollowupStatus(context, id, 'in_progress'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.statusOccupied,
                      side: const BorderSide(color: AppColors.statusOccupied),
                    ),
                    child: Text(
                      context.l10n.qcStartProgress,
                      style: AppFonts.system(fontSize: 12),
                    ),
                  ),
                if (status == 'open') const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => _showResolveDialog(context, id),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.statusAvailable,
                    side: const BorderSide(color: AppColors.statusAvailable),
                  ),
                  child: Text(
                    context.l10n.resolved,
                    style: AppFonts.system(fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _formatTimestamp(String raw) {
    final dt = DateTime.tryParse(raw);
    if (dt == null) return raw;
    return DateFormat('M/d HH:mm').format(dt.toLocal());
  }

  Future<void> _updateFollowupStatus(
    BuildContext context,
    String followupId,
    String status,
  ) async {
    final storeId = widget.storeId;
    if (storeId == null) return;

    final success = await ref
        .read(qcFollowupProvider.notifier)
        .updateStatus(followupId: followupId, storeId: storeId, status: status);

    if (!context.mounted) return;
    if (success) {
      showSuccessToast(context, context.l10n.qcStatusChanged);
    } else {
      final error = ref.read(qcFollowupProvider).error;
      if (error != null) showErrorToast(context, error);
    }
  }

  Future<void> _showResolveDialog(
    BuildContext context,
    String followupId,
  ) async {
    final notesController = TextEditingController();

    final confirmed = await ToastConfirmDialog.withContent(
      context: context,
      title: context.l10n.qcResolveFollowUp,
      confirmLabel: context.l10n.resolved,
      confirmTone: PosActionTone.affirm,
      content: TextField(
        controller: notesController,
        style: const TextStyle(color: AppColors.textPrimary),
        maxLines: 3,
        decoration: InputDecoration(
          labelText: context.l10n.qcAdminResolutionNotesOptional,
          labelStyle: const TextStyle(color: AppColors.textSecondary),
          enabledBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: AppColors.surface2),
          ),
          focusedBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: AppColors.amber500),
          ),
        ),
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final storeId = widget.storeId;
    if (storeId == null) return;

    final notes = notesController.text.trim();
    final success = await ref
        .read(qcFollowupProvider.notifier)
        .updateStatus(
          followupId: followupId,
          storeId: storeId,
          status: 'resolved',
          resolutionNotes: notes.isEmpty ? null : notes,
        );

    notesController.dispose();

    if (!context.mounted) return;
    if (success) {
      showSuccessToast(context, context.l10n.qcFollowUpResolved);
    } else {
      final error = ref.read(qcFollowupProvider).error;
      if (error != null) showErrorToast(context, error);
    }
  }
}
