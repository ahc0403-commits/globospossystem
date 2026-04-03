import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../main.dart';

class PinService {
  String hashPin(String pin) {
    final bytes = utf8.encode(pin);
    return sha256.convert(bytes).toString();
  }

  Future<String?> fetchPinHash(String restaurantId) async {
    try {
      final r = await supabase
          .from('restaurant_settings')
          .select('payroll_pin')
          .eq('restaurant_id', restaurantId)
          .maybeSingle();
      return r?['payroll_pin'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<bool> verifyPin(String restaurantId, String enteredPin) async {
    final stored = await fetchPinHash(restaurantId);
    if (stored == null) return true;
    return hashPin(enteredPin) == stored;
  }

  Future<void> setPin(String restaurantId, String pin) async {
    await supabase.from('restaurant_settings').upsert({
      'restaurant_id': restaurantId,
      'payroll_pin': hashPin(pin),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'restaurant_id');
  }

  Future<void> clearPin(String restaurantId) async {
    await supabase.from('restaurant_settings').upsert({
      'restaurant_id': restaurantId,
      'payroll_pin': null,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'restaurant_id');
  }
}

final pinService = PinService();
