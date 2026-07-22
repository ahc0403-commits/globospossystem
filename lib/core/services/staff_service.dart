import '../../main.dart';

class StaffService {
  Future<void> updateMyFullName(String fullName) async {
    await supabase.rpc(
      'update_my_profile_full_name',
      params: {'p_full_name': fullName},
    );
  }

  Future<List<Map<String, dynamic>>> fetchStoreEmployees(String storeId) async {
    final response = await supabase
        .from('store_employees')
        .select('*, employee_hourly_pay_rules(*)')
        .eq('store_id', storeId)
        .order('created_at');
    return List<Map<String, dynamic>>.from(response);
  }

  Future<Map<String, dynamic>> createStoreEmployee({
    required String fullName,
    required String employmentRole,
    required String storeId,
    String? phone,
    String? bankName,
    String? bankAccountNumber,
    String? bankAccountHolder,
  }) async {
    final response = await supabase.rpc(
      'create_store_employee',
      params: {
        'p_store_id': storeId,
        'p_full_name': fullName,
        'p_employment_role': employmentRole,
        'p_phone': phone,
        'p_bank_name': bankName,
        'p_bank_account_number': bankAccountNumber,
        'p_bank_account_holder': bankAccountHolder,
      },
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<Map<String, dynamic>> updateStoreEmployee({
    required String employeeId,
    required String storeId,
    required String fullName,
    required String employmentRole,
    String? phone,
    String? bankName,
    String? bankAccountNumber,
    String? bankAccountHolder,
  }) async {
    final response = await supabase.rpc(
      'update_store_employee',
      params: {
        'p_store_id': storeId,
        'p_employee_id': employeeId,
        'p_full_name': fullName,
        'p_employment_role': employmentRole,
        'p_phone': phone,
        'p_bank_name': bankName,
        'p_bank_account_number': bankAccountNumber,
        'p_bank_account_holder': bankAccountHolder,
      },
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<Map<String, dynamic>> createStorePartTimerWithPayRule({
    required String fullName,
    required String storeId,
    required double hourlyRate,
    required String scheduledStart,
    required String nightStart,
    required double nightMultiplier,
    required double holidayMultiplier,
    required int lateThresholdMinutes,
    required double lateReviewHourlyMultiplier,
    String? phone,
    String? bankName,
    String? bankAccountNumber,
    String? bankAccountHolder,
  }) async {
    final response = await supabase.rpc(
      'create_store_part_timer_with_pay_rule',
      params: {
        'p_store_id': storeId,
        'p_full_name': fullName,
        'p_phone': phone,
        'p_bank_name': bankName,
        'p_bank_account_number': bankAccountNumber,
        'p_bank_account_holder': bankAccountHolder,
        'p_hourly_rate': hourlyRate,
        'p_scheduled_start': scheduledStart,
        'p_night_start': nightStart,
        'p_night_multiplier': nightMultiplier,
        'p_holiday_multiplier': holidayMultiplier,
        'p_late_threshold_minutes': lateThresholdMinutes,
        'p_late_review_hourly_multiplier': lateReviewHourlyMultiplier,
      },
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<Map<String, dynamic>> deactivateStoreEmployee({
    required String employeeId,
    required String storeId,
  }) async {
    final response = await supabase.rpc(
      'deactivate_store_employee',
      params: {'p_store_id': storeId, 'p_employee_id': employeeId},
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<Map<String, dynamic>> upsertHourlyPayRule({
    required String employeeId,
    required String storeId,
    required double hourlyRate,
    required String scheduledStart,
    required String nightStart,
    required double nightMultiplier,
    required double holidayMultiplier,
    required int lateThresholdMinutes,
    required double lateReviewHourlyMultiplier,
  }) async {
    final response = await supabase.rpc(
      'upsert_employee_hourly_pay_rule',
      params: {
        'p_store_id': storeId,
        'p_employee_id': employeeId,
        'p_hourly_rate': hourlyRate,
        'p_scheduled_start': scheduledStart,
        'p_night_start': nightStart,
        'p_night_multiplier': nightMultiplier,
        'p_holiday_multiplier': holidayMultiplier,
        'p_exclude_sunday': true,
        'p_late_threshold_minutes': lateThresholdMinutes,
        'p_late_review_hourly_multiplier': lateReviewHourlyMultiplier,
      },
    );
    return Map<String, dynamic>.from(response as Map);
  }
}

final staffService = StaffService();
