import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production release includes direct delivery without activating it', () {
    final deploy = File('scripts/deploy_pos_production.sh').readAsStringSync();

    expect(
      deploy,
      contains('supabase functions deploy direct-order-public'),
    );
    expect(
      deploy,
      contains('DIRECT_ORDER_RATE_LIMIT_SECRET'),
    );
    expect(
      deploy,
      contains('DIRECT_ORDER_CLEANUP_SECRET'),
    );
    expect(
      deploy,
      contains('GOOGLE_TRANSLATE_SERVER_API_KEY'),
    );
    expect(
      deploy,
      contains('Direct order Edge security tests'),
    );
    expect(
      deploy,
      contains('direct-order-public; do'),
    );

    for (final path in <String>[
      'scripts/preflight_direct_delivery_ordering.sql',
      'scripts/verify_direct_delivery_ordering.sql',
      'scripts/preflight_direct_delivery_arrival_alerts.sql',
      'scripts/verify_direct_delivery_arrival_alerts.sql',
    ]) {
      expect(File(path).existsSync(), isTrue, reason: path);
      expect(
        File(path).readAsStringSync(),
        contains(r'\set ON_ERROR_STOP on'),
        reason: path,
      );
    }

    final orderingVerify =
        File('scripts/verify_direct_delivery_ordering.sql').readAsStringSync();
    final alertVerify = File(
      'scripts/verify_direct_delivery_arrival_alerts.sql',
    ).readAsStringSync();
    expect(orderingVerify, contains('STOREFRONT_UNEXPECTEDLY_ENABLED'));
    expect(alertVerify, contains('STOREFRONT_UNEXPECTEDLY_ENABLED'));
    expect(alertVerify, contains('AFTER INSERT'));

    final webIndex = File('web/index.html').readAsStringSync();
    expect(
      webIndex,
      contains(
        '<meta name="referrer" content="strict-origin-when-cross-origin">',
      ),
    );
    expect(
      webIndex,
      isNot(contains('<meta name="referrer" content="no-referrer">')),
    );
    expect(webIndex, contains('&auth_referrer_policy=origin'));
    expect(webIndex, contains("script.referrerPolicy = 'origin';"));
    expect(webIndex, isNot(contains("script.referrerPolicy = 'no-referrer';")));
    expect(
      webIndex,
      contains(r"/^\/order\/[a-z0-9][a-z0-9-]{2,62}$/"),
    );
    expect(webIndex, contains("'/#' + path + window.location.search"));

    final staffService = File(
      'lib/features/direct_order/direct_order_staff_service.dart',
    ).readAsStringSync();
    expect(staffService, contains('/#/order/'));
    expect(staffService, isNot(contains("posPublicUrl}/order/")));
  });
}
