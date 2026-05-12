import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('kitchen workspace exposes a read-only operational attention layer', () {
    final screen = readRepoFile('lib/features/kitchen/kitchen_screen.dart');
    final provider = readRepoFile('lib/features/kitchen/kitchen_provider.dart');

    expect(screen, contains("import '../../core/i18n/locale_extensions.dart';"));
    expect(screen, contains('context.l10n'));
    expect(screen, contains('l10n.kitchenAttentionTitle'));
    expect(screen, contains('l10n.kitchenAttentionSubtitle'));
    expect(screen, contains('l10n.kitchenAttentionFollowUpNow'));
    expect(screen, contains('l10n.kitchenAttentionPendingItems'));
    expect(screen, contains('l10n.kitchenAttentionReadyItems'));
    expect(screen, contains('l10n.kitchenAttentionOldestWait'));
    expect(screen, contains('l10n.kitchenAttentionLongWaits'));
    expect(screen, contains('l10n.kitchenAttentionReadyTables'));
    expect(screen, contains('l10n.kitchenAttentionFollowUpFocus'));
    expect(screen, contains('l10n.kitchenAttentionHandoffReadiness'));
    expect(screen, contains('l10n.kitchenAttentionBoundary'));
    expect(screen, contains('l10n.kitchenSecondsAgo'));
    expect(screen, contains('l10n.kitchenMinutesAgo'));
    expect(screen, contains('l10n.kitchenHoursAgo'));

    expect(provider, contains(".inFilter('status', ['pending', 'confirmed', 'serving'])"));
    expect(provider, contains(".channel('public:kitchen_orders:\$storeId')"));

    expect(screen, isNot(contains("path: '/kitchen/attention'")));
    expect(screen, isNot(contains('Navigator.push(')));
    expect(screen, isNot(contains('createKitchenFollowup')));
  });
}
