// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:globos_pos_system/features/super_admin/super_admin_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('forced catalog waiters share one follow-up', () async {
    var calls = 0, active = 0, peak = 0;
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final client = SupabaseClient(
      'http://127.0.0.1:54321',
      'audit-fixture',
      httpClient: MockClient((r) async {
        expect(r.url.path.endsWith('/brands'), isTrue);
        calls++;
        active++;
        if (active > peak) peak = active;
        if (calls == 1) {
          firstStarted.complete();
          await releaseFirst.future;
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        active--;
        return http.Response(
          '[]',
          200,
          request: r,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final notifier = SuperAdminNotifier(client: client);
    final first = notifier.loadBrands();
    await firstStarted.future;
    final forced = List.generate(100, (_) => notifier.loadBrands(force: true));
    expect(calls, 1);
    releaseFirst.complete();
    await Future.wait([first, ...forced]);
    expect(calls, 2);
    expect(peak, 1);
    print(
      'AUDIT_MEASUREMENT ' +
          jsonEncode({
            'initial_loads': 1,
            'forced_refresh_calls': 100,
            'http_calls': calls,
            'peak_http_in_flight': peak,
            'network': 'mock_only',
          }),
    );
    notifier.dispose();
    await client.dispose();
  });
}
