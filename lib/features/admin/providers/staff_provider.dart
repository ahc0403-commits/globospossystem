import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/staff_service.dart';
import '../../../main.dart';

class HourlyPayRule {
  const HourlyPayRule({
    required this.hourlyRate,
    required this.scheduledStart,
    required this.nightStart,
    required this.nightMultiplier,
    required this.holidayMultiplier,
    required this.lateThresholdMinutes,
    required this.lateReviewHourlyMultiplier,
  });

  final double hourlyRate;
  final String scheduledStart;
  final String nightStart;
  final double nightMultiplier;
  final double holidayMultiplier;
  final int lateThresholdMinutes;
  final double lateReviewHourlyMultiplier;

  factory HourlyPayRule.fromJson(Map<String, dynamic> json) => HourlyPayRule(
    hourlyRate: double.tryParse('${json['hourly_rate'] ?? 0}') ?? 0,
    scheduledStart: _clockText(json['scheduled_start'], '09:00'),
    nightStart: _clockText(json['night_start'], '22:00'),
    nightMultiplier:
        double.tryParse('${json['night_multiplier'] ?? 1.3}') ?? 1.3,
    holidayMultiplier:
        double.tryParse('${json['holiday_multiplier'] ?? 3}') ?? 3,
    lateThresholdMinutes:
        int.tryParse('${json['late_threshold_minutes'] ?? 60}') ?? 60,
    lateReviewHourlyMultiplier:
        double.tryParse('${json['late_review_hourly_multiplier'] ?? 2}') ?? 2,
  );

  static String _clockText(Object? value, String fallback) {
    final raw = value?.toString() ?? '';
    return raw.length >= 5 ? raw.substring(0, 5) : fallback;
  }
}

class StaffMember {
  const StaffMember({
    required this.id,
    required this.employeeNumber,
    required this.fullName,
    required this.role,
    required this.isActive,
    required this.createdAt,
    this.phone,
    this.bankName,
    this.bankAccountNumber,
    this.bankAccountHolder,
    this.hourlyPayRule,
  });

  final String id;
  final String employeeNumber;
  final String fullName;
  final String role;
  final bool isActive;
  final DateTime createdAt;
  final String? phone;
  final String? bankName;
  final String? bankAccountNumber;
  final String? bankAccountHolder;
  final HourlyPayRule? hourlyPayRule;

  factory StaffMember.fromJson(Map<String, dynamic> json) {
    final createdAtRaw = json['created_at']?.toString();
    final ruleRaw = json['employee_hourly_pay_rules'];
    final rule = ruleRaw is Map
        ? Map<String, dynamic>.from(ruleRaw)
        : ruleRaw is List && ruleRaw.isNotEmpty && ruleRaw.first is Map
        ? Map<String, dynamic>.from(ruleRaw.first as Map)
        : null;
    return StaffMember(
      id: json['id'].toString(),
      employeeNumber: json['employee_number']?.toString() ?? '',
      fullName: json['full_name']?.toString() ?? 'Unknown',
      role: json['employment_role']?.toString() ?? 'part_timer',
      isActive: json['is_active'] == true,
      createdAt: createdAtRaw != null
          ? DateTime.tryParse(createdAtRaw) ?? DateTime.now()
          : DateTime.now(),
      phone: json['phone']?.toString(),
      bankName: json['bank_name']?.toString(),
      bankAccountNumber: json['bank_account_number']?.toString(),
      bankAccountHolder: json['bank_account_holder']?.toString(),
      hourlyPayRule: rule == null ? null : HourlyPayRule.fromJson(rule),
    );
  }
}

class StaffState {
  const StaffState({
    this.staff = const [],
    this.isLoading = false,
    this.isCreating = false,
    this.lastCreatedEmployee,
    this.error,
  });

  final List<StaffMember> staff;
  final bool isLoading;
  final bool isCreating;
  final StaffMember? lastCreatedEmployee;
  final String? error;

  StaffState copyWith({
    List<StaffMember>? staff,
    bool? isLoading,
    bool? isCreating,
    StaffMember? lastCreatedEmployee,
    String? error,
    bool clearError = false,
    bool clearLastCreated = false,
  }) {
    return StaffState(
      staff: staff ?? this.staff,
      isLoading: isLoading ?? this.isLoading,
      isCreating: isCreating ?? this.isCreating,
      lastCreatedEmployee: clearLastCreated
          ? null
          : (lastCreatedEmployee ?? this.lastCreatedEmployee),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class AttendanceRecord {
  const AttendanceRecord({
    required this.id,
    required this.userId,
    required this.userName,
    required this.type,
    required this.loggedAt,
    this.userRole,
  });

  final String id;
  final String userId;
  final String userName;
  final String type;
  final DateTime loggedAt;
  final String? userRole;
}

class AttendanceState {
  const AttendanceState({
    this.logs = const [],
    this.isLoading = false,
    this.selectedDate,
    this.error,
  });

  final List<AttendanceRecord> logs;
  final bool isLoading;
  final DateTime? selectedDate;
  final String? error;

  AttendanceState copyWith({
    List<AttendanceRecord>? logs,
    bool? isLoading,
    DateTime? selectedDate,
    String? error,
    bool clearError = false,
  }) {
    return AttendanceState(
      logs: logs ?? this.logs,
      isLoading: isLoading ?? this.isLoading,
      selectedDate: selectedDate ?? this.selectedDate,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class StaffNotifier extends StateNotifier<StaffState> {
  StaffNotifier() : super(const StaffState());

  Future<void> loadStaff(String storeId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final response = await staffService.fetchStoreEmployees(storeId);

      final staff = response
          .map<StaffMember>(
            (row) => StaffMember.fromJson(Map<String, dynamic>.from(row)),
          )
          .toList();

      state = state.copyWith(staff: staff, isLoading: false, clearError: true);
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load staff: $error',
      );
    }
  }

  Future<void> createStaff({
    required String storeId,
    required String fullName,
    required String role,
    String? phone,
    String? bankName,
    String? bankAccountNumber,
    String? bankAccountHolder,
    double? hourlyRate,
    String scheduledStart = '09:00',
    String nightStart = '22:00',
    double nightMultiplier = 1.3,
    double holidayMultiplier = 3,
    int lateThresholdMinutes = 60,
    double lateReviewHourlyMultiplier = 2,
  }) async {
    state = state.copyWith(
      isCreating: true,
      clearError: true,
      clearLastCreated: true,
    );
    try {
      final created = role == 'part_timer' && hourlyRate != null
          ? await staffService.createStorePartTimerWithPayRule(
              fullName: fullName,
              storeId: storeId,
              phone: phone,
              bankName: bankName,
              bankAccountNumber: bankAccountNumber,
              bankAccountHolder: bankAccountHolder,
              hourlyRate: hourlyRate,
              scheduledStart: scheduledStart,
              nightStart: nightStart,
              nightMultiplier: nightMultiplier,
              holidayMultiplier: holidayMultiplier,
              lateThresholdMinutes: lateThresholdMinutes,
              lateReviewHourlyMultiplier: lateReviewHourlyMultiplier,
            )
          : await staffService.createStoreEmployee(
              fullName: fullName,
              employmentRole: role,
              storeId: storeId,
              phone: phone,
              bankName: bankName,
              bankAccountNumber: bankAccountNumber,
              bankAccountHolder: bankAccountHolder,
            );

      state = state.copyWith(
        isCreating: false,
        lastCreatedEmployee: StaffMember.fromJson(created),
        clearError: true,
      );
      await loadStaff(storeId);
    } catch (error) {
      state = state.copyWith(isCreating: false, error: _cleanException(error));
    }
  }

  Future<void> updateStaff({
    required String employeeId,
    required String storeId,
    required String fullName,
    required String role,
    String? phone,
    String? bankName,
    String? bankAccountNumber,
    String? bankAccountHolder,
    double? hourlyRate,
    String scheduledStart = '09:00',
    String nightStart = '22:00',
    double nightMultiplier = 1.3,
    double holidayMultiplier = 3,
    int lateThresholdMinutes = 60,
    double lateReviewHourlyMultiplier = 2,
  }) async {
    try {
      await staffService.updateStoreEmployee(
        employeeId: employeeId,
        storeId: storeId,
        fullName: fullName,
        employmentRole: role,
        phone: phone,
        bankName: bankName,
        bankAccountNumber: bankAccountNumber,
        bankAccountHolder: bankAccountHolder,
      );
      if (role == 'part_timer' && hourlyRate != null) {
        await staffService.upsertHourlyPayRule(
          employeeId: employeeId,
          storeId: storeId,
          hourlyRate: hourlyRate,
          scheduledStart: scheduledStart,
          nightStart: nightStart,
          nightMultiplier: nightMultiplier,
          holidayMultiplier: holidayMultiplier,
          lateThresholdMinutes: lateThresholdMinutes,
          lateReviewHourlyMultiplier: lateReviewHourlyMultiplier,
        );
      }
      await loadStaff(storeId);
    } catch (error) {
      state = state.copyWith(error: _cleanException(error));
    }
  }

  Future<void> deactivateStaff({
    required String employeeId,
    required String storeId,
  }) async {
    try {
      await staffService.deactivateStoreEmployee(
        employeeId: employeeId,
        storeId: storeId,
      );
      await loadStaff(storeId);
    } catch (error) {
      state = state.copyWith(error: _cleanException(error));
    }
  }
}

class AttendanceNotifier extends StateNotifier<AttendanceState> {
  AttendanceNotifier() : super(const AttendanceState());

  Future<void> loadLogs(String storeId, {DateTime? date}) async {
    final selectedDate = date ?? state.selectedDate ?? DateTime.now();
    final dayStart = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
    );
    final dayEnd = dayStart.add(const Duration(days: 1));

    state = state.copyWith(
      isLoading: true,
      selectedDate: dayStart,
      clearError: true,
    );

    try {
      final response = await supabase
          .from('attendance_logs')
          .select(
            'id, employee_id, type, logged_at, '
            'store_employees(employee_number, full_name, employment_role)',
          )
          .eq('restaurant_id', storeId)
          .gte('logged_at', dayStart.toIso8601String())
          .lt('logged_at', dayEnd.toIso8601String())
          .order('logged_at', ascending: false)
          .limit(50);

      final logs = response.map<AttendanceRecord>((row) {
        final data = Map<String, dynamic>.from(row);
        final userRaw = data['store_employees'];
        String userName = 'Unknown';
        String? role;
        if (userRaw is Map<String, dynamic>) {
          userName = userRaw['full_name']?.toString() ?? 'Unknown';
          role = userRaw['employment_role']?.toString();
        }

        final loggedAtRaw = data['logged_at']?.toString();
        return AttendanceRecord(
          id: data['id'].toString(),
          userId: data['employee_id']?.toString() ?? '',
          userName: userName,
          type: data['type']?.toString() ?? '',
          loggedAt: loggedAtRaw != null
              ? DateTime.tryParse(loggedAtRaw) ?? DateTime.now()
              : DateTime.now(),
          userRole: role,
        );
      }).toList();

      state = state.copyWith(logs: logs, isLoading: false, clearError: true);
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load attendance logs: $error',
      );
    }
  }
}

final staffProvider = StateNotifierProvider<StaffNotifier, StaffState>(
  (ref) => StaffNotifier(),
);

final attendanceProvider =
    StateNotifierProvider<AttendanceNotifier, AttendanceState>(
      (ref) => AttendanceNotifier(),
    );

String _cleanException(Object error) {
  return error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '').trim();
}
