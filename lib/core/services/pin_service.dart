import '../../main.dart';

class PinService {
  Future<bool> hasPin(String storeId) async {
    final result = await supabase.rpc(
      'get_payroll_pin_status',
      params: {'p_store_id': storeId},
    );
    final status = Map<String, dynamic>.from(result as Map);
    return status['has_pin'] == true;
  }

  Future<bool> verifyPin(String storeId, String enteredPin) async {
    final result = await supabase.rpc(
      'verify_payroll_pin',
      params: {'p_store_id': storeId, 'p_pin': enteredPin},
    );
    return result == true;
  }

  Future<void> setPin(String storeId, String pin) async {
    await supabase.rpc(
      'set_payroll_pin_v2',
      params: {'p_store_id': storeId, 'p_pin': pin},
    );
  }

  Future<void> clearPin(String storeId) async {
    await supabase.rpc('clear_payroll_pin_v2', params: {'p_store_id': storeId});
  }
}

final pinService = PinService();
