import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../core/services/attendance_service.dart';
import '../../../core/services/payroll_service.dart';
import '../../../core/services/pin_service.dart';
import '../../../core/ui/pos_design_tokens.dart';
import '../../../core/ui/toast/toast.dart';
import '../../../core/utils/time_utils.dart';
import '../../../main.dart';
import '../../../widgets/error_toast.dart';
import '../../auth/auth_provider.dart';

class AttendanceTab extends ConsumerStatefulWidget {
  const AttendanceTab({super.key});

  @override
  ConsumerState<AttendanceTab> createState() => _AttendanceTabState();
}

class _AttendanceTabState extends ConsumerState<AttendanceTab> {
  String? _initializedRestaurantId;
  DateTime _logFrom = _startOfWeek(TimeUtils.nowVietnam());
  DateTime _logTo = TimeUtils.nowVietnam();
  String _selectedStaffFilter = 'all';
  List<Map<String, dynamic>> _staffList = const [];
  List<Map<String, dynamic>> _logs = const [];
  List<StaffPayroll> _payrolls = const [];
  bool _isLogsLoading = false;
  bool _isPayrollLoading = false;
  bool _payrollUnlocked = false;
  String? _logsError;
  String? _payrollError;
  bool? _hasPayrollPin;
  String? _selectedAttendanceUserId;

  static DateTime _startOfWeek(DateTime now) {
    final weekday = now.weekday;
    return DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: weekday - 1));
  }

  Future<void> _initialize(String storeId) async {
    setState(() {
      _isLogsLoading = true;
      _logsError = null;
    });

    try {
      final staff = await attendanceService.fetchStaffList(storeId);
      final logs = await attendanceService.fetchLogs(
        storeId: storeId,
        from: _logFrom,
        to: _logTo,
      );
      final pinHash = await pinService.fetchPinHash(storeId);

      if (!mounted) return;
      setState(() {
        _staffList = staff;
        _logs = logs;
        _isLogsLoading = false;
        _hasPayrollPin = pinHash != null && pinHash.isNotEmpty;
        _payrollUnlocked = pinHash == null || pinHash.isEmpty;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLogsLoading = false;
        _logsError = _mapAttendanceError(e, context.l10n.attendanceLoadFailed);
      });
    }
  }

  Future<void> _reloadLogs(String storeId) async {
    setState(() {
      _isLogsLoading = true;
      _logsError = null;
    });

    try {
      final logs = await attendanceService.fetchLogs(
        storeId: storeId,
        from: _logFrom,
        to: _logTo,
      );
      if (!mounted) return;
      setState(() {
        _logs = logs;
        _isLogsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLogsLoading = false;
        _logsError = _mapAttendanceError(
          e,
          context.l10n.attendanceReloadFailed,
        );
      });
      showErrorToast(context, context.l10n.attendanceQueryFailed);
    }
  }

  Future<void> _loadPayrollPreview(String storeId) async {
    setState(() {
      _isPayrollLoading = true;
      _payrollError = null;
    });

    try {
      final payrolls = await payrollService.calculatePayroll(
        storeId: storeId,
        periodStart: _logFrom,
        periodEnd: _logTo,
      );
      if (!mounted) return;
      setState(() {
        _payrolls = payrolls;
        _isPayrollLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isPayrollLoading = false;
        _payrollError = _mapPayrollError(
          e,
          context.l10n.attendancePayrollLoadFailed,
        );
      });
      showErrorToast(context, context.l10n.attendancePayrollCalculateFailed);
    }
  }

  Future<void> _exportPayrollPreview(List<StaffPayroll> payrolls) async {
    final bytes = await payrollService.exportToExcel(
      payrolls: payrolls,
      periodStart: _logFrom,
      periodEnd: _logTo,
    );
    if (bytes.isEmpty) return;

    final fileName =
        'payroll_${DateFormat('yyyyMMdd').format(_logFrom)}_${DateFormat('yyyyMMdd').format(_logTo)}';
    await FileSaver.instance.saveFile(
      name: fileName,
      bytes: Uint8List.fromList(bytes),
      ext: 'xlsx',
      mimeType: MimeType.microsoftExcel,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.attendancePayrollSaved)),
    );
  }

  Future<void> _unlockPayroll(String storeId) async {
    final controller = TextEditingController();
    String? validationError;

    final unlocked = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(context.l10n.attendanceUnlockPayrollPreview),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.l10n.attendanceUnlockPayrollDescription),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    maxLength: 4,
                    decoration: InputDecoration(
                      labelText: context.l10n.attendancePayrollPin,
                      errorText: validationError,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(context.l10n.cancel),
                ),
                FilledButton(
                  onPressed: () async {
                    final pin = controller.text.trim();
                    if (pin.length != 4) {
                      setDialogState(
                        () => validationError =
                            context.l10n.settingsPayrollPinMustBe4Digits,
                      );
                      return;
                    }
                    final verified = await pinService.verifyPin(storeId, pin);
                    if (!verified) {
                      setDialogState(
                        () => validationError =
                            context.l10n.settingsPayrollPinIncorrect,
                      );
                      return;
                    }
                    if (!dialogContext.mounted) return;
                    Navigator.of(dialogContext).pop(true);
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.amber500,
                    foregroundColor: AppColors.surface0,
                  ),
                  child: Text(context.l10n.attendanceUnlockPayrollAction),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();

    if (unlocked == true && mounted) {
      setState(() => _payrollUnlocked = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.attendancePayrollUnlocked)),
      );
    }
  }

  String _mapAttendanceError(Object error, String fallback) {
    final message = error is PostgrestException ? error.message : '$error';

    if (message.contains('ATTENDANCE_STAFF_DIRECTORY_FORBIDDEN') ||
        message.contains('ATTENDANCE_LOG_VIEW_FORBIDDEN')) {
      return context.l10n.attendanceNoViewPermission;
    }
    if (message.contains('ATTENDANCE_LOG_RANGE_REQUIRED') ||
        message.contains('ATTENDANCE_LOG_RANGE_INVALID')) {
      return context.l10n.attendanceReselectPeriod;
    }
    if (message.contains('ATTENDANCE_LOG_USER_NOT_FOUND')) {
      return context.l10n.attendanceReselectStaffFilter;
    }

    return fallback;
  }

  String _mapPayrollError(Object error, String fallback) {
    final message = error is PostgrestException ? error.message : '$error';

    if (message.contains('ATTENDANCE_LOG_VIEW_FORBIDDEN')) {
      return context.l10n.attendanceNoPayrollPermission;
    }
    if (message.contains('ATTENDANCE_WAGE_CONFIG_FORBIDDEN')) {
      return context.l10n.attendanceNoWageConfigPermission;
    }
    if (message.contains('ATTENDANCE_WAGE_CONFIG_NOT_FOUND')) {
      return context.l10n.attendanceWageConfigMissing;
    }

    return fallback;
  }

  List<Map<String, dynamic>> _buildAttendanceRows(
    List<Map<String, dynamic>> filteredLogs,
    List<StaffPayroll> filteredPayrolls,
  ) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    final payrollByUser = {
      for (final payroll in filteredPayrolls) payroll.userId: payroll,
    };

    for (final row in filteredLogs) {
      final userId = row['user_id']?.toString() ?? '';
      if (userId.isEmpty) continue;
      grouped.putIfAbsent(userId, () => []).add(row);
    }

    final rows = grouped.entries.map((entry) {
      final userLogs = [...entry.value]
        ..sort((a, b) {
          final aTime = DateTime.tryParse(a['logged_at']?.toString() ?? '');
          final bTime = DateTime.tryParse(b['logged_at']?.toString() ?? '');
          return (aTime ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(
            bTime ?? DateTime.fromMillisecondsSinceEpoch(0),
          );
        });
      final firstClockIn = userLogs
          .where((row) => row['type']?.toString() == 'clock_in')
          .map((row) => DateTime.tryParse(row['logged_at']?.toString() ?? ''))
          .whereType<DateTime>()
          .map(TimeUtils.toVietnam)
          .fold<DateTime?>(null, (value, element) {
            if (value == null) return element;
            return element.isBefore(value) ? element : value;
          });
      final lastClockOut = userLogs
          .where((row) => row['type']?.toString() == 'clock_out')
          .map((row) => DateTime.tryParse(row['logged_at']?.toString() ?? ''))
          .whereType<DateTime>()
          .map(TimeUtils.toVietnam)
          .fold<DateTime?>(null, (value, element) {
            if (value == null) return element;
            return element.isAfter(value) ? element : value;
          });
      final user = userLogs.first['users'];
      final payroll = payrollByUser[entry.key];
      final hasClockOut = userLogs.any(
        (row) => row['type']?.toString() == 'clock_out',
      );
      final fallbackHours = firstClockIn != null && lastClockOut != null
          ? lastClockOut.difference(firstClockIn).inMinutes / 60.0
          : 0.0;
      final totalHours = payroll?.totalHours ?? fallbackHours;
      final needsReview =
          payroll?.dailyRecords.any((record) => record.isUnpaired) == true ||
          firstClockIn == null ||
          lastClockOut == null;

      return <String, dynamic>{
        'userId': entry.key,
        'name': user is Map<String, dynamic>
            ? user['full_name']?.toString() ?? '-'
            : '-',
        'role': user is Map<String, dynamic>
            ? user['role']?.toString() ?? 'staff'
            : 'staff',
        'clockIn': firstClockIn,
        'clockOut': lastClockOut,
        'hours': totalHours,
        'logCount': userLogs.length,
        'needsReview': needsReview,
        'statusLabel': needsReview
            ? context.l10n.reportsNeedsReviewShort
            : !hasClockOut
            ? context.l10n.staffWorking
            : context.l10n.inventoryStatusNormal,
        'statusColor': needsReview
            ? PosColors.warning
            : !hasClockOut
            ? PosColors.info
            : PosColors.success,
        'payroll': payroll,
      };
    }).toList();

    rows.sort((a, b) {
      final reviewCompare = (b['needsReview'] == true ? 1 : 0).compareTo(
        a['needsReview'] == true ? 1 : 0,
      );
      if (reviewCompare != 0) return reviewCompare;
      return (a['name'] as String).compareTo(b['name'] as String);
    });
    return rows;
  }

  Map<String, dynamic>? _resolveSelectedAttendanceRow(
    List<Map<String, dynamic>> rows,
  ) {
    if (rows.isEmpty) return null;
    final selectedId = _selectedAttendanceUserId;
    if (selectedId == null) return rows.first;
    for (final row in rows) {
      if (row['userId'] == selectedId) {
        return row;
      }
    }
    return rows.first;
  }

  String _formatClock(DateTime? value) {
    if (value == null) return '--:--';
    return DateFormat('HH:mm').format(value);
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

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final storeId = auth.storeId;

    if (storeId != null && _initializedRestaurantId != storeId) {
      _initializedRestaurantId = storeId;
      Future.microtask(() => _initialize(storeId));
    }

    final filteredLogs = _logs.where((row) {
      if (_selectedStaffFilter == 'all') return true;
      return row['user_id']?.toString() == _selectedStaffFilter;
    }).toList();
    final filteredPayrolls = _payrolls.where((payroll) {
      if (_selectedStaffFilter == 'all') return true;
      return payroll.userId == _selectedStaffFilter;
    }).toList();
    final payrollRequiresUnlock = _hasPayrollPin == true && !_payrollUnlocked;
    final attendanceRows = _buildAttendanceRows(filteredLogs, filteredPayrolls);
    final selectedAttendanceRow = _resolveSelectedAttendanceRow(attendanceRows);
    final today = TimeUtils.nowVietnam();
    final todayPresentCount = _logs
        .where((row) {
          final raw = DateTime.tryParse(row['logged_at']?.toString() ?? '');
          if (raw == null) return false;
          final local = TimeUtils.toVietnam(raw);
          return local.year == today.year &&
              local.month == today.month &&
              local.day == today.day;
        })
        .map((row) => row['user_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet()
        .length;
    final attendanceRate = _staffList.isEmpty
        ? 0
        : ((todayPresentCount / _staffList.length) * 100).round();
    final reviewCount = attendanceRows
        .where((row) => row['needsReview'])
        .length;
    final payrollTargetCount = filteredPayrolls.isNotEmpty
        ? filteredPayrolls.length
        : attendanceRows.length;
    final totalHours = filteredPayrolls.fold<double>(
      0,
      (sum, payroll) => sum + payroll.totalHours,
    );
    final overtimeHours = filteredPayrolls.fold<double>(
      0,
      (sum, payroll) =>
          sum +
          payroll.dailyRecords.fold<double>(
            0,
            (dailySum, record) => dailySum + ((record.hours - 8).clamp(0, 99)),
          ),
    );
    final estimatedPayroll = filteredPayrolls.fold<double>(
      0,
      (sum, payroll) => sum + payroll.totalAmount,
    );
    final selectedPayroll = selectedAttendanceRow?['payroll'] as StaffPayroll?;
    final photoCaptureCount = filteredLogs
        .where((row) => (row['photo_url']?.toString() ?? '').isNotEmpty)
        .length;
    final currency = NumberFormat('#,###', 'vi_VN');

    return Scaffold(
      key: const Key('attendance_root'),
      backgroundColor: AppColors.surface0,
      body: ToastResponsiveBody(
        maxWidth: 1480,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildAttendanceCommandHeader(
              storeId: storeId,
              todayPresentCount: todayPresentCount,
              attendanceRate: attendanceRate,
              reviewCount: reviewCount,
              payrollTargetCount: payrollTargetCount,
            ),
            if (_logsError != null) ...[
              const SizedBox(height: 12),
              PosExceptionAlert(label: _logsError!, color: PosColors.danger),
            ],
            if (_payrollError != null) ...[
              const SizedBox(height: 12),
              PosExceptionAlert(
                label: _payrollError!,
                color: PosColors.warning,
              ),
            ],
            const SizedBox(height: 16),
            Expanded(
              child: PosSplitContent(
                primary: PosDataPanel(
                  title: context.l10n.attendanceRecordsTitle,
                  subtitle: context.l10n.attendanceRecordsSubtitle,
                  trailing: ToastStatusBadge(
                    label: context.l10n.attendanceShowingStaff(
                      attendanceRows.length,
                    ),
                    color: PosColors.info,
                    compact: true,
                  ),
                  child: _isLogsLoading
                      ? const Center(
                          child: CircularProgressIndicator(
                            color: AppColors.amber500,
                          ),
                        )
                      : attendanceRows.isEmpty
                      ? PosEmptyState(
                          title: context.l10n.attendanceNoRecordsSelectedPeriod,
                          subtitle: context.l10n.attendanceRecordSourceHint,
                          icon: Icons.event_note_outlined,
                        )
                      : PosTableShell(
                          columns: [
                            ToastQueueColumn(
                              label: context.l10n.staff,
                              flex: 4,
                            ),
                            ToastQueueColumn(
                              label: context.l10n.clockIn,
                              flex: 2,
                            ),
                            ToastQueueColumn(
                              label: context.l10n.clockOut,
                              flex: 2,
                            ),
                            ToastQueueColumn(
                              label: context.l10n.attendanceWorkedHoursShort,
                              flex: 2,
                            ),
                            ToastQueueColumn(
                              label: context.l10n.status,
                              flex: 2,
                            ),
                          ],
                          rows: attendanceRows
                              .map(
                                (row) => ToastQueueRow(
                                  id: row['userId'] as String,
                                  cells: [
                                    Row(
                                      children: [
                                        CircleAvatar(
                                          radius: 18,
                                          backgroundColor:
                                              PosColors.accentMuted,
                                          child: Text(
                                            _initialsForName(
                                              row['name'] as String,
                                            ),
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelLarge
                                                ?.copyWith(
                                                  color: PosColors.accent,
                                                ),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                row['name'] as String,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodyMedium
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                row['role'] as String,
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.bodySmall,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    Text(
                                      _formatClock(row['clockIn'] as DateTime?),
                                    ),
                                    Text(
                                      _formatClock(
                                        row['clockOut'] as DateTime?,
                                      ),
                                    ),
                                    Text(
                                      '${(row['hours'] as double).toStringAsFixed(1)}h',
                                    ),
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: ToastStatusBadge(
                                        label: row['statusLabel'] as String,
                                        color: row['statusColor'] as Color,
                                        compact: true,
                                      ),
                                    ),
                                  ],
                                  muted: false,
                                ),
                              )
                              .toList(),
                          selectedId:
                              selectedAttendanceRow?['userId'] as String?,
                          onSelect: (userId) {
                            setState(() => _selectedAttendanceUserId = userId);
                          },
                        ),
                ),
                secondary: _buildSelectedAttendanceDetailPanel(
                  storeId: storeId,
                  selectedAttendanceRow: selectedAttendanceRow,
                  selectedPayroll: selectedPayroll,
                  filteredPayrolls: filteredPayrolls,
                  payrollRequiresUnlock: payrollRequiresUnlock,
                  totalHours: totalHours,
                  overtimeHours: overtimeHours,
                  estimatedPayroll: estimatedPayroll,
                  currency: currency,
                ),
              ),
            ),
            const SizedBox(height: 12),
            _buildAttendanceSecondarySignals(
              photoCaptureCount: photoCaptureCount,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttendanceCommandHeader({
    required String? storeId,
    required int todayPresentCount,
    required int attendanceRate,
    required int reviewCount,
    required int payrollTargetCount,
  }) {
    // Contract anchor: title: context.l10n.attendanceManagementTitle; label: context.l10n.payrollPreview; label: context.l10n.download; title: context.l10n.attendancePayrollSummaryTitle.
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
                      context.l10n.attendanceManagementTitle,
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.l10n.attendanceManagementSubtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PosColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              ToastStatusBadge(
                label: _payrollUnlocked
                    ? context.l10n.attendancePayrollUnlockedBadge
                    : context.l10n.attendancePayrollLockedBadge,
                color: _payrollUnlocked ? PosColors.success : PosColors.warning,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 14),
          ToastMetricStrip(
            metrics: [
              ToastMetric(
                label: context.l10n.staff,
                value: context.l10n.staffCount(_staffList.length),
              ),
              ToastMetric(
                label: context.l10n.attendanceTodayPresent,
                value: context.l10n.staffCount(todayPresentCount),
                tone: PosColors.success,
              ),
              ToastMetric(
                label: context.l10n.attendanceUnreviewedLogs,
                value: context.l10n.countCases(reviewCount),
                tone: reviewCount > 0
                    ? PosColors.warning
                    : PosColors.textSecondary,
              ),
              ToastMetric(
                label: context.l10n.attendancePayrollTargets,
                value: context.l10n.staffCount(payrollTargetCount),
                tone: PosColors.accent,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _DateButton(
                label: context.l10n.from,
                value: _logFrom,
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _logFrom,
                    firstDate: DateTime(2020),
                    lastDate: TimeUtils.nowVietnam(),
                  );
                  if (picked != null) {
                    setState(
                      () => _logFrom = DateTime(
                        picked.year,
                        picked.month,
                        picked.day,
                      ),
                    );
                  }
                },
              ),
              _DateButton(
                label: context.l10n.to,
                value: _logTo,
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _logTo,
                    firstDate: DateTime(2020),
                    lastDate: TimeUtils.nowVietnam(),
                  );
                  if (picked != null) {
                    setState(() {
                      _logTo = DateTime(
                        picked.year,
                        picked.month,
                        picked.day,
                        23,
                        59,
                        59,
                      );
                    });
                  }
                },
              ),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedStaffFilter,
                  dropdownColor: AppColors.surface1,
                  style: Theme.of(context).textTheme.bodyMedium,
                  decoration: InputDecoration(
                    isDense: true,
                    border: const OutlineInputBorder(),
                    labelText: context.l10n.attendanceStaffFilter,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'all',
                      child: Text(context.l10n.attendanceAllStaff),
                    ),
                    ..._staffList.map(
                      (staff) => DropdownMenuItem(
                        value: staff['user_id']?.toString() ?? '',
                        child: Text(staff['full_name']?.toString() ?? '-'),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _selectedStaffFilter = value;
                        _selectedAttendanceUserId = null;
                      });
                    }
                  },
                ),
              ),
              FilledButton.icon(
                onPressed: storeId == null ? null : () => _reloadLogs(storeId),
                icon: const Icon(Icons.search, size: 16),
                label: Text(context.l10n.search),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.attendanceRate(attendanceRate),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: PosColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedAttendanceDetailPanel({
    required String? storeId,
    required Map<String, dynamic>? selectedAttendanceRow,
    required StaffPayroll? selectedPayroll,
    required List<StaffPayroll> filteredPayrolls,
    required bool payrollRequiresUnlock,
    required double totalHours,
    required double overtimeHours,
    required double estimatedPayroll,
    required NumberFormat currency,
  }) {
    final hasUnpairedLogs =
        selectedPayroll?.dailyRecords.any((record) => record.isUnpaired) ??
        false;
    final statusLabel = selectedAttendanceRow?['statusLabel'] as String?;
    final statusColor =
        selectedAttendanceRow?['statusColor'] as Color? ?? PosColors.info;
    final payrollActionLabel = payrollRequiresUnlock
        ? context.l10n.attendanceUnlockPayrollAction
        : filteredPayrolls.isEmpty
        ? context.l10n.attendanceRunPayrollPreview
        : context.l10n.download;
    final VoidCallback? payrollAction = payrollRequiresUnlock
        ? storeId == null
              ? null
              : () => _unlockPayroll(storeId)
        : filteredPayrolls.isEmpty
        ? storeId == null
              ? null
              : () => _loadPayrollPreview(storeId)
        : () => _exportPayrollPreview(filteredPayrolls);

    return ToastWorkSurface(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selectedAttendanceRow == null
                          ? context.l10n.attendanceRecordsTitle
                          : selectedAttendanceRow['name'] as String,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      selectedAttendanceRow == null
                          ? context.l10n.attendanceRecordsSubtitle
                          : context.l10n.attendanceLogCountRole(
                              selectedAttendanceRow['logCount'] as int,
                              selectedAttendanceRow['role'] as String,
                            ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (statusLabel != null) ...[
                const SizedBox(width: 12),
                ToastStatusBadge(
                  label: statusLabel,
                  color: statusColor,
                  compact: true,
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: selectedAttendanceRow == null
                  ? PosEmptyState(
                      title: context.l10n.staffNoSelection,
                      subtitle: context.l10n.attendanceRecordsSubtitle,
                      icon: Icons.person_search_outlined,
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: PosColors.mutedSurface,
                            borderRadius: AppRadius.lg,
                            border: Border.all(color: PosColors.border),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _summaryMetricRow(
                                context.l10n.attendanceFirstClockIn,
                                _formatClock(
                                  selectedAttendanceRow['clockIn'] as DateTime?,
                                ),
                              ),
                              const SizedBox(height: 10),
                              _summaryMetricRow(
                                context.l10n.attendanceLastClockOut,
                                _formatClock(
                                  selectedAttendanceRow['clockOut']
                                      as DateTime?,
                                ),
                              ),
                              const SizedBox(height: 10),
                              _summaryMetricRow(
                                context.l10n.attendanceWorkedHoursShort,
                                context.l10n.attendanceHoursValue(
                                  (selectedAttendanceRow['hours'] as double)
                                      .toStringAsFixed(1),
                                ),
                              ),
                              if (hasUnpairedLogs) ...[
                                const SizedBox(height: 12),
                                PosExceptionAlert(
                                  label:
                                      context.l10n.attendanceUnpairedLogsTitle,
                                  detail:
                                      context.l10n.attendanceUnpairedLogsDetail,
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          decoration: BoxDecoration(
                            color: AppColors.surface1,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.surface2),
                          ),
                          child: ExpansionTile(
                            key: const Key(
                              'attendance_payroll_secondary_detail',
                            ),
                            initiallyExpanded: false,
                            tilePadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                            ),
                            childrenPadding: const EdgeInsets.fromLTRB(
                              14,
                              0,
                              14,
                              14,
                            ),
                            iconColor: AppColors.textSecondary,
                            collapsedIconColor: AppColors.textSecondary,
                            title: Text(
                              context.l10n.attendancePayrollSummaryTitle,
                              style: GoogleFonts.notoSansKr(
                                color: AppColors.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            subtitle: Text(
                              payrollRequiresUnlock
                                  ? context
                                        .l10n
                                        .attendancePayrollSummaryUnlockSubtitle
                                  : context
                                        .l10n
                                        .attendancePayrollSummaryReadySubtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.notoSansKr(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            children: [
                              if (_isPayrollLoading)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 12),
                                  child: Center(
                                    child: CircularProgressIndicator(
                                      color: AppColors.amber500,
                                    ),
                                  ),
                                )
                              else ...[
                                _summaryMetricRow(
                                  context.l10n.attendanceTotalWorkedHours,
                                  context.l10n.attendanceHoursValue(
                                    totalHours.toStringAsFixed(1),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                _summaryMetricRow(
                                  context.l10n.attendanceOvertimeHours,
                                  context.l10n.attendanceHoursValue(
                                    overtimeHours.toStringAsFixed(1),
                                  ),
                                  tone: overtimeHours > 0
                                      ? PosColors.warning
                                      : PosColors.textPrimary,
                                ),
                                const SizedBox(height: 10),
                                _summaryMetricRow(
                                  context.l10n.attendanceEstimatedPayroll,
                                  '₫${currency.format(estimatedPayroll)}',
                                  tone: PosColors.accent,
                                ),
                                const SizedBox(height: 10),
                                _summaryMetricRow(
                                  context.l10n.attendanceAccumulatedPayroll,
                                  selectedPayroll == null
                                      ? context.l10n.attendancePreviewRequired
                                      : '₫${currency.format(selectedPayroll.totalAmount)}',
                                  tone: selectedPayroll == null
                                      ? PosColors.textSecondary
                                      : PosColors.accent,
                                ),
                                const SizedBox(height: 14),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton.icon(
                                    onPressed: payrollAction,
                                    icon: Icon(
                                      payrollRequiresUnlock
                                          ? Icons.lock_open_rounded
                                          : filteredPayrolls.isEmpty
                                          ? Icons.payments_outlined
                                          : Icons.download_rounded,
                                      size: 18,
                                    ),
                                    label: Text(payrollActionLabel),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttendanceSecondarySignals({required int photoCaptureCount}) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: ExpansionTile(
        key: const Key('attendance_secondary_signals_detail'),
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        iconColor: AppColors.textSecondary,
        collapsedIconColor: AppColors.textSecondary,
        title: Text(
          context.l10n.attendanceKioskStatus,
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          _isLogsLoading
              ? context.l10n.attendanceRecordSyncing
              : context.l10n.attendanceConnectionStable,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.notoSansKr(
            color: AppColors.textSecondary,
            fontSize: 12,
          ),
        ),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _secondarySignalTile(
                context.l10n.attendanceKioskStatus,
                _isLogsLoading
                    ? context.l10n.attendanceChecking
                    : context.l10n.attendanceHealthy,
                _isLogsLoading ? PosColors.warning : PosColors.success,
              ),
              _secondarySignalTile(
                context.l10n.attendancePhotoRecords,
                context.l10n.countCases(photoCaptureCount),
                photoCaptureCount > 0
                    ? PosColors.info
                    : PosColors.textSecondary,
              ),
              _secondarySignalTile(
                context.l10n.attendancePayrollLock,
                _payrollUnlocked
                    ? context.l10n.attendanceUnlockedShort
                    : context.l10n.attendanceProtectedShort,
                _payrollUnlocked ? PosColors.success : PosColors.warning,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _secondarySignalTile(String label, String value, Color tone) {
    return SizedBox(
      width: 220,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: tone,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryMetricRow(
    String label,
    String value, {
    Color tone = PosColors.textPrimary,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
          ),
        ),
        Text(
          value,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: tone,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _DateButton extends StatelessWidget {
  const _DateButton({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final DateTime value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.calendar_month_outlined),
      label: Text(
        '$label ${DateFormat('yyyy-MM-dd').format(value)}',
        style: GoogleFonts.notoSansKr(),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        side: const BorderSide(color: AppColors.surface2),
      ),
    );
  }
}
