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
    expect(tab, contains('l10n.deliverySettlementAttentionTitle'));
    expect(tab, contains('l10n.deliverySettlementAttentionSubtitle'));
    expect(tab, contains('l10n.deliverySettlementFollowUpNow'));
    expect(tab, contains('l10n.deliverySettlementStatementsWaiting'));
    expect(tab, contains('l10n.deliverySettlementSettledPeriods'));
    expect(tab, contains('l10n.deliverySettlementNetAtRisk'));
    expect(tab, contains('l10n.deliverySettlementReadyToConfirm'));
    expect(tab, contains('l10n.deliverySettlementFollowUpFocus'));
    expect(tab, contains('l10n.deliverySettlementDepositReadiness'));
    expect(tab, contains('l10n.deliverySettlementAtRiskMix'));
    expect(tab, contains('l10n.deliverySettlementBoundary'));
    expect(tab, contains('_buildHistoryFocus('));
    expect(tab, contains('_settlementMiniMetric('));
    expect(tab, contains('s.receivedAt'));
    expect(tab, contains('s.notes'));

    expect(provider, contains(".from('v_settlement_summary')"));
    expect(provider, contains('confirm_delivery_settlement_received'));

    expect(tab, isNot(contains("path: '/delivery/settlements'")));
    expect(tab, isNot(contains('Navigator.push(')));
    expect(tab, isNot(contains('generate_delivery_settlement(')));
  });
}
