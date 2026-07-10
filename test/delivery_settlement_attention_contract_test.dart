import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('delivery settlement workspace exposes a read-only attention layer', () {
    final tab = readRepoFile(
      'lib/features/delivery/screens/delivery_settlement_tab.dart',
    );
    final provider = readRepoFile(
      'lib/features/delivery/delivery_settlement_provider.dart',
    );

    expect(
      tab,
      contains("import '../../../core/i18n/locale_extensions.dart';"),
    );
    expect(tab, contains('context.l10n'));
    expect(tab, contains('l10n.deliveryHeaderSubtitle'));
    expect(tab, contains('l10n.deliveryAttentionRequired'));
    expect(tab, contains('l10n.deliveryKpiUnsettledOrders'));
    expect(tab, contains('l10n.deliveryKpiStatementPending'));
    expect(tab, contains('l10n.deliveryKpiDispute'));
    expect(tab, contains('l10n.deliveryKpiRiskNet'));
    expect(tab, contains('l10n.deliverySettlementHistory'));
    expect(tab, contains('l10n.deliverySettlementAttentionTitle'));
    expect(tab, contains('l10n.deliverySettlementSettledPeriods'));
    expect(tab, contains('l10n.deliverySettlementFollowUpFocus'));
    expect(tab, contains('l10n.deliverySettlementDepositReadiness'));
    expect(tab, contains('l10n.deliverySettlementAtRiskMix'));
    expect(tab, contains('_buildDeliverySettlementHeader('));
    expect(tab, contains('_buildDeliveryQueueControls('));
    expect(tab, contains("Key('delivery_settlement_queue_header')"));
    expect(tab, contains("Key('delivery_settlement_queue_controls')"));
    expect(tab, contains("Key('delivery_aggregate_secondary_detail')"));
    expect(tab, contains('initiallyExpanded: false'));
    expect(tab, contains('ToastMetricStrip('));
    expect(tab, contains('PosExceptionAlert('));
    expect(tab, isNot(contains('PosPageHeader(')));
    expect(tab, isNot(contains('PosStatCard(')));
    expect(tab, isNot(contains('PosToolbar(')));
    expect(tab, contains('_buildOperationalAttention('));
    expect(tab, contains('_buildAggregateSummary('));
    expect(tab, contains('_buildUnsettledCard('));

    expect(provider, contains(".from('v_settlement_summary')"));
    expect(provider, contains('confirm_delivery_settlement_received'));

    expect(tab, isNot(contains("path: '/delivery/settlements'")));
    expect(tab, isNot(contains('Navigator.push(')));
    expect(tab, isNot(contains('generate_delivery_settlement(')));
  });
}
