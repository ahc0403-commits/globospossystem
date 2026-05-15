import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/app_primitives.dart';
import '../../core/ui/app_theme.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/auth/auth_state.dart';
import '../../widgets/app_nav_bar.dart';
import 'photo_ops_provider.dart';
import 'photo_ops_service.dart';

class PhotoOpsScreen extends ConsumerStatefulWidget {
  const PhotoOpsScreen({super.key});

  @override
  ConsumerState<PhotoOpsScreen> createState() => _PhotoOpsScreenState();
}

class _PhotoOpsScreenState extends ConsumerState<PhotoOpsScreen> {
  String? _lastLoadedStoreId;
  int _selectedSurfaceIndex = 0;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final state = ref.watch(photoOpsProvider);
    final notifier = ref.read(photoOpsProvider.notifier);
    final activeStoreId = auth.storeId;
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

    final surfaceMeta = _surfaceMeta(context);
    final safeSurfaceIndex = _selectedSurfaceIndex.clamp(
      0,
      surfaceMeta.length - 1,
    );
    final selectedSurface = surfaceMeta[safeSurfaceIndex];

    return KeyedSubtree(
      key: const Key('photo_ops_root'),
      child: ToastShell(
        sidebar: ToastSidebarPanel(
          title: l10n.photoOpsBrandName,
          subtitle: activeStoreName,
          selectedIndex: safeSurfaceIndex,
          onItemSelected: (index) =>
              setState(() => _selectedSurfaceIndex = index),
          items: [
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
          ],
        ),
        topbar: ToastTopbar(
          title: l10n.photoOpsBrandName,
          actions: const [AppNavBar()],
          trailing: ToastStatusBadge(
            label: activeStoreName,
            color: _surfaceTone(selectedSurface.kind),
            key: const Key('photo_ops_active_store_badge'),
          ),
        ),
        child: ToastResponsiveBody(
          maxWidth: 1360,
          child: ToastOperationalQueuePane(
            title: selectedSurface.title,
            subtitle: selectedSurface.subtitle,
            headerBottom: _PhotoOpsHeaderSummary(
              selectedSurface: selectedSurface,
              role: auth.role,
              activeStoreName: activeStoreName,
              storeCount: auth.accessibleStores.length,
              data: state.data,
            ),
            child: RefreshIndicator(
              onRefresh: notifier.load,
              color: PosColors.accent,
              child: ListView(
                children: [
                  _HeroBanner(
                    role: auth.role,
                    activeStoreName: activeStoreName,
                    storeCount: auth.accessibleStores.length,
                  ),
                  const SizedBox(height: 18),
                  if (state.isLoading && state.data == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 80),
                      child: Center(
                        child: CircularProgressIndicator(
                          color: PosColors.accent,
                        ),
                      ),
                    )
                  else if (state.error != null && state.data == null)
                    _ErrorCard(message: state.error!, onRetry: notifier.load)
                  else if (state.data != null) ...[
                    if (state.data!.salesWarningCode != null) ...[
                      _WarningSurface(
                        message: _localizedSalesWarning(context, state.data!),
                      ),
                      const SizedBox(height: 18),
                    ],
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
                      child: _SalesList(rows: state.data!.salesSummary),
                    ),
                    const SizedBox(height: 18),
                    _WorkflowSurface(
                      title: l10n.photoOpsAttendanceTitle,
                      subtitle: l10n.photoOpsAttendanceSubtitle,
                      kind: PhotoOpsSurfaceKind.live,
                      child: _AttendanceList(
                        rows: state.data!.recentAttendance,
                      ),
                    ),
                    const SizedBox(height: 18),
                    _WorkflowSurface(
                      title: l10n.photoOpsInventoryTitle,
                      subtitle: l10n.photoOpsInventorySubtitle,
                      kind: PhotoOpsSurfaceKind.priority,
                      child: _InventoryList(rows: state.data!.inventoryAlerts),
                    ),
                    const SizedBox(height: 18),
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<_PhotoOpsSurfaceMeta> _surfaceMeta(BuildContext context) {
    final l10n = context.l10n;
    return [
      _PhotoOpsSurfaceMeta(
        title: l10n.photoOpsPriorityQueueTitle,
        subtitle:
            'Review the next issue that needs intervention before moving into supporting detail.',
        kind: PhotoOpsSurfaceKind.priority,
      ),
      _PhotoOpsSurfaceMeta(
        title: l10n.photoOpsSalesTitle,
        subtitle:
            'Read current sales posture after priority exceptions are stable.',
        kind: PhotoOpsSurfaceKind.backOffice,
      ),
      _PhotoOpsSurfaceMeta(
        title: l10n.photoOpsAttendanceTitle,
        subtitle:
            'Track live workforce events and photo-backed attendance flow.',
        kind: PhotoOpsSurfaceKind.live,
      ),
      _PhotoOpsSurfaceMeta(
        title: l10n.photoOpsInventoryTitle,
        subtitle:
            'Use stock alerts as an action queue, not just a reporting surface.',
        kind: PhotoOpsSurfaceKind.priority,
      ),
      _PhotoOpsSurfaceMeta(
        title: l10n.photoOpsSalaryTitle,
        subtitle:
            'Review payroll preview only after live events and alert queues are understood.',
        kind: PhotoOpsSurfaceKind.backOffice,
      ),
    ];
  }
}

enum PhotoOpsSurfaceKind { priority, live, backOffice }

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

class _PhotoOpsHeaderSummary extends StatelessWidget {
  const _PhotoOpsHeaderSummary({
    required this.selectedSurface,
    required this.role,
    required this.activeStoreName,
    required this.storeCount,
    required this.data,
  });

  final _PhotoOpsSurfaceMeta selectedSurface;
  final String? role;
  final String activeStoreName;
  final int storeCount;
  final PhotoOpsDashboardData? data;

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
                subtitle:
                    'Photo Ops keeps HQ aware of live store health without replacing the store-level workflow.',
                urgentReason: _surfaceUrgencyCopy(selectedSurface.kind),
                noteColor: _surfaceNoteColor(selectedSurface.kind),
                noteBackgroundColor: _surfaceNoteBackground(
                  selectedSurface.kind,
                ),
                noteIcon: _surfaceNoteIcon(selectedSurface.kind),
                trailing: ToastStatusBadge(
                  label: _surfaceLabel(selectedSurface.kind),
                  color: _surfaceTone(selectedSurface.kind),
                  compact: true,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: ToastMetricStrip(
                  metrics: [
                    ToastMetric(label: 'Role', value: role ?? '-'),
                    ToastMetric(label: 'Active Store', value: activeStoreName),
                    ToastMetric(label: 'Scope', value: '$storeCount stores'),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (data != null) ...[
          const SizedBox(height: 12),
          ToastMetricStrip(
            metrics: [
              ToastMetric(
                label: 'Sales',
                value: '${data!.kpi.activeStoreSales.toStringAsFixed(0)} VND',
              ),
              ToastMetric(
                label: 'Attendance',
                value: '${data!.kpi.activeAttendanceEvents}',
                tone: data!.kpi.activeAttendanceEvents > 0
                    ? PosColors.accent
                    : PosColors.textSecondary,
              ),
              ToastMetric(
                label: 'Inventory Alerts',
                value: '${data!.kpi.activeInventoryAlerts}',
                tone: data!.kpi.activeInventoryAlerts > 0
                    ? PosColors.warning
                    : PosColors.textSecondary,
              ),
              ToastMetric(
                label: 'Payroll Preview',
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
            style: GoogleFonts.notoSansKr(
              color: PosColors.textMuted,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.photoOpsHeroTitle,
            style: GoogleFonts.notoSansKr(
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
        style: GoogleFonts.notoSansKr(
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
              style: GoogleFonts.notoSansKr(
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
                  label: _surfaceLabel(kind),
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

String _surfaceLabel(PhotoOpsSurfaceKind kind) {
  return switch (kind) {
    PhotoOpsSurfaceKind.priority => 'Priority Queue',
    PhotoOpsSurfaceKind.live => 'Live Ops',
    PhotoOpsSurfaceKind.backOffice => 'Back Office',
  };
}

String _surfaceUrgencyCopy(PhotoOpsSurfaceKind kind) {
  return switch (kind) {
    PhotoOpsSurfaceKind.priority =>
      'Use this lane to triage exceptions and the next cross-store follow-up item.',
    PhotoOpsSurfaceKind.live =>
      'This lane reflects current store activity that may require immediate awareness.',
    PhotoOpsSurfaceKind.backOffice =>
      'This lane is supportive reporting and review after urgent queues are stable.',
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
                  '${row.type.replaceAll('_', ' ')} · ${row.loggedAt.toLocal()}',
              trailing: row.photoUrl == null
                  ? context.l10n.photoOpsNoPhoto
                  : context.l10n.photoOpsPhoto,
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
  const _InventoryList({required this.rows});

  final List<PhotoOpsInventoryRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return _EmptyLabel(context.l10n.photoOpsNoInventoryAlerts);
    }
    return Column(
      children: rows
          .map(
            (row) => _SimpleRow(
              title: row.itemName,
              subtitle: context.l10n.photoOpsInventoryRowSubtitle(
                row.currentStock.toStringAsFixed(1),
                row.unit,
                row.reorderPoint?.toStringAsFixed(1) ?? '-',
              ),
              trailing: row.supplierName ?? context.l10n.photoOpsReview,
            ),
          )
          .toList(),
    );
  }
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
                    style: GoogleFonts.notoSansKr(
                      color: PosColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: GoogleFonts.notoSansKr(
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
              style: GoogleFonts.notoSansKr(
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
        style: GoogleFonts.notoSansKr(
          color: PosColors.textSecondary,
          fontSize: 13,
        ),
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
            style: GoogleFonts.notoSansKr(
              color: PosColors.textPrimary,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: Text(context.l10n.retry)),
        ],
      ),
    );
  }
}
