import '../../main.dart';

class StaffService {
  Future<Map<String, dynamic>> createStaffUser({
    required String email,
    required String password,
    required String fullName,
    required String role,
    required String storeId,
  }) async {
    final response = await supabase.functions.invoke(
      'create_staff_user',
      body: {
        'email': email,
        'password': password,
        'full_name': fullName,
        'role': role,
        'store_id': storeId,
      },
    );
    if (response.status != 200) {
      final errorData = response.data;
      final errorMsg = errorData is Map
          ? errorData['error'] ?? 'Failed to create staff'
          : 'Failed to create staff';
      throw Exception(errorMsg.toString());
    }
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<void> updateMyFullName(String fullName) async {
    await supabase.rpc(
      'update_my_profile_full_name',
      params: {'p_full_name': fullName},
    );
  }

  Future<void> adminUpdateStaffAccount({
    required String userId,
    required String storeId,
    String? fullName,
    bool? isActive,
    List<String>? extraPermissions,
  }) async {
    await supabase.rpc(
      'admin_update_staff_account',
      params: {
        'p_user_id': userId,
        'p_store_id': storeId,
        'p_full_name': fullName,
        'p_is_active': isActive,
        'p_extra_permissions': extraPermissions,
      },
    );
  }
}

final staffService = StaffService();
