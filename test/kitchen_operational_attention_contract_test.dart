import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('kitchen workspace exposes a read-only operational attention layer', () {
    final screen = readRepoFile('lib/features/kitchen/kitchen_screen.dart');
    final provider = readRepoFile('lib/features/kitchen/kitchen_provider.dart');

    expect(screen, contains('Kitchen Attention'));
    expect(
      screen,
      contains(
        'Read-only kitchen readiness layer built from the tracked active order queue.',
      ),
    );
    expect(screen, contains('Follow-up now'));
    expect(screen, contains('Pending items'));
    expect(screen, contains('Ready items'));
    expect(screen, contains('Long waits'));
    expect(screen, contains('Follow-up focus'));
    expect(screen, contains('Boundary'));

    expect(provider, contains(".inFilter('status', ['pending', 'confirmed', 'serving'])"));
    expect(provider, contains(".channel('public:kitchen_orders:\$storeId')"));

    expect(screen, isNot(contains("path: '/kitchen/attention'")));
    expect(screen, isNot(contains('Navigator.push(')));
    expect(screen, isNot(contains('createKitchenFollowup')));
  });
}
