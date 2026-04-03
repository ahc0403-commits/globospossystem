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
    length: 2,
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

  Future<void> _initData(String restaurantId) async {
    await ref.read(qcTemplateProvider.notifier).loadTemplates(restaurantId);
    await ref
        .read(qcCheckProvider.notifier)
        .loadWeek(restaurantId: restaurantId, weekStart: _weekStart);
  }

  Future<void> _loadWeek(String restaurantId, DateTime weekStart) async {
    setState(() => _weekStart = weekStart);
    await ref
        .read(qcCheckProvider.notifier)
        .loadWeek(restaurantId: restaurantId, weekStart: weekStart);
  }

  @override
  Widget build(BuildContext context) {
    final restaurantId = ref.watch(authProvider).restaurantId;

    if (restaurantId != null && _initializedRestaurantId != restaurantId) {
      _initializedRestaurantId = restaurantId;
      Future.microtask(() => _initData(restaurantId));
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
                Tab(text: '기준표 관리'),
                Tab(text: '주간 점검 현황'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _TemplateManagementTab(
                  picker: _picker,
                  restaurantId: restaurantId,
                  role: ref.watch(authProvider).role,
                ),
                _WeeklyViewTab(
                  restaurantId: restaurantId,
                  weekStart: _weekStart,
                  onPrevWeek: restaurantId == null
                      ? null
                      : () => _loadWeek(
                          restaurantId,
                          _weekStart.subtract(const Duration(days: 7)),
                        ),
                  onNextWeek: restaurantId == null
                      ? null
                      : () => _loadWeek(
                          restaurantId,
                          _weekStart.add(const Duration(days: 7)),
                        ),
                ),
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
    required this.restaurantId,
    required this.role,
  });

  final ImagePicker picker;
  final String? restaurantId;
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
                'QC 기준표',
                style: GoogleFonts.bebasNeue(
                  color: AppColors.textPrimary,
                  fontSize: 30,
                ),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: restaurantId == null
                    ? null
                    : () => _showTemplateSheet(
                        context,
                        ref,
                        picker,
                        restaurantId!,
                      ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                icon: const Icon(Icons.add),
                label: const Text('기준 추가'),
              ),
            ],
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
                      '기준표가 없습니다.',
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
                      final category = template['category']?.toString() ?? '기타';
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
                                  '순서 ${template['sort_order'] ?? 0}',
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
                                      '📌 본사 공통',
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
                                  onPressed: !canEdit || restaurantId == null
                                      ? null
                                      : () => _showTemplateSheet(
                                          context,
                                          ref,
                                          picker,
                                          restaurantId!,
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
                                          showSuccessToast(context, '삭제 완료');
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
    String restaurantId, {
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
                    isEdit ? '기준 수정' : '기준 추가',
                    style: GoogleFonts.bebasNeue(
                      color: AppColors.amber500,
                      fontSize: 30,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: categoryController,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: const InputDecoration(labelText: '카테고리'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: criteriaController,
                    minLines: 2,
                    maxLines: 4,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: const InputDecoration(labelText: '기준(글)'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: sortController,
                    keyboardType: TextInputType.number,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: const InputDecoration(labelText: '순서'),
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
                        label: const Text('사진 업로드'),
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
                            restaurantId,
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
                            restaurantId: restaurantId,
                            category: category,
                            criteriaText: criteria,
                            criteriaPhotoUrl: photoUrl,
                            sortOrder: sortOrder,
                          );
                        }

                        if (!context.mounted) return;
                        showSuccessToast(context, '저장 완료');
                        Navigator.of(context).pop();
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.amber500,
                        foregroundColor: AppColors.surface0,
                      ),
                      child: const Text('저장'),
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
    required this.restaurantId,
    required this.weekStart,
    required this.onPrevWeek,
    required this.onNextWeek,
  });

  final String? restaurantId;
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
    final restaurantId = widget.restaurantId;
    if (restaurantId == null) return;
    await ref
        .read(qcCheckProvider.notifier)
        .loadDateRange(restaurantId: restaurantId, from: _from, to: _to);
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
      ...templates.map((e) => e['category']?.toString() ?? '기타'),
    }.toList();

    final filteredRangeChecks = checkState.dateRangeChecks.where((check) {
      final result = check['result']?.toString() ?? '';
      final template = check['qc_templates'] as Map<String, dynamic>?;
      final category = template?['category']?.toString() ?? '기타';
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
          Row(
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment<bool>(value: false, label: Text('주간 보기')),
                  ButtonSegment<bool>(value: true, label: Text('기간 검색')),
                ],
                selected: {_rangeMode},
                onSelectionChanged: (selection) {
                  setState(() => _rangeMode = selection.first);
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
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
                                    '기준',
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
                child: const Text('검색'),
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
                    labelText: '결과',
                  ),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('전체')),
                    DropdownMenuItem(value: 'pass', child: Text('통과')),
                    DropdownMenuItem(value: 'fail', child: Text('불합격')),
                    DropdownMenuItem(value: 'na', child: Text('해당없음')),
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
                    labelText: '카테고리',
                  ),
                  items: categoryOptions
                      .map(
                        (category) => DropdownMenuItem(
                          value: category,
                          child: Text(category == 'all' ? '전체' : category),
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
                  '검색 결과가 없습니다.',
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
                    'pass' => '✅ 통과',
                    'fail' => '❌ 불합격',
                    'na' => '— 해당없음',
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
                            '${template?['category'] ?? '기타'} | ${template?['criteria_text'] ?? '-'}',
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
      final category = t['category']?.toString() ?? '기타';
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
      builder: (context) {
        final result = check?['result']?.toString();
        final note = check?['note']?.toString();
        final evidencePhotoUrl = check?['evidence_photo_url']?.toString();

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
                  '기준: ${row.criteria}',
                  style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 10),
                if (check == null)
                  Text(
                    '해당 날짜 미점검',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                    ),
                  )
                else ...[
                  Text(
                    '판정: ${switch (result) {
                      'pass' => '✅ 통과',
                      'fail' => '❌ 불합격',
                      'na' => '— 해당없음',
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
                  if (evidencePhotoUrl != null && evidencePhotoUrl.isNotEmpty)
                    GestureDetector(
                      onTap: () => _showImageDialog(context, evidencePhotoUrl),
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
                      '[메모] $note',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('닫기'),
            ),
          ],
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
