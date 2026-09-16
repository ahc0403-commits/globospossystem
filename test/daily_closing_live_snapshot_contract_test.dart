import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260916170000_daily_closing_live_snapshot_reconciliation.sql';

  test(
    'daily close separates live ledger, snapshot, and reconciliation delta',
    () {
      final sql = File(migrationPath).readAsStringSync();

      expect(sql, contains('-- production-gate: self-verifying'));
      expect(sql, contains('payments_bank_transfer numeric(15,2)'));
      expect(sql, contains('snapshot_payments_total numeric'));
      expect(sql, contains('ledger_payments_total numeric'));
      expect(sql, contains('reconciliation_delta numeric'));
      expect(sql, contains('ledger_as_of timestamptz'));
      expect(sql, contains("closing.close_source = 'manual'"));
      expect(
        sql,
        contains('COALESCE(ledger.payments_total, 0) - closing.payments_total'),
      );
      expect(sql, contains("lower(method) = 'banktransfer'"));
      expect(
        sql,
        contains("'cash', 'card', 'creditcard', 'atm', 'banktransfer'"),
      );
      expect(sql, contains('FROM PUBLIC, anon'));
      expect(sql, contains('TO authenticated, service_role'));
    },
  );
}
