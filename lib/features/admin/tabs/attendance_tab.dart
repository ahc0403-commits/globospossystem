import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../../core/services/attendance_service.dart';
import '../../../core/services/payroll_service.dart';
import '../../../main.dart';
import '../../../widgets/error_toast.dart';
import '../../auth/auth_provider.dart';

class AttendanceTab extends ConsumerStatefulWidget {
  const AttendanceTab({super.key});

  @override
  ConsumerState<AttendanceTab> createState() => _AttendanceTabState();
}

class _AttendanceTabState extends ConsumerState<AttendanceTab>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 2,
    vsync: this,
  );
  final _currencyFormat = NumberFormat('#,###', 'vi_VN');

  String? _initializedRestaurantId;

  DateTime _logFrom = _startOfWeek(DateTime.now());
  DateTime _logTo = DateTime.now();
  String _selectedStaffFilter = 'all';
  List<Map<String, dynamic>> _staffList = const [];
  List<Map<String, dynamic>> _logs = const [];
  bool _isLogsLoading = false;
  String? _logsError;

  String? _wageStaffId;
  String _wageType = 'hourly';
  final TextEditingController _hourlyRateController = TextEditingController();
  final List<_ShiftRowData> _shiftRows = [];
  bool _isSavingWage = false;

  DateTime _payrollFrom = _startOfWeek(DateTime.now());
  DateTime _payrollTo = DateTime.now();
  bool _isCalculating = false;
  bool _isExporting = false;
  String? _payrollError;
  List<StaffPayroll> _payrolls = const [];

  static DateTime _startOfWeek(DateTime now) {
    final weekday = now.weekday;
    return DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: weekday - 1));
  }

  @override
  void dispose() {
    _tabController.dispose();
    _hourlyRateController.dispose();
    for (final row in _shiftRows) {
      row.dispose();
    }
    super.dispose();
  }

  Future<void> _initialize(String restaurantId) async {
    setState(() {
      _isLogsLoading = true;
      _logsError = null;
    });

    try {
      final staff = await attendanceService.fetchStaffList(restaurantId);
      final logs = await attendanceService.fetchLogs(
        restaurantId: restaurantId,
        from: _logFrom,
        to: _logTo,
      );

      if (!mounted) return;
      setState(() {
        _staffList = staff;
        _logs = logs;
        _wageStaffId = staff.isNotEmpty ? staff.first['id']?.toString() : null;
        _isLogsLoading = false;
      });

      if (_wageStaffId != null) {
        await _loadWageConfig(restaurantId, _wageStaffId!);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLogsLoading = false;
        _logsError = '근태 데이터를 불러오지 못했습니다: $e';
      });
    }
  }

  Future<void> _reloadLogs(String restaurantId) async {
    setState(() {
      _isLogsLoading = true;
      _logsError = null;
    });
    try {
      final logs = await attendanceService.fetchLogs(
        restaurantId: restaurantId,
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
        _logsError = '근태 로그 조회 실패: $e';
      });
      showErrorToast(context, '근태 로그 조회 실패');
    }
  }

  Future<void> _loadWageConfig(String restaurantId, String userId) async {
    try {
      final config = await attendanceService.fetchWageConfig(
        restaurantId: restaurantId,
        userId: userId,
      );

      for (final row in _shiftRows) {
        row.dispose();
      }
      _shiftRows.clear();

      if (config == null) {
        if (!mounted) return;
        setState(() {
          _wageType = 'hourly';
          _hourlyRateController.text = '';
        });
        return;
      }

      final type = config['wage_type']?.toString() ?? 'hourly';
      final hourlyRate = config['hourly_rate'];
      final shiftRates = config['shift_rates'];

      if (!mounted) return;
      setState(() {
        _wageType = type;
        _hourlyRateController.text = hourlyRate == null ? '' : '$hourlyRate';
        if (shiftRates is List) {
          for (final row in shiftRates) {
            if (row is Map<String, dynamic>) {
              _shiftRows.add(
                _ShiftRowData(
                  start: _parseTime(row['start']?.toString() ?? '09:00'),
                  end: _parseTime(row['end']?.toString() ?? '18:00'),
                  amount: row['amount']?.toString() ?? '',
                ),
              );
            }
          }
        }
      });
    } catch (_) {
      // ignore and keep defaults
    }
  }

  Future<void> _saveWageConfig(String restaurantId) async {
    final staffId = _wageStaffId;
    if (staffId == null) {
      showErrorToast(context, '직원을 먼저 선택하세요');
      return;
    }

    setState(() => _isSavingWage = true);

    try {
      final hourlyRate = double.tryParse(_hourlyRateController.text.trim());
      final shiftRates = _shiftRows
          .map(
            (row) => {
              'start': _formatTime(row.start),
              'end': _formatTime(row.end),
              'amount': double.tryParse(row.amountController.text.trim()) ?? 0,
            },
          )
          .toList();

      await attendanceService.upsertWageConfig(
        restaurantId: restaurantId,
        userId: staffId,
        wageType: _wageType,
        hourlyRate: _wageType == 'hourly' ? (hourlyRate ?? 0) : null,
        shiftRates: _wageType == 'shift' ? shiftRates : const [],
      );

      if (!mounted) return;
      showSuccessToast(context, '급여 설정이 저장되었습니다');
    } catch (e) {
      if (!mounted) return;
      showErrorToast(context, '급여 설정 저장 실패: $e');
    } finally {
      if (mounted) {
        setState(() => _isSavingWage = false);
      }
    }
  }

  Future<void> _calculatePayroll(String restaurantId) async {
    setState(() {
      _isCalculating = true;
      _payrollError = null;
    });

    try {
      final payrolls = await payrollService.calculatePayroll(
        restaurantId: restaurantId,
        periodStart: _payrollFrom,
        periodEnd: _payrollTo,
      );

      if (!mounted) return;
      setState(() {
        _payrolls = payrolls;
      });

      await payrollService.savePayrollCache(
        restaurantId: restaurantId,
        periodStart: _payrollFrom,
        periodEnd: _payrollTo,
        payrolls: payrolls,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _payrollError = '급여 계산 실패: $e';
      });
      showErrorToast(context, '급여 계산 실패');
    } finally {
      if (mounted) {
        setState(() => _isCalculating = false);
      }
    }
  }

  Future<void> _exportPayroll() async {
    if (_payrolls.isEmpty) return;
    setState(() => _isExporting = true);

    try {
      final bytes = await payrollService.exportToExcel(
        payrolls: _payrolls,
        periodStart: _payrollFrom,
        periodEnd: _payrollTo,
      );

      final now = DateTime.now();
      final fileName =
          'globos_payroll_${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

      await FileSaver.instance.saveFile(
        name: fileName,
        bytes: Uint8List.fromList(bytes),
        ext: 'xlsx',
        mimeType: MimeType.microsoftExcel,
      );

      if (!mounted) return;
      showSuccessToast(context, '엑셀 파일 저장 완료');
    } catch (e) {
      if (!mounted) return;
      showErrorToast(context, '엑셀 저장 실패: $e');
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final restaurantId = auth.restaurantId;

    if (restaurantId != null && _initializedRestaurantId != restaurantId) {
      _initializedRestaurantId = restaurantId;
      Future.microtask(() => _initialize(restaurantId));
    }

    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: Column(
        children: [
          Container(
            color: AppColors.surface0,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: TabBar(
              controller: _tabController,
              indicatorColor: AppColors.amber500,
              labelColor: AppColors.amber500,
              unselectedLabelColor: AppColors.textSecondary,
              labelStyle: GoogleFonts.notoSansKr(fontWeight: FontWeight.w700),
              tabs: const [
                Tab(text: '근태 기록'),
                Tab(text: '급여 관리'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildLogsTab(restaurantId),
                _buildPayrollTab(restaurantId),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogsTab(String? restaurantId) {
    final filteredLogs = _logs.where((row) {
      if (_selectedStaffFilter == 'all') return true;
      return row['user_id']?.toString() == _selectedStaffFilter;
    }).toList();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
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
                    lastDate: DateTime.now(),
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
                    lastDate: DateTime.now(),
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
                    const DropdownMenuItem(value: 'all', child: Text('전체')),
                    ..._staffList.map(
                      (s) => DropdownMenuItem(
                        value: s['id']?.toString() ?? '',
                        child: Text(s['full_name']?.toString() ?? '-'),
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
                onPressed: restaurantId == null
                    ? null
                    : () => _reloadLogs(restaurantId),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                child: const Text('적용'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_logsError != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _logsError!,
                style: GoogleFonts.notoSansKr(
                  color: AppColors.statusCancelled,
                  fontSize: 13,
                ),
              ),
            ),
          if (_logsError != null) const SizedBox(height: 10),
          Expanded(
            child: _isLogsLoading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.amber500),
                  )
                : filteredLogs.isEmpty
                ? Center(
                    child: Text(
                      'No data for selected period',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  )
                : _buildLogsTable(filteredLogs),
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
                final dateTime = DateTime.tryParse(
                  row['logged_at']?.toString() ?? '',
                );
                final user = row['users'];
                final userName = user is Map<String, dynamic>
                    ? user['full_name']?.toString() ?? '-'
                    : '-';
                final type = row['type']?.toString() == 'clock_in'
                    ? '출근'
                    : '퇴근';
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
          _headerCell('날짜', flex: 3),
          _headerCell('직원', flex: 3),
          _headerCell('유형', flex: 2),
          _headerCell('시간', flex: 2),
          _headerCell('사진', flex: 2),
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

  Widget _buildPayrollTab(String? restaurantId) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '급여 설정',
            style: GoogleFonts.bebasNeue(
              color: AppColors.textPrimary,
              fontSize: 28,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surface1,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _wageStaffId,
                  dropdownColor: AppColors.surface1,
                  style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                  decoration: const InputDecoration(labelText: '직원 선택'),
                  items: _staffList
                      .map(
                        (s) => DropdownMenuItem(
                          value: s['id']?.toString(),
                          child: Text(s['full_name']?.toString() ?? '-'),
                        ),
                      )
                      .toList(),
                  onChanged: restaurantId == null
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() => _wageStaffId = value);
                          _loadWageConfig(restaurantId, value);
                        },
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment<String>(
                        value: 'hourly',
                        label: Text('시급제'),
                      ),
                      ButtonSegment<String>(
                        value: 'shift',
                        label: Text('시프트제'),
                      ),
                    ],
                    selected: {_wageType},
                    style: ButtonStyle(
                      foregroundColor: WidgetStateProperty.resolveWith((
                        states,
                      ) {
                        if (states.contains(WidgetState.selected)) {
                          return AppColors.amber500;
                        }
                        return AppColors.textPrimary;
                      }),
                      backgroundColor: WidgetStateProperty.resolveWith((
                        states,
                      ) {
                        if (states.contains(WidgetState.selected)) {
                          return AppColors.amber500.withValues(alpha: 0.2);
                        }
                        return Colors.transparent;
                      }),
                      side: WidgetStateProperty.all(
                        const BorderSide(color: AppColors.surface2),
                      ),
                    ),
                    onSelectionChanged: (selection) {
                      if (selection.isNotEmpty) {
                        setState(() => _wageType = selection.first);
                      }
                    },
                  ),
                ),
                if (_wageType == 'hourly')
                  TextField(
                    controller: _hourlyRateController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                    decoration: const InputDecoration(labelText: '시급 (VND)'),
                  )
                else
                  Column(
                    children: [
                      ..._shiftRows.asMap().entries.map((entry) {
                        final index = entry.key;
                        final row = entry.value;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () async {
                                    final picked = await showTimePicker(
                                      context: context,
                                      initialTime: row.start,
                                    );
                                    if (picked != null) {
                                      setState(() => row.start = picked);
                                    }
                                  },
                                  child: Text(_formatTime(row.start)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () async {
                                    final picked = await showTimePicker(
                                      context: context,
                                      initialTime: row.end,
                                    );
                                    if (picked != null) {
                                      setState(() => row.end = picked);
                                    }
                                  },
                                  child: Text(_formatTime(row.end)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: row.amountController,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  style: GoogleFonts.notoSansKr(
                                    color: AppColors.textPrimary,
                                  ),
                                  decoration: const InputDecoration(
                                    labelText: '금액',
                                  ),
                                ),
                              ),
                              IconButton(
                                onPressed: () {
                                  setState(() {
                                    final removed = _shiftRows.removeAt(index);
                                    removed.dispose();
                                  });
                                },
                                icon: const Icon(
                                  Icons.close,
                                  color: AppColors.statusCancelled,
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () {
                            setState(() {
                              _shiftRows.add(
                                _ShiftRowData(
                                  start: const TimeOfDay(hour: 9, minute: 0),
                                  end: const TimeOfDay(hour: 18, minute: 0),
                                ),
                              );
                            });
                          },
                          icon: const Icon(Icons.add),
                          label: const Text('시프트 추가'),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: (restaurantId == null || _isSavingWage)
                        ? null
                        : () => _saveWageConfig(restaurantId),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.amber500,
                      foregroundColor: AppColors.surface0,
                    ),
                    child: _isSavingWage
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('저장'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '급여 계산',
            style: GoogleFonts.bebasNeue(
              color: AppColors.textPrimary,
              fontSize: 28,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surface1,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    _DateButton(
                      label: 'From',
                      value: _payrollFrom,
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _payrollFrom,
                          firstDate: DateTime(2020),
                          lastDate: DateTime.now(),
                        );
                        if (picked != null) {
                          setState(() {
                            _payrollFrom = DateTime(
                              picked.year,
                              picked.month,
                              picked.day,
                            );
                          });
                        }
                      },
                    ),
                    const SizedBox(width: 10),
                    _DateButton(
                      label: 'To',
                      value: _payrollTo,
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _payrollTo,
                          firstDate: DateTime(2020),
                          lastDate: DateTime.now(),
                        );
                        if (picked != null) {
                          setState(() {
                            _payrollTo = DateTime(
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
                    FilledButton(
                      onPressed: (restaurantId == null || _isCalculating)
                          ? null
                          : () => _calculatePayroll(restaurantId),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.amber500,
                        foregroundColor: AppColors.surface0,
                      ),
                      child: _isCalculating
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('계산하기'),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: (_payrolls.isEmpty || _isExporting)
                          ? null
                          : _exportPayroll,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.amber500,
                        foregroundColor: AppColors.surface0,
                      ),
                      icon: const Icon(Icons.download),
                      label: _isExporting
                          ? const Text('저장 중...')
                          : const Text('엑셀 저장 📥'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_payrollError != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _payrollError!,
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.statusCancelled,
                        fontSize: 13,
                      ),
                    ),
                  ),
                if (_payrollError != null) const SizedBox(height: 10),
                _buildPayrollResultTable(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPayrollResultTable() {
    if (_isCalculating) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: CircularProgressIndicator(color: AppColors.amber500),
      );
    }

    if (_payrolls.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          '계산 결과가 없습니다.',
          style: GoogleFonts.notoSansKr(
            color: AppColors.textSecondary,
            fontSize: 13,
          ),
        ),
      );
    }

    final children = <Widget>[
      _buildPayrollHeaderRow(),
      const Divider(height: 1, color: AppColors.surface2),
    ];

    double grandHours = 0;
    double grandAmount = 0;

    for (final payroll in _payrolls) {
      for (final row in payroll.dailyRecords) {
        grandHours += row.hours;
        grandAmount += row.amount;
        children.add(
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                _payrollCell(
                  payroll.userName,
                  flex: 3,
                  color: AppColors.textPrimary,
                ),
                _payrollCell(
                  DateFormat('yyyy-MM-dd').format(row.date),
                  flex: 2,
                  color: AppColors.textPrimary,
                ),
                _payrollCell(
                  row.clockIn == null
                      ? '-'
                      : DateFormat('HH:mm').format(row.clockIn!),
                  flex: 2,
                  color: row.isUnpaired
                      ? AppColors.statusCancelled
                      : AppColors.textPrimary,
                ),
                _payrollCell(
                  row.clockOut == null
                      ? '-'
                      : DateFormat('HH:mm').format(row.clockOut!),
                  flex: 2,
                  color: row.isUnpaired
                      ? AppColors.statusCancelled
                      : AppColors.textPrimary,
                ),
                _payrollCell(
                  row.hours.toStringAsFixed(2),
                  flex: 2,
                  color: row.isUnpaired
                      ? AppColors.statusCancelled
                      : AppColors.textPrimary,
                ),
                _payrollCell(
                  _currencyFormat.format(row.amount),
                  flex: 2,
                  color: row.isUnpaired
                      ? AppColors.statusCancelled
                      : AppColors.textPrimary,
                ),
              ],
            ),
          ),
        );
      }

      children.add(
        Container(
          color: AppColors.surface2,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              _payrollCell(
                '${payroll.userName} 소계',
                flex: 7,
                color: AppColors.textPrimary,
                bold: true,
              ),
              _payrollCell(
                payroll.totalHours.toStringAsFixed(2),
                flex: 2,
                color: AppColors.textPrimary,
                bold: true,
              ),
              _payrollCell(
                _currencyFormat.format(payroll.totalAmount),
                flex: 2,
                color: AppColors.textPrimary,
                bold: true,
              ),
            ],
          ),
        ),
      );
    }

    children.add(
      Container(
        color: AppColors.amber500.withValues(alpha: 0.2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Row(
          children: [
            _payrollCell('합계', flex: 7, color: AppColors.amber500, bold: true),
            _payrollCell(
              grandHours.toStringAsFixed(2),
              flex: 2,
              color: AppColors.amber500,
              bold: true,
            ),
            _payrollCell(
              _currencyFormat.format(grandAmount),
              flex: 2,
              color: AppColors.amber500,
              bold: true,
            ),
          ],
        ),
      ),
    );

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.surface2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(children: children),
    );
  }

  Widget _buildPayrollHeaderRow() {
    return Container(
      color: AppColors.surface2,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      child: Row(
        children: [
          _payrollCell(
            '직원명',
            flex: 3,
            color: AppColors.textSecondary,
            bold: true,
          ),
          _payrollCell(
            '날짜',
            flex: 2,
            color: AppColors.textSecondary,
            bold: true,
          ),
          _payrollCell(
            '출근',
            flex: 2,
            color: AppColors.textSecondary,
            bold: true,
          ),
          _payrollCell(
            '퇴근',
            flex: 2,
            color: AppColors.textSecondary,
            bold: true,
          ),
          _payrollCell(
            '근무시간',
            flex: 2,
            color: AppColors.textSecondary,
            bold: true,
          ),
          _payrollCell(
            '금액(VND)',
            flex: 2,
            color: AppColors.textSecondary,
            bold: true,
          ),
        ],
      ),
    );
  }

  Widget _payrollCell(
    String text, {
    required int flex,
    required Color color,
    bool bold = false,
  }) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        style: GoogleFonts.notoSansKr(
          color: color,
          fontSize: 12,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }

  static TimeOfDay _parseTime(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return const TimeOfDay(hour: 9, minute: 0);
    return TimeOfDay(
      hour: int.tryParse(parts[0]) ?? 9,
      minute: int.tryParse(parts[1]) ?? 0,
    );
  }

  static String _formatTime(TimeOfDay time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
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
      icon: const Icon(Icons.event),
      label: Text('$label ${DateFormat('yyyy-MM-dd').format(value)}'),
    );
  }
}

class _ShiftRowData {
  _ShiftRowData({required this.start, required this.end, String amount = ''})
    : amountController = TextEditingController(text: amount);

  TimeOfDay start;
  TimeOfDay end;
  final TextEditingController amountController;

  void dispose() {
    amountController.dispose();
  }
}
