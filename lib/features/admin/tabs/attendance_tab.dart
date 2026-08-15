import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../core/services/attendance_service.dart';
import '../../../core/services/payroll_service.dart';
import '../../../core/services/pin_service.dart';
import '../../../core/ui/pos_design_tokens.dart';
import '../../../core/ui/toast/toast.dart';
import '../../../core/utils/time_utils.dart';
import '../../../core/utils/number_input_utils.dart';
import '../../../main.dart';
import '../../../widgets/error_toast.dart';
import '../../auth/auth_provider.dart';
import '../providers/admin_scope_provider.dart';

String _formatVnd(NumberFormat currency, num amount) {
  return '${currency.format(amount)} VND';
}

class _ManualAttendanceDraft {
  const _ManualAttendanceDraft({
    required this.employeeId,
    required this.type,
    required this.loggedAt,
    required this.reason,
    required this.managerPin,
  });

  final String employeeId;
  final String type;
  final DateTime loggedAt;
  final String reason;
  final String managerPin;
}

class AttendanceTab extends ConsumerStatefulWidget {
  const AttendanceTab({
    super.key,
    this.isPhotoObjetContext = false,
    this.attendanceServiceOverride,
    this.payrollServiceOverride,
    this.pinServiceOverride,
  });

  final bool isPhotoObjetContext;
  final AttendanceService? attendanceServiceOverride;
  final PayrollService? payrollServiceOverride;
  final PinService? pinServiceOverride;

  @override
  ConsumerState<AttendanceTab> createState() => _AttendanceTabState();
}

class _AttendanceTabState extends ConsumerState<AttendanceTab> {
  String? _initializedRestaurantId;
  DateTime _logFrom = _startOfWeek(TimeUtils.nowVietnam());
  DateTime _logTo = TimeUtils.nowVietnam();
  DateTime _attendanceDate = _startOfDay(TimeUtils.nowVietnam());
  List<Map<String, dynamic>> _staffList = const [];
  List<Map<String, dynamic>> _logs = const [];
  List<Map<String, dynamic>> _dailyLogs = const [];
  List<Map<String, dynamic>> _selectedEmployeeMonthLogs = const [];
  List<StaffPayroll> _payrolls = const [];
  bool _isLogsLoading = false;
  bool _isDailyLogsLoading = false;
  bool _isEmployeeMonthLoading = false;
  bool _isPayrollLoading = false;
  bool _isManualAttendanceSaving = false;
  bool _payrollUnlocked = false;
  String? _logsError;
  String? _dailyLogsError;
  String? _employeeMonthError;
  String? _payrollError;
  bool? _hasPayrollPin;
  String? _selectedAttendanceUserId;

  AttendanceService get _attendanceService =>
      widget.attendanceServiceOverride ?? attendanceService;
  PayrollService get _payrollService =>
      widget.payrollServiceOverride ?? payrollService;
  PinService get _pinService => widget.pinServiceOverride ?? pinService;

  static DateTime _startOfWeek(DateTime now) {
    final weekday = now.weekday;
    return DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: weekday - 1));
  }

  static DateTime _startOfDay(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static DateTime _startOfMonth(DateTime value) =>
      DateTime(value.year, value.month);

  static bool _isSameDay(DateTime first, DateTime second) =>
      first.year == second.year &&
      first.month == second.month &&
      first.day == second.day;

  void _clearPayrollPreview() {
    _payrolls = const [];
    _payrollError = null;
    _isPayrollLoading = false;
  }

  Future<void> _initialize(String storeId) async {
    setState(() {
      _isLogsLoading = true;
      _isDailyLogsLoading = true;
      _logsError = null;
      _dailyLogsError = null;
      _selectedAttendanceUserId = null;
      _selectedEmployeeMonthLogs = const [];
      _clearPayrollPreview();
    });

    try {
      final staff = await _attendanceService.fetchStaffList(storeId);
      final logs = await _attendanceService.fetchLogs(
        storeId: storeId,
        from: _logFrom,
        to: _logTo,
        limit: attendanceManagementRecordLimit,
      );
      final dailyLogs = await _attendanceService.fetchLogs(
        storeId: storeId,
        from: _attendanceDate,
        to: _attendanceDate.add(const Duration(days: 1)),
        limit: attendanceManagementRecordLimit,
      );
      final hasPayrollPin = await _pinService.hasPayrollPin(storeId);

      if (!mounted) return;
      setState(() {
        _staffList = staff;
        _logs = logs;
        _dailyLogs = dailyLogs;
        _isLogsLoading = false;
        _isDailyLogsLoading = false;
        _hasPayrollPin = hasPayrollPin;
        _payrollUnlocked = !hasPayrollPin;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLogsLoading = false;
        _isDailyLogsLoading = false;
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
      final logs = await _attendanceService.fetchLogs(
        storeId: storeId,
        from: _logFrom,
        to: _logTo,
        limit: attendanceManagementRecordLimit,
      );
      if (!mounted) return;
      setState(() {
        _logs = logs;
        _isLogsLoading = false;
        _clearPayrollPreview();
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

  Future<void> _reloadDailyLogs(
    String storeId,
    DateTime date, {
    bool preserveSelection = false,
  }) async {
    final day = _startOfDay(date);
    final selectedEmployeeId = preserveSelection
        ? _selectedAttendanceUserId
        : null;
    setState(() {
      _attendanceDate = day;
      _isDailyLogsLoading = true;
      _dailyLogsError = null;
      if (!preserveSelection) {
        _selectedAttendanceUserId = null;
        _selectedEmployeeMonthLogs = const [];
        _employeeMonthError = null;
      }
    });

    try {
      final logs = await _attendanceService.fetchLogs(
        storeId: storeId,
        from: day,
        to: day.add(const Duration(days: 1)),
        limit: attendanceManagementRecordLimit,
      );
      if (!mounted || _attendanceDate != day) return;
      setState(() {
        _dailyLogs = logs;
        _isDailyLogsLoading = false;
      });
      if (selectedEmployeeId != null && mounted) {
        await _selectAttendanceEmployee(storeId, selectedEmployeeId);
      }
    } catch (error) {
      if (!mounted || _attendanceDate != day) return;
      setState(() {
        _isDailyLogsLoading = false;
        _dailyLogsError = _mapAttendanceError(
          error,
          context.l10n.attendanceReloadFailed,
        );
      });
      showErrorToast(context, context.l10n.attendanceQueryFailed);
    }
  }

  Future<void> _selectAttendanceEmployee(
    String storeId,
    String employeeId,
  ) async {
    final monthStart = _startOfMonth(_attendanceDate);
    final monthEnd = DateTime(monthStart.year, monthStart.month + 1);
    setState(() {
      _selectedAttendanceUserId = employeeId;
      _selectedEmployeeMonthLogs = const [];
      _isEmployeeMonthLoading = true;
      _employeeMonthError = null;
    });

    try {
      final logs = await _attendanceService.fetchEmployeeLogs(
        storeId: storeId,
        employeeId: employeeId,
        from: monthStart,
        to: monthEnd,
        limit: attendanceManagementRecordLimit,
      );
      if (!mounted || _selectedAttendanceUserId != employeeId) return;
      setState(() {
        _selectedEmployeeMonthLogs = logs;
        _isEmployeeMonthLoading = false;
      });
    } catch (error) {
      if (!mounted || _selectedAttendanceUserId != employeeId) return;
      setState(() {
        _isEmployeeMonthLoading = false;
        _employeeMonthError = _mapAttendanceError(
          error,
          context.l10n.attendanceLoadFailed,
        );
      });
    }
  }

  Future<void> _loadPayrollPreview(String storeId) async {
    final periodStart = _logFrom;
    final periodEnd = _logTo;

    setState(() {
      _isPayrollLoading = true;
      _payrollError = null;
    });

    try {
      final payrolls = await _payrollService.calculatePayroll(
        storeId: storeId,
        periodStart: periodStart,
        periodEnd: periodEnd,
      );
      if (!mounted) return;
      if (periodStart != _logFrom || periodEnd != _logTo) return;
      setState(() {
        _payrolls = payrolls;
        _isPayrollLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (periodStart != _logFrom || periodEnd != _logTo) return;
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
    final bytes = await _payrollService.exportToExcel(
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

  Future<void> _downloadAllPayroll(String storeId) async {
    if (_isPayrollLoading || !_payrollUnlocked) return;
    setState(() {
      _isPayrollLoading = true;
      _payrollError = null;
    });
    try {
      final payrolls = await _payrollService.calculatePayroll(
        storeId: storeId,
        periodStart: _logFrom,
        periodEnd: _logTo,
      );
      if (!mounted) return;
      setState(() {
        _payrolls = payrolls;
        _isPayrollLoading = false;
      });
      await _exportPayrollPreview(payrolls);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isPayrollLoading = false;
        _payrollError = _mapPayrollError(
          error,
          context.l10n.attendancePayrollLoadFailed,
        );
      });
      showErrorToast(context, context.l10n.attendancePayrollCalculateFailed);
    }
  }

  Future<void> _showManualAttendanceDialog(String storeId) async {
    if (_staffList.isEmpty || _isManualAttendanceSaving) return;
    final now = TimeUtils.nowVietnam();
    var selectedEmployeeId =
        _staffList.any(
          (staff) => staff['user_id']?.toString() == _selectedAttendanceUserId,
        )
        ? _selectedAttendanceUserId!
        : _staffList.first['user_id']!.toString();
    var selectedType = 'clock_in';
    var selectedDate = _attendanceDate;
    var selectedTime = TimeOfDay.fromDateTime(now);
    var reason = '';
    var managerPin = '';
    String? validationError;
    String? pinValidationError;

    final draft = await showDialog<_ManualAttendanceDraft>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          key: const Key('attendance_manual_entry_dialog'),
          title: Text(context.l10n.attendanceManualEntryTitle),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(context.l10n.attendanceManualEntryDescription),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: const Key('attendance_manual_employee'),
                    initialValue: selectedEmployeeId,
                    decoration: InputDecoration(
                      labelText: context.l10n.staff,
                      border: const OutlineInputBorder(),
                    ),
                    items: _staffList
                        .map(
                          (staff) => DropdownMenuItem(
                            value: staff['user_id']!.toString(),
                            child: Text(
                              staff['full_name']?.toString() ?? '-',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      if (value != null) selectedEmployeeId = value;
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: const Key('attendance_manual_type'),
                    initialValue: selectedType,
                    decoration: InputDecoration(
                      labelText: context.l10n.attendanceManualEventType,
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'clock_in',
                        child: Text(context.l10n.clockIn),
                      ),
                      DropdownMenuItem(
                        value: 'clock_out',
                        child: Text(context.l10n.clockOut),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) selectedType = value;
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('attendance_manual_date'),
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: selectedDate,
                              firstDate: DateTime(2020),
                              lastDate: now,
                            );
                            if (picked != null) {
                              setDialogState(() => selectedDate = picked);
                            }
                          },
                          icon: const Icon(Icons.calendar_today_outlined),
                          label: Text(
                            DateFormat('yyyy-MM-dd').format(selectedDate),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('attendance_manual_time'),
                          onPressed: () async {
                            final picked = await showTimePicker(
                              context: context,
                              initialTime: selectedTime,
                            );
                            if (picked != null) {
                              setDialogState(() => selectedTime = picked);
                            }
                          },
                          icon: const Icon(Icons.schedule_outlined),
                          label: Text(selectedTime.format(context)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('attendance_manual_manager_pin'),
                    onChanged: (value) {
                      managerPin = value;
                      if (pinValidationError != null) {
                        setDialogState(() => pinValidationError = null);
                      }
                    },
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    maxLength: 8,
                    decoration: InputDecoration(
                      labelText: context.l10n.attendanceManualManagerPin,
                      hintText: context.l10n.attendanceManualManagerPinHint,
                      border: const OutlineInputBorder(),
                      errorText: pinValidationError,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('attendance_manual_reason'),
                    onChanged: (value) => reason = value,
                    maxLength: 500,
                    decoration: InputDecoration(
                      labelText: context.l10n.attendanceManualReason,
                      hintText: context.l10n.attendanceManualReasonHint,
                      border: const OutlineInputBorder(),
                      errorText: validationError,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              key: const Key('attendance_manual_save'),
              onPressed: () {
                if (!RegExp(r'^\d{4,8}$').hasMatch(managerPin)) {
                  setDialogState(
                    () => pinValidationError =
                        context.l10n.attendanceManualManagerPinRequired,
                  );
                  return;
                }
                if (reason.trim().length < 3) {
                  setDialogState(
                    () => validationError =
                        context.l10n.attendanceManualReasonRequired,
                  );
                  return;
                }
                final wallTime = DateTime(
                  selectedDate.year,
                  selectedDate.month,
                  selectedDate.day,
                  selectedTime.hour,
                  selectedTime.minute,
                );
                Navigator.of(dialogContext).pop(
                  _ManualAttendanceDraft(
                    employeeId: selectedEmployeeId,
                    type: selectedType,
                    loggedAt: TimeUtils.vietnamWallTimeToUtc(wallTime),
                    reason: reason.trim(),
                    managerPin: managerPin,
                  ),
                );
              },
              child: Text(context.l10n.save),
            ),
          ],
        ),
      ),
    );
    if (draft == null || !mounted) return;

    setState(() => _isManualAttendanceSaving = true);
    try {
      await _attendanceService.recordManualAttendance(
        storeId: storeId,
        employeeId: draft.employeeId,
        type: draft.type,
        loggedAt: draft.loggedAt,
        reason: draft.reason,
        managerPin: draft.managerPin,
      );
      if (!mounted) return;
      await _reloadLogs(storeId);
      if (!mounted) return;
      await _reloadDailyLogs(storeId, _attendanceDate, preserveSelection: true);
      if (!mounted) return;
      showSuccessToast(context, context.l10n.attendanceManualEntrySaved);
    } catch (error) {
      if (!mounted) return;
      showErrorToast(context, _mapManualAttendanceError(error));
    } finally {
      if (mounted) setState(() => _isManualAttendanceSaving = false);
    }
  }

  String _mapManualAttendanceError(Object error) {
    final message = error.toString();
    if (message.contains('DISCOUNT_PIN_NOT_CONFIGURED')) {
      return context.l10n.attendanceManualManagerPinNotConfigured;
    }
    if (message.contains('DISCOUNT_PIN_REJECTED')) {
      return context.l10n.attendanceManualManagerPinIncorrect;
    }
    if (message.contains('ATTENDANCE_MANUAL_SEQUENCE_INVALID')) {
      return context.l10n.attendanceManualSequenceInvalid;
    }
    if (message.contains('ATTENDANCE_MANUAL_TIME_DUPLICATE')) {
      return context.l10n.attendanceManualTimeDuplicate;
    }
    if (message.contains('ATTENDANCE_MANUAL_TIME_INVALID')) {
      return context.l10n.attendanceManualTimeInvalid;
    }
    if (message.contains('ATTENDANCE_MANUAL_ENTRY_FORBIDDEN')) {
      return context.l10n.attendanceManualEntryForbidden;
    }
    return context.l10n.attendanceManualEntryFailed;
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
              key: const Key('attendance_payroll_unlock_dialog'),
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
                    final verified = await _pinService.verifyPin(storeId, pin);
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

    await Future<void>.delayed(kThemeAnimationDuration);
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

  Future<void> _showDailyAllowanceDialog({
    required String storeId,
    required Map<String, dynamic> attendanceRow,
  }) async {
    final employeeId = attendanceRow['userId']?.toString() ?? '';
    final role = attendanceRow['role']?.toString() ?? '';
    if (employeeId.isEmpty || (role != 'part_timer' && role != 'full_time')) {
      return;
    }

    final logs = attendanceRow['logs'] is List
        ? List<Map<String, dynamic>>.from(attendanceRow['logs'] as List)
        : const <Map<String, dynamic>>[];
    final latestLogDate = logs
        .map((log) => DateTime.tryParse(log['logged_at']?.toString() ?? ''))
        .whereType<DateTime>()
        .map(TimeUtils.toVietnam)
        .fold<DateTime?>(null, (latest, value) {
          if (latest == null || value.isAfter(latest)) return value;
          return latest;
        });
    var workDate = latestLogDate == null
        ? TimeUtils.nowVietnam()
        : DateTime(latestLogDate.year, latestLogDate.month, latestLogDate.day);
    final parking = TextEditingController();
    final note = TextEditingController();
    var isSplitShift = false;
    var loading = true;
    var saving = false;
    String? validation;

    Future<Map<String, dynamic>?> loadAllowance() =>
        _attendanceService.fetchDailyAllowance(
          storeId: storeId,
          employeeId: employeeId,
          workDate: workDate,
        );

    final initial = await loadAllowance();
    isSplitShift = initial?['is_split_shift'] == true;
    parking.text =
        (double.tryParse('${initial?['parking_allowance_amount'] ?? 0}') ?? 0)
            .toStringAsFixed(0);
    note.text = initial?['note']?.toString() ?? '';
    loading = false;
    if (!mounted) return;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          key: const Key('attendance_daily_allowance_dialog'),
          title: Text(context.l10n.attendanceDailyAllowanceTitle),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  key: const Key('attendance_allowance_work_date'),
                  onPressed: loading || saving
                      ? null
                      : () async {
                          final picked = await showDatePicker(
                            context: dialogContext,
                            initialDate: workDate,
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now(),
                          );
                          if (picked == null) return;
                          setDialogState(() {
                            workDate = picked;
                            loading = true;
                            validation = null;
                          });
                          try {
                            final existing = await loadAllowance();
                            if (!dialogContext.mounted) return;
                            setDialogState(() {
                              isSplitShift =
                                  existing?['is_split_shift'] == true;
                              parking.text =
                                  (double.tryParse(
                                            '${existing?['parking_allowance_amount'] ?? 0}',
                                          ) ??
                                          0)
                                      .toStringAsFixed(0);
                              note.text = existing?['note']?.toString() ?? '';
                              loading = false;
                            });
                          } catch (_) {
                            if (!dialogContext.mounted) return;
                            setDialogState(() {
                              loading = false;
                              validation = context
                                  .l10n
                                  .attendanceDailyAllowanceLoadFailed;
                            });
                          }
                        },
                  icon: const Icon(Icons.event_outlined),
                  label: Text(DateFormat('yyyy-MM-dd').format(workDate)),
                ),
                if (widget.isPhotoObjetContext && role == 'part_timer') ...[
                  const SizedBox(height: 12),
                  SwitchListTile.adaptive(
                    key: const Key('attendance_allowance_split_shift'),
                    contentPadding: EdgeInsets.zero,
                    value: isSplitShift,
                    onChanged: loading || saving
                        ? null
                        : (value) => setDialogState(() => isSplitShift = value),
                    title: Text(context.l10n.attendanceSplitShift),
                    subtitle: Text(
                      context.l10n.attendanceSplitShiftMealAllowanceHint,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  key: const Key('attendance_allowance_parking'),
                  controller: parking,
                  enabled: !loading && !saving,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: context.l10n.attendanceParkingAllowance,
                    suffixText: 'VND',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('attendance_allowance_note'),
                  controller: note,
                  enabled: !loading && !saving,
                  maxLength: 200,
                  decoration: InputDecoration(
                    labelText: context.l10n.attendanceAllowanceNote,
                  ),
                ),
                if (validation != null)
                  Text(
                    validation!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving
                  ? null
                  : () => Navigator.of(dialogContext).pop(false),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              key: const Key('attendance_allowance_save'),
              onPressed: loading || saving
                  ? null
                  : () async {
                      final parkingAmount = parseDecimalInput(parking.text);
                      if (parkingAmount == null || parkingAmount < 0) {
                        setDialogState(
                          () => validation =
                              context.l10n.attendanceParkingAllowanceInvalid,
                        );
                        return;
                      }
                      setDialogState(() {
                        saving = true;
                        validation = null;
                      });
                      try {
                        await _attendanceService.upsertDailyAllowance(
                          storeId: storeId,
                          employeeId: employeeId,
                          workDate: workDate,
                          isSplitShift:
                              widget.isPhotoObjetContext &&
                              role == 'part_timer' &&
                              isSplitShift,
                          parkingAllowanceAmount: parkingAmount,
                          note: note.text.trim().isEmpty
                              ? null
                              : note.text.trim(),
                        );
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop(true);
                        }
                      } catch (error) {
                        if (!dialogContext.mounted) return;
                        final message = error.toString();
                        setDialogState(() {
                          saving = false;
                          validation =
                              message.contains(
                                'SPLIT_SHIFT_ATTENDANCE_INCOMPLETE',
                              )
                              ? context
                                    .l10n
                                    .attendanceSplitShiftRequiresCompletedLogs
                              : context.l10n.attendanceDailyAllowanceSaveFailed;
                        });
                      }
                    },
              child: Text(context.l10n.save),
            ),
          ],
        ),
      ),
    );

    Future<void>.delayed(const Duration(milliseconds: 300), () {
      parking.dispose();
      note.dispose();
    });
    if (saved == true && mounted) {
      showSuccessToast(context, context.l10n.attendanceDailyAllowanceSaved);
      _clearPayrollPreview();
      setState(() {});
    }
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
        'logs': userLogs,
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

  List<Map<String, dynamic>> _buildMonthlyAttendanceRows(
    List<Map<String, dynamic>> logs,
  ) {
    final grouped = <DateTime, List<Map<String, dynamic>>>{};
    for (final log in logs) {
      final parsed = DateTime.tryParse(log['logged_at']?.toString() ?? '');
      if (parsed == null) continue;
      final local = TimeUtils.toVietnam(parsed);
      final day = DateTime(local.year, local.month, local.day);
      grouped.putIfAbsent(day, () => []).add(log);
    }

    final rows = grouped.entries.map((entry) {
      final dayLogs = [...entry.value]
        ..sort((first, second) {
          final firstTime = DateTime.tryParse(
            first['logged_at']?.toString() ?? '',
          );
          final secondTime = DateTime.tryParse(
            second['logged_at']?.toString() ?? '',
          );
          return (firstTime ?? DateTime.fromMillisecondsSinceEpoch(0))
              .compareTo(secondTime ?? DateTime.fromMillisecondsSinceEpoch(0));
        });
      DateTime? firstClockIn;
      DateTime? lastClockOut;
      DateTime? openClockIn;
      var workedMinutes = 0;
      var needsReview = false;

      for (final log in dayLogs) {
        final parsed = DateTime.tryParse(log['logged_at']?.toString() ?? '');
        if (parsed == null) continue;
        final local = TimeUtils.toVietnam(parsed);
        if (log['type']?.toString() == 'clock_in') {
          firstClockIn ??= local;
          if (openClockIn != null) {
            needsReview = true;
          } else {
            openClockIn = local;
          }
        } else if (log['type']?.toString() == 'clock_out') {
          lastClockOut = local;
          if (openClockIn == null || local.isBefore(openClockIn)) {
            needsReview = true;
          } else {
            workedMinutes += local.difference(openClockIn).inMinutes;
            openClockIn = null;
          }
        }
      }
      if (openClockIn != null) needsReview = true;

      return <String, dynamic>{
        'date': entry.key,
        'clockIn': firstClockIn,
        'clockOut': lastClockOut,
        'hours': workedMinutes / 60,
        'needsReview': needsReview,
      };
    }).toList();

    rows.sort(
      (first, second) =>
          (second['date'] as DateTime).compareTo(first['date'] as DateTime),
    );
    return rows;
  }

  Widget _monthlyAttendanceRow(Map<String, dynamic> row) {
    final needsReview = row['needsReview'] == true;
    return Row(
      children: [
        SizedBox(
          width: 82,
          child: Text(
            DateFormat('MM-dd').format(row['date'] as DateTime),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        Expanded(
          child: Text(
            '${_formatClock(row['clockIn'] as DateTime?)} – ${_formatClock(row['clockOut'] as DateTime?)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          context.l10n.attendanceHoursValue(
            (row['hours'] as double).toStringAsFixed(1),
          ),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(width: 8),
        ToastStatusBadge(
          label: needsReview
              ? context.l10n.attendanceNeedsCheck
              : context.l10n.inventoryStatusNormal,
          color: needsReview ? PosColors.warning : PosColors.success,
          compact: true,
        ),
      ],
    );
  }

  Map<String, dynamic>? _resolveSelectedAttendanceRow(
    List<Map<String, dynamic>> rows,
  ) {
    if (rows.isEmpty) return null;
    final selectedId = _selectedAttendanceUserId;
    if (selectedId == null) return null;
    for (final row in rows) {
      if (row['userId'] == selectedId) {
        return row;
      }
    }
    return null;
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
    final storeId = ref.watch(adminScopedStoreIdProvider);
    final canManageAttendance = const {
      'admin',
      'store_admin',
      'brand_admin',
      'super_admin',
    }.contains(auth.role);

    if (storeId != null && _initializedRestaurantId != storeId) {
      _initializedRestaurantId = storeId;
      Future.microtask(() => _initialize(storeId));
    }

    final filteredLogs = _dailyLogs;
    final filteredPayrolls = _payrolls;
    final payrollRequiresUnlock = _hasPayrollPin == true && !_payrollUnlocked;
    final attendanceRows = _buildAttendanceRows(filteredLogs, const []);
    final selectedAttendanceRow = _resolveSelectedAttendanceRow(attendanceRows);
    final today = TimeUtils.nowVietnam();
    final dailyRecordsTitle = _isSameDay(_attendanceDate, today)
        ? context.l10n.attendanceRecordsTitle
        : context.l10n.attendanceDateRecordsTitle(
            DateFormat('yyyy-MM-dd').format(_attendanceDate),
          );
    final periodStaffCount = _logs
        .map((log) => log['user_id']?.toString())
        .whereType<String>()
        .where((userId) => userId.isNotEmpty)
        .toSet()
        .length;
    final payrollTargetCount = filteredPayrolls.isNotEmpty
        ? filteredPayrolls.length
        : _staffList
              .where((staff) => staff['role']?.toString() == 'part_timer')
              .length;
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
    StaffPayroll? selectedPayroll;
    final selectedUserId = selectedAttendanceRow?['userId']?.toString();
    if (selectedUserId != null) {
      for (final payroll in filteredPayrolls) {
        if (payroll.userId == selectedUserId) {
          selectedPayroll = payroll;
          break;
        }
      }
    }
    final photoCaptureCount = filteredLogs
        .where((row) => (row['photo_url']?.toString() ?? '').isNotEmpty)
        .length;
    final currency = NumberFormat('#,###', 'vi_VN');
    final attendanceHeader = _buildAttendanceCommandHeader(
      storeId: storeId,
      periodLogCount: _logs.length,
      periodStaffCount: periodStaffCount,
      payrollTargetCount: payrollTargetCount,
    );

    Widget dailyRecordActions() {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          KeyedSubtree(
            key: const Key('attendance_daily_date_filter'),
            child: _DateButton(
              label: context.l10n.attendanceRecordDateFilter,
              value: _attendanceDate,
              onTap: storeId == null
                  ? () {}
                  : () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _attendanceDate,
                        firstDate: DateTime(2020),
                        lastDate: TimeUtils.nowVietnam(),
                      );
                      if (picked != null && mounted) {
                        await _reloadDailyLogs(storeId, picked);
                      }
                    },
            ),
          ),
          if (canManageAttendance)
            OutlinedButton.icon(
              key: const Key('attendance_manual_entry_action'),
              onPressed: storeId == null || _isManualAttendanceSaving
                  ? null
                  : () => _showManualAttendanceDialog(storeId),
              icon: const Icon(Icons.more_time_rounded, size: 18),
              label: Text(context.l10n.attendanceManualEntryAction),
            ),
        ],
      );
    }

    Widget compactAttendanceList() {
      return PosDataPanel(
        title: dailyRecordsTitle,
        subtitle: context.l10n.attendanceDailyRecordsSubtitle,
        trailing: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            ToastStatusBadge(
              label: context.l10n.attendanceShowingStaff(attendanceRows.length),
              color: PosColors.info,
              compact: true,
            ),
            const SizedBox(height: 8),
            dailyRecordActions(),
          ],
        ),
        child: _isDailyLogsLoading
            ? const SizedBox(
                height: 260,
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.amber500),
                ),
              )
            : attendanceRows.isEmpty
            ? PosEmptyState(
                title: context.l10n.attendanceNoRecordsSelectedPeriod,
                subtitle: context.l10n.attendanceRecordSourceHint,
                icon: Icons.event_note_outlined,
              )
            : Column(
                children: [
                  for (
                    var index = 0;
                    index < attendanceRows.length;
                    index++
                  ) ...[
                    Builder(
                      builder: (context) {
                        final row = attendanceRows[index];
                        final selected =
                            selectedAttendanceRow?['userId'] == row['userId'];
                        return InkWell(
                          onTap: storeId == null
                              ? null
                              : () => _selectAttendanceEmployee(
                                  storeId,
                                  row['userId'] as String,
                                ),
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: selected
                                  ? PosColors.accentMuted
                                  : PosColors.surface,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: selected
                                    ? PosColors.accent
                                    : PosColors.border,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        row['name'] as String,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                            ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    ToastStatusBadge(
                                      label: row['statusLabel'] as String,
                                      color: row['statusColor'] as Color,
                                      compact: true,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    _compactAttendanceChip(
                                      row['role'] as String,
                                    ),
                                    _compactAttendanceChip(
                                      '${context.l10n.clockIn} ${_formatClock(row['clockIn'] as DateTime?)}',
                                    ),
                                    _compactAttendanceChip(
                                      '${context.l10n.clockOut} ${_formatClock(row['clockOut'] as DateTime?)}',
                                    ),
                                    _compactAttendanceChip(
                                      context.l10n.attendanceHoursValue(
                                        (row['hours'] as double)
                                            .toStringAsFixed(1),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    if (index != attendanceRows.length - 1)
                      const SizedBox(height: 8),
                  ],
                ],
              ),
      );
    }

    Widget selectedDetail({required bool scrollable}) =>
        _buildSelectedAttendanceDetailPanel(
          storeId: storeId,
          selectedAttendanceRow: selectedAttendanceRow,
          selectedPayroll: selectedPayroll,
          filteredPayrolls: filteredPayrolls,
          payrollRequiresUnlock: payrollRequiresUnlock,
          totalHours: totalHours,
          overtimeHours: overtimeHours,
          estimatedPayroll: estimatedPayroll,
          currency: currency,
          employeeMonthLogs: _selectedEmployeeMonthLogs,
          isEmployeeMonthLoading: _isEmployeeMonthLoading,
          employeeMonthError: _employeeMonthError,
          attendanceDate: _attendanceDate,
          scrollable: scrollable,
        );

    if (MediaQuery.sizeOf(context).width < 1120 ||
        MediaQuery.textScalerOf(context).scale(1) > 1.5) {
      return Scaffold(
        key: const Key('attendance_root'),
        backgroundColor: AppColors.surface0,
        body: ToastResponsiveScrollBody(
          maxWidth: 1480,
          padding: const EdgeInsets.all(20),
          children: [
            attendanceHeader,
            if (_logsError != null) ...[
              const SizedBox(height: 12),
              PosExceptionAlert(label: _logsError!, color: PosColors.danger),
            ],
            if (_dailyLogsError != null) ...[
              const SizedBox(height: 12),
              PosExceptionAlert(
                label: _dailyLogsError!,
                color: PosColors.danger,
              ),
            ],
            if (_payrollError != null) ...[
              const SizedBox(height: 12),
              PosExceptionAlert(
                label: _payrollError!,
                color: PosColors.warning,
              ),
            ],
            const SizedBox(height: 16),
            compactAttendanceList(),
            const SizedBox(height: 16),
            selectedDetail(scrollable: false),
            const SizedBox(height: 12),
            _buildAttendanceSecondarySignals(
              photoCaptureCount: photoCaptureCount,
            ),
          ],
        ),
      );
    }

    return Scaffold(
      key: const Key('attendance_root'),
      backgroundColor: AppColors.surface0,
      body: ToastResponsiveBody(
        maxWidth: 1480,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            attendanceHeader,
            if (_logsError != null) ...[
              const SizedBox(height: 12),
              PosExceptionAlert(label: _logsError!, color: PosColors.danger),
            ],
            if (_dailyLogsError != null) ...[
              const SizedBox(height: 12),
              PosExceptionAlert(
                label: _dailyLogsError!,
                color: PosColors.danger,
              ),
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
                  title: dailyRecordsTitle,
                  subtitle: context.l10n.attendanceDailyRecordsSubtitle,
                  trailing: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      ToastStatusBadge(
                        label: context.l10n.attendanceShowingStaff(
                          attendanceRows.length,
                        ),
                        color: PosColors.info,
                        compact: true,
                      ),
                      const SizedBox(height: 8),
                      dailyRecordActions(),
                    ],
                  ),
                  child: _isDailyLogsLoading
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
                            if (storeId != null) {
                              _selectAttendanceEmployee(storeId, userId);
                            }
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
                  employeeMonthLogs: _selectedEmployeeMonthLogs,
                  isEmployeeMonthLoading: _isEmployeeMonthLoading,
                  employeeMonthError: _employeeMonthError,
                  attendanceDate: _attendanceDate,
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
    required int periodLogCount,
    required int periodStaffCount,
    required int payrollTargetCount,
  }) {
    // Contract anchor: title: context.l10n.attendanceManagementTitle; label: context.l10n.payrollPreview; label: context.l10n.download; title: context.l10n.attendancePayrollSummaryTitle.
    final attendanceMetrics = [
      ToastMetric(
        label: context.l10n.staff,
        value: context.l10n.staffCount(_staffList.length),
      ),
      ToastMetric(
        label: context.l10n.attendancePeriodLogs,
        value: context.l10n.countCases(periodLogCount),
        tone: PosColors.info,
      ),
      ToastMetric(
        label: context.l10n.attendancePeriodStaff,
        value: context.l10n.staffCount(periodStaffCount),
        tone: PosColors.textSecondary,
      ),
      ToastMetric(
        label: context.l10n.attendancePayrollTargets,
        value: context.l10n.staffCount(payrollTargetCount),
        tone: PosColors.accent,
      ),
    ];

    return ToastWorkSurface(
      padding: const EdgeInsets.all(4),
      backgroundColor: AppColors.surface1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final title = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    context.l10n.attendanceManagementTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    context.l10n.attendanceManagementSubtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.textSecondary,
                    ),
                  ),
                ],
              );
              final metrics = ToastMetricStrip(
                dense: true,
                metrics: attendanceMetrics,
              );
              final badge = ToastStatusBadge(
                label: _payrollUnlocked
                    ? context.l10n.attendancePayrollUnlockedBadge
                    : context.l10n.attendancePayrollLockedBadge,
                color: _payrollUnlocked ? PosColors.success : PosColors.warning,
                compact: true,
              );
              if (constraints.maxWidth < 620 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.5) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [title, badge],
                    ),
                    const SizedBox(height: 8),
                    metrics,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 2, child: title),
                  const SizedBox(width: 10),
                  Expanded(flex: 5, child: metrics),
                  const SizedBox(width: 10),
                  badge,
                ],
              );
            },
          ),
          const SizedBox(height: 4),
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
                    setState(() {
                      _logFrom = DateTime(
                        picked.year,
                        picked.month,
                        picked.day,
                      );
                      _clearPayrollPreview();
                    });
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
                      _clearPayrollPreview();
                    });
                  }
                },
              ),
              FilledButton.icon(
                onPressed: storeId == null ? null : () => _reloadLogs(storeId),
                icon: const Icon(Icons.search, size: 16),
                label: Text(context.l10n.search),
              ),
              FilledButton.tonalIcon(
                key: const Key('attendance_export_all_payroll'),
                onPressed:
                    storeId == null || !_payrollUnlocked || _isPayrollLoading
                    ? null
                    : () => _downloadAllPayroll(storeId),
                icon: const Icon(Icons.download_rounded, size: 18),
                label: Text(context.l10n.attendanceExportAllPayroll),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            context.l10n.attendancePeriodUsageHint,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
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
    required List<Map<String, dynamic>> employeeMonthLogs,
    required bool isEmployeeMonthLoading,
    required String? employeeMonthError,
    required DateTime attendanceDate,
    bool scrollable = true,
  }) {
    final hasUnpairedLogs =
        selectedPayroll?.dailyRecords.any((record) => record.isUnpaired) ??
        false;
    final statusLabel = selectedAttendanceRow?['statusLabel'] as String?;
    final statusColor =
        selectedAttendanceRow?['statusColor'] as Color? ?? PosColors.info;
    final selectedLogs = selectedAttendanceRow?['logs'] is List
        ? List<Map<String, dynamic>>.from(
            selectedAttendanceRow!['logs'] as List,
          )
        : const <Map<String, dynamic>>[];
    final monthlyRows = _buildMonthlyAttendanceRows(employeeMonthLogs);
    final selectedMonth = DateFormat('yyyy-MM').format(attendanceDate);
    final payrollActionLabel = payrollRequiresUnlock
        ? context.l10n.attendanceUnlockPayrollAction
        : filteredPayrolls.isEmpty
        ? context.l10n.attendanceRunPayrollPreview
        : context.l10n.attendanceExportAllPayroll;
    final VoidCallback? payrollAction = payrollRequiresUnlock
        ? storeId == null
              ? null
              : () => _unlockPayroll(storeId)
        : filteredPayrolls.isEmpty
        ? storeId == null
              ? null
              : () => _loadPayrollPreview(storeId)
        : () => _exportPayrollPreview(_payrolls);

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
                          ? context.l10n.attendanceEmployeeSelectionHint
                          : '${context.l10n.attendanceMonthlyRecordsTitle(selectedMonth)} · ${selectedAttendanceRow['role'] as String}',
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
          _attendanceDetailBody(
            scrollable: scrollable,
            child: selectedAttendanceRow == null
                ? PosEmptyState(
                    title: context.l10n.staffNoSelection,
                    subtitle: context.l10n.attendanceEmployeeSelectionHint,
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
                                selectedAttendanceRow['clockOut'] as DateTime?,
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
                                label: context.l10n.attendanceUnpairedLogsTitle,
                                detail:
                                    context.l10n.attendanceUnpairedLogsDetail,
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        key: const Key('attendance_employee_monthly_records'),
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.surface1,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.surface2),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.l10n.attendanceMonthlyRecordsTitle(
                                selectedMonth,
                              ),
                              style: AppFonts.system(
                                color: AppColors.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              context.l10n.attendanceMonthlyRecordsSubtitle,
                              style: AppFonts.system(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 12),
                            if (isEmployeeMonthLoading)
                              const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(16),
                                  child: CircularProgressIndicator(
                                    color: AppColors.amber500,
                                  ),
                                ),
                              )
                            else if (employeeMonthError != null)
                              PosExceptionAlert(
                                label: employeeMonthError,
                                color: PosColors.danger,
                              )
                            else if (monthlyRows.isEmpty)
                              Text(
                                context.l10n.attendanceMonthlyNoRecords,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: PosColors.textSecondary),
                              )
                            else
                              Column(
                                children: [
                                  for (
                                    var index = 0;
                                    index < monthlyRows.length;
                                    index++
                                  ) ...[
                                    _monthlyAttendanceRow(monthlyRows[index]),
                                    if (index != monthlyRows.length - 1)
                                      const Divider(height: 18),
                                  ],
                                ],
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (storeId != null &&
                          (selectedAttendanceRow['role'] == 'part_timer' ||
                              selectedAttendanceRow['role'] == 'full_time'))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              key: const Key(
                                'attendance_manage_daily_allowance',
                              ),
                              onPressed: () => _showDailyAllowanceDialog(
                                storeId: storeId,
                                attendanceRow: selectedAttendanceRow,
                              ),
                              icon: const Icon(
                                Icons.account_balance_wallet_outlined,
                              ),
                              label: Text(
                                context.l10n.attendanceManageDailyAllowance,
                              ),
                            ),
                          ),
                        ),
                      _buildAttendancePhotoEvidence(selectedLogs),
                      const SizedBox(height: 12),
                      Container(
                        decoration: BoxDecoration(
                          color: AppColors.surface1,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.surface2),
                        ),
                        child: ExpansionTile(
                          key: const Key('attendance_payroll_secondary_detail'),
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
                            style: AppFonts.system(
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
                            style: AppFonts.system(
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
                                _formatVnd(currency, estimatedPayroll),
                                tone: PosColors.accent,
                              ),
                              const SizedBox(height: 10),
                              _summaryMetricRow(
                                context.l10n.attendanceAccumulatedPayroll,
                                selectedPayroll == null
                                    ? context.l10n.attendancePreviewRequired
                                    : _formatVnd(
                                        currency,
                                        selectedPayroll.totalAmount,
                                      ),
                                tone: selectedPayroll == null
                                    ? PosColors.textSecondary
                                    : PosColors.accent,
                              ),
                              const SizedBox(height: 14),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  key: const Key(
                                    'attendance_payroll_primary_action',
                                  ),
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
        ],
      ),
    );
  }

  Widget _buildAttendancePhotoEvidence(
    List<Map<String, dynamic>> attendanceLogs,
  ) {
    final photoLogs =
        attendanceLogs
            .where((log) => (log['photo_url']?.toString() ?? '').isNotEmpty)
            .toList()
          ..sort((a, b) {
            final aTime = DateTime.tryParse(a['logged_at']?.toString() ?? '');
            final bTime = DateTime.tryParse(b['logged_at']?.toString() ?? '');
            return (bTime ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(
              aTime ?? DateTime.fromMillisecondsSinceEpoch(0),
            );
          });

    return Container(
      key: const Key('attendance_photo_evidence_panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.attendancePhotosTitle,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          if (photoLogs.isEmpty)
            Text(
              context.l10n.attendanceNoPhotos,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final log in photoLogs) _attendancePhotoTile(log),
              ],
            ),
        ],
      ),
    );
  }

  Widget _attendancePhotoTile(Map<String, dynamic> log) {
    final photoUrl = log['photo_url']?.toString() ?? '';
    final thumbnailUrl =
        log['photo_thumbnail_url']?.toString().trim().isNotEmpty == true
        ? log['photo_thumbnail_url'].toString()
        : photoUrl;
    final loggedAt = DateTime.tryParse(log['logged_at']?.toString() ?? '');
    final localTime = loggedAt == null ? null : TimeUtils.toVietnam(loggedAt);
    final type = log['type']?.toString() == 'clock_out'
        ? context.l10n.clockOut
        : context.l10n.clockIn;
    final logId = log['id']?.toString() ?? photoUrl.hashCode.toString();

    return Semantics(
      button: true,
      label: context.l10n.attendanceViewPhoto,
      child: InkWell(
        key: Key('attendance_photo_$logId'),
        onTap: () => _showAttendancePhoto(
          photoUrl: photoUrl,
          title: localTime == null
              ? type
              : '$type · ${DateFormat('yyyy-MM-dd HH:mm').format(localTime)}',
        ),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 132,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: PosColors.mutedSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: PosColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 116,
                  height: 86,
                  child: Image.network(
                    thumbnailUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      color: PosColors.panelMuted,
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.broken_image_outlined,
                        color: PosColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                type,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w800),
              ),
              if (localTime != null)
                Text(
                  DateFormat('MM-dd HH:mm').format(localTime),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showAttendancePhoto({
    required String photoUrl,
    required String title,
  }) => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('attendance_photo_dialog'),
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
        child: InteractiveViewer(
          minScale: 0.8,
          maxScale: 4,
          child: Image.network(
            photoUrl,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => SizedBox(
              width: 420,
              height: 240,
              child: PosEmptyState(
                title: context.l10n.attendancePhotoLoadFailed,
                icon: Icons.broken_image_outlined,
              ),
            ),
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(context.l10n.close),
        ),
      ],
    ),
  );

  Widget _compactAttendanceChip(String label) {
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

  Widget _attendanceDetailBody({
    required bool scrollable,
    required Widget child,
  }) {
    if (!scrollable) {
      return child;
    }

    return Expanded(child: SingleChildScrollView(child: child));
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
          style: AppFonts.system(
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
          style: AppFonts.system(color: AppColors.textSecondary, fontSize: 12),
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
        style: AppFonts.system(),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        side: const BorderSide(color: AppColors.surface2),
      ),
    );
  }
}
