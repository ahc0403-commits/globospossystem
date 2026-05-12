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

    expect(tab, contains('Settlement Attention'));
    expect(
      tab,
      contains(
        'Read-only settlement readiness layer built from tracked Deliberry settlement state.',
      ),
    );
    expect(tab, contains('Follow-up now'));
    expect(tab, contains('Statements waiting'));
    expect(tab, contains('Settled periods'));
    expect(tab, contains('Net at risk'));
    expect(tab, contains('Ready to confirm'));
    expect(tab, contains('Follow-up focus'));
    expect(tab, contains('Deposit readiness'));
    expect(tab, contains('At-risk mix'));
    expect(tab, contains('Boundary'));

    expect(provider, contains(".from('v_settlement_summary')"));
    expect(provider, contains('confirm_delivery_settlement_received'));

    expect(tab, isNot(contains("path: '/delivery/settlements'")));
    expect(tab, isNot(contains('Navigator.push(')));
    expect(tab, isNot(contains('generate_delivery_settlement(')));
  });
}
