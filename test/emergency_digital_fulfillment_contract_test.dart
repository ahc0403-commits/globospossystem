import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/role_routes.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';

void main() {
  test('emergency station role is isolated to its web route', () {
    expect(homeRouteForRole('emergency_station'), '/emergency');
    expect(canAccessRouteForRole('emergency_station', '/emergency'), isTrue);
    for (final forbidden in [
      '/cashier',
      '/kitchen',
      '/admin',
      '/super-admin',
      '/print-station',
      '/payments/payment-id',
    ]) {
      expect(canAccessRouteForRole('emergency_station', forbidden), isFalse);
    }
  });

  test('quantity model keeps every fulfilment stage separate', () {
    final item = EmergencyFulfillmentItem.fromJson({
      'id': 'fulfilment-item',
      'order_item_id': 'order-item',
      'name_ko': '떡볶이',
      'name_vi': 'Tokbokki',
      'name_en': 'Tteokbokki',
      'ordered_quantity': 2,
      'kitchen_done_quantity': 2,
      'tray_received_quantity': 1,
      'tray_dispatched_quantity': 1,
      'floor_served_quantity': 0,
      'needs_review': false,
    });
    expect(item.quantityForStage('kitchen_done'), 2);
    expect(item.quantityForStage('tray_received'), 1);
    expect(item.quantityForStage('tray_dispatched'), 1);
    expect(item.quantityForStage('floor_served'), 0);
    expect(item.localizedName('vi'), 'Tokbokki');
    expect(item.localizedName('ko'), '떡볶이');
  });

  test('database contract is opt-in, quantity chained, and printer safe', () {
    final migration = File(
      'supabase/migrations/20260810170000_emergency_digital_fulfillment.sql',
    ).readAsStringSync();
    expect(migration, contains('emergency_one_active_session_per_store'));
    expect(migration, contains('emergency_fulfillment_quantity_chain'));
    expect(
      migration,
      contains('floor_served_quantity <= tray_dispatched_quantity'),
    );
    expect(
      migration,
      contains('tray_dispatched_quantity <= tray_received_quantity'),
    );
    expect(
      migration,
      contains('tray_received_quantity <= kitchen_done_quantity'),
    );
    expect(migration, contains("copy_type = 'receipt'"));
    expect(migration, contains('emergency_held_at IS NULL'));
    expect(migration, contains("'digital_completed', 'reprint', 'dismiss'"));
    expect(migration, contains('EMERGENCY_UNRESOLVED_ITEMS'));
    expect(migration, contains('p_event_id uuid'));
    expect(migration, contains('event_id uuid NOT NULL UNIQUE'));
  });

  test('Binh Thanh emergency identities contain only 1F and 2F floors', () {
    final migration = File(
      'supabase/migrations/20260810170000_emergency_digital_fulfillment.sql',
    ).readAsStringSync();
    final requiredEmails = File(
      'docs/pos/pos_required_production_auth_emails.txt',
    ).readAsStringSync();
    for (final code in ['bt_tray1', 'bt_floor_1f', 'bt_floor_2f']) {
      expect(migration, contains("'$code'"));
      expect(requiredEmails, contains('$code@globos.world'));
    }
    expect(migration, isNot(contains('bt_floor_g')));
    expect(requiredEmails, isNot(contains('bt_floor_g@globos.world')));
    expect(migration, contains("floor_label IN ('1F', '2F')"));
  });

  test('web fallback includes foreground alarm, push worker and IndexedDB', () {
    final screen = File(
      'lib/features/emergency_fulfillment/emergency_fulfillment_screen.dart',
    ).readAsStringSync();
    final index = File('web/index.html').readAsStringSync();
    final worker = File('web/firebase-messaging-sw.js').readAsStringSync();
    final provider = File(
      'lib/features/emergency_fulfillment/emergency_fulfillment_provider.dart',
    ).readAsStringSync();
    expect(screen, contains("Key('emergency_enable_alarm')"));
    expect(screen, contains('final pageSize = isPhone ? 4 : 8;'));
    expect(screen, contains("'emergency_order_grid_\${pageSize}_slots'"));
    expect(screen, contains("Key('emergency_complete_order')"));
    expect(screen, contains("Key('emergency_revert_order')"));
    expect(index, contains('indexedDB.open'));
    expect(index, contains('AudioContext'));
    expect(worker, contains('emergency_fulfillment'));
    expect(provider, contains('EmergencyWebBridge.putOutbox'));
    expect(provider, contains("'p_event_id': payload['event_id']"));
    expect(provider, contains("'emergency_complete_order_stage'"));
    expect(provider, contains("'emergency_revert_order_action'"));
  });

  test('order action contract is atomic, idempotent, and reversible', () {
    final migration = File(
      'supabase/migrations/20260811140000_emergency_kds_order_actions.sql',
    ).readAsStringSync();
    expect(migration, contains('emergency_fulfillment_actions'));
    expect(migration, contains('emergency_complete_order_stage'));
    expect(migration, contains('emergency_revert_order_action'));
    expect(migration, contains('FOR UPDATE OF queue'));
    expect(migration, contains('FOR UPDATE'));
    expect(migration, contains('ON CONFLICT (action_id) DO NOTHING'));
    expect(migration, contains('EMERGENCY_REVERT_DOWNSTREAM_PROGRESS'));
    expect(migration, contains("'tray_received'"));
    expect(migration, contains("'tray_dispatched'"));
    expect(migration, contains('original_action_id'));
  });

  test('production release deploys and verifies the emergency dispatcher', () {
    final deploy = File('scripts/deploy_pos_production.sh').readAsStringSync();
    final vercelBuild = File('scripts/vercel_build_web.sh').readAsStringSync();
    final authCheck = File(
      'scripts/check_pilot_auth_accounts.sh',
    ).readAsStringSync();
    final migration = File(
      'supabase/migrations/20260810170000_emergency_digital_fulfillment.sql',
    ).readAsStringSync();

    expect(
      deploy,
      contains('functions deploy emergency-fulfillment-dispatcher'),
    );
    expect(deploy, contains('verify_emergency_dispatcher_readiness'));
    expect(deploy, contains('verify_vercel_firebase_web_env'));
    expect(deploy, contains('FIREBASE_SERVICE_ACCOUNT_JSON'));
    for (final name in [
      'FIREBASE_API_KEY',
      'FIREBASE_APP_ID',
      'FIREBASE_MESSAGING_SENDER_ID',
      'FIREBASE_PROJECT_ID',
      'FIREBASE_WEB_VAPID_KEY',
    ]) {
      expect(deploy, contains(name));
      expect(vercelBuild, contains('--dart-define=$name='));
    }
    expect(authCheck, contains("'emergency_station'"));
    expect(migration, contains("'app.settings.cron_secret'"));
  });

  test('cashier warning is informational and does not gate payment', () {
    final cashier = File(
      'lib/features/cashier/cashier_screen.dart',
    ).readAsStringSync();
    final payment = File(
      'lib/features/payment/payment_provider.dart',
    ).readAsStringSync();
    expect(cashier, contains("Key('cashier_unserved_warning')"));
    expect(cashier, contains('cashier_item_fulfillment_'));
    expect(cashier, contains('미제공'));
    expect(payment, contains("'get_emergency_order_summaries'"));
    expect(payment, contains('_loadEmergencyItemProgress'));
    expect(payment, contains('emergency_fulfillment_sessions!inner(status)'));
    expect(
      cashier,
      isNot(contains('unservedQuantity == 0 && canCompletePayment')),
    );
  });
}
