import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/attendance_service.dart';
import '../../../core/services/payroll_service.dart';
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
  bool _hasLoadedPayroll = false;
  String? _logsError;
  String? _payrollError;

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

      if (!mounted) return;
      setState(() {
        _staffList = staff;
        _logs = logs;
        _isLogsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLogsLoading = false;
        _logsError = _mapAttendanceError(e, 'Failed to load attendance data.');
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
          'Failed to reload attendance logs.',
        );
      });
      showErrorToast(context, 'Failed to query attendance logs');
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
        _hasLoadedPayroll = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isPayrollLoading = false;
        _hasLoadedPayroll = true;
        _payrollError = _mapPayrollError(e, 'Failed to load payroll preview.');
      });
      showErrorToast(context, 'Failed to calculate payroll preview');
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Payroll preview saved.')));
  }

  String _mapAttendanceError(Object error, String fallback) {
    final message = error is PostgrestException ? error.message : '$error';

    if (message.contains('ATTENDANCE_STAFF_DIRECTORY_FORBIDDEN') ||
        message.contains('ATTENDANCE_LOG_VIEW_FORBIDDEN')) {
      return 'No permission to view attendance data for this store.';
    }
    if (message.contains('ATTENDANCE_LOG_RANGE_REQUIRED') ||
        message.contains('ATTENDANCE_LOG_RANGE_INVALID')) {
      return 'Re-select the query period.';
    }
    if (message.contains('ATTENDANCE_LOG_USER_NOT_FOUND')) {
      return 'Re-select the staff filter.';
    }

    return fallback;
  }

  String _mapPayrollError(Object error, String fallback) {
    final message = error is PostgrestException ? error.message : '$error';

    if (message.contains('ATTENDANCE_LOG_VIEW_FORBIDDEN')) {
      return 'No permission to calculate payroll for this store.';
    }
    if (message.contains('ATTENDANCE_WAGE_CONFIG_FORBIDDEN')) {
      return 'No permission to read wage configuration.';
    }
    if (message.contains('ATTENDANCE_WAGE_CONFIG_NOT_FOUND')) {
      return 'Wage configuration is missing for one or more staff members.';
    }

    return fallback;
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

    return Scaffold(
      key: const Key('attendance_root'),
      backgroundColor: AppColors.surface0,
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Attendance Records',
              style: GoogleFonts.bebasNeue(
                color: AppColors.textPrimary,
                fontSize: 32,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Attendance v1 scope includes only clock-in/out events and admin log queries. Payroll calculation, export, and device extensions are out of scope.',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _DateButton(
                  label: 'From',
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
                const SizedBox(width: 10),
                _DateButton(
                  label: 'To',
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
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedStaffFilter,
                    dropdownColor: AppColors.surface1,
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: 'all',
                        child: Text('All Staff'),
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
                        setState(() => _selectedStaffFilter = value);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: storeId == null
                      ? null
                      : () => _reloadLogs(storeId),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.amber500,
                    foregroundColor: AppColors.surface0,
                  ),
                  child: const Text('Apply'),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: storeId == null
                      ? null
                      : () => _loadPayrollPreview(storeId),
                  icon: const Icon(Icons.request_page_outlined, size: 18),
                  label: const Text('Preview Payroll'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textPrimary,
                    side: const BorderSide(color: AppColors.surface2),
                  ),
                ),
                if (filteredPayrolls.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: () => _exportPayrollPreview(filteredPayrolls),
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Export Payroll'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                      side: const BorderSide(color: AppColors.surface2),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 14),
            if (_logsError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  _logsError!,
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.statusCancelled,
                    fontSize: 13,
                  ),
                ),
              ),
            if (_isPayrollLoading ||
                _payrollError != null ||
                filteredPayrolls.isNotEmpty ||
                _hasLoadedPayroll) ...[
              _buildPayrollPreview(filteredPayrolls),
              const SizedBox(height: 14),
            ],
            Expanded(
              child: _isLogsLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.amber500,
                      ),
                    )
                  : filteredLogs.isEmpty
                  ? _buildInfoState(
                      icon: Icons.event_note_outlined,
                      title: 'No attendance records for the selected period.',
                      message:
                          'Events recorded at the clock-in/out kiosk appear here.',
                    )
                  : _buildLogsTable(filteredLogs),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoState({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surface1,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.surface2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: AppColors.textSecondary, size: 32),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: GoogleFonts.notoSansKr(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: GoogleFonts.notoSansKr(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPayrollPreview(List<StaffPayroll> payrolls) {
    final totalHours = payrolls.fold<double>(
      0,
      (sum, payroll) => sum + payroll.totalHours,
    );
    final totalAmount = payrolls.fold<double>(
      0,
      (sum, payroll) => sum + payroll.totalAmount,
    );
    final currency = NumberFormat('#,###', 'vi_VN');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Payroll Preview',
                style: GoogleFonts.notoSansKr(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Read-only estimate for the selected attendance period.',
                style: GoogleFonts.notoSansKr(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildPayrollMetric(
                label: 'Staff',
                value: '${payrolls.length}',
                accent: AppColors.amber500,
              ),
              _buildPayrollMetric(
                label: 'Hours',
                value: totalHours.toStringAsFixed(2),
                accent: AppColors.statusAvailable,
              ),
              _buildPayrollMetric(
                label: 'Estimated Payroll',
                value: '₫${currency.format(totalAmount)}',
                accent: AppColors.statusOccupied,
              ),
            ],
          ),
          if (_payrollError != null) ...[
            const SizedBox(height: 10),
            Text(
              _payrollError!,
              style: GoogleFonts.notoSansKr(
                color: AppColors.statusCancelled,
                fontSize: 13,
              ),
            ),
          ] else if (_isPayrollLoading) ...[
            const SizedBox(height: 16),
            const Center(
              child: CircularProgressIndicator(color: AppColors.amber500),
            ),
          ] else if (payrolls.isEmpty) ...[
            const SizedBox(height: 10),
            Text(
              _hasLoadedPayroll
                  ? 'No payroll preview is available for the selected period.'
                  : 'Load payroll preview when you need a read-only estimate.',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ] else ...[
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: payrolls.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: AppColors.surface2),
                itemBuilder: (context, index) {
                  final payroll = payrolls[index];
                  final shiftCount = payroll.dailyRecords
                      .where((record) => !record.isUnpaired)
                      .length;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      payroll.userName,
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: Text(
                      '$shiftCount shifts · ${payroll.totalHours.toStringAsFixed(2)} hours',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    trailing: Text(
                      '₫${currency.format(payroll.totalAmount)}',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.amber500,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPayrollMetric({
    required String label,
    required String value,
    required Color accent,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: GoogleFonts.notoSansKr(
              color: accent,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogsTable(List<Map<String, dynamic>> logs) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          _buildLogHeaderRow(),
          const Divider(height: 1, color: AppColors.surface2),
          Expanded(
            child: ListView.separated(
              itemCount: logs.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: AppColors.surface2),
              itemBuilder: (context, index) {
                final row = logs[index];
                final rawDateTime = DateTime.tryParse(
                  row['logged_at']?.toString() ?? '',
                );
                final dateTime = rawDateTime == null
                    ? null
                    : TimeUtils.toVietnam(rawDateTime);
                final user = row['users'];
                final userName = user is Map<String, dynamic>
                    ? user['full_name']?.toString() ?? '-'
                    : '-';
                final type = row['type']?.toString() == 'clock_in'
                    ? 'Clock In'
                    : 'Clock Out';
                final photoUrl = row['photo_url']?.toString();

                return Container(
                  color: index.isEven ? AppColors.surface1 : AppColors.surface0,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: Text(
                          dateTime == null
                              ? '-'
                              : DateFormat('yyyy-MM-dd').format(dateTime),
                          style: GoogleFonts.notoSansKr(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(
                          userName,
                          style: GoogleFonts.notoSansKr(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          type,
                          style: GoogleFonts.notoSansKr(
                            color: row['type']?.toString() == 'clock_in'
                                ? AppColors.statusAvailable
                                : AppColors.statusOccupied,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          dateTime == null
                              ? '-'
                              : DateFormat('HH:mm').format(dateTime),
                          style: GoogleFonts.notoSansKr(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: GestureDetector(
                            onTap: photoUrl == null
                                ? null
                                : () => _showPhotoDialog(photoUrl),
                            child: CircleAvatar(
                              radius: 20,
                              backgroundColor: AppColors.surface2,
                              backgroundImage: photoUrl == null
                                  ? null
                                  : NetworkImage(photoUrl),
                              child: photoUrl == null
                                  ? const Icon(
                                      Icons.person,
                                      color: AppColors.textSecondary,
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogHeaderRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          _headerCell('Date', flex: 3),
          _headerCell('Staff', flex: 3),
          _headerCell('Type', flex: 2),
          _headerCell('Time', flex: 2),
          _headerCell('Photo', flex: 2),
        ],
      ),
    );
  }

  Widget _headerCell(String label, {required int flex}) {
    return Expanded(
      flex: flex,
      child: Text(
        label,
        style: GoogleFonts.notoSansKr(
          color: AppColors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Future<void> _showPhotoDialog(String photoUrl) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.black,
          insetPadding: const EdgeInsets.all(20),
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 4,
                  child: Image.network(photoUrl, fit: BoxFit.contain),
                ),
              ),
              Positioned(
                right: 8,
                top: 8,
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: Colors.white),
                ),
              ),
            ],
          ),
        );
      },
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
