import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('Windows cashier keeps the native print agent running', () {
    final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');
    final platform = readRepoFile('lib/core/layout/platform_info.dart');

    expect(platform, contains('static bool get isWindows'));
    expect(cashier, contains('PlatformInfo.isWindows'));
    expect(cashier, contains('_printJobAgent.startPolling(storeId)'));
    expect(cashier, contains('_printJobAgent.stop()'));
  });

  test('cashier role can claim store-scoped print jobs', () {
    final migration = readRepoFile(
      'supabase/migrations/20260722080000_cashier_native_print_agent.sql',
    );
    final deployGate = readRepoFile('scripts/deploy_pos_production.sh');
    final verification = readRepoFile(
      'scripts/verify_cashier_native_print_agent.sql',
    );

    expect(migration, contains("'cashier'"));
    expect(migration, contains('public.user_accessible_stores(auth.uid())'));
    expect(migration, contains('public.print_routing_actor_can_run'));
    expect(
      deployGate,
      contains('20260722080000_cashier_native_print_agent.sql'),
    );
    expect(
      verification,
      contains('CASHIER_PRINT_AGENT_VERIFY_STORE_SCOPE_INCOMPLETE'),
    );
  });

  test('cashier payment stays in place and opens completion dialog', () {
    final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');
    final dialog = readRepoFile(
      'lib/features/cashier/payment_completion_dialog.dart',
    );

    expect(cashier, contains('_showPaymentCompletion('));
    expect(cashier, isNot(contains("context.go('/payments/")));
    expect(dialog, contains("Key('cashier_payment_completion_dialog')"));
  });

  test('cashier idle detail shows the full table overview', () {
    final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');

    expect(cashier, contains('class _CashierTableOverview'));
    expect(cashier, contains('FloorLayoutView('));
    expect(cashier, contains("Key('cashier_all_tables_overview')"));
  });
}
