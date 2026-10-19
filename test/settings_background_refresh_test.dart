import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/providers/settings_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
    'same-scope refresh joins one request pair and retains content',
    () async {
      var calls = 0;
      var fail = false;
      Completer<void>? gate;
      final client = SupabaseClient(
        'https://fixture.invalid',
        'fixture',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((r) async {
          calls++;
          if (r.url.path.endsWith('restaurants')) await gate?.future;
          if (fail) {
            return http.Response(
              '{"message":"temporary failure","code":"503"}',
              503,
            );
          }
          final row = r.url.path.endsWith('restaurants')
              ? {
                  'id': 'store-a',
                  'name': 'Store A',
                  'address': 'Fixture',
                  'operation_mode': 'standard',
                  'per_person_charge': 0,
                }
              : {'full_name': 'Fixture', 'role': 'store_admin'};
          return http.Response(
            jsonEncode(row),
            200,
            headers: {'content-type': 'application/json'},
            request: r,
          );
        }),
      );
      addTearDown(client.dispose);
      final notifier = SettingsNotifier(client: client);
      addTearDown(notifier.dispose);
      await notifier.loadSettings('store-a', 'user-a');
      expect(calls, 2);
      gate = Completer<void>();
      final first = notifier.loadSettings(
        'store-a',
        'user-a',
        showLoading: false,
      );
      final second = notifier.loadSettings(
        'store-a',
        'user-a',
        showLoading: false,
      );
      expect(first, same(second));
      expect(notifier.state.restaurantName, 'Store A');
      expect(notifier.state.isLoading, false);
      gate.complete();
      await first;
      expect(calls, 4);
      gate = null;
      fail = true;
      await notifier.loadSettings('store-a', 'user-a', showLoading: false);
      expect(notifier.state.restaurantName, 'Store A');
      expect(notifier.state.isLoading, false);
      expect(notifier.state.error, isNotNull);
    },
  );
}
