import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'delivery KDS routing stops at tray and synchronizes customer status',
    () {
      final migration = File(
        'supabase/migrations/20260824060000_direct_delivery_kds_routing.sql',
      ).readAsStringSync();

      expect(migration, contains("order_row.sales_channel = 'delivery'"));
      expect(migration, contains("p_station_type <> 'floor'"));
      expect(migration, contains("p_target_station = 'floor'"));
      expect(migration, contains('sync_direct_delivery_ticket_from_kds'));
      expect(migration, contains("NEW.stage = 'kitchen_done'"));
      expect(migration, contains("NEW.stage = 'tray_dispatched'"));
      expect(migration, contains("SET status = 'preparing'"));
      expect(migration, contains("SET status = 'dispatched'"));
      expect(migration, contains('WHERE user_row.id = NEW.actor_user_id'));
      expect(
        migration,
        isNot(contains("IF FOUND AND v_ticket.status = 'ready' THEN")),
      );
    },
  );
}
