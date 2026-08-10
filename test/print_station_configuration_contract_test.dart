import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('print station exposes store-scoped printer destination settings', () {
    final screen = _read(
      'lib/features/print_station/print_station_screen.dart',
    );

    expect(screen, contains("Key('print_station_destination_add')"));
    expect(screen, contains('print_station_destination_edit_'));
    expect(screen, contains('print_station_destination_remove_'));
    expect(screen, contains("Key('print_station_destination_dialog')"));
    expect(screen, contains('PrinterDestinationDraft('));
    expect(screen, contains('.upsertDestination('));
    expect(screen, contains('.deleteDestination('));
    expect(screen, contains('constraints.maxWidth < 560'));
  });

  test(
    'printer mutation RPCs permit only admin or same-store station actors',
    () {
      final migration = _read(
        'supabase/migrations/'
        '20260810160000_print_station_printer_configuration.sql',
      );

      expect(migration, contains('public.require_printer_configuration_actor'));
      expect(migration, contains("v_actor.role = 'print_station'"));
      expect(
        migration,
        contains("v_actor.account_type = 'device_print_station'"),
      );
      expect(migration, contains('public.user_accessible_stores(auth.uid())'));
      expect(
        migration,
        contains(
          'RETURN public.require_admin_actor_for_restaurant(p_store_id)',
        ),
      );
      expect(
        RegExp(
          r'PERFORM public\.require_printer_configuration_actor\(p_store_id\);',
        ).allMatches(migration),
        hasLength(3),
      );
      expect(
        migration,
        isNot(
          contains(
            'GRANT EXECUTE ON FUNCTION '
            'public.require_printer_configuration_actor(uuid) '
            'TO authenticated',
          ),
        ),
      );
    },
  );
}
