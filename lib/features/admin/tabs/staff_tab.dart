import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:intl/intl.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../core/ui/pos_design_tokens.dart';
import '../../../core/ui/toast/toast.dart';
import '../../../core/utils/staff_role_utils.dart';
import '../../../main.dart';
import '../../../widgets/error_toast.dart';
import '../../auth/auth_provider.dart';
import '../providers/staff_provider.dart';

class StaffTab extends ConsumerStatefulWidget {
  const StaffTab({super.key});

  @override
  ConsumerState<StaffTab> createState() => _StaffTabState();
}

class _StaffTabState extends ConsumerState<StaffTab> {
  String? _initializedRestaurantId;
  String? _lastError;
  String? _lastAttendanceError;
  String? _selectedStaffId;
  String _roleFilter = 'all';
  String _statusFilter = 'all';
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final storeId = authState.storeId;
    final viewerRole = authState.role;
    final staffState = ref.watch(staffProvider);
    final attendanceState = ref.watch(attendanceProvider);
    final notifier = ref.read(staffProvider.notifier);
    final l10n = context.l10n;

    if (storeId != null && _initializedRestaurantId != storeId) {
      _initializedRestaurantId = storeId;
      Future.microtask(() async {
        await notifier.loadStaff(storeId);
        await ref.read(attendanceProvider.notifier).loadLogs(storeId);
      });
    }

    if (staffState.error != null &&
        staffState.error!.isNotEmpty &&
        staffState.error != _lastError) {
      _lastError = staffState.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showErrorToast(
            context,
            _localizedStaffCreationMessage(context, staffState.error!),
          );
        }
      });
    }

    if (attendanceState.error != null &&
        attendanceState.error!.isNotEmpty &&
        attendanceState.error != _lastAttendanceError) {
      _lastAttendanceError = attendanceState.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showErrorToast(context, attendanceState.error!);
        }
      });
    }

    final rows = _buildStaffRows(staffState.staff, attendanceState.logs);
    final filteredRows = rows.where((row) {
      if (_roleFilter != 'all' && row.member.role != _roleFilter) {
        return false;
      }
      if (_statusFilter != 'all' && row.statusKey != _statusFilter) {
        return false;
      }
      final query = _searchController.text.trim().toLowerCase();
      if (query.isEmpty) return true;
      return row.member.fullName.toLowerCase().contains(query) ||
          (row.member.email ?? '').toLowerCase().contains(query) ||
          _roleLabelKo(context, row.member.role).toLowerCase().contains(query);
    }).toList();
    final selectedRow = _resolveSelectedRow(filteredRows);

    final roleOptions = <String>{
      'all',
      ...staffState.staff.map((member) => member.role),
    }.toList();
    final workingCount = rows.where((row) => row.statusKey == 'working').length;
    final absentCount = rows.where((row) => row.statusKey == 'absent').length;
    final permissionReviewCount = rows
        .where((row) => row.permissionNeedsReview)
        .length;
    Widget header({required bool compact}) => _buildStaffCommandHeader(
      staffCount: staffState.staff.length,
      workingCount: workingCount,
      absentCount: absentCount,
      permissionReviewCount: permissionReviewCount,
      roleOptions: roleOptions,
      storeId: storeId,
      viewerRole: viewerRole,
      compact: compact,
    );
    final loadingState = const SizedBox(
      height: 320,
      child: Center(
        child: CircularProgressIndicator(color: AppColors.amber500),
      ),
    );

    return Scaffold(
      key: const Key('staff_root'),
      backgroundColor: AppColors.surface0,
      body: LayoutBuilder(
        builder: (context, viewport) {
          final compact = viewport.maxWidth < 1120;
          if (compact) {
            return ToastResponsiveScrollBody(
              maxWidth: 1480,
              padding: const EdgeInsets.all(16),
              children: [
                header(compact: true),
                const SizedBox(height: 16),
                if (staffState.isLoading)
                  loadingState
                else if (filteredRows.isEmpty)
                  ToastWorkSurface(
                    child: SizedBox(
                      height: 260,
                      child: ToastOperationalEmptyState(
                        headline: l10n.staffNoVisibleStaff,
                      ),
                    ),
                  )
                else ...[
                  _buildSelectedStaffPane(
                    storeId: storeId,
                    row: selectedRow,
                    compact: true,
                  ),
                  const SizedBox(height: 16),
                  _buildStaffListPane(
                    rows: filteredRows,
                    selectedRow: selectedRow,
                    scrollable: false,
                  ),
                ],
              ],
            );
          }

          return ToastResponsiveBody(
            maxWidth: 1480,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header(compact: false),
                const SizedBox(height: 16),
                Expanded(
                  child: staffState.isLoading
                      ? loadingState
                      : filteredRows.isEmpty
                      ? ToastOperationalEmptyState(
                          headline: l10n.staffNoVisibleStaff,
                        )
                      : ToastSplitPane(
                          queueWidth: 460,
                          queue: _buildStaffListPane(
                            rows: filteredRows,
                            selectedRow: selectedRow,
                          ),
                          detail: _buildSelectedStaffPane(
                            storeId: storeId,
                            row: selectedRow,
                            compact: false,
                          ),
                          divider: false,
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildStaffCommandHeader({
    required int staffCount,
    required int workingCount,
    required int absentCount,
    required int permissionReviewCount,
    required List<String> roleOptions,
    required String? storeId,
    required String? viewerRole,
    bool compact = false,
  }) {
    final l10n = context.l10n;
    final statusOptions = <String, String>{
      'all': l10n.staffAllStatuses,
      'permission': l10n.staffPermissionReview,
      'working': l10n.staffWorking,
      'absent': l10n.staffAbsent,
      'off': l10n.staffDayOff,
      'done': l10n.staffAttendanceCompleted,
    };

    if (compact) {
      return ToastWorkSurface(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        backgroundColor: AppColors.surface1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    l10n.staffManagementTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.titleLarge?.copyWith(fontSize: 20),
                  ),
                ),
                const SizedBox(width: 8),
                ToastStatusBadge(
                  label: permissionReviewCount > 0
                      ? l10n.staffPermissionReviewRequired
                      : l10n.staffOperationalHealthy,
                  color: permissionReviewCount > 0
                      ? PosColors.warning
                      : PosColors.success,
                  compact: true,
                ),
              ],
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _compactStaffSignal(
                    label: l10n.staffTotalCount,
                    value: l10n.staffCount(staffCount),
                  ),
                  const SizedBox(width: 8),
                  _compactStaffSignal(
                    label: l10n.staffWorkingToday,
                    value: l10n.staffCount(workingCount),
                    tone: PosColors.success,
                  ),
                  const SizedBox(width: 8),
                  _compactStaffSignal(
                    label: l10n.staffAbsent,
                    value: l10n.staffCount(absentCount),
                    tone: absentCount > 0
                        ? PosColors.warning
                        : PosColors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  _compactStaffSignal(
                    label: l10n.staffPermissionReviewRequired,
                    value: l10n.staffCount(permissionReviewCount),
                    tone: permissionReviewCount > 0
                        ? PosColors.danger
                        : PosColors.success,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: l10n.staffSearchHint,
                prefixIcon: const Icon(Icons.search),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _roleFilter,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.staffAllRoles,
                      isDense: true,
                    ),
                    items: [
                      for (final role in roleOptions)
                        DropdownMenuItem(
                          value: role,
                          child: Text(
                            role == 'all'
                                ? l10n.staffAllRoles
                                : _roleLabelKo(context, role),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _roleFilter = value);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _statusFilter,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.staffAllStatuses,
                      isDense: true,
                    ),
                    items: [
                      for (final entry in statusOptions.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(
                            entry.value,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _statusFilter = value);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: storeId == null
                    ? null
                    : () => _showAddStaffSheet(
                        context,
                        storeId,
                        viewerRole: viewerRole,
                      ),
                icon: const Icon(Icons.person_add_alt_1, size: 18),
                label: Text(l10n.staffAddAction),
              ),
            ),
          ],
        ),
      );
    }

    return ToastWorkSurface(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      backgroundColor: AppColors.surface1,
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
                      l10n.staffManagementTitle,
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.staffManagementSubtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PosColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              ToastStatusBadge(
                label: permissionReviewCount > 0
                    ? l10n.staffPermissionReviewRequired
                    : l10n.staffOperationalHealthy,
                color: permissionReviewCount > 0
                    ? PosColors.warning
                    : PosColors.success,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 14),
          ToastMetricStrip(
            metrics: [
              ToastMetric(
                label: l10n.staffTotalCount,
                value: l10n.staffCount(staffCount),
              ),
              ToastMetric(
                label: l10n.staffWorkingToday,
                value: l10n.staffCount(workingCount),
                tone: PosColors.success,
              ),
              ToastMetric(
                label: l10n.staffAbsent,
                value: l10n.staffCount(absentCount),
                tone: absentCount > 0
                    ? PosColors.warning
                    : PosColors.textSecondary,
              ),
              ToastMetric(
                label: l10n.staffPermissionReviewRequired,
                value: l10n.staffCount(permissionReviewCount),
                tone: permissionReviewCount > 0
                    ? PosColors.danger
                    : PosColors.success,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 210,
                child: DropdownButtonFormField<String>(
                  initialValue: _roleFilter,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.staffAllRoles,
                    isDense: true,
                  ),
                  items: [
                    for (final role in roleOptions)
                      DropdownMenuItem(
                        value: role,
                        child: Text(
                          role == 'all'
                              ? l10n.staffAllRoles
                              : _roleLabelKo(context, role),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _roleFilter = value);
                  },
                ),
              ),
              SizedBox(
                width: 210,
                child: DropdownButtonFormField<String>(
                  initialValue: _statusFilter,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.staffAllStatuses,
                    isDense: true,
                  ),
                  items: [
                    for (final entry in statusOptions.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(
                          entry.value,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _statusFilter = value);
                  },
                ),
              ),
              SizedBox(
                width: 260,
                child: TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: l10n.staffSearchHint,
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: storeId == null
                    ? null
                    : () => _showAddStaffSheet(
                        context,
                        storeId,
                        viewerRole: viewerRole,
                      ),
                icon: const Icon(Icons.person_add_alt_1, size: 18),
                label: Text(l10n.staffAddAction),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _compactStaffSignal({
    required String label,
    required String value,
    Color? tone,
  }) {
    final color = tone ?? PosColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.14)),
      ),
      child: Text(
        '$label $value',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  List<_StaffBoardRow> _buildStaffRows(
    List<StaffMember> staff,
    List<AttendanceRecord> logs,
  ) {
    final logsByUser = <String, List<AttendanceRecord>>{};
    for (final log in logs) {
      logsByUser.putIfAbsent(log.userId, () => []).add(log);
    }

    final rows = staff.map((member) {
      final memberLogs = [
        ...(logsByUser[member.id] ?? const <AttendanceRecord>[]),
      ];
      memberLogs.sort((a, b) => b.loggedAt.compareTo(a.loggedAt));

      DateTime? firstClockIn;
      DateTime? lastClockOut;
      for (final log in memberLogs) {
        if (log.type == 'clock_in') {
          firstClockIn =
              firstClockIn == null || log.loggedAt.isBefore(firstClockIn)
              ? log.loggedAt
              : firstClockIn;
        }
        if (log.type == 'clock_out') {
          lastClockOut =
              lastClockOut == null || log.loggedAt.isAfter(lastClockOut)
              ? log.loggedAt
              : lastClockOut;
        }
      }

      final permissionNeedsReview =
          member.authId.isEmpty ||
          !_isKnownRole(member.role) ||
          member.extraPermissions.any(
            (permission) =>
                permission != 'qc_check' && permission != 'inventory_count',
          );

      final statusKey = !member.isActive
          ? 'off'
          : permissionNeedsReview
          ? 'permission'
          : firstClockIn == null
          ? 'absent'
          : lastClockOut == null
          ? 'working'
          : 'done';

      final statusLabel = switch (statusKey) {
        'off' => context.l10n.staffDayOff,
        'permission' => context.l10n.staffPermissionReview,
        'absent' => context.l10n.staffAbsent,
        'working' => context.l10n.staffWorking,
        'done' => context.l10n.staffAttendanceCompleted,
        _ => context.l10n.staffAbsent,
      };

      final statusColor = switch (statusKey) {
        'off' => PosColors.textSecondary,
        'permission' => PosColors.warning,
        'absent' => PosColors.danger,
        'working' => PosColors.success,
        'done' => PosColors.info,
        _ => PosColors.textSecondary,
      };

      return _StaffBoardRow(
        member: member,
        logs: memberLogs,
        firstClockIn: firstClockIn,
        lastClockOut: lastClockOut,
        statusKey: statusKey,
        statusLabel: statusLabel,
        statusColor: statusColor,
        permissionNeedsReview: permissionNeedsReview,
      );
    }).toList();

    rows.sort((a, b) {
      final statusCompare = _statusPriority(
        a.statusKey,
      ).compareTo(_statusPriority(b.statusKey));
      if (statusCompare != 0) return statusCompare;
      return a.member.fullName.compareTo(b.member.fullName);
    });
    return rows;
  }

  int _statusPriority(String statusKey) {
    return switch (statusKey) {
      'permission' => 0,
      'working' => 1,
      'absent' => 2,
      'off' => 3,
      _ => 4,
    };
  }

  _StaffBoardRow? _resolveSelectedRow(List<_StaffBoardRow> rows) {
    if (rows.isEmpty) return null;
    if (_selectedStaffId == null) return rows.first;
    for (final row in rows) {
      if (row.member.id == _selectedStaffId) {
        return row;
      }
    }
    return rows.first;
  }

  Widget _buildStaffListPane({
    required List<_StaffBoardRow> rows,
    required _StaffBoardRow? selectedRow,
    bool scrollable = true,
  }) {
    return ToastWorkSurface(
      padding: const EdgeInsets.all(12),
      child: ListView.separated(
        shrinkWrap: !scrollable,
        physics: scrollable ? null : const NeverScrollableScrollPhysics(),
        itemCount: rows.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final row = rows[index];
          final selected = selectedRow?.member.id == row.member.id;
          return InkWell(
            onTap: () => setState(() => _selectedStaffId = row.member.id),
            borderRadius: BorderRadius.circular(10),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: selected ? PosColors.accentMuted : PosColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? PosColors.accent : PosColors.border,
                  width: selected ? 1.5 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          row.member.fullName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ToastStatusBadge(
                        label: row.statusLabel,
                        color: row.statusColor,
                        compact: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _RoleBadge(role: row.member.role),
                      _metaTag(
                        row.member.email?.isNotEmpty == true
                            ? row.member.email!
                            : context.l10n.staffEmailMissing,
                      ),
                      _metaTag(
                        row.firstClockIn == null
                            ? context.l10n.staffNoClockInRecords
                            : context.l10n.staffClockedInAt(
                                _formatTime(row.firstClockIn),
                              ),
                      ),
                      if (row.permissionNeedsReview)
                        _metaTag(context.l10n.staffPermissionReview),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSelectedStaffPane({
    required String? storeId,
    required _StaffBoardRow? row,
    bool compact = false,
  }) {
    if (row == null) {
      return ToastOperationalEmptyState(
        headline: context.l10n.staffNoSelection,
      );
    }

    final canEditPermissions =
        storeId != null && _canEditPermissionsForRole(row.member.role);

    if (compact) {
      return ToastWorkSurface(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: PosColors.accentMuted,
                  child: Text(
                    _initialsForName(row.member.fullName),
                    style: AppFonts.system(
                      color: PosColors.accent,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.member.fullName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_roleLabelKo(context, row.member.role)} · ${row.member.email?.isNotEmpty == true ? row.member.email! : context.l10n.staffEmailMissing}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: PosColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ToastStatusBadge(
                  label: row.statusLabel,
                  color: row.statusColor,
                  compact: true,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _StaffDetailDisclosure(
              row: row,
              canEditPermissions: canEditPermissions,
              onChangePermission: canEditPermissions
                  ? () => _showPermissionDialog(
                      context: context,
                      storeId: storeId,
                      member: row.member,
                    )
                  : null,
              onViewAttendance: () => _showAttendanceLogSheet(row),
              attendanceTypeLabel: _attendanceTypeLabel,
              roleLabel: (role) => _roleLabelKo(context, role),
              initiallyExpanded: true,
              showAttendancePreview: false,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: storeId == null
                    ? null
                    : () => ref
                          .read(staffProvider.notifier)
                          .toggleActive(
                            row.member.id,
                            !row.member.isActive,
                            storeId,
                          ),
                icon: Icon(
                  row.member.isActive
                      ? Icons.person_off_outlined
                      : Icons.person,
                  size: 16,
                ),
                label: Text(
                  row.member.isActive
                      ? context.l10n.staffDeactivate
                      : context.l10n.staffActivate,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _detailMetric(
                  context.l10n.staffTodayClockIn,
                  _formatTime(row.firstClockIn),
                  compact: true,
                ),
                _detailMetric(
                  context.l10n.staffClockOutRecord,
                  row.lastClockOut == null
                      ? '--:--'
                      : _formatTime(row.lastClockOut),
                  compact: true,
                ),
                _detailMetric(
                  context.l10n.staffPermissionStatus,
                  row.permissionNeedsReview
                      ? context.l10n.staffPermissionReview
                      : row.member.extraPermissions.isEmpty
                      ? context.l10n.staffDefaultPermission
                      : context.l10n.staffAdditionalPermissions(
                          row.member.extraPermissions.length,
                        ),
                  compact: true,
                ),
                _detailMetric(
                  context.l10n.staffRegisteredAt,
                  DateFormat(
                    'yyyy-MM-dd',
                  ).format(row.member.createdAt.toLocal()),
                  compact: true,
                ),
              ],
            ),
          ],
        ),
      );
    }

    return ToastWorkSurface(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: PosColors.accentMuted,
                child: Text(
                  _initialsForName(row.member.fullName),
                  style: AppFonts.system(
                    color: PosColors.accent,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.member.fullName,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_roleLabelKo(context, row.member.role)} · ${row.member.email?.isNotEmpty == true ? row.member.email! : context.l10n.staffEmailMissing}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: PosColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              ToastStatusBadge(
                label: row.statusLabel,
                color: row.statusColor,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _detailMetric(
                context.l10n.staffTodayClockIn,
                _formatTime(row.firstClockIn),
              ),
              _detailMetric(
                context.l10n.staffClockOutRecord,
                row.lastClockOut == null
                    ? '--:--'
                    : _formatTime(row.lastClockOut),
              ),
              _detailMetric(
                context.l10n.staffPermissionStatus,
                row.permissionNeedsReview
                    ? context.l10n.staffPermissionReview
                    : row.member.extraPermissions.isEmpty
                    ? context.l10n.staffDefaultPermission
                    : context.l10n.staffAdditionalPermissions(
                        row.member.extraPermissions.length,
                      ),
              ),
              _detailMetric(
                context.l10n.staffRegisteredAt,
                DateFormat('yyyy-MM-dd').format(row.member.createdAt.toLocal()),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: storeId == null
                  ? null
                  : () => ref
                        .read(staffProvider.notifier)
                        .toggleActive(
                          row.member.id,
                          !row.member.isActive,
                          storeId,
                        ),
              icon: Icon(
                row.member.isActive ? Icons.person_off_outlined : Icons.person,
                size: 16,
              ),
              label: Text(
                row.member.isActive
                    ? context.l10n.staffDeactivate
                    : context.l10n.staffActivate,
              ),
            ),
          ),
          const SizedBox(height: 12),
          _StaffDetailDisclosure(
            row: row,
            canEditPermissions: canEditPermissions,
            onChangePermission: canEditPermissions
                ? () => _showPermissionDialog(
                    context: context,
                    storeId: storeId,
                    member: row.member,
                  )
                : null,
            onViewAttendance: () => _showAttendanceLogSheet(row),
            attendanceTypeLabel: _attendanceTypeLabel,
            roleLabel: (role) => _roleLabelKo(context, role),
          ),
        ],
      ),
    );
  }

  Widget _metaTag(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: PosColors.panelMuted,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: PosColors.border),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: PosColors.textSecondary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _detailMetric(String label, String value, {bool compact = false}) {
    return SizedBox(
      width: compact ? 148 : 180,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical: compact ? 8 : 10,
        ),
        decoration: BoxDecoration(
          color: PosColors.panelMuted,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: PosColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PosColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime? value) {
    if (value == null) return '--:--';
    return DateFormat('HH:mm').format(value.toLocal());
  }

  String _initialsForName(String name) {
    final parts = name
        .split(RegExp(r'\s+'))
        .where((part) => part.trim().isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return '${parts.first.substring(0, 1)}${parts.last.substring(0, 1)}'
        .toUpperCase();
  }

  bool _isKnownRole(String role) {
    const roles = {
      'waiter',
      'kitchen',
      'cashier',
      'admin',
      'store_admin',
      'brand_admin',
      'photo_objet_master',
      'photo_objet_store_admin',
      'super_admin',
    };
    return roles.contains(role.toLowerCase());
  }

  bool _canEditPermissionsForRole(String role) {
    return canManageExtraPermissions(role);
  }

  String _attendanceTypeLabel(String type) {
    final l10n = context.l10n;
    return switch (type) {
      'clock_in' => l10n.clockIn,
      'clock_out' => l10n.clockOut,
      _ => type,
    };
  }

  Future<void> _showAttendanceLogSheet(_StaffBoardRow row) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface1,
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.staffAttendanceSheetTitle(row.member.fullName),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              if (row.logs.isEmpty)
                Text(
                  context.l10n.staffNoLogsTodayShort,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: PosColors.textSecondary,
                  ),
                )
              else
                ...row.logs.map(
                  (log) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        ToastStatusBadge(
                          label: _attendanceTypeLabel(log.type),
                          color: log.type == 'clock_in'
                              ? PosColors.success
                              : PosColors.info,
                          compact: true,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          DateFormat(
                            'yyyy-MM-dd HH:mm',
                          ).format(log.loggedAt.toLocal()),
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showAddStaffSheet(
    BuildContext context,
    String storeId, {
    required String? viewerRole,
  }) async {
    final fullNameController = TextEditingController();
    final emailController = TextEditingController();
    final passwordController = TextEditingController();
    String role = 'waiter';
    String? validationMessage;
    final notifier = ref.read(staffProvider.notifier);
    final rootContext = context;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface1,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: StatefulBuilder(
            builder: (context, setModalState) {
              final isCreating = ref.watch(staffProvider).isCreating;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.staffAddAction,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: fullNameController,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(labelText: context.l10n.name),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: emailController,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(labelText: context.l10n.email),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: context.l10n.password,
                      hintText: context.l10n.staffPasswordHint,
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: role,
                    dropdownColor: AppColors.surface1,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    items: _availableRoleOptions(context, viewerRole),
                    onChanged: (value) {
                      if (value != null) {
                        setModalState(() => role = value);
                      }
                    },
                  ),
                  if (validationMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      key: const Key('staff_create_validation_message'),
                      validationMessage!,
                      style: AppFonts.system(
                        color: AppColors.statusCancelled,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: isCreating
                          ? null
                          : () async {
                              final fullName = fullNameController.text.trim();
                              final email = emailController.text.trim();
                              final password = passwordController.text.trim();
                              if (fullName.isEmpty ||
                                  email.isEmpty ||
                                  password.isEmpty) {
                                setModalState(() {
                                  validationMessage =
                                      context
                                          .l10n
                                          .staffCreateValidationRequired;
                                });
                                return;
                              }
                              if (!email.contains('@')) {
                                setModalState(() {
                                  validationMessage =
                                      context.l10n.redInvoiceInvalidEmail;
                                });
                                return;
                              }
                              if (password.length < 6) {
                                setModalState(() {
                                  validationMessage =
                                      context
                                          .l10n
                                          .staffCreateValidationPasswordLength;
                                });
                                return;
                              }
                              setModalState(() => validationMessage = null);

                              await notifier.createStaff(
                                storeId: storeId,
                                email: email,
                                password: password,
                                fullName: fullName,
                                role: role,
                              );

                              if (!context.mounted) return;
                              final nextState = ref.read(staffProvider);
                              if (nextState.error != null) {
                                setModalState(() {
                                  validationMessage =
                                      _localizedStaffCreationMessage(
                                        context,
                                        nextState.error!,
                                        genericForUnknown: true,
                                      );
                                });
                                return;
                              }
                              Navigator.of(context).pop();
                              if (!rootContext.mounted) return;
                              showSuccessToast(
                                rootContext,
                                rootContext.l10n.staffCreatedMessage,
                              );
                              await _showStaffCredentialDialog(
                                rootContext,
                                email: email,
                                password: password,
                              );
                            },
                      child: isCreating
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(context.l10n.staffAddAction),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(context.l10n.close),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );

    fullNameController.dispose();
    emailController.dispose();
    passwordController.dispose();
  }

  Future<void> _showStaffCredentialDialog(
    BuildContext context, {
    required String email,
    required String password,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        final l10n = context.l10n;
        return AlertDialog(
          key: const Key('staff_created_credentials_dialog'),
          backgroundColor: AppColors.surface1,
          title: Text(
            l10n.staffCreatedMessage,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w800,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CredentialValueRow(label: l10n.email, value: email),
              const SizedBox(height: 10),
              _CredentialValueRow(label: l10n.password, value: password),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.close),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showPermissionDialog({
    required BuildContext context,
    required String storeId,
    required StaffMember member,
  }) async {
    final notifier = ref.read(staffProvider.notifier);
    bool canQc = member.extraPermissions.contains('qc_check');
    bool canCount = member.extraPermissions.contains('inventory_count');

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              backgroundColor: AppColors.surface1,
              title: Text(
                context.l10n.staffPermissionDialogTitle(member.fullName),
                style: AppFonts.system(color: AppColors.textPrimary),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CheckboxListTile(
                    value: canQc,
                    activeColor: AppColors.amber500,
                    title: Text(
                      context.l10n.staffQcPermission,
                      style: AppFonts.system(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                      ),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (value) =>
                        setModalState(() => canQc = value ?? false),
                  ),
                  CheckboxListTile(
                    value: canCount,
                    activeColor: AppColors.amber500,
                    title: Text(
                      context.l10n.staffInventoryCountPermission,
                      style: AppFonts.system(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                      ),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (value) =>
                        setModalState(() => canCount = value ?? false),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.l10n.cancel),
                ),
                FilledButton(
                  onPressed: () async {
                    final permissions = <String>[
                      if (canQc) 'qc_check',
                      if (canCount) 'inventory_count',
                    ];
                    await notifier.updateExtraPermissions(
                      userId: member.id,
                      storeId: storeId,
                      permissions: permissions,
                    );
                    if (!context.mounted) return;
                    final nextState = ref.read(staffProvider);
                    if (nextState.error != null) return;
                    Navigator.of(context).pop();
                    showSuccessToast(
                      context,
                      context.l10n.staffPermissionsSaved,
                    );
                  },
                  child: Text(context.l10n.save),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

String _localizedStaffCreationMessage(
  BuildContext context,
  String raw, {
  bool genericForUnknown = false,
}) {
  final lower = raw.toLowerCase();
  final l10n = context.l10n;
  if (lower.contains('missing required')) {
    return l10n.staffCreateErrorMissingRequired;
  }
  if (lower.contains('unsupported role')) {
    return l10n.staffCreateErrorUnsupportedRole;
  }
  if (lower.contains('cannot create admin accounts') ||
      lower.contains('cannot create this role')) {
    return l10n.staffCreateErrorElevatedRoleForbidden;
  }
  if (lower.contains('another store') || lower.contains('another brand')) {
    return l10n.staffCreateErrorScope;
  }
  if (lower.contains('target store not found') ||
      lower.contains('target store is inactive')) {
    return l10n.staffCreateErrorStoreInactive;
  }
  if (lower.contains('already') || lower.contains('duplicate')) {
    return l10n.staffCreateErrorDuplicate;
  }
  if (lower.contains('auth user') || lower.contains('unauthorized')) {
    return l10n.staffCreateErrorAuth;
  }
  if (lower.contains('timed out')) {
    return l10n.staffCreateErrorTimedOut;
  }
  return genericForUnknown ? l10n.staffCreateErrorGeneric : raw;
}

class _StaffBoardRow {
  const _StaffBoardRow({
    required this.member,
    required this.logs,
    required this.firstClockIn,
    required this.lastClockOut,
    required this.statusKey,
    required this.statusLabel,
    required this.statusColor,
    required this.permissionNeedsReview,
  });

  final StaffMember member;
  final List<AttendanceRecord> logs;
  final DateTime? firstClockIn;
  final DateTime? lastClockOut;
  final String statusKey;
  final String statusLabel;
  final Color statusColor;
  final bool permissionNeedsReview;
}

class _StaffDetailDisclosure extends StatelessWidget {
  const _StaffDetailDisclosure({
    required this.row,
    required this.canEditPermissions,
    required this.onChangePermission,
    required this.onViewAttendance,
    required this.attendanceTypeLabel,
    required this.roleLabel,
    this.initiallyExpanded = false,
    this.showAttendancePreview = true,
  });

  final _StaffBoardRow row;
  final bool canEditPermissions;
  final VoidCallback? onChangePermission;
  final VoidCallback onViewAttendance;
  final String Function(String type) attendanceTypeLabel;
  final String Function(String role) roleLabel;
  final bool initiallyExpanded;
  final bool showAttendancePreview;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: ExpansionTile(
        key: const Key('staff_detail_secondary_detail'),
        initiallyExpanded: initiallyExpanded,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        iconColor: AppColors.textSecondary,
        collapsedIconColor: AppColors.textSecondary,
        title: Text(
          context.l10n.staffQuickActions,
          style: AppFonts.system(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          '${context.l10n.staffViewAttendanceLog} · ${context.l10n.staffChangePermission}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppFonts.system(
            color: AppColors.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: canEditPermissions ? onChangePermission : null,
                  icon: const Icon(Icons.verified_user_outlined, size: 16),
                  label: Text(context.l10n.staffChangePermission),
                ),
                OutlinedButton.icon(
                  onPressed: onViewAttendance,
                  icon: const Icon(Icons.history_outlined, size: 16),
                  label: Text(context.l10n.staffViewAttendanceLog),
                ),
              ],
            ),
          ),
          if (showAttendancePreview) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                context.l10n.staffTodayAttendanceLog,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 8),
            if (row.logs.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: PosColors.panelMuted,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: PosColors.border),
                ),
                child: Text(
                  context.l10n.staffNoLogsToday,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textSecondary,
                  ),
                ),
              )
            else
              ...row.logs
                  .take(5)
                  .map(
                    (log) => Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: PosColors.surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: PosColors.border),
                      ),
                      child: Row(
                        children: [
                          ToastStatusBadge(
                            label: attendanceTypeLabel(log.type),
                            color: log.type == 'clock_in'
                                ? PosColors.success
                                : PosColors.info,
                            compact: true,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              DateFormat(
                                'yyyy-MM-dd HH:mm',
                              ).format(log.loggedAt.toLocal()),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          Text(
                            roleLabel(log.userRole ?? row.member.role),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: PosColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ),
          ],
        ],
      ),
    );
  }
}

class _CredentialValueRow extends StatelessWidget {
  const _CredentialValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: PosSurfaceRole.action.fill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PosSurfaceRole.action.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: PosColors.textSecondary,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            value,
            style: AppFonts.system(
              color: PosColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    final normalized = role.toLowerCase();
    final color = switch (normalized) {
      'waiter' => const Color(0xFF2563EB),
      'kitchen' => AppColors.statusOccupied,
      'cashier' => AppColors.statusAvailable,
      'admin' => const Color(0xFF111827),
      'store_admin' => const Color(0xFF7C3AED),
      'brand_admin' => const Color(0xFFD97706),
      'photo_objet_master' => const Color(0xFF0891B2),
      'photo_objet_store_admin' => const Color(0xFF0EA5E9),
      'super_admin' => const Color(0xFFDC2626),
      _ => AppColors.surface2,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        _roleLabelKo(context, normalized),
        style: AppFonts.system(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String _roleLabelKo(BuildContext context, String role) {
  final l10n = context.l10n;
  return switch (role.toLowerCase()) {
    'waiter' => l10n.staffRoleWaiter,
    'kitchen' => l10n.staffRoleKitchen,
    'cashier' => l10n.staffRoleCashier,
    'admin' => l10n.staffRoleAdmin,
    'store_admin' => l10n.staffRoleStoreAdmin,
    'brand_admin' => l10n.staffRoleBrandAdmin,
    'photo_objet_master' => l10n.staffRolePhotoMaster,
    'photo_objet_store_admin' => l10n.staffRolePhotoStoreAdmin,
    'super_admin' => l10n.staffRoleSuperAdmin,
    _ => role,
  };
}

List<DropdownMenuItem<String>> _availableRoleOptions(
  BuildContext context,
  String? viewerRole,
) {
  return [
    for (final role in assignableRolesForViewer(viewerRole))
      DropdownMenuItem(value: role, child: Text(_roleLabelKo(context, role))),
  ];
}
