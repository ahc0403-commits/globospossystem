import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production release includes direct delivery without activating it', () {
    final deploy = File('scripts/deploy_pos_production.sh').readAsStringSync();

    expect(deploy, contains('supabase functions deploy direct-order-public'));
    expect(deploy, contains('DIRECT_ORDER_RATE_LIMIT_SECRET'));
    expect(deploy, contains('DIRECT_ORDER_CLEANUP_SECRET'));
    expect(deploy, isNot(contains('GOOGLE_TRANSLATE_SERVER_API_KEY')));
    expect(deploy, contains('Direct order Edge security tests'));
    expect(deploy, contains('direct-order-public; do'));

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

    final orderingVerify = File(
      'scripts/verify_direct_delivery_ordering.sql',
    ).readAsStringSync();
    final alertVerify = File(
      'scripts/verify_direct_delivery_arrival_alerts.sql',
    ).readAsStringSync();
    expect(orderingVerify, contains('STOREFRONT_UNEXPECTEDLY_ENABLED'));
    expect(alertVerify, contains('STOREFRONT_UNEXPECTEDLY_ENABLED'));
    expect(alertVerify, contains('AFTER INSERT'));

    final pilotHoursMigration = File(
      'supabase/migrations/'
      '20260824013000_direct_delivery_pilot_open_hours.sql',
    ).readAsStringSync();
    expect(pilotHoursMigration, contains('ordering_hours_enforced = false'));
    expect(
      pilotHoursMigration,
      contains('v_storefront.ordering_hours_enforced'),
    );
    expect(pilotHoursMigration, contains('isolated fulfillment ticket graph'));
    expect(pilotHoursMigration, contains('DIRECT_ORDER_REQUIRES_POS_PRINT'));
    expect(pilotHoursMigration, contains('-- production-gate: self-verifying'));
    expect(
      File(
        'scripts/rollback_direct_delivery_pilot_open_hours.sql',
      ).existsSync(),
      isTrue,
    );

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
    expect(webIndex, contains(r"/^\/order\/[a-z0-9][a-z0-9-]{2,62}$/"));
    expect(webIndex, contains("'/#' + path + window.location.search"));

    final staffService = File(
      'lib/features/direct_order/direct_order_staff_service.dart',
    ).readAsStringSync();
    expect(staffService, contains("posPublicUrl}/order/"));
    expect(staffService, isNot(contains('/#/order/')));
    expect(staffService, contains("'direct_order_staff_message'"));

    expect(
      webIndex,
      contains('property="og:title" content="BunsikClub Delivery Order"'),
    );
    expect(webIndex, contains('bunsikclub-social-preview.png'));
    expect(File('web/bunsikclub-social-preview.png').existsSync(), isTrue);

    final pilotActionsMigration = File(
      'supabase/migrations/'
      '20260824040000_direct_order_pilot_actions_and_progress.sql',
    ).readAsStringSync();
    expect(
      pilotActionsMigration,
      contains('Uploading payment proof locks the quoted amount'),
    );
    expect(
      pilotActionsMigration,
      contains('Direct delivery uses its own fulfillment ticket graph'),
    );
    expect(
      pilotActionsMigration,
      contains("position('DIRECT_ORDER_EMERGENCY_ACTIVE' IN v_definition)"),
    );
    expect(
      File(
        'scripts/rollback_direct_order_pilot_actions_and_progress.sql',
      ).existsSync(),
      isTrue,
    );

    final edge = File(
      'supabase/functions/direct-order-public/index.ts',
    ).readAsStringSync();
    expect(edge, isNot(contains('translation.googleapis.com')));
    expect(edge, isNot(contains('GOOGLE_TRANSLATE_SERVER_API_KEY')));
    expect(edge, isNot(contains('message_translations')));
    expect(edge, contains('direct_order_public_message'));

    expect(
      File(
        'supabase/migrations/'
        '20260822100000_direct_order_chat_translation.sql',
      ).existsSync(),
      isFalse,
    );
  });
}
