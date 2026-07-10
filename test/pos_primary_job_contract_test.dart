import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'primary job audit gates are documented as the POS redesign contract',
    () {
      final contract = readRepoFile(
        'docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md',
      );
      final sequence = readRepoFile(
        'docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_IMPLEMENTATION_SEQUENCE.md',
      );
      final closure = readRepoFile(
        'docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PHASE5_CLOSURE_AUDIT.md',
      );

      for (final gate in const [
        'Primary Job Gate',
        'Supporting Actions Gate',
        'Separate Workflow Gate',
        'Secondary Detail Gate',
        'Role Boundary Gate',
        '3-Second Operator Gate',
        'Action Hierarchy Gate',
        'Workflow Safety Gate',
      ]) {
        expect(contract, contains(gate));
      }

      expect(contract, contains('Cashier Payment Execution Non-Split Rule'));
      expect(contract, contains('Payment method selection'));
      expect(contract, contains('Proof attachment'));
      expect(contract, contains('Guest-requested red invoice capture'));
      expect(sequence, contains('Phase 0-5 Closure Plan'));
      expect(sequence, contains('Do not split Cashier Payment Execution'));
      expect(
        sequence,
        contains('ONE_WORKFLOW_PER_SCREEN_POS_PHASE5_CLOSURE_AUDIT.md'),
      );
      expect(closure, contains('Phase 0 through Phase 5 are closed'));
      expect(closure, contains('Cashier Non-Split Confirmation'));
      expect(closure, contains('git diff --name-only -- supabase docs/vendor'));
      expect(closure, contains('flutter analyze'));
      expect(closure, contains('flutter test'));
    },
  );

  test('live POS surfaces enforce primary-job boundaries in source', () {
    final adminTables = readRepoFile('lib/features/admin/tabs/tables_tab.dart');
    final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');
    final kitchen = readRepoFile('lib/features/kitchen/kitchen_screen.dart');
    final orderWorkspace = readRepoFile('lib/widgets/order_workspace.dart');

    expect(adminTables, contains('_AdminTableOperationsPanel'));
    expect(adminTables, isNot(contains('OrderWorkspace(')));
    expect(adminTables, isNot(contains('onProcessPayment:')));
    expect(adminTables, isNot(contains('onCycleSentItemStatus:')));

    expect(cashier, contains('PaymentProofModal('));
    expect(cashier, contains('RedInvoiceModal('));
    expect(cashier, isNot(contains('_CashierTodaySummaryDialog')));
    expect(cashier, isNot(contains('cashierTodaySummaryProvider')));

    expect(kitchen, contains('class _KitchenTicketPreview'));
    expect(kitchen, contains('class _KitchenTicketItemRow'));
    expect(kitchen, contains('onPressed: isProcessing ? null : onItemAction'));
    expect(kitchen, isNot(contains('_handleOrderPrimaryAction')));
    expect(
      kitchen,
      isNot(contains("const Key('kitchen_start_cooking_button')")),
    );
    expect(kitchen, isNot(contains('PosPrimaryButton(')));
    expect(kitchen, isNot(contains('class _KitchenExecutionItemRow')));
    expect(kitchen, isNot(contains('_executionOpen')));

    expect(
      orderWorkspace,
      contains('order_sent_items_always_visible_detail'),
    );
    expect(orderWorkspace, isNot(contains('order_sent_items_secondary_detail')));
    expect(orderWorkspace, contains('initiallyExpanded: true'));
  });

  test(
    'manager diagnostic-heavy surfaces keep secondary detail disclosed on demand',
    () {
      final reports = readRepoFile('lib/features/admin/tabs/reports_tab.dart');
      final einvoice = readRepoFile(
        'lib/features/admin/tabs/einvoice_tab.dart',
      );
      final qc = readRepoFile('lib/features/admin/tabs/qc_tab.dart');
      final settings = readRepoFile(
        'lib/features/admin/tabs/settings_tab.dart',
      );
      final deliverySettlement = readRepoFile(
        'lib/features/delivery/screens/delivery_settlement_tab.dart',
      );
      final paymentDetail = readRepoFile(
        'lib/features/payment/payment_detail_screen.dart',
      );

      expect(reports, contains('class _ReportsOperationalSignalsDetail'));
      expect(
        reports,
        contains("key: const Key('reports_operational_signals_detail')"),
      );
      expect(reports, contains('initiallyExpanded: false'));

      expect(einvoice, contains("Key('einvoice_job_secondary_detail')"));
      expect(einvoice, contains('initiallyExpanded: false'));
      expect(einvoice, isNot(contains('PosStatCard(')));

      expect(qc, contains("Key('qc_analytics_secondary_detail')"));
      expect(qc, contains('initiallyExpanded: false'));
      expect(qc, isNot(contains('PosStatCard(')));

      expect(
        settings,
        contains("Key('settings_audit_trace_secondary_detail')"),
      );
      expect(settings, contains('initiallyExpanded: false'));
      expect(settings, isNot(contains('PosStatCard(')));

      expect(
        deliverySettlement,
        contains("Key('delivery_aggregate_secondary_detail')"),
      );
      expect(deliverySettlement, contains('initiallyExpanded: false'));
      expect(deliverySettlement, isNot(contains('PosStatCard(')));

      expect(paymentDetail, contains('class _SecondaryInfoPanel'));
      expect(paymentDetail, contains('ExpansionTile('));
      expect(paymentDetail, contains('initiallyExpanded: false'));
    },
  );
}
