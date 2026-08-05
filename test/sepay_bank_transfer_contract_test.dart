import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/bank_transfer_alert_service.dart';

void main() {
  test('SePay alert model parses PostgREST number representations', () {
    final alert = BankTransferAlert.fromJson({
      'transaction_id': '3431af72-2e82-46f0-abcd-499613b874bb',
      'provider_transaction_id': '92704',
      'amount': 350000.0,
      'payment_code': 'GBA1B2C3D4',
      'gateway': 'Vietcombank',
      'transaction_at': '2026-08-05T10:00:00Z',
      'received_at': '2026-08-05T10:00:01Z',
    });

    expect(alert.providerTransactionId, 92704);
    expect(alert.amount, 350000);
    expect(alert.paymentCode, 'GBA1B2C3D4');
  });

  test('SePay SQL keeps raw payload private and emits store-scoped events', () {
    final sql = File(
      'supabase/migrations/20260805120000_sepay_bank_transfer_alerts.sql',
    ).readAsStringSync();

    expect(sql, contains('REVOKE ALL ON public.sepay_transactions'));
    expect(sql, contains('p_raw_payload jsonb'));
    expect(sql, contains("emit_pos_live_event('bank_transfer')"));
    expect(sql, contains('WHEN (NEW.restaurant_id IS NOT NULL'));
    expect(sql, contains('ON CONFLICT (sepay_transaction_id) DO NOTHING'));
  });

  test('production deploy exposes only the HMAC-protected SePay endpoint', () {
    final deploy = File('scripts/deploy_pos_production.sh').readAsStringSync();
    expect(deploy, contains('functions deploy sepay-webhook --no-verify-jwt'));

    final edge = File(
      'supabase/functions/sepay-webhook/index.ts',
    ).readAsStringSync();
    expect(edge, contains('x-sepay-signature'));
    expect(edge, contains('x-sepay-timestamp'));
    expect(edge, contains('SEPAY_SIGNATURE_INVALID'));
    expect(edge, contains('return json({ success: true })'));
  });
}
