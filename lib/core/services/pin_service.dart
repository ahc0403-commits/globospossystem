import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../main.dart';

class PinService {
  String hashPin(String pin) {
    final bytes = utf8.encode(pin);
    return sha256.convert(bytes).toString();
  }

  Future<String?> fetchPinHash(String storeId) async {
    try {
      final r = await supabase
          .from('restaurant_settings')
          .select('payroll_pin')
          .eq('restaurant_id', storeId)
          .maybeSingle();
      return r?['payroll_pin'] as String?;
    } catch (_) {
      return null;
    }
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
    final stored = await fetchPinHash(storeId);
    if (stored == null) return true;
    return hashPin(enteredPin) == stored;
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
