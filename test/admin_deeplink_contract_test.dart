import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'admin query tabs include exception queues used for manual QA links',
    () {
      final router = readRepoFile('lib/core/router/app_router.dart');
      final adminScreen = readRepoFile('lib/features/admin/admin_screen.dart');

      expect(router, contains("'delivery' || 'settlement' => 8"));
      expect(router, contains("'einvoice' || 'e-invoice' || 'invoice' => 9"));
      expect(adminScreen, contains('tabs.add(const DeliverySettlementTab())'));
      expect(adminScreen, contains('tabs.add(const EinvoiceTab())'));
    },
  );
}
