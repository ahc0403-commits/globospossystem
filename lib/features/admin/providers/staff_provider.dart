import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../main.dart';

class StaffMember {
  const StaffMember({
    required this.id,
    required this.authId,
    required this.fullName,
    required this.role,
    required this.isActive,
    required this.createdAt,
    this.email,
  });

  final String id;
  final String authId;
  final String fullName;
  final String role;
  final bool isActive;
  final DateTime createdAt;
  final String? email;

  factory StaffMember.fromJson(Map<String, dynamic> json) {
    final createdAtRaw = json['created_at']?.toString();
    return StaffMember(
      id: json['id'].toString(),
      authId: json['auth_id']?.toString() ?? '',
      fullName: json['full_name']?.toString() ?? 'Unknown',
      role: json['role']?.toString() ?? 'waiter',
      isActive: json['is_active'] == true,
      createdAt: createdAtRaw != null
          ? DateTime.tryParse(createdAtRaw) ?? DateTime.now()
          : DateTime.now(),
      email: json['email']?.toString(),
    );
  }
}

class StaffState {
  const StaffState({
    this.staff = const [],
    this.isLoading = false,
    this.isCreating = false,
    this.error,
  });

  final List<StaffMember> staff;
  final bool isLoading;
  final bool isCreating;
  final String? error;

  StaffState copyWith({
    List<StaffMember>? staff,
    bool? isLoading,
    bool? isCreating,
    String? error,
    bool clearError = false,
  }) {
    return StaffState(
      staff: staff ?? this.staff,
      isLoading: isLoading ?? this.isLoading,
      isCreating: isCreating ?? this.isCreating,
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

  Future<void> loadStaff(String restaurantId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final response = await supabase
          .from('users')
          .select()
          .eq('restaurant_id', restaurantId)
          .order('created_at', ascending: true);

      final staff = response
          .map<StaffMember>((row) => StaffMember.fromJson(Map<String, dynamic>.from(row)))
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
    required String restaurantId,
    required String email,
    required String password,
    required String fullName,
    required String role,
  }) async {
    state = state.copyWith(isCreating: true, clearError: true);
    try {
      final response = await supabase.functions.invoke(
        'create_staff_user',
        body: {
          'email': email,
          'password': password,
          'full_name': fullName,
          'role': role,
          'restaurant_id': restaurantId,
        },
      );

      if (response.status != 200) {
        final errorData = response.data;
        final errorMsg = errorData is Map
            ? errorData['error'] ?? 'Failed to create staff'
            : 'Failed to create staff';
        state = state.copyWith(isCreating: false, error: errorMsg.toString());
        return;
      }

      state = state.copyWith(isCreating: false, clearError: true);
      await loadStaff(restaurantId);
    } catch (error) {
      state = state.copyWith(
        isCreating: false,
        error: 'Failed to create staff: $error',
      );
    }
  }

  Future<void> toggleActive(String userId, bool isActive, String restaurantId) async {
    try {
      await supabase.from('users').update({'is_active': isActive}).eq('id', userId);
      await loadStaff(restaurantId);
    } catch (error) {
      state = state.copyWith(error: 'Failed to update staff status: $error');
    }
  }
}

class AttendanceNotifier extends StateNotifier<AttendanceState> {
  AttendanceNotifier() : super(const AttendanceState());

  Future<void> loadLogs(String restaurantId, {DateTime? date}) async {
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
          .select('id, user_id, type, logged_at, users(full_name, role)')
          .eq('restaurant_id', restaurantId)
          .gte('logged_at', dayStart.toIso8601String())
          .lt('logged_at', dayEnd.toIso8601String())
          .order('logged_at', ascending: false)
          .limit(50);

      final logs = response.map<AttendanceRecord>((row) {
        final data = Map<String, dynamic>.from(row);
        final userRaw = data['users'];
        String userName = 'Unknown';
        String? role;
        if (userRaw is Map<String, dynamic>) {
          userName = userRaw['full_name']?.toString() ?? 'Unknown';
          role = userRaw['role']?.toString();
        }

        final loggedAtRaw = data['logged_at']?.toString();
        return AttendanceRecord(
          id: data['id'].toString(),
          userId: data['user_id']?.toString() ?? '',
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
