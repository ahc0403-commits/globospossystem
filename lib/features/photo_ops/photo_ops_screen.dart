import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/services/attendance_service.dart';
import '../../core/services/inventory_service.dart';
import '../../core/ui/app_primitives.dart';
import '../../core/ui/app_theme.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/auth/auth_state.dart';
import '../../widgets/app_nav_bar.dart';
import 'photo_ops_provider.dart';
import 'photo_ops_sales_export.dart';
import 'photo_ops_service.dart';

class PhotoOpsScreen extends ConsumerStatefulWidget {
  const PhotoOpsScreen({super.key});

  @override
  ConsumerState<PhotoOpsScreen> createState() => _PhotoOpsScreenState();
}

class _PhotoOpsScreenState extends ConsumerState<PhotoOpsScreen> {
  String? _lastLoadedStoreId;
  int _selectedSurfaceIndex = 0;
  bool _isExportingSales = false;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final state = ref.watch(photoOpsProvider);
    final notifier = ref.read(photoOpsProvider.notifier);
    final activeStoreId = auth.storeId;
    final surfaceAccess = PhotoOpsSurfaceAccess.forRole(auth.role);
    final l10n = context.l10n;
    String activeStoreName = l10n.photoOpsNoActiveStore;

    for (final store in auth.accessibleStores) {
      if (store.id == activeStoreId) {
        activeStoreName = store.name;
        break;
      }
    }

    if (activeStoreId != null && _lastLoadedStoreId != activeStoreId) {
      _lastLoadedStoreId = activeStoreId;
      Future.microtask(notifier.load);
    }

    final surfaceMeta = _surfaceMeta(context, surfaceAccess);
    final safeSurfaceIndex = _selectedSurfaceIndex.clamp(
      0,
      surfaceMeta.length - 1,
    );
    final selectedSurface = surfaceMeta[safeSurfaceIndex];
    final contentChildren = <Widget>[
      if (surfaceAccess.showManagementSurfaces) ...[
        _HeroBanner(
          role: auth.role,
          activeStoreName: activeStoreName,
          storeCount: auth.accessibleStores.length,
        ),
        const SizedBox(height: 18),
      ],
      if (state.isLoading && state.data == null)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 80),
          child: Center(
            child: CircularProgressIndicator(color: PosColors.accent),
          ),
        )
      else if (state.error != null && state.data == null)
        _ErrorCard(message: state.error!, onRetry: notifier.load)
      else if (state.data != null) ...[
        if (surfaceAccess.showManagementSurfaces &&
            state.data!.salesWarningCode != null) ...[
          _WarningSurface(
            message: _localizedSalesWarning(context, state.data!),
          ),
          const SizedBox(height: 18),
        ],
        PhotoOpsManagementSurfaceGate(
          role: auth.role,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _KpiGrid(data: state.data!.kpi),
              const SizedBox(height: 18),
              _WorkflowSurface(
                title: l10n.photoOpsPriorityQueueTitle,
                subtitle: l10n.photoOpsPriorityQueueSubtitle,
                kind: PhotoOpsSurfaceKind.priority,
                child: _PriorityList(
                  items: _buildPriorityItems(context, state.data!.kpi),
                ),
              ),
              const SizedBox(height: 18),
              _WorkflowSurface(
                title: l10n.photoOpsSalesTitle,
                subtitle: l10n.photoOpsSalesSubtitle,
                kind: PhotoOpsSurfaceKind.backOffice,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        key: const Key('photo_ops_sales_export_button'),
                        onPressed: _isExportingSales
                            ? null
                            : _exportLegalEntitySales,
                        icon: _isExportingSales
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.download_outlined),
                        label: Text(l10n.photoOpsSalesDownloadExcel),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _SalesList(rows: state.data!.salesSummary),
                  ],
                ),
              ),
              const SizedBox(height: 18),
            ],
          ),
        ),
        _WorkflowSurface(
          title: l10n.photoOpsAttendanceTitle,
          subtitle: l10n.photoOpsAttendanceSubtitle,
          kind: PhotoOpsSurfaceKind.live,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _EmployeeAttendanceActions(
                storeId: activeStoreId!,
                onRecorded: notifier.load,
              ),
              const SizedBox(height: 12),
              _AttendanceList(rows: state.data!.recentAttendance),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _WorkflowSurface(
          title: l10n.photoOpsInventoryTitle,
          subtitle: l10n.photoOpsInventorySubtitle,
          kind: PhotoOpsSurfaceKind.priority,
          child: _InventoryList(
            rows: state.data!.inventoryAlerts,
            onAdjust: (row) => _showInventoryAdjustment(
              storeId: activeStoreId,
              row: row,
              onRecorded: notifier.load,
            ),
          ),
        ),
        const SizedBox(height: 18),
        PhotoOpsManagementSurfaceGate(
          role: auth.role,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _WorkflowSurface(
                title: l10n.photoOpsSalaryTitle,
                subtitle: l10n.photoOpsSalarySubtitle,
                kind: PhotoOpsSurfaceKind.backOffice,
                child: _PayrollList(rows: state.data!.payrollPreview),
              ),
              const SizedBox(height: 18),
              _WorkflowSurface(
                title: l10n.photoOpsStoreScopeTitle,
                subtitle: l10n.photoOpsStoreScopeSubtitle,
                kind: PhotoOpsSurfaceKind.backOffice,
                child: _StoreScopeList(
                  stores: auth.accessibleStores,
                  activeStoreId: activeStoreId,
                ),
              ),
            ],
          ),
        ),
      ],
    ];

    Widget surface({required Widget child}) {
      return ToastOperationalQueuePane(
        title: selectedSurface.title,
        subtitle: selectedSurface.subtitle,
        headerBottom: _PhotoOpsHeaderSummary(
          selectedSurface: selectedSurface,
          role: auth.role,
          activeStoreName: activeStoreName,
          storeCount: auth.accessibleStores.length,
          data: state.data,
          surfaceAccess: surfaceAccess,
        ),
        child: child,
      );
    }

    final sidebarItems = surfaceAccess.showManagementSurfaces
        ? [
            ToastSidebarPanelItem(
              icon: Icons.dashboard_outlined,
              label: l10n.photoOpsPriorityQueueTitle,
              sectionLabel: l10n.photoOpsHeroEyebrow,
            ),
            ToastSidebarPanelItem(
              icon: Icons.payments_outlined,
              label: l10n.photoOpsSalesTitle,
              sectionLabel: l10n.photoOpsSalesTitle,
            ),
            ToastSidebarPanelItem(
              icon: Icons.schedule_outlined,
              label: l10n.photoOpsAttendanceTitle,
              sectionLabel: l10n.photoOpsAttendanceTitle,
            ),
            ToastSidebarPanelItem(
              icon: Icons.inventory_2_outlined,
              label: l10n.photoOpsInventoryTitle,
              sectionLabel: l10n.photoOpsInventoryTitle,
            ),
            ToastSidebarPanelItem(
              icon: Icons.group_outlined,
              label: l10n.photoOpsSalaryTitle,
              sectionLabel: l10n.photoOpsSalaryTitle,
            ),
          ]
        : [
            ToastSidebarPanelItem(
              icon: Icons.schedule_outlined,
              label: l10n.photoOpsAttendanceTitle,
              sectionLabel: l10n.photoOpsAttendanceTitle,
            ),
            ToastSidebarPanelItem(
              icon: Icons.inventory_2_outlined,
              label: l10n.photoOpsInventoryTitle,
              sectionLabel: l10n.photoOpsInventoryTitle,
            ),
          ];

    return KeyedSubtree(
      key: const Key('photo_ops_root'),
      child: LayoutBuilder(
        builder: (context, shellConstraints) {
          final compactShell = shellConstraints.maxWidth < 900;
          return ToastShell(
            sidebar: compactShell
                ? null
                : ToastSidebarPanel(
                    title: l10n.photoOpsBrandName,
                    subtitle: activeStoreName,
                    selectedIndex: safeSurfaceIndex,
                    onItemSelected: (index) =>
                        setState(() => _selectedSurfaceIndex = index),
                    items: sidebarItems,
                  ),
            topbar: ToastTopbar(
              title: l10n.photoOpsBrandName,
              actions: const [AppNavBar()],
              trailing: compactShell
                  ? null
                  : ToastStatusBadge(
                      label: activeStoreName,
                      color: _surfaceTone(selectedSurface.kind),
                      key: const Key('photo_ops_active_store_badge'),
                    ),
            ),
            child: Column(
              children: [
                if (compactShell) ...[
                  _PhotoOpsCompactNav(
                    items: sidebarItems,
                    selectedIndex: safeSurfaceIndex,
                    onItemSelected: (index) =>
                        setState(() => _selectedSurfaceIndex = index),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth < 1120 ||
                          MediaQuery.textScalerOf(context).scale(1) > 1.5) {
                        return RefreshIndicator(
                          onRefresh: notifier.load,
                          color: PosColors.accent,
                          child: ToastResponsiveScrollBody(
                            maxWidth: 1360,
                            children: [
                              surface(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: contentChildren,
                                ),
                              ),
                            ],
                          ),
                        );
                      }

                      return ToastResponsiveBody(
                        maxWidth: 1360,
                        child: surface(
                          child: RefreshIndicator(
                            onRefresh: notifier.load,
                            color: PosColors.accent,
                            child: ListView(children: contentChildren),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _exportLegalEntitySales() async {
    final auth = ref.read(authProvider);
    final storeIds = auth.accessibleStores.map((store) => store.id).toList();
    final saleDate = photoOpsHcmDate(DateTime.now());
    setState(() => _isExportingSales = true);

    try {
      final export = await photoOpsService.loadSalesExport(
        accessibleStoreIds: storeIds,
        saleDate: saleDate,
      );
      final bytes = buildPhotoOpsSalesWorkbook(export);
      await FileSaver.instance.saveFile(
        name: 'photo_sales_${saleDate.replaceAll('-', '')}',
        bytes: Uint8List.fromList(bytes),
        ext: 'xlsx',
        mimeType: MimeType.microsoftExcel,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.photoOpsSalesExportSaved(
              export.receiptCount,
              export.totalAmount.toString(),
            ),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      final message =
          error is FormatException &&
              error.message.toString().startsWith('PHOTO_EXPORT_NOT_READY:')
          ? context.l10n.photoOpsSalesExportNotReady
          : context.l10n.photoOpsSalesExportFailed('$error');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _isExportingSales = false);
    }
  }

  List<_PhotoOpsSurfaceMeta> _surfaceMeta(
    BuildContext context,
    PhotoOpsSurfaceAccess access,
  ) {
    final l10n = context.l10n;
    if (!access.showManagementSurfaces) {
      return [
        _PhotoOpsSurfaceMeta(
          title: l10n.photoOpsAttendanceTitle,
          subtitle: l10n.photoOpsAttendanceNumberOnlySubtitle,
          kind: PhotoOpsSurfaceKind.live,
        ),
        _PhotoOpsSurfaceMeta(
          title: l10n.photoOpsInventoryTitle,
          subtitle: l10n.photoOpsInventorySubtitle,
          kind: PhotoOpsSurfaceKind.priority,
        ),
      ];
    }
    return [
      _PhotoOpsSurfaceMeta(
        title: l10n.photoOpsPriorityQueueTitle,
        subtitle: l10n.photoOpsPriorityQueueSubtitle,
        kind: PhotoOpsSurfaceKind.priority,
      ),
      _PhotoOpsSurfaceMeta(
        title: l10n.photoOpsSalesTitle,
        subtitle: l10n.photoOpsSalesSubtitle,
        kind: PhotoOpsSurfaceKind.backOffice,
      ),
      _PhotoOpsSurfaceMeta(
        title: l10n.photoOpsAttendanceTitle,
        subtitle: l10n.photoOpsAttendanceNumberOnlySubtitle,
        kind: PhotoOpsSurfaceKind.live,
      ),
      _PhotoOpsSurfaceMeta(
        title: l10n.photoOpsInventoryTitle,
        subtitle: l10n.photoOpsInventorySubtitle,
        kind: PhotoOpsSurfaceKind.priority,
      ),
      _PhotoOpsSurfaceMeta(
        title: l10n.photoOpsSalaryTitle,
        subtitle: l10n.photoOpsSalarySubtitle,
        kind: PhotoOpsSurfaceKind.backOffice,
      ),
    ];
  }

  Future<void> _showInventoryAdjustment({
    required String storeId,
    required PhotoOpsInventoryRow row,
    required Future<void> Function() onRecorded,
  }) async {
    final employeeNumber = TextEditingController();
    final quantity = TextEditingController();
    final note = TextEditingController();
    var transactionType = 'restock';
    String? validation;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          key: const Key('photo_ops_inventory_adjustment_dialog'),
          title: Text(
            context.l10n.photoOpsInventoryAdjustmentTitle(row.itemName),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('photo_ops_inventory_employee_number'),
                controller: employeeNumber,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: context.l10n.attendanceEmployeeNumber,
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: transactionType,
                decoration: InputDecoration(
                  labelText: context.l10n.photoOpsInventoryAdjustmentType,
                ),
                items: [
                  DropdownMenuItem(
                    value: 'restock',
                    child: Text(context.l10n.photoOpsInventoryRestock),
                  ),
                  DropdownMenuItem(
                    value: 'adjust',
                    child: Text(context.l10n.photoOpsInventoryAdjust),
                  ),
                  DropdownMenuItem(
                    value: 'waste',
                    child: Text(context.l10n.photoOpsInventoryWaste),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setDialogState(() => transactionType = value);
                  }
                },
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('photo_ops_inventory_quantity'),
                controller: quantity,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: context.l10n.photoOpsInventoryQuantity,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: note,
                decoration: InputDecoration(
                  labelText: context.l10n.photoOpsInventoryNote,
                ),
              ),
              if (validation != null) ...[
                const SizedBox(height: 8),
                Text(
                  validation!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              key: const Key('photo_ops_inventory_adjustment_save'),
              onPressed: () async {
                final parsedQuantity = double.tryParse(quantity.text.trim());
                if (employeeNumber.text.trim().isEmpty ||
                    parsedQuantity == null ||
                    parsedQuantity <= 0 ||
                    row.ingredientId.isEmpty) {
                  setDialogState(
                    () => validation =
                        context.l10n.photoOpsInventoryAdjustmentInvalid,
                  );
                  return;
                }
                try {
                  await inventoryService.recordEmployeeInventoryAdjustment(
                    storeId: storeId,
                    employeeNumber: employeeNumber.text,
                    ingredientId: row.ingredientId,
                    transactionType: transactionType,
                    quantityG: parsedQuantity,
                    note: note.text.trim().isEmpty ? null : note.text.trim(),
                  );
                  await onRecorded();
                  if (!dialogContext.mounted) return;
                  Navigator.of(dialogContext).pop();
                  if (mounted) {
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      SnackBar(
                        content: Text(
                          this.context.l10n.photoOpsInventoryAdjustmentSaved,
                        ),
                      ),
                    );
                  }
                } catch (_) {
                  setDialogState(
                    () => validation =
                        context.l10n.photoOpsInventoryAdjustmentFailed,
                  );
                }
              },
              child: Text(context.l10n.save),
            ),
          ],
        ),
      ),
    );

    employeeNumber.dispose();
    quantity.dispose();
    note.dispose();
  }
}

enum PhotoOpsSurfaceKind { priority, live, backOffice }

class PhotoOpsSurfaceAccess {
  const PhotoOpsSurfaceAccess._({required this.showManagementSurfaces});

  factory PhotoOpsSurfaceAccess.forRole(String? role) =>
      PhotoOpsSurfaceAccess._(
        showManagementSurfaces:
            role == 'photo_objet_master' || role == 'super_admin',
      );

  final bool showManagementSurfaces;
}

class PhotoOpsManagementSurfaceGate extends StatelessWidget {
  const PhotoOpsManagementSurfaceGate({
    super.key,
    required this.role,
    required this.child,
  });

  final String? role;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      PhotoOpsSurfaceAccess.forRole(role).showManagementSurfaces
      ? child
      : const SizedBox.shrink();
}

class _PhotoOpsSurfaceMeta {
  const _PhotoOpsSurfaceMeta({
    required this.title,
    required this.subtitle,
    required this.kind,
  });

  final String title;
  final String subtitle;
  final PhotoOpsSurfaceKind kind;
}

class _PhotoOpsCompactNav extends StatelessWidget {
  const _PhotoOpsCompactNav({
    required this.items,
    required this.selectedIndex,
    required this.onItemSelected,
  });

  final List<ToastSidebarPanelItem> items;
  final int selectedIndex;
  final ValueChanged<int> onItemSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics(),
        ),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, index) => ToastFilterChip(
          key: Key('photo_ops_section_$index'),
          label: items[index].label,
          selected: index == selectedIndex,
          onSelected: () => onItemSelected(index),
        ),
      ),
    );
  }
}

class _PhotoOpsHeaderSummary extends StatelessWidget {
  const _PhotoOpsHeaderSummary({
    required this.selectedSurface,
    required this.role,
    required this.activeStoreName,
    required this.storeCount,
    required this.data,
    required this.surfaceAccess,
  });

  final _PhotoOpsSurfaceMeta selectedSurface;
  final String? role;
  final String activeStoreName;
  final int storeCount;
  final PhotoOpsDashboardData? data;
  final PhotoOpsSurfaceAccess surfaceAccess;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ToastWorkSurface(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              ToastSelectedContextHeader(
                title: selectedSurface.title,
                subtitle: context.l10n.photoOpsContextSubtitle,
                urgentReason: _surfaceUrgencyCopy(
                  context,
                  selectedSurface.kind,
                ),
                noteColor: _surfaceNoteColor(selectedSurface.kind),
                noteBackgroundColor: _surfaceNoteBackground(
                  selectedSurface.kind,
                ),
                noteIcon: _surfaceNoteIcon(selectedSurface.kind),
                trailing: ToastStatusBadge(
                  label: _surfaceLabel(context, selectedSurface.kind),
                  color: _surfaceTone(selectedSurface.kind),
                  compact: true,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: ToastMetricStrip(
                  metrics: [
                    ToastMetric(label: context.l10n.role, value: role ?? '-'),
                    ToastMetric(
                      label: context.l10n.photoOpsMetaActiveStore,
                      value: activeStoreName,
                    ),
                    if (surfaceAccess.showManagementSurfaces)
                      ToastMetric(
                        label: context.l10n.photoOpsMetaAccessibleStores,
                        value: context.l10n.photoOpsStoreCount(storeCount),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (data != null && surfaceAccess.showManagementSurfaces) ...[
          const SizedBox(height: 12),
          ToastMetricStrip(
            metrics: [
              ToastMetric(
                label: context.l10n.photoOpsKpiSales,
                value: '${data!.kpi.activeStoreSales.toStringAsFixed(0)} VND',
              ),
              ToastMetric(
                label: context.l10n.photoOpsKpiAttendance,
                value: '${data!.kpi.activeAttendanceEvents}',
                tone: data!.kpi.activeAttendanceEvents > 0
                    ? PosColors.accent
                    : PosColors.textSecondary,
              ),
              ToastMetric(
                label: context.l10n.photoOpsKpiInventoryAlerts,
                value: '${data!.kpi.activeInventoryAlerts}',
                tone: data!.kpi.activeInventoryAlerts > 0
                    ? PosColors.warning
                    : PosColors.textSecondary,
              ),
              ToastMetric(
                label: context.l10n.photoOpsKpiPayrollEstimate,
                value:
                    '${data!.kpi.activePayrollEstimate.toStringAsFixed(0)} VND',
              ),
            ],
          ),
        ],
      ],
    );
  }
}

String _localizedSalesWarning(
  BuildContext context,
  PhotoOpsDashboardData data,
) {
  final detail = data.salesWarningDetail ?? '-';
  return switch (data.salesWarningCode) {
    'photo_ops_recent_sales_failed_using_latest' =>
      context.l10n.photoOpsRecentSalesFailedUsingLatest(detail),
    'photo_ops_sales_load_failed' => context.l10n.photoOpsSalesLoadFailed(
      detail,
    ),
    _ => context.l10n.photoOpsSalesLoadFailed(detail),
  };
}

class _HeroBanner extends StatelessWidget {
  const _HeroBanner({
    required this.role,
    required this.activeStoreName,
    required this.storeCount,
  });

  final String? role;
  final String activeStoreName;
  final int storeCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: AppRadius.sm,
        border: Border.all(color: PosColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.photoOpsHeroEyebrow,
            style: AppFonts.system(
              color: PosColors.textMuted,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.photoOpsHeroTitle,
            style: AppFonts.system(
              color: PosColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w900,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _MetaPill(
                label: context.l10n.photoOpsMetaRole,
                value: role ?? '-',
              ),
              _MetaPill(
                label: context.l10n.photoOpsMetaActiveStore,
                value: activeStoreName,
              ),
              _MetaPill(
                label: context.l10n.photoOpsMetaAccessibleStores,
                value: '$storeCount',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

List<String> _buildPriorityItems(BuildContext context, PhotoOpsKpi data) {
  final l10n = context.l10n;
  final items = <String>[];

  if (data.activeInventoryAlerts > 0) {
    items.add(l10n.photoOpsPriorityInventoryAlert(data.activeInventoryAlerts));
  }

  if (data.activeStoreSales > 0) {
    items.add(
      l10n.photoOpsPrioritySalesSummary(
        data.activeStoreSales.toStringAsFixed(0),
        data.activeStoreTransactions,
      ),
    );
  } else {
    items.add(l10n.photoOpsPriorityNoSalesSummary);
  }

  if (data.activeAttendanceEvents == 0) {
    items.add(l10n.photoOpsPriorityNoAttendance);
  } else {
    items.add(
      l10n.photoOpsPriorityAttendanceLogged(data.activeAttendanceEvents),
    );
  }

  if (data.activePayrollEstimate > 0) {
    items.add(
      l10n.photoOpsPriorityPayrollEstimate(
        data.activePayrollEstimate.toStringAsFixed(0),
      ),
    );
  }

  if (data.lastSalesPulledAt != null) {
    items.add(
      l10n.photoOpsPriorityLastSalesPull(
        data.lastSalesPulledAt!.toLocal().toString(),
      ),
    );
  }

  if (items.isEmpty) {
    items.add(l10n.photoOpsPriorityNoUrgentActions);
  }

  return items;
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: PosColors.panelMuted,
        borderRadius: AppRadius.pill,
        border: Border.all(color: PosColors.border),
      ),
      child: Text(
        '$label: $value',
        style: AppFonts.system(
          color: PosColors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _KpiGrid extends StatelessWidget {
  const _KpiGrid({required this.data});

  final PhotoOpsKpi data;

  @override
  Widget build(BuildContext context) {
    final items = [
      (
        context.l10n.photoOpsKpiAttendance,
        '${data.activeAttendanceEvents}',
        context.l10n.photoOpsKpiAttendanceScope,
      ),
      (
        context.l10n.photoOpsKpiInventoryAlerts,
        '${data.activeInventoryAlerts}',
        context.l10n.photoOpsKpiInventoryAlertsScope,
      ),
      (
        context.l10n.photoOpsKpiSales,
        _currency(data.activeStoreSales),
        context.l10n.photoOpsKpiSalesScope,
      ),
      (
        context.l10n.photoOpsKpiNetworkSales,
        _currency(data.networkSales),
        context.l10n.photoOpsKpiNetworkSalesScope,
      ),
      (
        context.l10n.photoOpsKpiTransactions,
        '${data.activeStoreTransactions}',
        context.l10n.photoOpsKpiTransactionsScope,
      ),
      (
        context.l10n.photoOpsKpiPayrollEstimate,
        _currency(data.activePayrollEstimate),
        context.l10n.photoOpsKpiPayrollEstimateScope,
      ),
      (
        context.l10n.photoOpsKpiAllAttendance,
        '${data.allAttendanceEvents}',
        context.l10n.photoOpsKpiAllAttendanceScope,
      ),
      (
        context.l10n.photoOpsKpiAllAlerts,
        '${data.allInventoryAlerts}',
        context.l10n.photoOpsKpiAllAlertsScope,
      ),
    ];

    final metricItems = items
        .map(
          (item) => ToastMetricItem(
            label: item.$1,
            value: item.$2,
            color: PosColors.accent,
          ),
        )
        .toList();

    return Column(
      children: [
        ToastMetricItemStrip(items: metricItems.take(4).toList()),
        const SizedBox(height: AppSpacing.sm),
        ToastMetricItemStrip(items: metricItems.skip(4).take(4).toList()),
      ],
    );
  }

  static String _currency(double value) => '${value.toStringAsFixed(0)} VND';
}

class _WarningSurface extends StatelessWidget {
  const _WarningSurface({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return ToastWorkSurface(
      padding: const EdgeInsets.all(AppSpacing.md),
      backgroundColor: PosColors.warningMuted,
      borderColor: PosColors.warning.withValues(alpha: 0.18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: PosColors.warning),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: AppFonts.system(
                color: PosColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkflowSurface extends StatelessWidget {
  const _WorkflowSurface({
    required this.title,
    required this.subtitle,
    required this.kind,
    required this.child,
  });

  final String title;
  final String subtitle;
  final PhotoOpsSurfaceKind kind;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ToastWorkSurface(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: PosColors.border)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: AppSectionHeader(title: title, subtitle: subtitle),
                ),
                const SizedBox(width: 12),
                ToastStatusBadge(
                  label: _surfaceLabel(context, kind),
                  color: _surfaceTone(kind),
                  compact: true,
                ),
              ],
            ),
          ),
          Padding(padding: const EdgeInsets.all(AppSpacing.md), child: child),
        ],
      ),
    );
  }
}

String _surfaceLabel(BuildContext context, PhotoOpsSurfaceKind kind) {
  final l10n = context.l10n;
  return switch (kind) {
    PhotoOpsSurfaceKind.priority => l10n.photoOpsPriorityQueueTitle,
    PhotoOpsSurfaceKind.live => l10n.photoOpsLiveOps,
    PhotoOpsSurfaceKind.backOffice => l10n.photoOpsBackOffice,
  };
}

String _surfaceUrgencyCopy(BuildContext context, PhotoOpsSurfaceKind kind) {
  final l10n = context.l10n;
  return switch (kind) {
    PhotoOpsSurfaceKind.priority => l10n.photoOpsPriorityUrgency,
    PhotoOpsSurfaceKind.live => l10n.photoOpsLiveUrgency,
    PhotoOpsSurfaceKind.backOffice => l10n.photoOpsBackOfficeUrgency,
  };
}

Color _surfaceTone(PhotoOpsSurfaceKind kind) {
  return switch (kind) {
    PhotoOpsSurfaceKind.priority => PosColors.warning,
    PhotoOpsSurfaceKind.live => PosColors.accent,
    PhotoOpsSurfaceKind.backOffice => PosColors.textSecondary,
  };
}

Color _surfaceNoteColor(PhotoOpsSurfaceKind kind) {
  return switch (kind) {
    PhotoOpsSurfaceKind.priority => PosColors.warning,
    PhotoOpsSurfaceKind.live => PosColors.accent,
    PhotoOpsSurfaceKind.backOffice => PosColors.textSecondary,
  };
}

Color _surfaceNoteBackground(PhotoOpsSurfaceKind kind) {
  return switch (kind) {
    PhotoOpsSurfaceKind.priority => PosColors.warningMuted,
    PhotoOpsSurfaceKind.live => PosColors.accentMuted,
    PhotoOpsSurfaceKind.backOffice => PosColors.panelMuted,
  };
}

IconData _surfaceNoteIcon(PhotoOpsSurfaceKind kind) {
  return switch (kind) {
    PhotoOpsSurfaceKind.priority => Icons.priority_high_rounded,
    PhotoOpsSurfaceKind.live => Icons.bolt_rounded,
    PhotoOpsSurfaceKind.backOffice => Icons.insights_rounded,
  };
}

class _AttendanceList extends StatelessWidget {
  const _AttendanceList({required this.rows});

  final List<PhotoOpsAttendanceRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return _EmptyLabel(context.l10n.photoOpsNoAttendanceActivity);
    }
    return Column(
      children: rows
          .map(
            (row) => _SimpleRow(
              title: row.employeeName,
              subtitle:
                  '${_attendanceTypeLabel(context, row.type)} · ${row.loggedAt.toLocal()}',
              trailing: context.l10n.photoOpsRecorded,
            ),
          )
          .toList(),
    );
  }
}

class _SalesList extends StatelessWidget {
  const _SalesList({required this.rows});

  final List<PhotoOpsSalesRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return _EmptyLabel(context.l10n.photoOpsNoSalesSummary);
    }
    return Column(
      children: rows
          .map(
            (row) => _SimpleRow(
              title:
                  '${row.storeName} · ${row.saleDate.toIso8601String().substring(0, 10)}',
              subtitle: context.l10n.photoOpsSalesRowSubtitle(
                row.totalTransactions,
                row.serviceAmount.toStringAsFixed(0),
                row.activeMachines,
              ),
              trailing: '${row.grossSales.toStringAsFixed(0)} VND',
            ),
          )
          .toList(),
    );
  }
}

class _InventoryList extends StatelessWidget {
  const _InventoryList({required this.rows, required this.onAdjust});

  final List<PhotoOpsInventoryRow> rows;
  final ValueChanged<PhotoOpsInventoryRow> onAdjust;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return _EmptyLabel(context.l10n.photoOpsNoInventoryAlerts);
    }
    return Column(
      children: rows
          .map(
            (row) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: PosListRow(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            row.itemName,
                            style: AppFonts.system(
                              color: PosColors.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            context.l10n.photoOpsInventoryRowSubtitle(
                              row.currentStock.toStringAsFixed(1),
                              row.unit,
                              row.reorderPoint?.toStringAsFixed(1) ?? '-',
                            ),
                            style: AppFonts.system(
                              color: PosColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    OutlinedButton(
                      key: ValueKey(
                        'photo_ops_inventory_adjust_${row.ingredientId}',
                      ),
                      onPressed: row.ingredientId.isEmpty
                          ? null
                          : () => onAdjust(row),
                      child: Text(context.l10n.photoOpsInventoryRecordAction),
                    ),
                  ],
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

String _attendanceTypeLabel(BuildContext context, String type) =>
    switch (type) {
      'clock_in' => context.l10n.clockIn,
      'clock_out' => context.l10n.clockOut,
      _ => context.l10n.photoOpsAttendanceUnknown,
    };

class _EmployeeAttendanceActions extends StatefulWidget {
  const _EmployeeAttendanceActions({
    required this.storeId,
    required this.onRecorded,
  });

  final String storeId;
  final Future<void> Function() onRecorded;

  @override
  State<_EmployeeAttendanceActions> createState() =>
      _EmployeeAttendanceActionsState();
}

class _EmployeeAttendanceActionsState
    extends State<_EmployeeAttendanceActions> {
  final _employeeNumber = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _employeeNumber.dispose();
    super.dispose();
  }

  Future<void> _record(String type) async {
    if (_employeeNumber.text.trim().isEmpty) {
      setState(() => _error = context.l10n.attendanceEmployeeNumberRequired);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await attendanceService.recordEmployeeAttendance(
        storeId: widget.storeId,
        employeeNumber: _employeeNumber.text,
        type: type,
      );
      await widget.onRecorded();
      if (!mounted) return;
      _employeeNumber.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.photoOpsAttendanceRecorded)),
      );
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.attendanceRecordFailed);
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) => ToastWorkSurface(
    padding: const EdgeInsets.all(14),
    backgroundColor: PosColors.panelMuted,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.l10n.photoOpsPartTimerAttendanceTitle,
          style: AppFonts.system(
            color: PosColors.textPrimary,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('photo_ops_employee_number_field'),
          controller: _employeeNumber,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            labelText: context.l10n.attendanceEmployeeNumber,
            errorText: _error,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                key: const Key('photo_ops_employee_clock_in'),
                onPressed: _submitting ? null : () => _record('clock_in'),
                child: Text(context.l10n.clockIn),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                key: const Key('photo_ops_employee_clock_out'),
                onPressed: _submitting ? null : () => _record('clock_out'),
                child: Text(context.l10n.clockOut),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _PayrollList extends StatelessWidget {
  const _PayrollList({required this.rows});

  final List<PhotoOpsPayrollRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return _EmptyLabel(context.l10n.photoOpsNoPayrollEstimate);
    }
    return Column(
      children: rows
          .map(
            (row) => _SimpleRow(
              title: row.employeeName,
              subtitle: context.l10n.photoOpsPayrollRowSubtitle(
                row.shiftCount,
                row.totalHours.toStringAsFixed(1),
              ),
              trailing: '${row.totalAmount.toStringAsFixed(0)} VND',
            ),
          )
          .toList(),
    );
  }
}

class _PriorityList extends StatelessWidget {
  const _PriorityList({required this.items});

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: items
          .map(
            (item) => _SimpleRow(
              title: context.l10n.photoOpsAction,
              subtitle: item,
              trailing: context.l10n.photoOpsReview,
            ),
          )
          .toList(),
    );
  }
}

class _StoreScopeList extends StatelessWidget {
  const _StoreScopeList({required this.stores, required this.activeStoreId});

  final List<AccessibleStore> stores;
  final String? activeStoreId;

  @override
  Widget build(BuildContext context) {
    if (stores.isEmpty) {
      return _EmptyLabel(context.l10n.photoOpsNoAccessibleStores);
    }

    return Column(
      children: stores
          .map(
            (store) => _SimpleRow(
              title: store.name,
              subtitle: store.brandName == null
                  ? context.l10n.photoOpsOfficeLinkedStoreAccess
                  : context.l10n.photoOpsBrandLabel(store.brandName!),
              trailing: store.id == activeStoreId
                  ? context.l10n.photoOpsActive
                  : context.l10n.photoOpsAvailable,
            ),
          )
          .toList(),
    );
  }
}

class _SimpleRow extends StatelessWidget {
  const _SimpleRow({
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final String title;
  final String subtitle;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: PosListRow(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppFonts.system(
                      color: PosColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: AppFonts.system(
                      color: PosColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              trailing,
              style: AppFonts.system(
                color: PosColors.accent,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyLabel extends StatelessWidget {
  const _EmptyLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Text(
        text,
        style: AppFonts.system(color: PosColors.textSecondary, fontSize: 13),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return ToastWorkSurface(
      child: Column(
        children: [
          Text(
            message,
            style: AppFonts.system(color: PosColors.textPrimary, fontSize: 14),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: Text(context.l10n.retry)),
        ],
      ),
    );
  }
}
