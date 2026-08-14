import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../main.dart';

class PinService {
  String hashPin(String pin) {
    final bytes = utf8.encode(pin);
    return sha256.convert(bytes).toString();
  }

  Future<bool> hasPayrollPin(String storeId) async {
    final result = await supabase.rpc(
      'has_payroll_pin',
      params: {'p_store_id': storeId},
    );
    return result == true;
  }

  Future<bool> hasDiscountManagerPin(String storeId) async {
    try {
      final result = await supabase.rpc(
        'has_discount_manager_pin',
        params: {'p_store_id': storeId},
      );
      return result == true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> verifyPin(String storeId, String enteredPin) async {
    final result = await supabase.rpc(
      'verify_payroll_pin',
      params: {'p_store_id': storeId, 'p_payroll_pin': hashPin(enteredPin)},
    );
    return result == true;
  }

  Future<void> setPin(String storeId, String pin) async {
    await supabase.rpc(
      'set_payroll_pin',
      params: {'p_store_id': storeId, 'p_payroll_pin': hashPin(pin)},
    );
  }

  Future<void> clearPin(String storeId) async {
    await supabase.rpc('clear_payroll_pin', params: {'p_store_id': storeId});
  }

  Future<void> setDiscountManagerPin(String storeId, String pin) async {
    await supabase.rpc(
      'set_discount_manager_pin',
      params: {'p_store_id': storeId, 'p_pin': pin},
    );
  }

  Future<void> clearDiscountManagerPin(String storeId) async {
    await supabase.rpc(
      'clear_discount_manager_pin',
      params: {'p_store_id': storeId},
    );
  }
}

final pinService = PinService();
