import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'payment refund/void uses append-only adjustments and Office event feed',
    () {
      final migration = readRepoFile(
        'supabase/migrations/20260604001000_pos_payment_refund_void_adjustments.sql',
      );
      final service = readRepoFile('lib/core/services/payment_service.dart');
      final screen = readRepoFile(
        'lib/features/payment/payment_detail_screen.dart',
      );

      expect(
        migration,
        contains('create table if not exists public.payment_adjustments'),
      );
      expect(
        migration,
        contains("check (adjustment_type in ('refund', 'void'))"),
      );
      expect(migration, contains('check (amount > 0)'));
      expect(migration, contains('PAYMENT_ADJUSTMENTS_IMMUTABLE'));
      expect(migration, contains('from public.payments'));
      expect(migration, contains('for update'));
      expect(migration, contains('PAYMENT_REFUND_EXCEEDS_REMAINING_AMOUNT'));
      expect(migration, contains('PAYMENT_VOID_AFTER_REFUND_NOT_ALLOWED'));
      expect(migration, contains('PAYMENT_VOID_AMOUNT_MUST_MATCH_PAYMENT'));
      expect(
        migration,
        contains("'payment_adjustments'::text as source_table"),
      );
      expect(migration, contains('pa.adjustment_type as event_type'));
      expect(
        migration,
        contains('(-pa.amount)::numeric(15,2) as signed_amount'),
      );
      expect(
        migration,
        contains('wetax_action_required'),
        reason: 'WeTax follow-up is flagged without pretending to cancel it.',
      );
      expect(
        migration,
        isNot(contains('update public.payments')),
        reason: 'The original positive payment ledger must not be rewritten.',
      );
      expect(
        migration,
        isNot(contains('update public.orders')),
        reason: 'Completed order history must not be rewritten by refund/void.',
      );

      expect(service, contains(".from('payment_adjustments')"));
      expect(service, contains("'record_payment_adjustment'"));
      expect(service, contains('result is List'));
      expect(screen, contains("Key('payment_detail_refund_payment')"));
      expect(screen, contains("Key('payment_detail_void_payment')"));
    },
  );
}
