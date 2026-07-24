import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/services/attendance_service.dart';
import '../../core/services/inventory_service.dart';
import '../../core/services/payroll_service.dart';
import '../../core/ui/app_primitives.dart';
import '../../core/ui/app_theme.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../features/auth/auth_provider.dart';
import '../../widgets/app_nav_bar.dart';
import 'photo_ops_provider.dart';
import 'photo_ops_sales_export.dart';
import 'photo_ops_service.dart';

typedef PhotoOpsAttendancePhotoPicker = Future<XFile?> Function();
typedef PhotoOpsPayrollFileSaver =
    Future<void> Function(String fileName, List<int> bytes);

class PhotoOpsScreen extends ConsumerStatefulWidget {
  const PhotoOpsScreen({
    super.key,
    this.attendanceServiceOverride,
    this.payrollServiceOverride,
    this.attendancePhotoPickerOverride,
    this.payrollFileSaverOverride,
  });

  final AttendanceService? attendanceServiceOverride;
  final PayrollService? payrollServiceOverride;
  final PhotoOpsAttendancePhotoPicker? attendancePhotoPickerOverride;
  final PhotoOpsPayrollFileSaver? payrollFileSaverOverride;

  @override
  ConsumerState<PhotoOpsScreen> createState() => _PhotoOpsScreenState();
}

class _PhotoOpsScreenState extends ConsumerState<PhotoOpsScreen> {
  String? _lastLoadedScopeKey;
  int _selectedSurfaceIndex = 0;
  bool _isExportingSales = false;
  bool _isExportingPayroll = false;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final state = ref.watch(photoOpsProvider);
    final notifier = ref.read(photoOpsProvider.notifier);
    final activeStoreId = auth.storeId;
    final surfaceAccess = PhotoOpsSurfaceAccess.forRole(auth.role);
    final canManageWorkforce = auth.role == 'photo_objet_master';
    final l10n = context.l10n;
    String activeStoreName = l10n.photoOpsNoActiveStore;

    for (final store in auth.accessibleStores) {
      if (store.id == activeStoreId) {
        activeStoreName = store.name;
        break;
      }
    }

    final scopeKey = activeStoreId == null
        ? null
        : '$activeStoreId:${auth.accessibleStores.map((store) => store.id).join(',')}';
    if (scopeKey != null &&
        auth.accessibleStores.isNotEmpty &&
        _lastLoadedScopeKey != scopeKey) {
      _lastLoadedScopeKey = scopeKey;
      Future.microtask(notifier.load);
    }

    final surfaceMeta = _surfaceMeta(context, surfaceAccess);
    final safeSurfaceIndex = _selectedSurfaceIndex.clamp(
      0,
      surfaceMeta.length - 1,
    );
    final selectedSurface = surfaceMeta[safeSurfaceIndex];
    final today = DateTime.now();
    final salesEndDate =
        state.salesEndDate ?? DateTime(today.year, today.month, today.day);
    final salesStartDate =
        state.salesStartDate ?? salesEndDate.subtract(const Duration(days: 6));
    final contentChildren = <Widget>[
      if (state.isLoading && state.data == null)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 80),
          child: Center(
            child: CircularProgressIndicator(color: PosColors.accent),
          ),
        )
      else if (state.error != null && state.data == null)
        _ErrorCard(message: state.error!, onRetry: notifier.load)
      else if (state.data != null)
        ..._selectedSurfaceChildren(
          index: safeSurfaceIndex,
          showManagementSurfaces: surfaceAccess.showManagementSurfaces,
          data: state.data!,
          activeStoreId: activeStoreId!,
          activeStoreName: activeStoreName,
          salesStartDate: salesStartDate,
          salesEndDate: salesEndDate,
          onReload: notifier.load,
        ),
    ];

    Widget surface({required Widget child}) {
      return ToastOperationalQueuePane(
        title: selectedSurface.title,
        subtitle: selectedSurface.subtitle,
        headerBottom: _PhotoOpsHeaderSummary(
          selectedSurface: selectedSurface,
          activeStoreName: activeStoreName,
          storeCount: auth.accessibleStores.length,
        ),
        child: child,
      );
    }

    final sidebarItems = surfaceAccess.showManagementSurfaces
        ? [
            ToastSidebarPanelItem(
              icon: Icons.payments_outlined,
              label: l10n.photoOpsSalesTitle,
              sectionLabel: l10n.photoOpsSalesTitle,
              itemKey: const Key('photo_ops_nav_sales'),
            ),
            ToastSidebarPanelItem(
              icon: Icons.schedule_outlined,
              label: l10n.photoOpsAttendanceTitle,
              sectionLabel: l10n.photoOpsAttendanceTitle,
              itemKey: const Key('photo_ops_nav_attendance'),
            ),
            ToastSidebarPanelItem(
              icon: Icons.inventory_2_outlined,
              label: l10n.photoOpsInventoryTitle,
              sectionLabel: l10n.photoOpsInventoryTitle,
              itemKey: const Key('photo_ops_nav_inventory'),
            ),
            ToastSidebarPanelItem(
              icon: Icons.group_outlined,
              label: l10n.photoOpsSalaryTitle,
              sectionLabel: l10n.photoOpsSalaryTitle,
              itemKey: const Key('photo_ops_nav_payroll'),
            ),
            ToastSidebarPanelItem(
              icon: Icons.manage_accounts_outlined,
              label: l10n.staffManagementTitle,
              sectionLabel: l10n.staffManagementTitle,
              itemKey: const Key('photo_ops_nav_staff'),
            ),
          ]
        : [
            ToastSidebarPanelItem(
              icon: Icons.schedule_outlined,
              label: l10n.photoOpsAttendanceTitle,
              sectionLabel: l10n.photoOpsAttendanceTitle,
              itemKey: const Key('photo_ops_nav_attendance'),
            ),
            ToastSidebarPanelItem(
              icon: Icons.inventory_2_outlined,
              label: l10n.photoOpsInventoryTitle,
              sectionLabel: l10n.photoOpsInventoryTitle,
              itemKey: const Key('photo_ops_nav_inventory'),
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
                        _selectSurface(index, notifier.load),
                    items: sidebarItems,
                  ),
            topbar: ToastTopbar(
              title: l10n.photoOpsBrandName,
              actions: [
                if (canManageWorkforce)
                  if (compactShell)
                    IconButton(
                      key: const Key('photo_ops_open_brand_manager'),
                      onPressed: () => context.go('/admin'),
                      tooltip: l10n.roleBrandAdminMenu,
                      icon: const Icon(Icons.business_outlined),
                    )
                  else
                    OutlinedButton.icon(
                      key: const Key('photo_ops_open_brand_manager'),
                      onPressed: () => context.go('/admin'),
                      icon: const Icon(Icons.business_outlined, size: 18),
                      label: Text(l10n.roleBrandAdminMenu),
                    ),
                AppNavBar(
                  forceHomeEnabled: canManageWorkforce,
                  onHomePressed: canManageWorkforce
                      ? () => context.go('/admin')
                      : null,
                ),
              ],
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
                        _selectSurface(index, notifier.load),
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

  void _selectSurface(int index, Future<void> Function() onReload) {
    setState(() => _selectedSurfaceIndex = index);
    Future.microtask(onReload);
  }

  Future<void> _selectSalesDateRange(
    DateTime salesStartDate,
    DateTime salesEndDate,
  ) async {
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(start: salesStartDate, end: salesEndDate),
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      helpText: '${context.l10n.photoOpsSalesTitle} · ${context.l10n.date}',
    );
    if (picked == null || !mounted) return;
    await ref
        .read(photoOpsProvider.notifier)
        .setSalesDateRange(picked.start, picked.end);
  }

  Future<void> _exportLegalEntitySales() async {
    final auth = ref.read(authProvider);
    final dashboard = ref.read(photoOpsProvider).data;
    final storeIds = auth.accessibleStores.map((store) => store.id).toList();
    final saleDate = dashboard == null || dashboard.salesSummary.isEmpty
        ? photoOpsHcmDate(DateTime.now())
        : dashboard.salesSummary.first.saleDate.toIso8601String().substring(
            0,
            10,
          );
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

  Future<void> _exportPayroll(String storeId) async {
    final today = DateTime.now();
    final periodStart = DateTime(today.year, today.month, 1);
    final periodEnd = DateTime(today.year, today.month, today.day, 23, 59, 59);
    setState(() => _isExportingPayroll = true);

    try {
      final service = widget.payrollServiceOverride ?? payrollService;
      final payrolls = await service.calculatePayroll(
        storeId: storeId,
        periodStart: periodStart,
        periodEnd: periodEnd,
      );
      final bytes = await service.exportToExcel(
        payrolls: payrolls,
        periodStart: periodStart,
        periodEnd: periodEnd,
      );
      if (bytes.isEmpty) {
        throw StateError('PAYROLL_EXPORT_EMPTY');
      }

      final fileName =
          'photo_payroll_${DateFormat('yyyyMM').format(periodStart)}';
      final saver = widget.payrollFileSaverOverride;
      if (saver != null) {
        await saver(fileName, bytes);
      } else {
        await FileSaver.instance.saveFile(
          name: fileName,
          bytes: Uint8List.fromList(bytes),
          ext: 'xlsx',
          mimeType: MimeType.microsoftExcel,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.attendancePayrollSaved)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.attendancePayrollLoadFailed)),
      );
    } finally {
      if (mounted) setState(() => _isExportingPayroll = false);
    }
  }

  List<Widget> _selectedSurfaceChildren({
    required int index,
    required bool showManagementSurfaces,
    required PhotoOpsDashboardData data,
    required String activeStoreId,
    required String activeStoreName,
    required DateTime salesStartDate,
    required DateTime salesEndDate,
    required Future<void> Function() onReload,
  }) {
    final l10n = context.l10n;
    final attendance = _WorkflowSurface(
      title: l10n.photoOpsAttendanceTitle,
      subtitle: l10n.photoOpsAttendanceSubtitle,
      kind: PhotoOpsSurfaceKind.live,
      showHeader: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (data.attendanceWarningDetail != null) ...[
            _SectionWarning(
              section: l10n.photoOpsAttendanceTitle,
              onRetry: onReload,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          _EmployeeAttendanceActions(
            storeId: activeStoreId,
            onRecorded: onReload,
            attendanceService:
                widget.attendanceServiceOverride ?? attendanceService,
            photoPicker: widget.attendancePhotoPickerOverride,
          ),
          const SizedBox(height: 12),
          _AttendanceList(rows: data.recentAttendance),
        ],
      ),
    );
    final inventory = _WorkflowSurface(
      title: l10n.photoOpsInventoryTitle,
      subtitle: '$activeStoreName · ${l10n.photoOpsInventorySubtitle}',
      kind: PhotoOpsSurfaceKind.attention,
      showHeader: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (data.inventoryWarningDetail != null) ...[
            _SectionWarning(
              section: l10n.photoOpsInventoryTitle,
              onRetry: onReload,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          _InventoryList(
            rows: data.inventoryItems.isEmpty
                ? data.inventoryAlerts
                : data.inventoryItems,
            onAdjust: (row) => _showInventoryAdjustment(
              storeId: activeStoreId,
              row: row,
              onRecorded: onReload,
            ),
          ),
        ],
      ),
    );

    if (!showManagementSurfaces) {
      return [index == 0 ? attendance : inventory];
    }

    return switch (index) {
      0 => [
        if (data.salesWarningCode != null) ...[
          _WarningSurface(message: _localizedSalesWarning(context, data)),
          const SizedBox(height: 18),
        ],
        _WorkflowSurface(
          title: l10n.photoOpsSalesTitle,
          subtitle: l10n.photoOpsSalesSubtitle,
          kind: PhotoOpsSurfaceKind.backOffice,
          showHeader: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('photo_ops_sales_date_range_button'),
                  onPressed: () =>
                      _selectSalesDateRange(salesStartDate, salesEndDate),
                  icon: const Icon(Icons.date_range_outlined, size: 18),
                  label: Text(
                    '${context.l10n.from} '
                    '${DateFormat('yyyy-MM-dd').format(salesStartDate)}  ·  '
                    '${context.l10n.to} '
                    '${DateFormat('yyyy-MM-dd').format(salesEndDate)}',
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              ToastMetricStrip(
                metrics: [
                  ToastMetric(
                    label: '$activeStoreName · ${l10n.photoOpsKpiSales}',
                    value:
                        '${data.kpi.activeStoreSales.toStringAsFixed(0)} VND',
                  ),
                  ToastMetric(
                    label: l10n.photoOpsKpiNetworkSales,
                    value: '${data.kpi.networkSales.toStringAsFixed(0)} VND',
                  ),
                  ToastMetric(
                    label: l10n.photoOpsKpiTransactions,
                    value: '${data.kpi.activeStoreTransactions}',
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  key: const Key('photo_ops_sales_export_button'),
                  onPressed: _isExportingSales ? null : _exportLegalEntitySales,
                  icon: _isExportingSales
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined),
                  label: Text(l10n.photoOpsSalesDownloadExcel),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              _SalesList(rows: data.salesSummary),
            ],
          ),
        ),
      ],
      1 => [attendance],
      2 => [inventory],
      3 => [
        _WorkflowSurface(
          title: l10n.photoOpsSalaryTitle,
          subtitle: '$activeStoreName · ${l10n.photoOpsSalarySubtitle}',
          kind: PhotoOpsSurfaceKind.backOffice,
          showHeader: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (data.payrollWarningDetail != null) ...[
                _SectionWarning(
                  section: l10n.photoOpsSalaryTitle,
                  onRetry: onReload,
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  key: const Key('photo_ops_payroll_export_button'),
                  onPressed: _isExportingPayroll
                      ? null
                      : () => _exportPayroll(activeStoreId),
                  icon: _isExportingPayroll
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined),
                  label: Text(context.l10n.download),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              _PayrollList(rows: data.payrollPreview),
            ],
          ),
        ),
      ],
      _ => [
        _WorkflowSurface(
          title: l10n.staffManagementTitle,
          subtitle:
              '$activeStoreName · ${l10n.staffEmployeeManagementSubtitle}',
          kind: PhotoOpsSurfaceKind.backOffice,
          showHeader: false,
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const Key('photo_ops_open_staff_management'),
              onPressed: () => context.go('/admin'),
              icon: const Icon(Icons.manage_accounts_outlined),
              label: Text(l10n.staffAddAction),
            ),
          ),
        ),
      ],
    };
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
          kind: PhotoOpsSurfaceKind.attention,
        ),
      ];
    }
    return [
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
        kind: PhotoOpsSurfaceKind.attention,
      ),
      _PhotoOpsSurfaceMeta(
        title: l10n.photoOpsSalaryTitle,
        subtitle: l10n.photoOpsSalarySubtitle,
        kind: PhotoOpsSurfaceKind.backOffice,
      ),
      _PhotoOpsSurfaceMeta(
        title: l10n.staffManagementTitle,
        subtitle: l10n.staffEmployeeManagementSubtitle,
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

enum PhotoOpsSurfaceKind { attention, live, backOffice }

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
    required this.activeStoreName,
    required this.storeCount,
  });

  final _PhotoOpsSurfaceMeta selectedSurface;
  final String activeStoreName;
  final int storeCount;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '${selectedSurface.title}, $activeStoreName',
      child: Container(
        key: const Key('photo_ops_compact_context'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: PosColors.panelMuted,
          borderRadius: AppRadius.sm,
          border: Border.all(color: PosColors.border),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.storefront_outlined,
              size: 18,
              color: PosColors.textSecondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$activeStoreName · ${context.l10n.photoOpsStoreCount(storeCount)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.system(
                  color: PosColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            ToastStatusBadge(
              label: _surfaceLabel(context, selectedSurface.kind),
              color: _surfaceTone(selectedSurface.kind),
              compact: true,
            ),
          ],
        ),
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
    this.showHeader = true,
  });

  final String title;
  final String subtitle;
  final PhotoOpsSurfaceKind kind;
  final Widget child;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    return ToastWorkSurface(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showHeader)
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
          Padding(
            padding: EdgeInsets.all(showHeader ? AppSpacing.md : AppSpacing.sm),
            child: child,
          ),
        ],
      ),
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

class _SectionWarning extends StatelessWidget {
  const _SectionWarning({required this.section, required this.onRetry});

  final String section;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return ToastWorkSurface(
      padding: const EdgeInsets.all(AppSpacing.md),
      backgroundColor: PosColors.warningMuted,
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: PosColors.warning),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(context.l10n.photoOpsSectionLoadFailed(section)),
          ),
          TextButton(onPressed: onRetry, child: Text(context.l10n.retry)),
        ],
      ),
    );
  }
}

String _surfaceLabel(BuildContext context, PhotoOpsSurfaceKind kind) {
  final l10n = context.l10n;
  return switch (kind) {
    PhotoOpsSurfaceKind.attention => l10n.photoOpsKpiInventoryAlerts,
    PhotoOpsSurfaceKind.live => l10n.photoOpsLiveOps,
    PhotoOpsSurfaceKind.backOffice => l10n.photoOpsBackOffice,
  };
}

Color _surfaceTone(PhotoOpsSurfaceKind kind) {
  return switch (kind) {
    PhotoOpsSurfaceKind.attention => PosColors.warning,
    PhotoOpsSurfaceKind.live => PosColors.accent,
    PhotoOpsSurfaceKind.backOffice => PosColors.textSecondary,
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
    required this.attendanceService,
    this.photoPicker,
  });

  final String storeId;
  final Future<void> Function() onRecorded;
  final AttendanceService attendanceService;
  final PhotoOpsAttendancePhotoPicker? photoPicker;

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
      final photo =
          await (widget.photoPicker?.call() ??
              ImagePicker().pickImage(
                source: ImageSource.camera,
                preferredCameraDevice: CameraDevice.front,
                imageQuality: 85,
                requestFullMetadata: false,
              ));
      if (photo == null) {
        if (mounted) {
          setState(() => _error = context.l10n.attendancePhotoRequired);
        }
        return;
      }

      final photoUrl = await widget.attendanceService
          .uploadEmployeeAttendancePhoto(
            storeId: widget.storeId,
            employeeNumber: _employeeNumber.text,
            originalFile: photo,
            type: type,
          );
      if (photoUrl == null || photoUrl.isEmpty) {
        throw StateError('ATTENDANCE_PHOTO_FAILED');
      }

      await widget.attendanceService.recordEmployeeAttendance(
        storeId: widget.storeId,
        employeeNumber: _employeeNumber.text,
        type: type,
        photoUrl: photoUrl,
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
