import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'dart:io';

import '../../core/constants/app_constants.dart';
import '../../main.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/error_toast.dart';
import '../auth/auth_provider.dart';
import '../auth/auth_state.dart';
import '../qc/qc_provider.dart';
import 'super_admin_provider.dart';

class SuperAdminScreen extends ConsumerStatefulWidget {
  const SuperAdminScreen({super.key});

  @override
  ConsumerState<SuperAdminScreen> createState() => _SuperAdminScreenState();
}

class _SuperAdminScreenState extends ConsumerState<SuperAdminScreen> {
  int _tabIndex = 0;
  bool _initialized = false;
  String? _lastError;

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final state = ref.watch(superAdminProvider);
    final notifier = ref.read(superAdminProvider.notifier);

    if (!_initialized) {
      _initialized = true;
      Future.microtask(() async {
        await notifier.loadAllRestaurants();
        await notifier.loadAllReports();
      });
    }

    if (state.error != null &&
        state.error!.isNotEmpty &&
        state.error != _lastError) {
      _lastError = state.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          showErrorToast(context, state.error!);
        }
      });
    }

    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: Row(
        children: [
          Container(
            width: 220,
            color: AppColors.surface1,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'SYSTEM ADMIN',
                  style: GoogleFonts.bebasNeue(
                    color: AppColors.amber500,
                    fontSize: 30,
                    letterSpacing: 1.1,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                _navItem(Icons.store, 'Restaurants', 0),
                const SizedBox(height: 8),
                _navItem(Icons.bar_chart, 'All Reports', 1),
                const SizedBox(height: 8),
                _navItem(Icons.fact_check, 'QC 현황', 2),
                const SizedBox(height: 8),
                _navItem(Icons.rule, 'QC 기준표', 3),
                const SizedBox(height: 8),
                _navItem(Icons.settings, 'System Settings', 4),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: () => ref.read(authProvider.notifier).logout(),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.statusCancelled),
                    foregroundColor: AppColors.statusCancelled,
                  ),
                  icon: const Icon(Icons.logout),
                  label: const Text('Logout'),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: AppNavBar(),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: switch (_tabIndex) {
                      0 => _RestaurantsTab(
                        state: state,
                        notifier: notifier,
                        onGoToAdmin: (restaurantId) =>
                            context.go('/admin/$restaurantId'),
                      ),
                      1 => _AllReportsTab(state: state, notifier: notifier),
                      2 => const _QcOverviewTab(),
                      3 => const _QcGlobalTemplatesTab(),
                      _ => _SystemSettingsTab(authState: authState),
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _navItem(IconData icon, String label, int index) {
    final selected = _tabIndex == index;
    return InkWell(
      onTap: () => setState(() => _tabIndex = index),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.amber500.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.amber500 : AppColors.surface2,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: selected ? AppColors.amber500 : AppColors.textSecondary,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: GoogleFonts.notoSansKr(
                  color: selected
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QcGlobalTemplatesTab extends ConsumerWidget {
  const _QcGlobalTemplatesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templatesAsync = ref.watch(globalQcTemplatesProvider);
    final notifier = ref.read(qcTemplateProvider.notifier);
    final picker = ImagePicker();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '본사 공통 QC 기준표 관리',
              style: GoogleFonts.bebasNeue(
                color: AppColors.amber500,
                fontSize: 30,
                letterSpacing: 1,
              ),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: () =>
                  _showGlobalTemplateSheet(context, ref, picker, notifier),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              icon: const Icon(Icons.add),
              label: const Text('공통 기준 추가'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: templatesAsync.when(
            data: (templates) {
              if (templates.isEmpty) {
                return Center(
                  child: Text(
                    '등록된 공통 기준표가 없습니다.',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                    ),
                  ),
                );
              }
              final grouped = <String, List<Map<String, dynamic>>>{};
              for (final template in templates) {
                final category = template['category']?.toString() ?? '기타';
                grouped.putIfAbsent(category, () => []).add(template);
              }

              return ListView(
                children: [
                  for (final category in grouped.keys) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.amber500.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        category,
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.amber500,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    ...grouped[category]!.map((template) {
                      final id = template['id']?.toString() ?? '';
                      final photo = template['criteria_photo_url']?.toString();
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.surface1,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.surface2),
                        ),
                        child: Row(
                          children: [
                            if (photo != null && photo.isNotEmpty)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  photo,
                                  width: 52,
                                  height: 52,
                                  fit: BoxFit.cover,
                                ),
                              )
                            else
                              const Icon(
                                Icons.image_not_supported_outlined,
                                color: AppColors.textSecondary,
                              ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    template['criteria_text']?.toString() ??
                                        '-',
                                    style: GoogleFonts.notoSansKr(
                                      color: AppColors.textPrimary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.amber500.withValues(
                                        alpha: 0.16,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      '📌 전체 매장 공통',
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
                            IconButton(
                              onPressed: () => _showGlobalTemplateSheet(
                                context,
                                ref,
                                picker,
                                notifier,
                                initial: template,
                              ),
                              icon: const Icon(Icons.edit_outlined),
                              color: AppColors.textSecondary,
                            ),
                            IconButton(
                              onPressed: () async {
                                await notifier.deleteTemplate(id);
                                ref.invalidate(globalQcTemplatesProvider);
                                if (!context.mounted) return;
                                showSuccessToast(context, '비활성화 완료');
                              },
                              icon: const Icon(Icons.block_outlined),
                              color: AppColors.statusCancelled,
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ],
              );
            },
            loading: () => const Center(
              child: CircularProgressIndicator(color: AppColors.amber500),
            ),
            error: (error, _) => Center(
              child: Text(
                '$error',
                style: GoogleFonts.notoSansKr(color: AppColors.statusCancelled),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '✅ 위 항목은 모든 매장에 자동 적용됩니다. 매장별 추가 항목은 매장 어드민이 설정합니다.',
          style: GoogleFonts.notoSansKr(
            color: AppColors.textSecondary,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Future<void> _showGlobalTemplateSheet(
    BuildContext context,
    WidgetRef ref,
    ImagePicker picker,
    QcTemplateNotifier notifier, {
    Map<String, dynamic>? initial,
  }) async {
    final isEdit = initial != null;
    final categoryController = TextEditingController(
      text: initial?['category']?.toString() ?? '',
    );
    final criteriaController = TextEditingController(
      text: initial?['criteria_text']?.toString() ?? '',
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
                    isEdit ? '공통 기준 수정' : '공통 기준 추가',
                    style: GoogleFonts.bebasNeue(
                      color: AppColors.amber500,
                      fontSize: 30,
                    ),
                  ),
                  const SizedBox(height: 10),
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
                    decoration: const InputDecoration(labelText: '기준 내용'),
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
                        label: const Text('기준사진 업로드'),
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
                      else if (existingUrl != null && existingUrl!.isNotEmpty)
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
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () async {
                        final category = categoryController.text.trim();
                        final criteria = criteriaController.text.trim();
                        if (category.isEmpty || criteria.isEmpty) {
                          return;
                        }

                        String? photoUrl = existingUrl;
                        if (selectedFile != null) {
                          final templateId = isEdit
                              ? initial['id'].toString()
                              : notifier.generateTemplateId();
                          photoUrl = await notifier.uploadCriteriaPhoto(
                            'global',
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
                              });
                        } else {
                          await notifier.addGlobalTemplate(
                            category: category,
                            criteriaText: criteria,
                            criteriaPhotoUrl: photoUrl,
                          );
                        }
                        ref.invalidate(globalQcTemplatesProvider);
                        if (!context.mounted) return;
                        Navigator.of(context).pop();
                        showSuccessToast(context, '저장 완료');
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
  }
}

class _QcOverviewTab extends ConsumerWidget {
  const _QcOverviewTab();

  DateTime _startOfWeek(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final weekStart = _startOfWeek(DateTime.now());
    final summaryAsync = ref.watch(superAdminQcSummaryProvider(weekStart));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'QC 현황',
          style: GoogleFonts.bebasNeue(
            color: AppColors.amber500,
            fontSize: 28,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: summaryAsync.when(
            data: (rows) {
              if (rows.isEmpty) {
                return Center(
                  child: Text(
                    'QC 데이터가 없습니다.',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                    ),
                  ),
                );
              }

              return ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final row = rows[index];
                  final restaurantId = row['restaurant_id']?.toString() ?? '';
                  final restaurantName =
                      row['restaurant_name']?.toString() ?? '-';
                  final coverage = (row['coverage'] as num?)?.toDouble() ?? 0.0;
                  final failCount = row['fail_count']?.toString() ?? '0';
                  final latest = row['latest_check_date']?.toString() ?? '-';

                  return InkWell(
                    onTap: restaurantId.isEmpty
                        ? null
                        : () => context.go('/admin/$restaurantId?tab=qc'),
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.surface1,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.surface2),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Text(
                              restaurantName,
                              style: GoogleFonts.notoSansKr(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              '${coverage.toStringAsFixed(0)}%',
                              style: GoogleFonts.bebasNeue(
                                color: AppColors.amber500,
                                fontSize: 24,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              '$failCount건',
                              style: GoogleFonts.notoSansKr(
                                color: failCount == '0'
                                    ? AppColors.statusAvailable
                                    : AppColors.statusCancelled,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              latest,
                              style: GoogleFonts.notoSansKr(
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
            loading: () => const Center(
              child: CircularProgressIndicator(color: AppColors.amber500),
            ),
            error: (error, _) => Center(
              child: Text(
                '$error',
                style: GoogleFonts.notoSansKr(color: AppColors.statusCancelled),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RestaurantsTab extends StatelessWidget {
  const _RestaurantsTab({
    required this.state,
    required this.notifier,
    required this.onGoToAdmin,
  });

  final SuperAdminState state;
  final SuperAdminNotifier notifier;
  final void Function(String restaurantId) onGoToAdmin;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Text(
              'RESTAURANTS',
              style: GoogleFonts.bebasNeue(
                color: AppColors.amber500,
                fontSize: 28,
                letterSpacing: 1.0,
              ),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: () =>
                  _showRestaurantSheet(context, notifier: notifier),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              icon: const Icon(Icons.add_business),
              label: const Text('Add Restaurant'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: state.isLoading && state.restaurants.isEmpty
              ? const Center(
                  child: CircularProgressIndicator(color: AppColors.amber500),
                )
              : ListView.separated(
                  itemCount: state.restaurants.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final restaurant = state.restaurants[index];
                    return Container(
                      decoration: BoxDecoration(
                        color: AppColors.surface1,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: restaurant.isActive
                                  ? AppColors.statusAvailable
                                  : AppColors.textSecondary,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  restaurant.name,
                                  style: GoogleFonts.bebasNeue(
                                    color: AppColors.textPrimary,
                                    fontSize: 24,
                                  ),
                                ),
                                Text(
                                  '${restaurant.slug} • ${restaurant.address}',
                                  style: GoogleFonts.notoSansKr(
                                    color: AppColors.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          _modeBadge(restaurant.operationMode),
                          const SizedBox(width: 10),
                          OutlinedButton(
                            onPressed: () => _showRestaurantSheet(
                              context,
                              notifier: notifier,
                              initial: restaurant,
                            ),
                            child: const Text('Manage'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () {
                              notifier.selectRestaurant(restaurant);
                              onGoToAdmin(restaurant.id);
                            },
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.amber500,
                              foregroundColor: AppColors.surface0,
                            ),
                            child: const Text('Go to Admin'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _modeBadge(String mode) {
    final normalized = mode.toLowerCase();
    final color = switch (normalized) {
      'buffet' => AppColors.amber500,
      'hybrid' => const Color(0xFF3A7BD5),
      _ => AppColors.textSecondary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color),
      ),
      child: Text(
        normalized.toUpperCase(),
        style: GoogleFonts.notoSansKr(
          color: AppColors.textPrimary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Future<void> _showRestaurantSheet(
    BuildContext context, {
    required SuperAdminNotifier notifier,
    SuperRestaurant? initial,
  }) async {
    final isEdit = initial != null;
    final nameController = TextEditingController(text: initial?.name ?? '');
    final addressController = TextEditingController(
      text: initial?.address ?? '',
    );
    final slugController = TextEditingController(text: initial?.slug ?? '');
    final chargeController = TextEditingController(
      text: initial?.perPersonCharge?.toString() ?? '',
    );
    String operationMode = initial?.operationMode ?? 'standard';

    Future<void> save() async {
      final name = nameController.text.trim();
      final slug = slugController.text.trim();
      final address = addressController.text.trim();
      if (name.isEmpty || slug.isEmpty) {
        return;
      }
      final charge = (operationMode == 'buffet' || operationMode == 'hybrid')
          ? double.tryParse(chargeController.text.trim())
          : null;

      final success = isEdit
          ? await notifier.updateRestaurant(
              id: initial.id,
              name: name,
              address: address,
              slug: slug,
              operationMode: operationMode,
              perPersonCharge: charge,
            )
          : await notifier.addRestaurant(
              name: name,
              address: address,
              slug: slug,
              operationMode: operationMode,
              perPersonCharge: charge,
            );

      if (success && context.mounted) {
        showSuccessToast(
          context,
          isEdit ? 'Restaurant updated' : 'Restaurant created',
        );
        Navigator.of(context).pop();
      }
    }

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
                    isEdit ? 'Edit Restaurant' : 'Add Restaurant',
                    style: GoogleFonts.bebasNeue(
                      color: AppColors.amber500,
                      fontSize: 30,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameController,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: const InputDecoration(labelText: 'Name'),
                    onChanged: (value) {
                      if (!isEdit && slugController.text.trim().isEmpty) {
                        slugController.text = _slugify(value);
                      }
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: addressController,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: const InputDecoration(labelText: 'Address'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: slugController,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: const InputDecoration(labelText: 'Slug'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: operationMode,
                    dropdownColor: AppColors.surface1,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: const InputDecoration(
                      labelText: 'Operation Mode',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'standard',
                        child: Text('Standard'),
                      ),
                      DropdownMenuItem(value: 'buffet', child: Text('Buffet')),
                      DropdownMenuItem(value: 'hybrid', child: Text('Hybrid')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setModalState(() => operationMode = value);
                      }
                    },
                  ),
                  if (operationMode == 'buffet' ||
                      operationMode == 'hybrid') ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: chargeController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Per Person Charge',
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: save,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.amber500,
                        foregroundColor: AppColors.surface0,
                      ),
                      child: const Text('SAVE'),
                    ),
                  ),
                  if (isEdit) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () async {
                          final success = await notifier.deactivateRestaurant(
                            initial.id,
                          );
                          if (success && context.mounted) {
                            showSuccessToast(context, 'Restaurant deactivated');
                            Navigator.of(context).pop();
                          }
                        },
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(
                            color: AppColors.statusCancelled,
                          ),
                          foregroundColor: AppColors.statusCancelled,
                        ),
                        child: const Text('DELETE (Deactivate)'),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );

    nameController.dispose();
    addressController.dispose();
    slugController.dispose();
    chargeController.dispose();
  }

  String _slugify(String input) {
    return input
        .toLowerCase()
        .trim()
        .replaceAll(RegExp(r'[^a-z0-9\s-]'), '')
        .replaceAll(RegExp(r'\s+'), '-');
  }
}

class _AllReportsTab extends StatelessWidget {
  const _AllReportsTab({required this.state, required this.notifier});

  final SuperAdminState state;
  final SuperAdminNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final summary = state.reportSummary;
    final currency = NumberFormat('#,###', 'vi_VN');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ALL REPORTS',
          style: GoogleFonts.bebasNeue(color: AppColors.amber500, fontSize: 30),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<SuperRestaurant?>(
              value: state.selectedRestaurant,
              dropdownColor: AppColors.surface1,
              hint: Text(
                'All Restaurants',
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
              ),
              items: [
                DropdownMenuItem<SuperRestaurant?>(
                  value: null,
                  child: Text(
                    'All Restaurants',
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                  ),
                ),
                ...state.restaurants.map((restaurant) {
                  return DropdownMenuItem<SuperRestaurant?>(
                    value: restaurant,
                    child: Text(
                      restaurant.name,
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  );
                }),
              ],
              onChanged: (value) async {
                notifier.selectRestaurant(value);
                await notifier.loadAllReports(selectedRestaurantId: value?.id);
              },
            ),
            OutlinedButton(
              onPressed: () async {
                final picked = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now(),
                  initialDateRange: DateTimeRange(
                    start: state.reportStart,
                    end: state.reportEnd,
                  ),
                );
                if (picked != null) {
                  await notifier.setReportRange(picked.start, picked.end);
                }
              },
              child: Text(
                '${DateFormat('dd/MM/yyyy').format(state.reportStart)} - ${DateFormat('dd/MM/yyyy').format(state.reportEnd)}',
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (summary != null)
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _summaryCard(
                'Total Revenue',
                '₫${currency.format(summary.totalRevenue)}',
              ),
              _summaryCard(
                'Dine-in',
                '₫${currency.format(summary.dineInRevenue)}',
              ),
              _summaryCard(
                'Delivery',
                '₫${currency.format(summary.deliveryRevenue)}',
              ),
            ],
          ),
        const SizedBox(height: 16),
        Expanded(
          child: summary == null || summary.rows.isEmpty
              ? Center(
                  child: Text(
                    'No report data',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                )
              : Container(
                  decoration: BoxDecoration(
                    color: AppColors.surface1,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      _reportHeader(),
                      Expanded(
                        child: ListView.builder(
                          itemCount: summary.rows.length,
                          itemBuilder: (context, index) {
                            final row = summary.rows[index];
                            final bg = index.isEven
                                ? AppColors.surface1
                                : AppColors.surface0;
                            return Container(
                              color: bg,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  _cell(row.restaurantName, flex: 3),
                                  _cell('₫${currency.format(row.dineIn)}'),
                                  _cell('₫${currency.format(row.delivery)}'),
                                  _cell('₫${currency.format(row.total)}'),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _summaryCard(String title, String value) {
    return Container(
      width: 220,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          Text(
            value,
            style: GoogleFonts.bebasNeue(
              color: AppColors.amber500,
              fontSize: 30,
            ),
          ),
        ],
      ),
    );
  }

  Widget _reportHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.surface2)),
      ),
      child: Row(
        children: [
          _cell('Restaurant', flex: 3, bold: true),
          _cell('Dine-in', bold: true),
          _cell('Delivery', bold: true),
          _cell('Total', bold: true),
        ],
      ),
    );
  }

  Widget _cell(String text, {int flex = 1, bool bold = false}) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        style: GoogleFonts.notoSansKr(
          color: AppColors.textPrimary,
          fontSize: 12,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}

class _SystemSettingsTab extends StatelessWidget {
  const _SystemSettingsTab({required this.authState});

  final PosAuthState authState;

  @override
  Widget build(BuildContext context) {
    final projectRef =
        Uri.tryParse(AppConstants.supabaseUrl)?.host ??
        AppConstants.supabaseUrl;
    final email = authState.user?.email?.toString() ?? '-';
    final role = authState.role?.toString() ?? '-';

    return SingleChildScrollView(
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface1,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'System Settings',
              style: GoogleFonts.bebasNeue(
                color: AppColors.amber500,
                fontSize: 30,
              ),
            ),
            const SizedBox(height: 10),
            _infoRow('Email', email),
            _infoRow('Role', role),
            _infoRow('Version', 'GLOBOS POS v1.0.0'),
            _infoRow('Supabase', projectRef),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: GoogleFonts.notoSansKr(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
