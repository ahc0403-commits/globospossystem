import '../../main.dart';

class StaffService {
  Future<Map<String, dynamic>> createStaffUser({
    required String email,
    required String password,
    required String fullName,
    required String role,
    required String restaurantId,
  }) async {
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
      throw Exception(errorMsg.toString());
    }
    return Map<String, dynamic>.from(response.data as Map);
  }
}

final staffService = StaffService();
