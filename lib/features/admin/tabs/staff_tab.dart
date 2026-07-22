import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:intl/intl.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../core/ui/pos_design_tokens.dart';
import '../../../core/ui/app_theme.dart';
import '../../../core/ui/toast/toast.dart';
import '../../../widgets/error_toast.dart';
import '../../auth/auth_provider.dart';
import '../providers/staff_provider.dart';

class StaffTab extends ConsumerStatefulWidget {
  const StaffTab({super.key});

  @override
  ConsumerState<StaffTab> createState() => _StaffTabState();
}

class _StaffTabState extends ConsumerState<StaffTab> {
  String? _initializedStoreId;
  String? _lastError;
  String? _lastAttendanceError;
  String? _selectedStaffId;
  String _roleFilter = 'all';
  String _statusFilter = 'active';
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final storeId = ref.watch(authProvider).storeId;
    final staffState = ref.watch(staffProvider);
    final attendanceState = ref.watch(attendanceProvider);

    if (storeId != null && _initializedStoreId != storeId) {
      _initializedStoreId = storeId;
      Future.microtask(() async {
        await ref.read(staffProvider.notifier).loadStaff(storeId);
        await ref.read(attendanceProvider.notifier).loadLogs(storeId);
      });
    }

    _showErrors(staffState, attendanceState);
    final rows = _buildStaffRows(staffState.staff, attendanceState.logs);
    final filteredRows = rows.where(_matchesFilters).toList();
    final selectedRow = _resolveSelectedRow(filteredRows);
    final workingCount = rows.where((row) => row.statusKey == 'working').length;
    final activeCount = rows.where((row) => row.member.isActive).length;

    Widget header({required bool compact}) => _buildStaffCommandHeader(
      staffCount: staffState.staff.length,
      activeCount: activeCount,
      workingCount: workingCount,
      storeId: storeId,
      compact: compact,
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
                  const _StaffLoading()
                else if (filteredRows.isEmpty)
                  ToastWorkSurface(
                    child: SizedBox(
                      height: 260,
                      child: ToastOperationalEmptyState(
                        headline: context.l10n.staffNoVisibleStaff,
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
                      ? const _StaffLoading()
                      : filteredRows.isEmpty
                      ? ToastOperationalEmptyState(
                          headline: context.l10n.staffNoVisibleStaff,
                        )
                      : ToastSplitPane(
                          queueWidth: 440,
                          queue: _buildStaffListPane(
                            rows: filteredRows,
                            selectedRow: selectedRow,
                          ),
                          detail: _buildSelectedStaffPane(
                            storeId: storeId,
                            row: selectedRow,
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

  void _showErrors(StaffState staffState, AttendanceState attendanceState) {
    if (staffState.error != null && staffState.error != _lastError) {
      _lastError = staffState.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showErrorToast(context, context.l10n.staffEmployeeSaveFailed);
        }
      });
    }
    if (attendanceState.error != null &&
        attendanceState.error != _lastAttendanceError) {
      _lastAttendanceError = attendanceState.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showErrorToast(context, context.l10n.attendanceLoadFailed);
        }
      });
    }
  }

  bool _matchesFilters(_StaffBoardRow row) {
    if (_roleFilter != 'all' && row.member.role != _roleFilter) return false;
    if (_statusFilter == 'active' && !row.member.isActive) return false;
    if (_statusFilter == 'inactive' && row.member.isActive) return false;
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    return row.member.fullName.toLowerCase().contains(query) ||
        row.member.employeeNumber.toLowerCase().contains(query) ||
        (row.member.phone ?? '').toLowerCase().contains(query) ||
        _roleLabel(context, row.member.role).toLowerCase().contains(query);
  }

  Widget _buildStaffCommandHeader({
    required int staffCount,
    required int activeCount,
    required int workingCount,
    required String? storeId,
    required bool compact,
  }) {
    final filterBar = Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        SizedBox(
          width: compact ? 165 : 190,
          child: DropdownButtonFormField<String>(
            initialValue: _roleFilter,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: context.l10n.staffAllRoles,
              isDense: true,
            ),
            items: [
              DropdownMenuItem(
                value: 'all',
                child: Text(
                  context.l10n.staffAllRoles,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              for (final role in _employmentRoles)
                DropdownMenuItem(
                  value: role,
                  child: Text(
                    _roleLabel(context, role),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) => setState(() => _roleFilter = value ?? 'all'),
          ),
        ),
        SizedBox(
          width: compact ? 165 : 190,
          child: DropdownButtonFormField<String>(
            initialValue: _statusFilter,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: context.l10n.staffAllStatuses,
              isDense: true,
            ),
            items: [
              DropdownMenuItem(
                value: 'all',
                child: Text(
                  context.l10n.staffAllStatuses,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DropdownMenuItem(
                value: 'active',
                child: Text(
                  context.l10n.staffEmployeeActive,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DropdownMenuItem(
                value: 'inactive',
                child: Text(
                  context.l10n.staffEmployeeInactive,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            onChanged: (value) =>
                setState(() => _statusFilter = value ?? 'active'),
          ),
        ),
        SizedBox(
          width: compact ? 340 : 260,
          child: TextField(
            controller: _searchController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: context.l10n.staffEmployeeSearchHint,
              prefixIcon: const Icon(Icons.search),
              isDense: true,
            ),
          ),
        ),
        FilledButton.icon(
          key: const Key('admin_staff_add_action'),
          onPressed: storeId == null
              ? null
              : () => _showEmployeeForm(storeId: storeId),
          icon: const Icon(Icons.person_add_alt_1, size: 18),
          label: Text(context.l10n.staffAddAction),
        ),
      ],
    );

    return ToastWorkSurface(
      padding: EdgeInsets.all(compact ? 14 : 18),
      backgroundColor: AppColors.surface1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.staffManagementTitle,
                      style: compact
                          ? Theme.of(context).textTheme.titleLarge
                          : Theme.of(context).textTheme.headlineLarge,
                    ),
                    if (!compact) ...[
                      const SizedBox(height: 4),
                      Text(
                        context.l10n.staffEmployeeManagementSubtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: PosColors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              ToastStatusBadge(
                label: context.l10n.staffEmployeeNumberOnlyBadge,
                color: PosColors.success,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (compact)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ToastMetricStrip(
                metrics: _staffMetrics(staffCount, activeCount, workingCount),
              ),
            )
          else
            ToastMetricStrip(
              metrics: _staffMetrics(staffCount, activeCount, workingCount),
            ),
          const SizedBox(height: 12),
          filterBar,
        ],
      ),
    );
  }

  List<ToastMetric> _staffMetrics(int total, int active, int working) => [
    ToastMetric(
      label: context.l10n.staffTotalCount,
      value: context.l10n.staffCount(total),
    ),
    ToastMetric(
      label: context.l10n.staffEmployeeActive,
      value: context.l10n.staffCount(active),
      tone: PosColors.success,
    ),
    ToastMetric(
      label: context.l10n.staffWorkingToday,
      value: context.l10n.staffCount(working),
      tone: PosColors.info,
    ),
  ];

  List<_StaffBoardRow> _buildStaffRows(
    List<StaffMember> staff,
    List<AttendanceRecord> logs,
  ) {
    final logsByEmployee = <String, List<AttendanceRecord>>{};
    for (final log in logs) {
      logsByEmployee.putIfAbsent(log.userId, () => []).add(log);
    }

    final rows = staff.map((member) {
      final memberLogs = <AttendanceRecord>[
        ...(logsByEmployee[member.id] ?? const <AttendanceRecord>[]),
      ]..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
      final clockIns = memberLogs.where((log) => log.type == 'clock_in');
      final clockOuts = memberLogs.where((log) => log.type == 'clock_out');
      final firstClockIn = clockIns.isEmpty
          ? null
          : clockIns
                .map((log) => log.loggedAt)
                .reduce((a, b) => a.isBefore(b) ? a : b);
      final lastClockOut = clockOuts.isEmpty
          ? null
          : clockOuts
                .map((log) => log.loggedAt)
                .reduce((a, b) => a.isAfter(b) ? a : b);
      final statusKey = !member.isActive
          ? 'inactive'
          : firstClockIn == null
          ? 'absent'
          : lastClockOut == null || lastClockOut.isBefore(firstClockIn)
          ? 'working'
          : 'done';
      return _StaffBoardRow(
        member: member,
        logs: memberLogs,
        firstClockIn: firstClockIn,
        lastClockOut: lastClockOut,
        statusKey: statusKey,
      );
    }).toList();
    rows.sort((a, b) {
      if (a.member.isActive != b.member.isActive) {
        return a.member.isActive ? -1 : 1;
      }
      return a.member.employeeNumber.compareTo(b.member.employeeNumber);
    });
    return rows;
  }

  _StaffBoardRow? _resolveSelectedRow(List<_StaffBoardRow> rows) {
    if (rows.isEmpty) return null;
    return rows.firstWhere(
      (row) => row.member.id == _selectedStaffId,
      orElse: () => rows.first,
    );
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
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: selected ? PosColors.accentMuted : PosColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? PosColors.accent : PosColors.border,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          row.member.fullName,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      ToastStatusBadge(
                        label: _statusLabel(context, row.statusKey),
                        color: _statusColor(row.statusKey),
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
                      _MetaTag(
                        label: context.l10n.staffEmployeeNumberValue(
                          row.member.employeeNumber,
                        ),
                      ),
                      if (row.member.phone?.isNotEmpty == true)
                        _MetaTag(label: row.member.phone!),
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
    final member = row.member;
    return ToastWorkSurface(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        physics: compact ? const NeverScrollableScrollPhysics() : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: PosColors.accentMuted,
                  child: Text(
                    _initials(member.fullName),
                    style: AppFonts.system(
                      color: PosColors.accent,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        member.fullName,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_roleLabel(context, member.role)} · ${member.employeeNumber}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: PosColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                ToastStatusBadge(
                  label: _statusLabel(context, row.statusKey),
                  color: _statusColor(row.statusKey),
                  compact: true,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _DetailMetric(
                  label: context.l10n.attendanceEmployeeNumber,
                  value: member.employeeNumber,
                ),
                _DetailMetric(
                  label: context.l10n.staffEmployeePhone,
                  value: member.phone?.isNotEmpty == true ? member.phone! : '-',
                ),
                _DetailMetric(
                  label: context.l10n.staffTodayClockIn,
                  value: _formatTime(row.firstClockIn),
                ),
                _DetailMetric(
                  label: context.l10n.staffClockOutRecord,
                  value: _formatTime(row.lastClockOut),
                ),
                _DetailMetric(
                  label: context.l10n.staffEmployeeBankName,
                  value: member.bankName?.isNotEmpty == true
                      ? member.bankName!
                      : '-',
                ),
                _DetailMetric(
                  label: context.l10n.staffEmployeeBankAccount,
                  value: member.bankAccountNumber?.isNotEmpty == true
                      ? member.bankAccountNumber!
                      : '-',
                ),
                if (member.role == 'part_timer')
                  _DetailMetric(
                    label: context.l10n.staffHourlyRuleSummary,
                    value: member.hourlyPayRule == null
                        ? context.l10n.staffHourlyRuleNotConfigured
                        : context.l10n.staffHourlyRuleConfigured(
                            member.hourlyPayRule!.hourlyRate.toStringAsFixed(0),
                            member.hourlyPayRule!.nightMultiplier,
                            member.hourlyPayRule!.holidayMultiplier,
                          ),
                  ),
                _DetailMetric(
                  label: context.l10n.staffRegisteredAt,
                  value: DateFormat('yyyy-MM-dd').format(member.createdAt),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _StaffDetailDisclosure(
              row: row,
              initiallyExpanded: compact,
              showAttendancePreview: !compact,
              onEdit: storeId == null || !member.isActive
                  ? null
                  : () => _showEmployeeForm(storeId: storeId, employee: member),
              onViewAttendance: () => _showAttendanceLogSheet(row),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: const Key('staff_deactivate_employee_action'),
                onPressed: storeId == null || !member.isActive
                    ? null
                    : () => _confirmDeactivate(storeId, member),
                icon: const Icon(Icons.person_off_outlined, size: 18),
                label: Text(
                  member.isActive
                      ? context.l10n.staffDeactivate
                      : context.l10n.staffEmployeeInactive,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showEmployeeForm({
    required String storeId,
    StaffMember? employee,
  }) async {
    final name = TextEditingController(text: employee?.fullName);
    final phone = TextEditingController(text: employee?.phone);
    final bankName = TextEditingController(text: employee?.bankName);
    final bankNumber = TextEditingController(text: employee?.bankAccountNumber);
    final bankHolder = TextEditingController(text: employee?.bankAccountHolder);
    final hourlyRule = employee?.hourlyPayRule;
    final hourlyRate = TextEditingController(
      text: hourlyRule == null ? '' : hourlyRule.hourlyRate.toStringAsFixed(0),
    );
    final scheduledStart = TextEditingController(
      text: hourlyRule?.scheduledStart ?? '09:00',
    );
    final nightStart = TextEditingController(
      text: hourlyRule?.nightStart ?? '22:00',
    );
    final nightMultiplier = TextEditingController(
      text: '${hourlyRule?.nightMultiplier ?? 1.3}',
    );
    final holidayMultiplier = TextEditingController(
      text: '${hourlyRule?.holidayMultiplier ?? 3}',
    );
    final lateThreshold = TextEditingController(
      text: '${hourlyRule?.lateThresholdMinutes ?? 60}',
    );
    final lateReview = TextEditingController(
      text: '${hourlyRule?.lateReviewHourlyMultiplier ?? 2}',
    );
    var role = employee?.role ?? 'part_timer';
    String? validation;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface1,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          key: const Key('admin_staff_add_sheet'),
          padding: EdgeInsets.fromLTRB(
            18,
            18,
            18,
            MediaQuery.viewInsetsOf(context).bottom + 18,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  employee == null
                      ? context.l10n.staffEmployeeCreateTitle
                      : context.l10n.staffEmployeeEditTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  employee == null
                      ? context.l10n.staffEmployeeNumberGeneratedHint
                      : context.l10n.staffEmployeeNumberReadOnly(
                          employee.employeeNumber,
                        ),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  key: const Key('staff_employee_name_field'),
                  controller: name,
                  decoration: InputDecoration(labelText: context.l10n.name),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  key: const Key('staff_employee_role_field'),
                  initialValue: role,
                  decoration: InputDecoration(
                    labelText: context.l10n.staffEmployeeRole,
                  ),
                  items: [
                    for (final value in _employmentRoles)
                      DropdownMenuItem(
                        value: value,
                        child: Text(_roleLabel(context, value)),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setModalState(() => role = value);
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: phone,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: context.l10n.staffEmployeePhone,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const Key('staff_employee_bank_name_field'),
                  controller: bankName,
                  decoration: InputDecoration(
                    labelText: context.l10n.staffEmployeeBankName,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: bankNumber,
                  decoration: InputDecoration(
                    labelText: context.l10n.staffEmployeeBankAccount,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: bankHolder,
                  decoration: InputDecoration(
                    labelText: context.l10n.staffEmployeeBankHolder,
                  ),
                ),
                if (role == 'part_timer') ...[
                  const SizedBox(height: 18),
                  Text(
                    context.l10n.staffHourlyRulesTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    context.l10n.staffHourlyRulesHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const Key('staff_hourly_rate_field'),
                    controller: hourlyRate,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: context.l10n.staffHourlyRate,
                      suffixText: 'VND/h',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('staff_scheduled_start_field'),
                          controller: scheduledStart,
                          decoration: InputDecoration(
                            labelText: context.l10n.staffScheduledStart,
                            hintText: '09:00',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          key: const Key('staff_night_start_field'),
                          controller: nightStart,
                          decoration: InputDecoration(
                            labelText: context.l10n.staffNightStart,
                            hintText: '22:00',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: nightMultiplier,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: context.l10n.staffNightMultiplier,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: holidayMultiplier,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: context.l10n.staffHolidayMultiplier,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: lateThreshold,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: context.l10n.staffLateThreshold,
                            suffixText: context.l10n.staffMinutesUnit,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: lateReview,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: context.l10n.staffLateReviewMultiplier,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    context.l10n.staffSundayHolidayExcluded,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.textSecondary,
                    ),
                  ),
                ],
                if (validation != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    key: const Key('staff_create_validation_message'),
                    validation!,
                    style: AppFonts.system(color: PosColors.danger),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('staff_employee_save_action'),
                  onPressed: () async {
                    if (name.text.trim().isEmpty) {
                      setModalState(
                        () =>
                            validation = context.l10n.staffEmployeeNameRequired,
                      );
                      return;
                    }
                    final parsedHourlyRate = double.tryParse(
                      hourlyRate.text.trim().replaceAll(',', ''),
                    );
                    final parsedNightMultiplier = double.tryParse(
                      nightMultiplier.text.trim(),
                    );
                    final parsedHolidayMultiplier = double.tryParse(
                      holidayMultiplier.text.trim(),
                    );
                    final parsedLateThreshold = int.tryParse(
                      lateThreshold.text.trim(),
                    );
                    final parsedLateReview = double.tryParse(
                      lateReview.text.trim(),
                    );
                    final validClock = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
                    if (role == 'part_timer' &&
                        (parsedHourlyRate == null ||
                            parsedHourlyRate <= 0 ||
                            parsedNightMultiplier == null ||
                            parsedNightMultiplier < 1 ||
                            parsedHolidayMultiplier == null ||
                            parsedHolidayMultiplier < 3 ||
                            parsedLateThreshold == null ||
                            parsedLateThreshold < 0 ||
                            parsedLateReview == null ||
                            parsedLateReview < 0 ||
                            !validClock.hasMatch(scheduledStart.text.trim()) ||
                            !validClock.hasMatch(nightStart.text.trim()))) {
                      setModalState(
                        () => validation =
                            context.l10n.staffHourlyRulesValidation,
                      );
                      return;
                    }
                    final notifier = ref.read(staffProvider.notifier);
                    if (employee == null) {
                      await notifier.createStaff(
                        storeId: storeId,
                        fullName: name.text.trim(),
                        role: role,
                        phone: _nullable(phone.text),
                        bankName: _nullable(bankName.text),
                        bankAccountNumber: _nullable(bankNumber.text),
                        bankAccountHolder: _nullable(bankHolder.text),
                        hourlyRate: parsedHourlyRate,
                        scheduledStart: scheduledStart.text.trim(),
                        nightStart: nightStart.text.trim(),
                        nightMultiplier: parsedNightMultiplier ?? 1.3,
                        holidayMultiplier: parsedHolidayMultiplier ?? 3,
                        lateThresholdMinutes: parsedLateThreshold ?? 60,
                        lateReviewHourlyMultiplier: parsedLateReview ?? 2,
                      );
                    } else {
                      await notifier.updateStaff(
                        employeeId: employee.id,
                        storeId: storeId,
                        fullName: name.text.trim(),
                        role: role,
                        phone: _nullable(phone.text),
                        bankName: _nullable(bankName.text),
                        bankAccountNumber: _nullable(bankNumber.text),
                        bankAccountHolder: _nullable(bankHolder.text),
                        hourlyRate: parsedHourlyRate,
                        scheduledStart: scheduledStart.text.trim(),
                        nightStart: nightStart.text.trim(),
                        nightMultiplier: parsedNightMultiplier ?? 1.3,
                        holidayMultiplier: parsedHolidayMultiplier ?? 3,
                        lateThresholdMinutes: parsedLateThreshold ?? 60,
                        lateReviewHourlyMultiplier: parsedLateReview ?? 2,
                      );
                    }
                    if (!sheetContext.mounted) return;
                    final next = ref.read(staffProvider);
                    if (next.error != null) {
                      setModalState(
                        () => validation = context.l10n.staffEmployeeSaveFailed,
                      );
                      return;
                    }
                    Navigator.of(sheetContext).pop();
                    if (!mounted) return;
                    if (employee == null && next.lastCreatedEmployee != null) {
                      await _showCreatedEmployee(next.lastCreatedEmployee!);
                    } else {
                      showSuccessToast(
                        context,
                        context.l10n.staffEmployeeSaved,
                      );
                    }
                  },
                  child: Text(context.l10n.save),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await Future<void>.delayed(kThemeAnimationDuration);

    name.dispose();
    phone.dispose();
    bankName.dispose();
    bankNumber.dispose();
    bankHolder.dispose();
    hourlyRate.dispose();
    scheduledStart.dispose();
    nightStart.dispose();
    nightMultiplier.dispose();
    holidayMultiplier.dispose();
    lateThreshold.dispose();
    lateReview.dispose();
  }

  Future<void> _showCreatedEmployee(StaffMember employee) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('staff_created_employee_number_dialog'),
      title: Text(context.l10n.staffEmployeeCreated),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.l10n.staffEmployeeNumberShareHint),
          const SizedBox(height: 12),
          SelectableText(
            employee.employeeNumber,
            textAlign: TextAlign.center,
            style: AppFonts.system(
              color: PosColors.accent,
              fontSize: 28,
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.close),
        ),
      ],
    ),
  );

  Future<void> _confirmDeactivate(String storeId, StaffMember member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('staff_deactivate_employee_dialog'),
        title: Text(context.l10n.staffEmployeeDeactivateTitle),
        content: Text(
          context.l10n.staffEmployeeDeactivateMessage(member.fullName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.staffDeactivate),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref
        .read(staffProvider.notifier)
        .deactivateStaff(employeeId: member.id, storeId: storeId);
  }

  Future<void> _showAttendanceLogSheet(_StaffBoardRow row) =>
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: AppColors.surface1,
        builder: (context) => Padding(
          key: const Key('admin_staff_attendance_sheet'),
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
                Text(context.l10n.staffNoLogsTodayShort)
              else
                for (final log in row.logs)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      log.type == 'clock_in' ? Icons.login : Icons.logout,
                    ),
                    title: Text(
                      log.type == 'clock_in'
                          ? context.l10n.clockIn
                          : context.l10n.clockOut,
                    ),
                    trailing: Text(
                      DateFormat('yyyy-MM-dd HH:mm').format(log.loggedAt),
                    ),
                  ),
            ],
          ),
        ),
      );
}

const _employmentRoles = ['part_timer', 'full_time', 'manager'];

String? _nullable(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String _formatTime(DateTime? value) =>
    value == null ? '--:--' : DateFormat('HH:mm').format(value.toLocal());

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty || parts.first.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return '${parts.first.substring(0, 1)}${parts.last.substring(0, 1)}'
      .toUpperCase();
}

String _roleLabel(BuildContext context, String role) => switch (role) {
  'part_timer' => context.l10n.staffEmploymentRolePartTimer,
  'full_time' => context.l10n.staffEmploymentRoleFullTime,
  'manager' => context.l10n.staffEmploymentRoleManager,
  _ => context.l10n.staffEmploymentRoleUnknown,
};

String _statusLabel(BuildContext context, String status) => switch (status) {
  'inactive' => context.l10n.staffEmployeeInactive,
  'absent' => context.l10n.staffAbsent,
  'working' => context.l10n.staffWorking,
  'done' => context.l10n.staffAttendanceCompleted,
  _ => context.l10n.staffEmployeeActive,
};

Color _statusColor(String status) => switch (status) {
  'inactive' => PosColors.textSecondary,
  'absent' => PosColors.warning,
  'working' => PosColors.success,
  'done' => PosColors.info,
  _ => PosColors.textSecondary,
};

class _StaffBoardRow {
  const _StaffBoardRow({
    required this.member,
    required this.logs,
    required this.firstClockIn,
    required this.lastClockOut,
    required this.statusKey,
  });

  final StaffMember member;
  final List<AttendanceRecord> logs;
  final DateTime? firstClockIn;
  final DateTime? lastClockOut;
  final String statusKey;
}

class _StaffDetailDisclosure extends StatelessWidget {
  const _StaffDetailDisclosure({
    required this.row,
    required this.onEdit,
    required this.onViewAttendance,
    this.initiallyExpanded = false,
    this.showAttendancePreview = true,
  });

  final _StaffBoardRow row;
  final VoidCallback? onEdit;
  final VoidCallback onViewAttendance;
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
        title: Text(context.l10n.staffQuickActions),
        subtitle: Text(
          '${context.l10n.staffEmployeeEditTitle} · ${context.l10n.staffViewAttendanceLog}',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const Key('staff_edit_employee_action'),
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: Text(context.l10n.staffEmployeeEditAction),
                ),
                OutlinedButton.icon(
                  key: const Key('admin_staff_attendance_action'),
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
                row.logs.isEmpty
                    ? context.l10n.staffNoLogsToday
                    : context.l10n.staffTodayAttendanceLog,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.role});
  final String role;

  @override
  Widget build(BuildContext context) => _MetaTag(
    label: _roleLabel(context, role),
    color: role == 'manager' ? PosColors.warning : PosColors.accent,
  );
}

class _MetaTag extends StatelessWidget {
  const _MetaTag({required this.label, this.color});
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tone = color ?? PosColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withValues(alpha: 0.2)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: tone,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _DetailMetric extends StatelessWidget {
  const _DetailMetric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    width: 190,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: PosColors.panelMuted,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: PosColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
        ),
        const SizedBox(height: 5),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ],
    ),
  );
}

class _StaffLoading extends StatelessWidget {
  const _StaffLoading();

  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator(color: AppColors.amber500));
}
