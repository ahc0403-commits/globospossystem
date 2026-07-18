import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../core/utils/number_input_utils.dart';
import '../../main.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/error_toast.dart';
import '../auth/auth_provider.dart';
import '../auth/auth_state.dart';
import '../qc/qc_provider.dart';
import 'super_admin_provider.dart';

const _superAdminScrollPadding = EdgeInsets.only(bottom: 96);
const _superAdminScrollPhysics = AlwaysScrollableScrollPhysics(
  parent: ClampingScrollPhysics(),
);

class _SuperAdminHierarchyCopy {
  _SuperAdminHierarchyCopy(BuildContext context)
    : filterInternal = context.l10n.superAdminFilterInternal,
      filterExternal = context.l10n.superAdminFilterExternal,
      legalEntity = context.l10n.superAdminLegalEntity,
      legalEntityPrefix = context.l10n.superAdminLegalEntityPrefix,
      brand = context.l10n.superAdminBrand,
      brandPrefix = context.l10n.superAdminBrandPrefix,
      brandRequired = context.l10n.superAdminBrandRequired,
      uncategorized = context.l10n.superAdminUncategorized,
      badgeInternal = context.l10n.superAdminBadgeInternal,
      badgeExternal = context.l10n.superAdminBadgeExternal,
      officeIntegration = context.l10n.superAdminOfficeIntegration,
      officeLinkedDerived = context.l10n.superAdminOfficeLinkedDerived,
      officeNotLinkedDerived = context.l10n.superAdminOfficeNotLinkedDerived,
      groupByLegalEntityBrand = context.l10n.superAdminGroupByLegalEntityBrand,
      legalEntityBrandColumn = context.l10n.superAdminLegalEntityBrandColumn;

  final String filterInternal;
  final String filterExternal;
  final String legalEntity;
  final String Function(String) legalEntityPrefix;
  final String brand;
  final String Function(String) brandPrefix;
  final String brandRequired;
  final String uncategorized;
  final String badgeInternal;
  final String badgeExternal;
  final String officeIntegration;
  final String officeLinkedDerived;
  final String officeNotLinkedDerived;
  final String groupByLegalEntityBrand;
  final String legalEntityBrandColumn;
}

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
    final l10n = context.l10n;

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

    final tabs = _tabViews(state, notifier, authState);
    final groups = _sidebarGroups(context);
    final items = groups.expand((group) => group.items).toList(growable: false);
    final safeIndex = _tabIndex.clamp(0, tabs.length - 1);
    final selected = items[safeIndex];

    return ToastSidebar(
      key: const Key('admin_root'),
      title: l10n.superAdminTitle,
      groups: groups,
      selectedIndex: safeIndex,
      onItemSelected: (index) => setState(() => _tabIndex = index),
      topBarTrailing: MediaQuery.sizeOf(context).width < 600
          ? const AppNavBar()
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppNavBar(),
                const SizedBox(width: 10),
                ToastStatusBadge(
                  label: l10n.superAdminHq,
                  color: AppColors.statusOccupied,
                  compact: true,
                ),
              ],
            ),
      bottomItems: [
        ToastSidebarItem(
          icon: Icons.logout,
          label: l10n.logout,
          urgency: ToastSidebarUrgency.backOffice,
          itemKey: const Key('logout_button'),
          onTap: () => ref.read(authProvider.notifier).logout(),
        ),
      ],
      body: LayoutBuilder(
        builder: (context, constraints) {
          final compactContext =
              constraints.maxWidth < 600 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.5;
          final contextHeader = compactContext
              ? ToastWorkSurface(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        selected.label,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        selected.helperLabel ?? l10n.superAdminDefaultSubtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ToastStatusBadge(
                        label: _superAdminUrgencyLabel(
                          context,
                          selected.urgency,
                        ),
                        color: _superAdminUrgencyColor(selected.urgency),
                        compact: true,
                      ),
                    ],
                  ),
                )
              : ToastWorkSurface(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      ToastSelectedContextHeader(
                        title: selected.label,
                        subtitle:
                            selected.helperLabel ??
                            l10n.superAdminDefaultSubtitle,
                        urgentReason: _superAdminUrgencyCopy(
                          context,
                          selected.urgency,
                        ),
                        noteColor: _superAdminUrgencyNoteColor(
                          selected.urgency,
                        ),
                        noteBackgroundColor: _superAdminUrgencyNoteBackground(
                          selected.urgency,
                        ),
                        noteIcon: _superAdminUrgencyNoteIcon(selected.urgency),
                        trailing: ToastStatusBadge(
                          label: _superAdminUrgencyLabel(
                            context,
                            selected.urgency,
                          ),
                          color: _superAdminUrgencyColor(selected.urgency),
                          compact: true,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                        child: ToastMetricStrip(
                          metrics: [
                            ToastMetric(
                              label: l10n.superAdminStores,
                              value: '${state.filteredRestaurants.length}',
                            ),
                            ToastMetric(
                              label: l10n.superAdminBrands,
                              value: '${state.brands.length}',
                            ),
                            ToastMetric(
                              label: l10n.superAdminSurface,
                              value: '${safeIndex + 1}/${items.length}',
                              tone: _superAdminUrgencyColor(selected.urgency),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: contextHeader,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: tabs[safeIndex],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _tabViews(
    SuperAdminState state,
    SuperAdminNotifier notifier,
    PosAuthState authState,
  ) {
    return [
      _RestaurantsTab(
        state: state,
        notifier: notifier,
        onGoToAdmin: (storeId) => context.go('/admin/$storeId'),
      ),
      _AllReportsTab(state: state, notifier: notifier),
      const _QcOverviewTab(),
      const _QcGlobalTemplatesTab(),
      _SystemSettingsTab(authState: authState),
    ];
  }

  List<ToastSidebarGroup> _sidebarGroups(BuildContext context) {
    final l10n = context.l10n;
    return [
      ToastSidebarGroup(
        title: l10n.superAdminNetworkOps,
        items: [
          ToastSidebarItem(
            icon: Icons.store,
            label: l10n.superAdminStores,
            urgency: ToastSidebarUrgency.live,
            helperLabel: l10n.superAdminStoresHelper,
            itemKey: const Key('super_admin_nav_stores'),
          ),
          ToastSidebarItem(
            icon: Icons.bar_chart,
            label: l10n.superAdminAllReports,
            urgency: ToastSidebarUrgency.backOffice,
            helperLabel: l10n.superAdminReportsHelper,
            itemKey: const Key('super_admin_nav_reports'),
          ),
        ],
      ),
      ToastSidebarGroup(
        title: l10n.superAdminCompliance,
        items: [
          ToastSidebarItem(
            icon: Icons.fact_check,
            label: l10n.superAdminQcStatus,
            urgency: ToastSidebarUrgency.exception,
            helperLabel: l10n.superAdminQcStatusHelper,
            itemKey: const Key('super_admin_nav_qc_status'),
          ),
          ToastSidebarItem(
            icon: Icons.rule,
            label: l10n.superAdminQcTemplate,
            urgency: ToastSidebarUrgency.backOffice,
            helperLabel: l10n.superAdminQcTemplateHelper,
            itemKey: const Key('super_admin_nav_qc_template'),
          ),
        ],
      ),
      ToastSidebarGroup(
        title: l10n.superAdminGovernance,
        items: [
          ToastSidebarItem(
            icon: Icons.settings,
            label: l10n.superAdminSystemSettings,
            urgency: ToastSidebarUrgency.backOffice,
            helperLabel: l10n.superAdminSystemSettingsHelper,
            itemKey: const Key('super_admin_nav_system_settings'),
          ),
        ],
      ),
    ];
  }
}

String _superAdminUrgencyLabel(
  BuildContext context,
  ToastSidebarUrgency urgency,
) {
  final l10n = context.l10n;
  return switch (urgency) {
    ToastSidebarUrgency.live => l10n.superAdminNetworkOps,
    ToastSidebarUrgency.exception => l10n.inventoryExceptionQueue,
    ToastSidebarUrgency.backOffice => l10n.superAdminGovernance,
  };
}

String _superAdminUrgencyCopy(
  BuildContext context,
  ToastSidebarUrgency urgency,
) {
  final l10n = context.l10n;
  return switch (urgency) {
    ToastSidebarUrgency.live => l10n.superAdminUrgencyLiveCopy,
    ToastSidebarUrgency.exception => l10n.superAdminUrgencyExceptionCopy,
    ToastSidebarUrgency.backOffice => l10n.superAdminUrgencyBackOfficeCopy,
  };
}

Color _superAdminUrgencyColor(ToastSidebarUrgency urgency) {
  return switch (urgency) {
    ToastSidebarUrgency.live => AppColors.amber500,
    ToastSidebarUrgency.exception => AppColors.statusOccupied,
    ToastSidebarUrgency.backOffice => AppColors.textSecondary,
  };
}

Color _superAdminUrgencyNoteColor(ToastSidebarUrgency urgency) {
  return switch (urgency) {
    ToastSidebarUrgency.live => PosColors.accent,
    ToastSidebarUrgency.exception => PosColors.warning,
    ToastSidebarUrgency.backOffice => PosColors.textSecondary,
  };
}

Color _superAdminUrgencyNoteBackground(ToastSidebarUrgency urgency) {
  return switch (urgency) {
    ToastSidebarUrgency.live => PosColors.accentMuted,
    ToastSidebarUrgency.exception => PosColors.warningMuted,
    ToastSidebarUrgency.backOffice => PosColors.panelMuted,
  };
}

IconData _superAdminUrgencyNoteIcon(ToastSidebarUrgency urgency) {
  return switch (urgency) {
    ToastSidebarUrgency.live => Icons.travel_explore_rounded,
    ToastSidebarUrgency.exception => Icons.priority_high_rounded,
    ToastSidebarUrgency.backOffice => Icons.policy_rounded,
  };
}

class _QcGlobalTemplatesTab extends ConsumerWidget {
  const _QcGlobalTemplatesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templatesAsync = ref.watch(globalQcTemplatesProvider);
    final notifier = ref.read(qcTemplateProvider.notifier);
    final picker = ImagePicker();
    final l10n = context.l10n;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final title = Text(
              l10n.superAdminSharedQcTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.system(
                color: AppColors.amber500,
                fontSize: 30,
                letterSpacing: 1,
              ),
            );
            final action = FilledButton.icon(
              key: const Key('super_admin_global_template_add_action'),
              onPressed: () =>
                  _showGlobalTemplateSheet(context, ref, picker, notifier),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              icon: const Icon(Icons.add),
              label: Text(l10n.superAdminAddSharedCriterion),
            );

            if (constraints.maxWidth < 520) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  title,
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerRight, child: action),
                ],
              );
            }

            return Row(
              children: [
                Expanded(child: title),
                const SizedBox(width: 12),
                action,
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        Expanded(
          child: templatesAsync.when(
            data: (templates) {
              if (templates.isEmpty) {
                return Center(
                  child: Text(
                    l10n.superAdminNoSharedTemplates,
                    style: AppFonts.system(color: AppColors.textSecondary),
                  ),
                );
              }
              final grouped = <String, List<Map<String, dynamic>>>{};
              for (final template in templates) {
                final category =
                    template['category']?.toString() ?? l10n.qcCategoryOther;
                grouped.putIfAbsent(category, () => []).add(template);
              }

              return ListView(
                key: const Key('super_admin_qc_templates_scroll'),
                primary: false,
                physics: _superAdminScrollPhysics,
                padding: _superAdminScrollPadding,
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
                        style: AppFonts.system(
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
                                    style: AppFonts.system(
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
                                      l10n.superAdminSharedAcrossStores,
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
                                showSuccessToast(
                                  context,
                                  l10n.superAdminDeactivated,
                                );
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
                style: AppFonts.system(color: AppColors.statusCancelled),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.superAdminSharedScopeHint,
          style: AppFonts.system(color: AppColors.textSecondary, fontSize: 12),
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
    final l10n = context.l10n;
    final categoryController = TextEditingController(
      text: initial?['category']?.toString() ?? '',
    );
    final criteriaController = TextEditingController(
      text: initial?['criteria_text']?.toString() ?? '',
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
              key: const Key('super_admin_global_template_sheet'),
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
                        ? l10n.superAdminEditSharedCriterion
                        : l10n.superAdminAddSharedCriterion,
                    style: AppFonts.system(
                      color: AppColors.amber500,
                      fontSize: 30,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: categoryController,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.superAdminCategory,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: criteriaController,
                    minLines: 2,
                    maxLines: 4,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.superAdminCriterionDetails,
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
                        label: Text(l10n.superAdminUploadReferencePhoto),
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
                        showSuccessToast(context, l10n.superAdminSaved);
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.amber500,
                        foregroundColor: AppColors.surface0,
                      ),
                      child: Text(l10n.save),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    await Future<void>.delayed(kThemeAnimationDuration);
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
    final l10n = context.l10n;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.superAdminQcOverviewTitle,
          style: AppFonts.system(
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
                    l10n.superAdminQcNoData,
                    style: AppFonts.system(color: AppColors.textSecondary),
                  ),
                );
              }

              return ListView.separated(
                key: const Key('super_admin_qc_overview_scroll'),
                primary: false,
                physics: _superAdminScrollPhysics,
                padding: _superAdminScrollPadding,
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
                              style: AppFonts.system(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              '${coverage.toStringAsFixed(0)}%',
                              style: AppFonts.system(
                                color: AppColors.amber500,
                                fontSize: 24,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              failCount,
                              style: AppFonts.system(
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
                              style: AppFonts.system(
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
                style: AppFonts.system(color: AppColors.statusCancelled),
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
    final l10n = context.l10n;
    final hierarchyCopy = _SuperAdminHierarchyCopy(context);
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final title = Text(
              l10n.superAdminStores,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.system(
                color: AppColors.amber500,
                fontSize: 28,
                letterSpacing: 1.0,
              ),
            );
            final actions = [
              OutlinedButton.icon(
                onPressed: _openOfficeSystem,
                icon: const Icon(Icons.business),
                label: Text(l10n.superAdminGoToOfficeSystem),
              ),
              FilledButton.icon(
                key: const Key('super_admin_add_store_action'),
                onPressed: () =>
                    _showRestaurantSheet(context, notifier: notifier),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                icon: const Icon(Icons.add_business),
                label: Text(l10n.superAdminAddStore),
              ),
            ];

            if (constraints.maxWidth < 560 ||
                MediaQuery.textScalerOf(context).scale(1) > 1.5) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  title,
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: actions,
                  ),
                ],
              );
            }

            return Row(
              children: [
                Expanded(child: title),
                const SizedBox(width: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: actions,
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _ownerTypeChip(
                null,
                l10n.superAdminFilterAll,
                state.selectedOwnerType,
              ),
              const SizedBox(width: 6),
              _ownerTypeChip(
                'internal',
                hierarchyCopy.filterInternal,
                state.selectedOwnerType,
              ),
              const SizedBox(width: 6),
              _ownerTypeChip(
                'external',
                hierarchyCopy.filterExternal,
                state.selectedOwnerType,
              ),
              const SizedBox(width: 16),
              Text(
                hierarchyCopy.legalEntity,
                style: AppFonts.system(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String?>(
                value: state.selectedTaxEntityId,
                dropdownColor: AppColors.surface1,
                hint: Text(
                  l10n.superAdminSelectLegalEntity,
                  style: AppFonts.system(color: AppColors.textPrimary),
                ),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(l10n.superAdminFilterAll),
                  ),
                  ...state.filteredTaxEntities.map(
                    (entity) => DropdownMenuItem<String?>(
                      value: entity.id,
                      child: Text(entity.name),
                    ),
                  ),
                ],
                onChanged: notifier.setTaxEntityFilter,
              ),
              const SizedBox(width: 16),
              Text(
                l10n.superAdminBrand,
                style: AppFonts.system(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String?>(
                value: state.selectedBrandId,
                dropdownColor: AppColors.surface1,
                hint: Text(
                  l10n.superAdminFilterAll,
                  style: AppFonts.system(color: AppColors.textPrimary),
                ),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(
                      l10n.superAdminFilterAll,
                      style: AppFonts.system(color: AppColors.textPrimary),
                    ),
                  ),
                  DropdownMenuItem<String?>(
                    value: kUnclassifiedBrandFilter,
                    child: Text(
                      l10n.superAdminUncategorized,
                      style: AppFonts.system(color: AppColors.textPrimary),
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
                        style: AppFonts.system(color: AppColors.textPrimary),
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
                  primary: false,
                  physics: _superAdminScrollPhysics,
                  padding: _superAdminScrollPadding,
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
                                  style: AppFonts.system(
                                    color: AppColors.textPrimary,
                                    fontSize: 24,
                                  ),
                                ),
                                Text(
                                  '${restaurant.slug} • ${restaurant.address}',
                                  style: AppFonts.system(
                                    color: AppColors.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  l10n.superAdminLegalEntityPrefix(
                                    restaurant.taxEntityName ??
                                        l10n.superAdminUncategorized,
                                  ),
                                  style: AppFonts.system(
                                    color: AppColors.textSecondary,
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  l10n.superAdminBrandPrefix(
                                    restaurant.brandName ??
                                        l10n.superAdminUncategorized,
                                  ),
                                  style: AppFonts.system(
                                    color: AppColors.textSecondary,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          _ownerTypeBadge(context, restaurant.ownerType),
                          const SizedBox(width: 6),
                          _officeIntegrationBadge(
                            context,
                            restaurant.isOfficeLinked,
                          ),
                          const SizedBox(width: 6),
                          _modeBadge(context, restaurant.operationMode),
                          const SizedBox(width: 10),
                          OutlinedButton(
                            key: Key(
                              'super_admin_manage_store_${restaurant.id}',
                            ),
                            onPressed: () => _showRestaurantSheet(
                              context,
                              notifier: notifier,
                              initial: restaurant,
                            ),
                            child: Text(l10n.superAdminManageStore),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            key: Key(
                              'super_admin_store_setup_${restaurant.id}',
                            ),
                            onPressed: restaurant.isActive
                                ? () => context.go(
                                    '/store-setup/${restaurant.id}',
                                  )
                                : null,
                            icon: const Icon(Icons.rocket_launch_outlined),
                            label: Text(l10n.storeSetupEntry),
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
                            child: Text(l10n.superAdminGoToAdmin),
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
        style: AppFonts.system(
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
    final l10n = context.l10n;
    final isExternal = ownerType == 'external';
    final color = isExternal
        ? const Color(0xFFE57373)
        : const Color(0xFF66BB6A);
    final label = isExternal
        ? l10n.superAdminBadgeExternal
        : l10n.superAdminBadgeInternal;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: AppFonts.system(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _officeIntegrationBadge(BuildContext context, bool isLinked) {
    final l10n = context.l10n;
    final color = isLinked
        ? AppColors.statusAvailable
        : AppColors.textSecondary;
    return Tooltip(
      message: isLinked
          ? l10n.superAdminOfficeLinkedDerived
          : l10n.superAdminOfficeNotLinkedDerived,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color),
        ),
        child: Text(
          isLinked
              ? l10n.superAdminOfficeLinked
              : l10n.superAdminOfficeNotLinked,
          style: AppFonts.system(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _modeBadge(BuildContext context, String mode) {
    final l10n = context.l10n;
    final normalized = mode.toLowerCase();
    final color = switch (normalized) {
      'buffet' => AppColors.amber500,
      'hybrid' => const Color(0xFF3A7BD5),
      _ => AppColors.textSecondary,
    };
    final label = switch (normalized) {
      'buffet' => l10n.superAdminOperationModeBuffet,
      'hybrid' => l10n.superAdminOperationModeHybrid,
      _ => l10n.superAdminOperationModeStandard,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: AppFonts.system(
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
    final l10n = context.l10n;
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
        (state.filteredTaxEntities.length == 1
            ? state.filteredTaxEntities.first.id
            : null);
    if (selectedTaxEntityId != null &&
        !state.taxEntities.any((entity) => entity.id == selectedTaxEntityId)) {
      selectedTaxEntityId = null;
    }
    var availableBrands = selectedTaxEntityId == null
        ? const <Map<String, dynamic>>[]
        : state.brandsForTaxEntity(selectedTaxEntityId);
    final filterBrandId = state.selectedBrandId == kUnclassifiedBrandFilter
        ? null
        : state.selectedBrandId;
    String? selectedBrandId =
        initial?.brandId ??
        filterBrandId ??
        (availableBrands.length == 1
            ? availableBrands.first['id']?.toString()
            : null);
    if (selectedBrandId != null &&
        !availableBrands.any(
          (brand) => brand['id']?.toString() == selectedBrandId,
        )) {
      selectedBrandId = null;
    }

    Future<void> save() async {
      final name = nameController.text.trim();
      final slug = slugController.text.trim();
      final address = addressController.text.trim();
      if (name.isEmpty || slug.isEmpty) {
        return;
      }
      if (selectedTaxEntityId == null || selectedTaxEntityId!.isEmpty) {
        showErrorToast(context, l10n.superAdminLegalEntityRequiredBeforeStore);
        return;
      }
      if (selectedBrandId == null || selectedBrandId!.isEmpty) {
        showErrorToast(context, l10n.superAdminBrandRequired);
        return;
      }
      final taxEntityId = selectedTaxEntityId!;
      final brandId = selectedBrandId!;
      final charge = (operationMode == 'buffet' || operationMode == 'hybrid')
          ? parseDecimalInput(chargeController.text)
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
        final createdStoreId = isEdit
            ? initial.id
            : notifier.restaurantIdForSlug(slug);
        showSuccessToast(
          context,
          isEdit ? l10n.superAdminStoreUpdated : l10n.superAdminStoreCreated,
        );
        Navigator.of(context).pop();
        if (!isEdit && createdStoreId != null) {
          await Future<void>.delayed(Duration.zero);
          if (!context.mounted) return;
          final continueSetup = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              key: const Key('super_admin_continue_store_setup_dialog'),
              title: Text(l10n.storeSetupTitle),
              content: Text(l10n.storeSetupTemplateDescription),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(l10n.close),
                ),
                FilledButton(
                  key: const Key('super_admin_continue_store_setup'),
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(l10n.storeSetupNext),
                ),
              ],
            ),
          );
          if (continueSetup == true && context.mounted) {
            context.go('/store-setup/$createdStoreId');
          }
        }
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
              key: const Key('super_admin_store_sheet'),
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
                    isEdit ? l10n.superAdminEditStore : l10n.superAdminAddStore,
                    style: AppFonts.system(
                      color: AppColors.amber500,
                      fontSize: 30,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameController,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.superAdminStoreName,
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
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.superAdminStoreAddress,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: slugController,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.superAdminStoreSlug,
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: operationMode,
                    dropdownColor: AppColors.surface1,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.superAdminOperationMode,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'standard',
                        child: Text(l10n.superAdminOperationModeStandard),
                      ),
                      DropdownMenuItem(
                        value: 'buffet',
                        child: Text(l10n.superAdminOperationModeBuffet),
                      ),
                      DropdownMenuItem(
                        value: 'hybrid',
                        child: Text(l10n.superAdminOperationModeHybrid),
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
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.superAdminLegalEntity,
                      hintText: l10n.superAdminSelectLegalEntity,
                    ),
                    items: state.filteredTaxEntities
                        .map(
                          (entity) => DropdownMenuItem<String?>(
                            value: entity.id,
                            child: Text(entity.name),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      setModalState(() {
                        selectedTaxEntityId = value;
                        availableBrands = value == null
                            ? const <Map<String, dynamic>>[]
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
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.superAdminBrand,
                      hintText: l10n.superAdminSelectBrand,
                      helperText: l10n.superAdminBrandRequiredBeforeStore,
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
                  Text(
                    l10n.superAdminOfficeIntegration,
                    style: AppFonts.system(
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    selectedTaxEntityId == null
                        ? l10n.superAdminSelectLegalEntityFirst
                        : state.taxEntities
                              .firstWhere(
                                (entity) => entity.id == selectedTaxEntityId,
                              )
                              .isInternal
                        ? l10n.superAdminOfficeLinkedDerived
                        : l10n.superAdminOfficeNotLinkedDerived,
                    style: AppFonts.system(color: AppColors.textPrimary),
                  ),
                  if (operationMode == 'buffet' ||
                      operationMode == 'hybrid') ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: chargeController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      style: AppFonts.system(color: AppColors.textPrimary),
                      decoration: InputDecoration(
                        labelText: l10n.superAdminPerPersonCharge,
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
                      child: Text(l10n.superAdminSaveUpper),
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
                              l10n.superAdminStoreDeactivated,
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
                        child: Text(l10n.superAdminDeleteDeactivate),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        key: const Key('super_admin_close_store_button'),
                        onPressed: () =>
                            _confirmAndCloseStore(context, notifier, initial),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.statusCancelled,
                          foregroundColor: Colors.white,
                        ),
                        child: Text(l10n.superAdminCloseStore),
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

    await Future<void>.delayed(kThemeAnimationDuration);
    nameController.dispose();
    addressController.dispose();
    slugController.dispose();
    chargeController.dispose();
  }

  Future<void> _confirmAndCloseStore(
    BuildContext context,
    SuperAdminNotifier notifier,
    SuperRestaurant store,
  ) async {
    final l10n = context.l10n;
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        String? errorText;
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              key: const Key('super_admin_close_store_dialog'),
              backgroundColor: AppColors.surface1,
              title: Text(
                l10n.superAdminCloseStoreTitle,
                style: AppFonts.system(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.superAdminCloseStoreMessage,
                    style: AppFonts.system(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('super_admin_close_store_reason'),
                    controller: reasonController,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.superAdminCloseStoreReasonLabel,
                      errorText: errorText,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(l10n.cancel),
                ),
                FilledButton(
                  key: const Key('super_admin_close_store_confirm'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.statusCancelled,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    if (reasonController.text.trim().isEmpty) {
                      setDialogState(() {
                        errorText = l10n.superAdminCloseStoreReasonRequired;
                      });
                      return;
                    }
                    Navigator.of(dialogContext).pop(true);
                  },
                  child: Text(l10n.superAdminCloseStoreConfirm),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed != true) {
      await Future<void>.delayed(kThemeAnimationDuration);
      reasonController.dispose();
      return;
    }

    final result = await notifier.closeStore(
      store.id,
      reasonController.text.trim(),
    );
    await Future<void>.delayed(kThemeAnimationDuration);
    reasonController.dispose();
    if (!context.mounted) return;

    if (result.isSuccess) {
      showSuccessToast(context, l10n.superAdminStoreClosed);
      Navigator.of(context).pop();
    } else {
      final error = result.error ?? '';
      showErrorToast(
        context,
        error.contains('STORE_HAS_OPEN_ORDERS')
            ? l10n.superAdminCloseStoreOpenOrders
            : error,
      );
    }
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
  ) {
    final map = <String, _BrandRevenueRow>{};
    for (final row in rows) {
      final restaurant = restaurants
          .where((r) => r.id == row.storeId)
          .cast<SuperRestaurant?>()
          .firstWhere((r) => r != null, orElse: () => null);
      final key = restaurant?.brandId ?? kUnclassifiedBrandFilter;
      final name = restaurant?.brandName ?? 'Uncategorized';
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
      brands
          .putIfAbsent(brandId, () => _RevenueGroupAccumulator(brandName))
          .add(row);
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
    final l10n = context.l10n;
    final summary = state.reportSummary;
    final currency = NumberFormat('#,###', 'vi_VN');
    final brandRows = summary == null
        ? const <_BrandRevenueRow>[]
        : _brandRows(summary.rows, state.restaurants);
    final legalEntityBrandRows = summary == null
        ? const <_RevenueGroupRow>[]
        : _legalEntityBrandRows(
            summary.rows,
            state.restaurants,
            l10n.superAdminUncategorized,
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        final estimatedHeaderHeight = brandRows.isNotEmpty ? 470.0 : 330.0;
        final rawTableHeight = constraints.maxHeight - estimatedHeaderHeight;
        final tableHeight = rawTableHeight.clamp(320.0, 520.0).toDouble();

        return ListView(
          key: const Key('super_admin_reports_scroll'),
          primary: false,
          physics: _superAdminScrollPhysics,
          padding: _superAdminScrollPadding,
          children: [
            Text(
              l10n.superAdminAllReportsTitle,
              style: AppFonts.system(color: AppColors.amber500, fontSize: 30),
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
                    l10n.superAdminAllStores,
                    style: AppFonts.system(color: AppColors.textPrimary),
                  ),
                  items: [
                    DropdownMenuItem<SuperRestaurant?>(
                      value: null,
                      child: Text(
                        l10n.superAdminAllStores,
                        style: AppFonts.system(color: AppColors.textPrimary),
                      ),
                    ),
                    ...state.restaurants.map((restaurant) {
                      return DropdownMenuItem<SuperRestaurant?>(
                        value: restaurant,
                        child: Text(
                          restaurant.name,
                          style: AppFonts.system(color: AppColors.textPrimary),
                        ),
                      );
                    }),
                  ],
                  onChanged: (value) async {
                    notifier.selectRestaurant(value);
                    await notifier.loadAllReports(
                      selectedRestaurantId: value?.id,
                    );
                  },
                ),
                DropdownButton<String>(
                  value: _reportGrouping,
                  dropdownColor: AppColors.surface1,
                  items: [
                    DropdownMenuItem<String>(
                      value: 'store',
                      child: Text(
                        l10n.superAdminGroupByStore,
                        style: AppFonts.system(color: AppColors.textPrimary),
                      ),
                    ),
                    DropdownMenuItem<String>(
                      value: 'brand',
                      child: Text(
                        l10n.superAdminGroupByBrand,
                        style: AppFonts.system(color: AppColors.textPrimary),
                      ),
                    ),
                    DropdownMenuItem<String>(
                      value: 'legal_entity_brand',
                      child: Text(
                        l10n.superAdminGroupByLegalEntityBrand,
                        style: AppFonts.system(color: AppColors.textPrimary),
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
                  label: Text(l10n.superAdminViewDetailedReports),
                ),
                FilledButton.icon(
                  key: const Key('super_admin_restaurant_sales_export_link'),
                  onPressed: () => context.go('/restaurant-sales-export'),
                  icon: const Icon(Icons.download_outlined),
                  label: Text(l10n.restaurantSalesExportDownload),
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
                    l10n.superAdminTotalRevenue,
                    '₫${currency.format(summary.totalRevenue)}',
                  ),
                  _summaryCard(
                    l10n.superAdminDineIn,
                    '₫${currency.format(summary.dineInRevenue)}',
                  ),
                  _summaryCard(
                    l10n.superAdminDelivery,
                    '₫${currency.format(summary.deliveryRevenue)}',
                  ),
                ],
              ),
            if (brandRows.isNotEmpty) ...[
              const SizedBox(height: 12),
              _BrandRevenueChart(rows: brandRows),
            ],
            const SizedBox(height: 16),
            SizedBox(
              key: const Key('super_admin_reports_table_region'),
              height: tableHeight,
              child: summary == null || summary.rows.isEmpty
                  ? Center(
                      child: Text(
                        l10n.superAdminNoReportData,
                        style: AppFonts.system(
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
                              'brand' => l10n.superAdminBrandColumn,
                              'legal_entity_brand' =>
                                l10n.superAdminLegalEntityBrandColumn,
                              _ => l10n.superAdminStoreColumn,
                            },
                            dineInLabel: l10n.superAdminDineIn,
                            deliveryLabel: l10n.superAdminDelivery,
                            totalLabel: l10n.superAdminTotal,
                          ),
                          Expanded(
                            child: _reportGrouping == 'brand'
                                ? ListView.builder(
                                    primary: false,
                                    physics: _superAdminScrollPhysics,
                                    padding: _superAdminScrollPadding,
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
                                            _cell(
                                              '₫${currency.format(row.total)}',
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  )
                                : _reportGrouping == 'legal_entity_brand'
                                ? ListView.builder(
                                    primary: false,
                                    physics: _superAdminScrollPhysics,
                                    padding: _superAdminScrollPadding,
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
                                    primary: false,
                                    physics: _superAdminScrollPhysics,
                                    padding: _superAdminScrollPadding,
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
                                            _cell(
                                              '₫${currency.format(row.total)}',
                                            ),
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
      },
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
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          Text(
            value,
            style: AppFonts.system(color: AppColors.amber500, fontSize: 30),
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
        style: AppFonts.system(
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

  double _axisInterval(double maxY) {
    if (maxY <= 0) return 1;
    return maxY / 4;
  }

  String _formatAxisCurrency(double value) {
    final abs = value.abs();
    if (abs >= 1000000000) {
      return '₫${(value / 1000000000).toStringAsFixed(1)}B';
    }
    if (abs >= 1000000) {
      return '₫${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (abs >= 1000) {
      return '₫${(value / 1000).toStringAsFixed(0)}K';
    }
    return '₫${value.toStringAsFixed(0)}';
  }

  String _shortAxisLabel(String value) {
    final trimmed = value.trim();
    if (trimmed.length <= 12) return trimmed;
    return '${trimmed.substring(0, 12)}...';
  }

  @override
  Widget build(BuildContext context) {
    final maxY = rows
        .map((e) => e.total)
        .fold<double>(0, (a, b) => a > b ? a : b);
    final chartMaxY = maxY <= 0 ? 1.0 : maxY * 1.2;
    final interval = _axisInterval(chartMaxY);

    return Container(
      height: 300,
      padding: const EdgeInsets.fromLTRB(8, 14, 14, 8),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(14),
      ),
      child: BarChart(
        BarChartData(
          minY: 0,
          maxY: chartMaxY,
          alignment: BarChartAlignment.spaceAround,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: interval,
            getDrawingHorizontalLine: (_) =>
                const FlLine(color: AppColors.surface2, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 62,
                interval: interval,
                getTitlesWidget: (value, meta) {
                  if (value < 0 || value > meta.max) {
                    return const SizedBox.shrink();
                  }
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    space: 6,
                    child: SizedBox(
                      width: 56,
                      child: Text(
                        _formatAxisCurrency(value),
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: AppFonts.system(
                          color: AppColors.textSecondary,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 42,
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  if (index < 0 || index >= rows.length) {
                    return const SizedBox.shrink();
                  }
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    space: 8,
                    child: SizedBox(
                      width: 64,
                      child: Text(
                        _shortAxisLabel(rows[index].name),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.system(
                          color: AppColors.textSecondary,
                          fontSize: 10,
                          height: 1.15,
                          fontWeight: FontWeight.w600,
                        ),
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
    final l10n = context.l10n;
    final projectRef =
        Uri.tryParse(AppConstants.supabaseUrl)?.host ??
        AppConstants.supabaseUrl;
    final email = authState.user?.email?.toString() ?? '-';
    final role = authState.role?.toString() ?? '-';

    return SingleChildScrollView(
      primary: false,
      physics: _superAdminScrollPhysics,
      padding: _superAdminScrollPadding,
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
              l10n.superAdminSystemSettingsTitle,
              style: AppFonts.system(color: AppColors.amber500, fontSize: 30),
            ),
            const SizedBox(height: 10),
            _infoRow(l10n.email, email),
            _infoRow(l10n.role, role),
            _infoRow(l10n.version, 'GLOBOS POS v1.0.0'),
            _infoRow(l10n.supabase, projectRef),
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
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppFonts.system(
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
