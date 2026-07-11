import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io';

import '../../core/constants/app_constants.dart';
import '../../core/i18n/locale_extensions.dart';
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
        await notifier.loadBrands();
        await notifier.loadLegalEntityStructure();
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
      key: const Key('admin_root'),
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
                _navItem(
                  Icons.store,
                  context.l10n.superAdminStores,
                  0,
                  itemKey: const Key('super_admin_nav_stores'),
                ),
                const SizedBox(height: 8),
                _navItem(
                  Icons.bar_chart,
                  context.l10n.superAdminAllReports,
                  1,
                  itemKey: const Key('super_admin_nav_reports'),
                ),
                const SizedBox(height: 8),
                _navItem(
                  Icons.fact_check,
                  'QC Status',
                  2,
                  itemKey: const Key('super_admin_nav_qc_status'),
                ),
                const SizedBox(height: 8),
                _navItem(
                  Icons.rule,
                  'QC Template',
                  3,
                  itemKey: const Key('super_admin_nav_qc_template'),
                ),
                const SizedBox(height: 8),
                _navItem(
                  Icons.settings,
                  'System Settings',
                  4,
                  itemKey: const Key('super_admin_nav_system_settings'),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  key: const Key('logout_button'),
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
                        onGoToAdmin: (storeId) => context.go('/admin/$storeId'),
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

  Widget _navItem(IconData icon, String label, int index, {Key? itemKey}) {
    final selected = _tabIndex == index;
    return InkWell(
      key: itemKey,
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
              'HQ Shared QC Template Management',
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
              label: const Text('Add Shared Criterion'),
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
                    'No shared templates registered.',
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textSecondary,
                    ),
                  ),
                );
              }
              final grouped = <String, List<Map<String, dynamic>>>{};
              for (final template in templates) {
                final category = template['category']?.toString() ?? 'Other';
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
                                      '📌 Shared Across All Stores',
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
                                showSuccessToast(context, 'Deactivated');
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
          '✅ The items above apply automatically to all stores. Store-specific items are configured by the store admin.',
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
                    isEdit ? 'Edit Shared Criterion' : 'Add Shared Criterion',
                    style: GoogleFonts.bebasNeue(
                      color: AppColors.amber500,
                      fontSize: 30,
                    ),
                  ),
                  const SizedBox(height: 10),
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
                    decoration: const InputDecoration(
                      labelText: 'Criterion Details',
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
                          setModalState(() {
                            selectedFile = File(picked.path);
                            existingUrl = null;
                          });
                        },
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('Upload Reference Photo'),
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
                        showSuccessToast(context, 'Saved');
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
          'QC Status',
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
                    'No QC data.',
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
                  final storeId = row['restaurant_id']?.toString() ?? '';
                  final restaurantName =
                      row['restaurant_name']?.toString() ?? '-';
                  final coverage = (row['coverage'] as num?)?.toDouble() ?? 0.0;
                  final failCount = row['fail_count']?.toString() ?? '0';
                  final latest = row['latest_check_date']?.toString() ?? '-';

                  return InkWell(
                    onTap: storeId.isEmpty
                        ? null
                        : () => context.go('/admin/$storeId?tab=qc'),
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
                              failCount,
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
  final void Function(String storeId) onGoToAdmin;

  Future<void> _openOfficeSystem() async {
    final uri = Uri.parse(AppConstants.officeSystemUrl);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Text(
              context.l10n.superAdminStores.toUpperCase(),
              style: GoogleFonts.bebasNeue(
                color: AppColors.amber500,
                fontSize: 28,
                letterSpacing: 1.0,
              ),
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _openOfficeSystem,
              icon: const Icon(Icons.business),
              label: Text(context.l10n.superAdminGoToOfficeSystem),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: () =>
                  _showRestaurantSheet(context, notifier: notifier),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              icon: const Icon(Icons.add_business),
              label: Text(context.l10n.superAdminAddStore),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _ownerTypeChip(
                null,
                context.l10n.superAdminFilterAll,
                state.selectedOwnerType,
              ),
              const SizedBox(width: 6),
              _ownerTypeChip(
                'internal',
                context.l10n.superAdminFilterInternal,
                state.selectedOwnerType,
              ),
              const SizedBox(width: 6),
              _ownerTypeChip(
                'external',
                context.l10n.superAdminFilterExternal,
                state.selectedOwnerType,
              ),
              const SizedBox(width: 16),
              Text(
                context.l10n.superAdminLegalEntity,
                style: GoogleFonts.notoSansKr(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String?>(
                value: state.selectedTaxEntityId,
                dropdownColor: AppColors.surface1,
                hint: Text(
                  context.l10n.superAdminFilterAll,
                  style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                ),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(
                      context.l10n.superAdminFilterAll,
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  ...state.filteredTaxEntities.map((entity) {
                    return DropdownMenuItem<String?>(
                      value: entity.id,
                      child: Text(
                        '${entity.name} (${entity.taxCode})',
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    );
                  }),
                ],
                onChanged: notifier.setTaxEntityFilter,
              ),
              const SizedBox(width: 16),
              Text(
                context.l10n.superAdminBrand,
                style: GoogleFonts.notoSansKr(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String?>(
                value: state.selectedBrandId,
                dropdownColor: AppColors.surface1,
                hint: Text(
                  context.l10n.superAdminFilterAll,
                  style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                ),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(
                      context.l10n.superAdminFilterAll,
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  DropdownMenuItem<String?>(
                    value: kUnclassifiedBrandFilter,
                    child: Text(
                      context.l10n.superAdminUncategorized,
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  ...state.filteredBrands.map((brand) {
                    final id = brand['id']?.toString();
                    final code = brand['code']?.toString() ?? '-';
                    final name = brand['name']?.toString() ?? '-';
                    return DropdownMenuItem<String?>(
                      value: id,
                      child: Text(
                        '$name ($code)',
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    );
                  }),
                ],
                onChanged: notifier.setBrandFilter,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: state.isLoading && state.restaurants.isEmpty
              ? const Center(
                  child: CircularProgressIndicator(color: AppColors.amber500),
                )
              : ListView.separated(
                  itemCount: state.filteredRestaurants.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final restaurant = state.filteredRestaurants[index];
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
                                const SizedBox(height: 2),
                                Text(
                                  context.l10n.superAdminLegalEntityPrefix(
                                    restaurant.taxEntityName ??
                                        context.l10n.superAdminUncategorized,
                                  ),
                                  style: GoogleFonts.notoSansKr(
                                    color: AppColors.textSecondary,
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  context.l10n.superAdminBrandPrefix(
                                    restaurant.brandName ??
                                        context.l10n.superAdminUncategorized,
                                  ),
                                  style: GoogleFonts.notoSansKr(
                                    color: AppColors.textSecondary,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          _ownerTypeBadge(context, restaurant.ownerType),
                          const SizedBox(width: 6),
                          _officeStatusBadge(
                            context,
                            restaurant.isOfficeLinked,
                          ),
                          const SizedBox(width: 6),
                          _modeBadge(context, restaurant.operationMode),
                          const SizedBox(width: 10),
                          OutlinedButton(
                            onPressed: () => _showRestaurantSheet(
                              context,
                              notifier: notifier,
                              initial: restaurant,
                            ),
                            child: Text(context.l10n.superAdminManageStore),
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
                            child: Text(context.l10n.superAdminGoToAdmin),
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

  Widget _ownerTypeChip(String? type, String label, String? selected) {
    final isSelected = type == selected;
    return ChoiceChip(
      label: Text(
        label,
        style: GoogleFonts.notoSansKr(
          color: isSelected ? AppColors.surface0 : AppColors.textPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      selected: isSelected,
      selectedColor: type == 'external'
          ? const Color(0xFFE57373)
          : AppColors.amber500,
      backgroundColor: AppColors.surface1,
      side: BorderSide.none,
      onSelected: (_) => notifier.setOwnerTypeFilter(type),
    );
  }

  Widget _ownerTypeBadge(BuildContext context, String ownerType) {
    final isExternal = ownerType == 'external';
    final color = isExternal
        ? const Color(0xFFE57373)
        : const Color(0xFF66BB6A);
    final label = isExternal
        ? context.l10n.superAdminBadgeExternal
        : context.l10n.superAdminBadgeInternal;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: GoogleFonts.notoSansKr(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _officeStatusBadge(BuildContext context, bool isLinked) {
    final color = isLinked ? const Color(0xFF3A7BD5) : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color),
      ),
      child: Text(
        isLinked
            ? context.l10n.superAdminOfficeLinked
            : context.l10n.superAdminOfficeNotLinked,
        style: GoogleFonts.notoSansKr(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _modeBadge(BuildContext context, String mode) {
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
        switch (normalized) {
          'buffet' => context.l10n.superAdminOperationModeBuffet,
          'hybrid' => context.l10n.superAdminOperationModeHybrid,
          _ => context.l10n.superAdminOperationModeStandard,
        },
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
    String? selectedTaxEntityId =
        initial?.taxEntityId ??
        state.selectedTaxEntityId ??
        (state.taxEntities.length == 1 ? state.taxEntities.first.id : null);
    if (selectedTaxEntityId != null &&
        !state.taxEntities.any((entity) => entity.id == selectedTaxEntityId)) {
      selectedTaxEntityId = null;
    }
    var availableBrands = selectedTaxEntityId == null
        ? <Map<String, dynamic>>[]
        : state.brandsForTaxEntity(selectedTaxEntityId);
    final filterBrandId = state.selectedBrandId == kUnclassifiedBrandFilter
        ? null
        : state.selectedBrandId;
    String? selectedBrandId = initial?.brandId ?? filterBrandId;
    if (selectedBrandId != null &&
        !availableBrands.any(
          (brand) => brand['id']?.toString() == selectedBrandId,
        )) {
      selectedBrandId = null;
    }
    if (selectedBrandId == null && availableBrands.length == 1) {
      selectedBrandId = availableBrands.first['id']?.toString();
    }

    Future<void> save() async {
      final name = nameController.text.trim();
      final slug = slugController.text.trim();
      final address = addressController.text.trim();
      if (name.isEmpty || slug.isEmpty) {
        return;
      }
      if (selectedTaxEntityId == null || selectedTaxEntityId!.isEmpty) {
        showErrorToast(
          context,
          context.l10n.superAdminLegalEntityRequiredBeforeStore,
        );
        return;
      }
      if (selectedBrandId == null || selectedBrandId!.isEmpty) {
        showErrorToast(context, context.l10n.superAdminBrandRequired);
        return;
      }
      final taxEntityId = selectedTaxEntityId!;
      final brandId = selectedBrandId!;
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
              taxEntityId: taxEntityId,
              brandId: brandId,
            )
          : await notifier.addRestaurant(
              name: name,
              address: address,
              slug: slug,
              operationMode: operationMode,
              perPersonCharge: charge,
              taxEntityId: taxEntityId,
              brandId: brandId,
            );

      if (success && context.mounted) {
        showSuccessToast(
          context,
          isEdit
              ? context.l10n.superAdminStoreUpdated
              : context.l10n.superAdminStoreCreated,
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
                    isEdit
                        ? context.l10n.superAdminEditStore
                        : context.l10n.superAdminAddStore,
                    style: GoogleFonts.bebasNeue(
                      color: AppColors.amber500,
                      fontSize: 30,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameController,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: context.l10n.superAdminStoreName,
                    ),
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
                    decoration: InputDecoration(
                      labelText: context.l10n.superAdminStoreAddress,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: slugController,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: context.l10n.superAdminStoreSlug,
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: operationMode,
                    dropdownColor: AppColors.surface1,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: context.l10n.superAdminOperationMode,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'standard',
                        child: Text(
                          context.l10n.superAdminOperationModeStandard,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'buffet',
                        child: Text(context.l10n.superAdminOperationModeBuffet),
                      ),
                      DropdownMenuItem(
                        value: 'hybrid',
                        child: Text(context.l10n.superAdminOperationModeHybrid),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setModalState(() => operationMode = value);
                      }
                    },
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String?>(
                    key: ValueKey(selectedTaxEntityId),
                    initialValue: selectedTaxEntityId,
                    dropdownColor: AppColors.surface1,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: context.l10n.superAdminLegalEntity,
                    ),
                    items: state.taxEntities
                        .map(
                          (entity) => DropdownMenuItem<String?>(
                            value: entity.id,
                            child: Text('${entity.name} (${entity.taxCode})'),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      setModalState(() {
                        selectedTaxEntityId = value;
                        availableBrands = value == null
                            ? <Map<String, dynamic>>[]
                            : state.brandsForTaxEntity(value);
                        selectedBrandId = availableBrands.length == 1
                            ? availableBrands.first['id']?.toString()
                            : null;
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String?>(
                    key: ValueKey(
                      '${selectedTaxEntityId ?? 'none'}-${selectedBrandId ?? 'none'}',
                    ),
                    initialValue: selectedBrandId,
                    dropdownColor: AppColors.surface1,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: context.l10n.superAdminBrand,
                    ),
                    items: [
                      ...availableBrands.map((brand) {
                        final id = brand['id']?.toString();
                        final name = brand['name']?.toString() ?? '-';
                        final code = brand['code']?.toString() ?? '-';
                        return DropdownMenuItem<String?>(
                          value: id,
                          child: Text('$name ($code)'),
                        );
                      }),
                    ],
                    onChanged: (value) {
                      setModalState(() => selectedBrandId = value);
                    },
                  ),
                  const SizedBox(height: 10),
                  InputDecorator(
                    decoration: InputDecoration(
                      labelText: context.l10n.superAdminOfficeIntegration,
                    ),
                    child: Text(
                      selectedTaxEntityId == null
                          ? context.l10n.superAdminSelectLegalEntityFirst
                          : state.taxEntities
                                .firstWhere(
                                  (entity) => entity.id == selectedTaxEntityId,
                                )
                                .isInternal
                          ? context.l10n.superAdminOfficeLinkedDerived
                          : context.l10n.superAdminOfficeNotLinkedDerived,
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                      ),
                    ),
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
                      decoration: InputDecoration(
                        labelText: context.l10n.superAdminPerPersonCharge,
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
                      child: Text(context.l10n.superAdminSaveUpper),
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
                            showSuccessToast(
                              context,
                              context.l10n.superAdminStoreDeactivated,
                            );
                            Navigator.of(context).pop();
                          }
                        },
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(
                            color: AppColors.statusCancelled,
                          ),
                          foregroundColor: AppColors.statusCancelled,
                        ),
                        child: Text(context.l10n.superAdminDeleteDeactivate),
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

class _AllReportsTab extends StatefulWidget {
  const _AllReportsTab({required this.state, required this.notifier});

  final SuperAdminState state;
  final SuperAdminNotifier notifier;

  @override
  State<_AllReportsTab> createState() => _AllReportsTabState();
}

class _AllReportsTabState extends State<_AllReportsTab> {
  String _reportGrouping = 'store';

  Future<void> _openOfficeKpi() async {
    final uri = Uri.parse(AppConstants.officeKpiUrl);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  List<_BrandRevenueRow> _brandRows(
    List<SuperAdminRestaurantReport> rows,
    List<SuperRestaurant> restaurants,
    String uncategorized,
  ) {
    final map = <String, _BrandRevenueRow>{};
    for (final row in rows) {
      final restaurant = restaurants
          .where((r) => r.id == row.storeId)
          .cast<SuperRestaurant?>()
          .firstWhere((r) => r != null, orElse: () => null);
      final key = restaurant?.brandId ?? kUnclassifiedBrandFilter;
      final name = restaurant?.brandName ?? uncategorized;
      final current = map[key];
      if (current == null) {
        map[key] = _BrandRevenueRow(name: name, total: row.total);
      } else {
        map[key] = _BrandRevenueRow(
          name: name,
          total: current.total + row.total,
        );
      }
    }
    final rowsSorted = map.values.toList();
    rowsSorted.sort((a, b) => b.total.compareTo(a.total));
    return rowsSorted;
  }

  List<_RevenueGroupRow> _legalEntityBrandRows(
    List<SuperAdminRestaurantReport> rows,
    List<SuperRestaurant> restaurants,
    String uncategorized,
  ) {
    final storesById = {for (final store in restaurants) store.id: store};
    final entities = <String, Map<String, _RevenueGroupAccumulator>>{};
    final entityNames = <String, String>{};
    for (final row in rows) {
      final store = storesById[row.storeId];
      final entityId = store?.taxEntityId ?? '__unclassified_entity__';
      final entityName = store?.taxEntityName ?? uncategorized;
      final brandId = store?.brandId ?? kUnclassifiedBrandFilter;
      final brandName = store?.brandName ?? uncategorized;
      entityNames[entityId] = entityName;
      final brands = entities.putIfAbsent(entityId, () => {});
      final accumulator = brands.putIfAbsent(
        brandId,
        () => _RevenueGroupAccumulator(brandName),
      );
      accumulator.add(row);
    }

    final result = <_RevenueGroupRow>[];
    final sortedEntities = entities.entries.toList()
      ..sort(
        (a, b) =>
            (entityNames[a.key] ?? '').compareTo(entityNames[b.key] ?? ''),
      );
    for (final entity in sortedEntities) {
      final brandRows = entity.value.values.toList()
        ..sort((a, b) => b.total.compareTo(a.total));
      result.add(
        _RevenueGroupRow(
          name: entityNames[entity.key] ?? uncategorized,
          dineIn: brandRows.fold(0, (sum, row) => sum + row.dineIn),
          delivery: brandRows.fold(0, (sum, row) => sum + row.delivery),
          isBrand: false,
        ),
      );
      result.addAll(
        brandRows.map(
          (row) => _RevenueGroupRow(
            name: row.name,
            dineIn: row.dineIn,
            delivery: row.delivery,
            isBrand: true,
          ),
        ),
      );
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final notifier = widget.notifier;
    final summary = state.reportSummary;
    final currency = NumberFormat('#,###', 'vi_VN');
    final brandRows = summary == null
        ? const <_BrandRevenueRow>[]
        : _brandRows(
            summary.rows,
            state.restaurants,
            context.l10n.superAdminUncategorized,
          );
    final legalEntityBrandRows = summary == null
        ? const <_RevenueGroupRow>[]
        : _legalEntityBrandRows(
            summary.rows,
            state.restaurants,
            context.l10n.superAdminUncategorized,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.superAdminAllReportsTitle,
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
                context.l10n.superAdminAllStores,
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
              ),
              items: [
                DropdownMenuItem<SuperRestaurant?>(
                  value: null,
                  child: Text(
                    context.l10n.superAdminAllStores,
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
            DropdownButton<String>(
              value: _reportGrouping,
              dropdownColor: AppColors.surface1,
              items: [
                DropdownMenuItem<String>(
                  value: 'store',
                  child: Text(
                    context.l10n.superAdminGroupByStore,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                  ),
                ),
                DropdownMenuItem<String>(
                  value: 'brand',
                  child: Text(
                    context.l10n.superAdminGroupByBrand,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                  ),
                ),
                DropdownMenuItem<String>(
                  value: 'legal_entity_brand',
                  child: Text(
                    context.l10n.superAdminGroupByLegalEntityBrand,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                  ),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _reportGrouping = value);
                }
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
            OutlinedButton.icon(
              onPressed: _openOfficeKpi,
              icon: const Icon(Icons.dashboard_customize),
              label: Text(context.l10n.superAdminViewDetailedReports),
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
                context.l10n.superAdminTotalRevenue,
                '₫${currency.format(summary.totalRevenue)}',
              ),
              _summaryCard(
                context.l10n.superAdminDineIn,
                '₫${currency.format(summary.dineInRevenue)}',
              ),
              _summaryCard(
                context.l10n.superAdminDelivery,
                '₫${currency.format(summary.deliveryRevenue)}',
              ),
            ],
          ),
        if (brandRows.isNotEmpty) ...[
          const SizedBox(height: 12),
          _BrandRevenueChart(rows: brandRows),
        ],
        const SizedBox(height: 16),
        Expanded(
          child: summary == null || summary.rows.isEmpty
              ? Center(
                  child: Text(
                    context.l10n.superAdminNoReportData,
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
                      _reportHeader(
                        label: switch (_reportGrouping) {
                          'brand' => context.l10n.superAdminBrandColumn,
                          'legal_entity_brand' =>
                            context.l10n.superAdminLegalEntityBrandColumn,
                          _ => context.l10n.superAdminStoreColumn,
                        },
                        dineInLabel: context.l10n.superAdminDineIn,
                        deliveryLabel: context.l10n.superAdminDelivery,
                        totalLabel: context.l10n.superAdminTotal,
                      ),
                      Expanded(
                        child: _reportGrouping == 'brand'
                            ? ListView.builder(
                                itemCount: brandRows.length,
                                itemBuilder: (context, index) {
                                  final row = brandRows[index];
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
                                        _cell(row.name, flex: 3),
                                        _cell('-'),
                                        _cell('-'),
                                        _cell('₫${currency.format(row.total)}'),
                                      ],
                                    ),
                                  );
                                },
                              )
                            : _reportGrouping == 'legal_entity_brand'
                            ? ListView.builder(
                                itemCount: legalEntityBrandRows.length,
                                itemBuilder: (context, index) {
                                  final row = legalEntityBrandRows[index];
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
                                        _cell(
                                          row.isBrand
                                              ? '  ${row.name}'
                                              : row.name,
                                          flex: 3,
                                          bold: !row.isBrand,
                                        ),
                                        _cell(
                                          '₫${currency.format(row.dineIn)}',
                                        ),
                                        _cell(
                                          '₫${currency.format(row.delivery)}',
                                        ),
                                        _cell(
                                          '₫${currency.format(row.total)}',
                                          bold: !row.isBrand,
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              )
                            : ListView.builder(
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
                                        _cell(
                                          '₫${currency.format(row.dineIn)}',
                                        ),
                                        _cell(
                                          '₫${currency.format(row.delivery)}',
                                        ),
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

  Widget _reportHeader({
    required String label,
    required String dineInLabel,
    required String deliveryLabel,
    required String totalLabel,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.surface2)),
      ),
      child: Row(
        children: [
          _cell(label, flex: 3, bold: true),
          _cell(dineInLabel, bold: true),
          _cell(deliveryLabel, bold: true),
          _cell(totalLabel, bold: true),
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

class _BrandRevenueRow {
  const _BrandRevenueRow({required this.name, required this.total});

  final String name;
  final double total;
}

class _RevenueGroupAccumulator {
  _RevenueGroupAccumulator(this.name);

  final String name;
  double dineIn = 0;
  double delivery = 0;
  double get total => dineIn + delivery;

  void add(SuperAdminRestaurantReport row) {
    dineIn += row.dineIn;
    delivery += row.delivery;
  }
}

class _RevenueGroupRow {
  const _RevenueGroupRow({
    required this.name,
    required this.dineIn,
    required this.delivery,
    required this.isBrand,
  });

  final String name;
  final double dineIn;
  final double delivery;
  final bool isBrand;
  double get total => dineIn + delivery;
}

class _BrandRevenueChart extends StatelessWidget {
  const _BrandRevenueChart({required this.rows});

  final List<_BrandRevenueRow> rows;

  @override
  Widget build(BuildContext context) {
    final maxY = rows
        .map((e) => e.total)
        .fold<double>(0, (a, b) => a > b ? a : b);
    return Container(
      height: 260,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(14),
      ),
      child: BarChart(
        BarChartData(
          maxY: maxY <= 0 ? 1 : maxY * 1.2,
          alignment: BarChartAlignment.spaceAround,
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: true),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  if (index < 0 || index >= rows.length) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      rows[index].name,
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                        fontSize: 10,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          barGroups: [
            for (var i = 0; i < rows.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: rows[i].total,
                    color: AppColors.amber500,
                    width: 18,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ],
              ),
          ],
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
