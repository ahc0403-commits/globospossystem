import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260808220000_printer_network_endpoints.sql';
  const preflightPath = 'scripts/preflight_printer_network_endpoints.sql';
  const verifyPath = 'scripts/verify_printer_network_endpoints.sql';

  test('printer schema separates physical printers, routes, and endpoints', () {
    final sql = File(migrationPath).readAsStringSync();

    expect(
      sql,
      contains('CREATE TABLE IF NOT EXISTS public.physical_printers'),
    );
    expect(
      sql,
      contains('CREATE TABLE IF NOT EXISTS public.printer_endpoints'),
    );
    expect(sql, contains("endpoint_type IN ('wired', 'wireless')"));
    expect(sql, contains('ADD COLUMN IF NOT EXISTS physical_printer_id'));
    expect(sql, contains('ALTER COLUMN physical_printer_id SET NOT NULL'));
  });

  test('legacy single-address destinations migrate as wireless endpoints', () {
    final sql = File(migrationPath).readAsStringSync();

    expect(sql, contains("SELECT physical_printer_id, 'wireless', ip, port"));
    expect(sql, contains('sync_legacy_printer_destination_endpoint'));
  });

  test('v2 admin RPC accepts both wired and wireless endpoints', () {
    final sql = File(migrationPath).readAsStringSync();

    expect(sql, contains('admin_upsert_printer_destination_v2'));
    expect(sql, contains('p_wired_ip text'));
    expect(sql, contains('p_wireless_ip text'));
    expect(sql, contains("'has_wired_endpoint'"));
    expect(sql, contains("'has_wireless_endpoint'"));
    expect(sql, contains('p_wired_port IS NULL'));
    expect(sql, contains('p_wireless_port IS NULL'));
    expect(sql, contains('cleanup_orphaned_physical_printer'));
  });

  test('Windows runner exposes native wired and wireless link state', () {
    final runner = File('windows/runner/flutter_window.cpp').readAsStringSync();
    final cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();

    expect(runner, contains('globos/network_capabilities'));
    expect(runner, contains('IF_TYPE_ETHERNET_CSMACD'));
    expect(runner, contains('IF_TYPE_IEEE80211'));
    expect(runner, contains('GetIfEntry2'));
    expect(runner, contains('HardwareInterface'));
    expect(runner, contains('NotMediaConnected'));
    expect(cmake, contains('iphlpapi.lib'));
  });

  test(
    'production migration gate checks printer preconditions and outcome',
    () {
      final preflight = File(preflightPath).readAsStringSync();
      final verify = File(verifyPath).readAsStringSync();

      expect(preflight, contains('PRINTER_NETWORK_ENDPOINT_PREFLIGHT_OK'));
      expect(preflight, contains('require_admin_actor_for_restaurant'));
      expect(verify, contains('PRINTER_NETWORK_ENDPOINT_VERIFY_OK'));
      expect(verify, contains('PRINTER_DESTINATION_BACKFILL_INCOMPLETE'));
      expect(verify, contains('PRINTER_ENDPOINT_FUNCTION_SECURITY_INVALID'));
      expect(verify, contains('sync_legacy_printer_destination_endpoint'));
    },
  );
}
