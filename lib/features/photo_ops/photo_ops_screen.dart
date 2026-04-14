import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/ui/app_theme.dart';
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

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final state = ref.watch(photoOpsProvider);
    final notifier = ref.read(photoOpsProvider.notifier);
    final activeStoreId = auth.storeId;
    String activeStoreName = 'No active store';

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

    return Scaffold(
      backgroundColor: AppColors.surface0,
      appBar: AppBar(
        title: Text(
          'PHOTO OBJET',
          style: GoogleFonts.bebasNeue(
            color: AppColors.amber500,
            fontSize: 34,
            letterSpacing: 1.2,
          ),
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Center(child: AppNavBar()),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: notifier.load,
        color: AppColors.amber500,
        child: ListView(
          padding: const EdgeInsets.all(20),
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
                  child: CircularProgressIndicator(color: AppColors.amber500),
                ),
              )
            else if (state.error != null && state.data == null)
              _ErrorCard(message: state.error!, onRetry: notifier.load)
            else if (state.data != null) ...[
              _KpiGrid(data: state.data!.kpi),
              const SizedBox(height: 18),
              _SectionCard(
                title: 'Priority Queue',
                subtitle: 'What needs attention first in the current office workflow.',
                child: _PriorityList(
                  items: _buildPriorityItems(state.data!.kpi),
                ),
              ),
              const SizedBox(height: 18),
              _SectionCard(
                title: 'Attendance',
                subtitle: 'Recent attendance activity in the active store.',
                child: _AttendanceList(rows: state.data!.recentAttendance),
              ),
              const SizedBox(height: 18),
              _SectionCard(
                title: 'Inventory',
                subtitle: 'Low-stock ingredients that need attention now.',
                child: _InventoryList(rows: state.data!.inventoryAlerts),
              ),
              const SizedBox(height: 18),
              _SectionCard(
                title: 'Salary',
                subtitle: 'Current payroll estimate for the active store.',
                child: _PayrollList(rows: state.data!.payrollPreview),
              ),
              const SizedBox(height: 18),
              _SectionCard(
                title: 'Store Scope',
                subtitle: 'Photo Objet stays on office operations while Deliberry settlement remains in the admin workflow.',
                child: _StoreScopeList(
                  stores: auth.accessibleStores,
                  activeStoreId: activeStoreId,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
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
        borderRadius: AppRadius.lg,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF5A623), Color(0xFFD97B11)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Office-linked operations workspace',
            style: GoogleFonts.notoSansKr(
              color: AppColors.surface0,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Manage attendance, inventory, and salary in an office-linked workspace without delivery-settlement or red-invoice tasks.',
            style: GoogleFonts.notoSansKr(
              color: AppColors.surface0,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _MetaPill(label: 'Role', value: role ?? '-'),
              _MetaPill(label: 'Active store', value: activeStoreName),
              _MetaPill(label: 'Accessible stores', value: '$storeCount'),
            ],
          ),
        ],
      ),
    );
  }
}

List<String> _buildPriorityItems(PhotoOpsKpi data) {
  final items = <String>[];

  if (data.activeInventoryAlerts > 0) {
    items.add(
      '${data.activeInventoryAlerts} inventory items are below reorder level in the active store.',
    );
  }

  if (data.activeAttendanceEvents == 0) {
    items.add('No attendance events are logged for the active store today.');
  } else {
    items.add(
      '${data.activeAttendanceEvents} attendance events are already logged for the active store today.',
    );
  }

  if (data.activePayrollEstimate > 0) {
    items.add(
      'Current payroll estimate is ${data.activePayrollEstimate.toStringAsFixed(0)} VND and should be reviewed before month close.',
    );
  }

  if (items.isEmpty) {
    items.add('No urgent office actions are currently flagged.');
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
        color: AppColors.surface0.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label: $value',
        style: GoogleFonts.notoSansKr(
          color: AppColors.surface0,
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
      ('Attendance', '${data.activeAttendanceEvents}', 'active store today'),
      ('Inventory alerts', '${data.activeInventoryAlerts}', 'active store'),
      ('Payroll est.', _currency(data.activePayrollEstimate), 'active store'),
      ('All attendance', '${data.allAttendanceEvents}', 'accessible stores today'),
      ('All alerts', '${data.allInventoryAlerts}', 'accessible stores'),
    ];

    return Wrap(
      spacing: 14,
      runSpacing: 14,
      children:
          items
              .map(
                (item) => SizedBox(
                  width: 220,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.$1,
                            style: GoogleFonts.notoSansKr(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            item.$2,
                            style: GoogleFonts.bebasNeue(
                              color: AppColors.amber500,
                              fontSize: 34,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            item.$3,
                            style: GoogleFonts.notoSansKr(
                              color: AppColors.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
    );
  }

  static String _currency(double value) => '${value.toStringAsFixed(0)} VND';
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: GoogleFonts.bebasNeue(
                color: AppColors.amber500,
                fontSize: 28,
                letterSpacing: 1.0,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _AttendanceList extends StatelessWidget {
  const _AttendanceList({required this.rows});

  final List<PhotoOpsAttendanceRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const _EmptyLabel('No attendance activity found.');
    return Column(
      children:
          rows
              .map(
                (row) => _SimpleRow(
                  title: row.employeeName,
                  subtitle:
                      '${row.type.replaceAll('_', ' ')} · ${row.loggedAt.toLocal()}',
                  trailing: row.photoUrl == null ? 'No photo' : 'Photo',
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
    if (rows.isEmpty) return const _EmptyLabel('No low-stock inventory items.');
    return Column(
      children:
          rows
              .map(
                (row) => _SimpleRow(
                  title: row.itemName,
                  subtitle:
                      'Stock ${row.currentStock.toStringAsFixed(1)} ${row.unit} · Reorder ${row.reorderPoint?.toStringAsFixed(1) ?? '-'}',
                  trailing: row.supplierName ?? 'Review',
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
    if (rows.isEmpty) return const _EmptyLabel('No payroll estimate available.');
    return Column(
      children:
          rows
              .map(
                (row) => _SimpleRow(
                  title: row.employeeName,
                  subtitle:
                      '${row.shiftCount} shifts · ${row.totalHours.toStringAsFixed(1)} hours',
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
      children:
          items
              .map(
                (item) => _SimpleRow(
                  title: 'Action',
                  subtitle: item,
                  trailing: 'Review',
                ),
              )
              .toList(),
    );
  }
}

class _StoreScopeList extends StatelessWidget {
  const _StoreScopeList({
    required this.stores,
    required this.activeStoreId,
  });

  final List<AccessibleStore> stores;
  final String? activeStoreId;

  @override
  Widget build(BuildContext context) {
    if (stores.isEmpty) {
      return const _EmptyLabel('No accessible stores are linked to this role.');
    }

    return Column(
      children:
          stores
              .map(
                (store) => _SimpleRow(
                  title: store.name,
                  subtitle: store.brandName == null
                      ? 'Office-linked store access'
                      : 'Brand ${store.brandName}',
                  trailing: store.id == activeStoreId ? 'Active' : 'Available',
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
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadius.md,
        border: Border.all(color: AppColors.surface3),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textSecondary,
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
              color: AppColors.amber500,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
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
          color: AppColors.textSecondary,
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Text(
              message,
              style: GoogleFonts.notoSansKr(
                color: AppColors.textPrimary,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
