import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../../main.dart';
import '../../../widgets/error_toast.dart';
import '../../auth/auth_provider.dart';
import '../../qc/qc_provider.dart';

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

  static DateTime _startOfWeek(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    return day.subtract(Duration(days: day.weekday - 1));
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

    if (storeId != null && _initializedRestaurantId != storeId) {
      _initializedRestaurantId = storeId;
      Future.microtask(() => _initData(storeId));
    }

    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: Column(
        children: [
          Container(
            color: AppColors.surface0,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: TabBar(
              controller: _tabController,
              indicatorColor: AppColors.amber500,
              labelColor: AppColors.amber500,
              unselectedLabelColor: AppColors.textSecondary,
              labelStyle: GoogleFonts.notoSansKr(fontWeight: FontWeight.w700),
              tabs: const [
                Tab(text: 'Template Management'),
                Tab(text: 'Weekly Inspection Status'),
                Tab(text: 'Follow-ups'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _TemplateManagementTab(
                  picker: _picker,
                  storeId: storeId,
                  role: ref.watch(authProvider).role,
                ),
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
                _FollowupTab(storeId: storeId),
              ],
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
      child: Column(
        children: [
          Row(
            children: [
              Text(
                'QC Template',
                style: GoogleFonts.bebasNeue(
                  color: AppColors.textPrimary,
                  fontSize: 30,
                ),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: storeId == null
                    ? null
                    : () => _showTemplateSheet(
                        context,
                        ref,
                        picker,
                        storeId!,
                      ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                icon: const Icon(Icons.add),
                label: const Text('Add Criterion'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'QC v1 scope includes only template management and criteria visibility needed for inspection execution. Save and deactivation are recorded in the audit log.',
              style: GoogleFonts.notoSansKr(
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
                style: GoogleFonts.notoSansKr(
                  color: AppColors.statusCancelled,
                  fontSize: 13,
                ),
              ),
            ),
          if (state.error != null) const SizedBox(height: 8),
          Expanded(
            child: state.isLoading && state.templates.isEmpty
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.amber500),
                  )
                : state.templates.isEmpty
                ? Center(
                    child: Text(
                      'No templates.',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  )
                : ReorderableListView.builder(
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
                      final category = template['category']?.toString() ?? 'Other';
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
                            style: GoogleFonts.notoSansKr(
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
                                    color: AppColors.amber500.withValues(
                                      alpha: 0.16,
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    category,
                                    style: GoogleFonts.notoSansKr(
                                      color: AppColors.amber500,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Text(
                                  'Order ${template['sort_order'] ?? 0}',
                                  style: GoogleFonts.notoSansKr(
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
                                      '📌 HQ Shared',
                                      style: GoogleFonts.notoSansKr(
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
                                          showSuccessToast(context, 'Deleted');
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

    File? selectedFile;
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
                    isEdit ? 'Edit Criterion' : 'Add Criterion',
                    style: GoogleFonts.bebasNeue(
                      color: AppColors.amber500,
                      fontSize: 30,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: categoryController,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: const InputDecoration(labelText: 'Category'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: criteriaController,
                    minLines: 2,
                    maxLines: 4,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: const InputDecoration(labelText: 'Criterion (text)'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: sortController,
                    keyboardType: TextInputType.number,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: const InputDecoration(labelText: 'Order'),
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
                          setModalState(() {
                            selectedFile = File(picked.path);
                            existingUrl = null;
                          });
                        },
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('Upload Photo'),
                      ),
                      const SizedBox(width: 8),
                      if (selectedFile != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            selectedFile!,
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
                            int.tryParse(sortController.text.trim()) ?? 0;
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
                        showSuccessToast(context, 'Saved');
                        Navigator.of(context).pop();
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.amber500,
                        foregroundColor: AppColors.surface0,
                      ),
                      child: const Text('Save'),
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
      ...templates.map((e) => e['category']?.toString() ?? 'Other'),
    }.toList();

    final filteredRangeChecks = checkState.dateRangeChecks.where((check) {
      final result = check['result']?.toString() ?? '';
      final template = check['qc_templates'] as Map<String, dynamic>?;
      final category = template?['category']?.toString() ?? 'Other';
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
              'QC v1 scope includes only weekly inspection status and per-date inspection history. Coverage analysis and follow-ups are in a separate product scope.',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment<bool>(value: false, label: Text('Weekly View')),
                  ButtonSegment<bool>(value: true, label: Text('Period Search')),
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
                style: GoogleFonts.notoSansKr(
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
                        style: GoogleFonts.notoSansKr(
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
                                    'Criterion',
                                    style: GoogleFonts.notoSansKr(
                                      color: AppColors.textSecondary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: ListView.builder(
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
                                            style: GoogleFonts.notoSansKr(
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
                                          style: GoogleFonts.notoSansKr(
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
                                                        GoogleFonts.notoSansKr(
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
                                                        GoogleFonts.notoSansKr(
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
                                                    style: GoogleFonts.notoSansKr(
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
                label: 'From',
                value: _from,
                onPicked: (picked) => setState(() => _from = picked),
              ),
              const SizedBox(width: 8),
              _dateButton(
                context: context,
                label: 'To',
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
                child: const Text('Search'),
              ),
              const Spacer(),
              SizedBox(
                width: 140,
                child: DropdownButtonFormField<String>(
                  initialValue: _resultFilter,
                  dropdownColor: AppColors.surface1,
                  style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Result',
                  ),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('All')),
                    DropdownMenuItem(value: 'pass', child: Text('Pass')),
                    DropdownMenuItem(value: 'fail', child: Text('Fail')),
                    DropdownMenuItem(value: 'na', child: Text('N/A')),
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
                  style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Category',
                  ),
                  items: categoryOptions
                      .map(
                        (category) => DropdownMenuItem(
                          value: category,
                          child: Text(category == 'all' ? 'All' : category),
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
                  'No search results.',
                  style: GoogleFonts.notoSansKr(color: AppColors.textSecondary),
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
                    'pass' => '✅ Pass',
                    'fail' => '❌ Fail',
                    'na' => '— N/A',
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
                            style: GoogleFonts.notoSansKr(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${template?['category'] ?? 'Other'} | ${template?['criteria_text'] ?? '-'}',
                            style: GoogleFonts.notoSansKr(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          resultLabel,
                          style: GoogleFonts.notoSansKr(
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
        style: GoogleFonts.notoSansKr(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  List<_QcRow> _buildRows(List<Map<String, dynamic>> templates) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final t in templates) {
      final category = t['category']?.toString() ?? 'Other';
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
                DateFormat('yyyy-MM-dd (E)', 'ko').format(day),
                style: GoogleFonts.notoSansKr(
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
                      'Criterion: ${row.criteria}',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (check == null)
                      Text(
                        'Not inspected on this date',
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textSecondary,
                        ),
                      )
                    else ...[
                      Text(
                        'Result: ${switch (result) {
                          'pass' => '✅ Pass',
                          'fail' => '❌ Fail',
                          'na' => '— N/A',
                          _ => '-',
                        }}',
                        style: GoogleFonts.notoSansKr(
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
                          '[memo] $note',
                          style: GoogleFonts.notoSansKr(
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
                            status: existingFollowup['status']?.toString() ??
                                'open',
                          )
                        else
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final success =
                                    await followupNotifier.createFollowup(
                                  storeId: widget.storeId!,
                                  sourceCheckId: checkId,
                                );
                                if (ctx.mounted) {
                                  Navigator.of(ctx).pop();
                                  if (success) {
                                    showSuccessToast(
                                      context,
                                      'Follow-up created',
                                    );
                                  } else {
                                    final error =
                                        ref.read(qcFollowupProvider).error;
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
                                'Follow-ups Created',
                                style: GoogleFonts.notoSansKr(fontSize: 12),
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
                  child: const Text('Close'),
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
      'open' => ('Unresolved', AppColors.statusCancelled),
      'in_progress' => ('In Progress', AppColors.statusOccupied),
      'resolved' => ('Resolved', AppColors.statusAvailable),
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
          Icon(Icons.assignment_turned_in_outlined,
              size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            'Follow-ups: $label',
            style: GoogleFonts.notoSansKr(
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

  DateTime _analyticsFrom =
      DateTime.now().subtract(const Duration(days: 6));
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
            .where((f) =>
                f['status'] == 'open' || f['status'] == 'in_progress')
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
          // ─── Analytics Section ───
          Text(
            'QC Analytics',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _analyticsDateButton(
                context: context,
                label: 'From',
                value: _analyticsFrom,
                onPicked: (picked) =>
                    setState(() => _analyticsFrom = picked),
              ),
              const SizedBox(width: 8),
              _analyticsDateButton(
                context: context,
                label: 'To',
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
                  child:
                      CircularProgressIndicator(color: AppColors.amber500),
                ),
              ),
              error: (e, _) => Text(
                'Failed to load analytics data: $e',
                style: GoogleFonts.notoSansKr(
                  color: AppColors.statusCancelled,
                  fontSize: 12,
                ),
              ),
            ),
          const SizedBox(height: 20),
          // ─── Followup Section ───
          Row(
            children: [
              Text(
                'Follow-up Management',
                style: GoogleFonts.notoSansKr(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                '${filtered.length}',
                style: GoogleFonts.notoSansKr(
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
              _followupFilterChip('Unresolved', 'active'),
              _followupFilterChip('All', 'all'),
              _followupFilterChip('Unresolved', 'open'),
              _followupFilterChip('In Progress', 'in_progress'),
              _followupFilterChip('Resolved', 'resolved'),
            ],
          ),
          const SizedBox(height: 12),
          if (followupState.error != null) ...[
            Text(
              followupState.error!,
              style: GoogleFonts.notoSansKr(
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
                child:
                    CircularProgressIndicator(color: AppColors.amber500),
              ),
            )
          else if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(
                  'No follow-ups.',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            )
          else
            ...filtered.map((f) => _buildFollowupCard(context, f)),
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
        style: GoogleFonts.notoSansKr(fontSize: 12),
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
    final openFollowups =
        (data['open_followups'] as num?)?.toInt() ?? 0;

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
                  'Total Inspections',
                  '$totalChecks',
                  AppColors.textPrimary,
                ),
              ),
              Expanded(
                child: _analyticMetric(
                  'Pass Rate',
                  '$passRate%',
                  passRate >= 80
                      ? AppColors.statusAvailable
                      : AppColors.statusCancelled,
                ),
              ),
              Expanded(
                child: _analyticMetric(
                  'Coverage',
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
                  'Pass',
                  '$passCount',
                  AppColors.statusAvailable,
                ),
              ),
              Expanded(
                child: _analyticMetric(
                  'Fail',
                  '$failCount',
                  AppColors.statusCancelled,
                ),
              ),
              Expanded(
                child: _analyticMetric(
                  'N/A',
                  '$naCount',
                  AppColors.textSecondary,
                ),
              ),
              Expanded(
                child: _analyticMetric(
                  'Unresolved Actions',
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
          style: GoogleFonts.notoSansKr(
            color: AppColors.textSecondary,
            fontSize: 11,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: GoogleFonts.notoSansKr(
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
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color:
              isSelected ? AppColors.amber500 : AppColors.surface1,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? AppColors.amber500
                : AppColors.surface2,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.notoSansKr(
            color: isSelected
                ? AppColors.surface0
                : AppColors.textPrimary,
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
    final category = followup['template_category']?.toString() ?? 'Other';
    final criteria = followup['template_criteria']?.toString() ?? '-';
    final createdAt = followup['created_at']?.toString();
    final resolvedAt = followup['resolved_at']?.toString();

    final (statusLabel, statusColor) = switch (status) {
      'open' => ('Unresolved', AppColors.statusCancelled),
      'in_progress' => ('In Progress', AppColors.statusOccupied),
      'resolved' => ('Resolved', AppColors.statusAvailable),
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
                'Inspection date $checkDate',
                style: GoogleFonts.notoSansKr(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$category | $criteria',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          if (assignedTo != null && assignedTo.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Assignee: $assignedTo',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
          if (resolutionNotes != null && resolutionNotes.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Resolution notes: $resolutionNotes',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
          if (createdAt != null) ...[
            const SizedBox(height: 4),
            Text(
              'Created ${_formatTimestamp(createdAt)}'
              '${resolvedAt != null ? ' · Resolved ${_formatTimestamp(resolvedAt)}' : ''}',
              style: GoogleFonts.notoSansKr(
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
                    onPressed: () => _updateFollowupStatus(
                      context,
                      id,
                      'in_progress',
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.statusOccupied,
                      side: const BorderSide(
                        color: AppColors.statusOccupied,
                      ),
                    ),
                    child: Text(
                      'Start Progress',
                      style: GoogleFonts.notoSansKr(fontSize: 12),
                    ),
                  ),
                if (status == 'open') const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => _showResolveDialog(context, id),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.statusAvailable,
                    side: const BorderSide(
                      color: AppColors.statusAvailable,
                    ),
                  ),
                  child: Text(
                    'Resolved',
                    style: GoogleFonts.notoSansKr(fontSize: 12),
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

    final success = await ref.read(qcFollowupProvider.notifier).updateStatus(
      followupId: followupId,
      storeId: storeId,
      status: status,
    );

    if (!context.mounted) return;
    if (success) {
      showSuccessToast(context, 'Status changed');
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

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Text(
          'Resolve Follow-up',
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: TextField(
          controller: notesController,
          style: const TextStyle(color: AppColors.textPrimary),
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Resolution notes (optional)',
            labelStyle: TextStyle(color: AppColors.textSecondary),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: AppColors.surface2),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: AppColors.amber500),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.statusAvailable,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Resolved'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final storeId = widget.storeId;
    if (storeId == null) return;

    final notes = notesController.text.trim();
    final success = await ref.read(qcFollowupProvider.notifier).updateStatus(
      followupId: followupId,
      storeId: storeId,
      status: 'resolved',
      resolutionNotes: notes.isEmpty ? null : notes,
    );

    notesController.dispose();

    if (!context.mounted) return;
    if (success) {
      showSuccessToast(context, 'Follow-up resolved');
    } else {
      final error = ref.read(qcFollowupProvider).error;
      if (error != null) showErrorToast(context, error);
    }
  }
}
