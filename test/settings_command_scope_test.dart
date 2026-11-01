import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/staff_service.dart';
import 'package:globos_pos_system/core/services/store_service.dart';
import 'package:globos_pos_system/features/admin/providers/settings_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Stores extends StoreService {
  final done = Completer<void>();
  final calls = <String>[];
  double? charge;
  @override
  Future<void> updateRestaurantSettings({
    required String id,
    required String name,
    required String operationMode,
    String? address,
    double? perPersonCharge,
  }) async {
    calls.add(id);
    charge = perPersonCharge;
    await done.future;
  }
}

class _Staff extends StaffService {
  final done = Completer<void>();
  var calls = 0;
  @override
  Future<void> updateMyFullName(String name) async {
    calls++;
    await done.future;
  }
}

void main() {
  late _Stores stores;
  late _Staff staff;
  late SupabaseClient client;
  late SettingsNotifier n;
  var disposed = false;
  var calls = 0;
  Completer<void>? readGate;
  double? loadedCharge;

  setUp(() {
    stores = _Stores();
    staff = _Staff();
    disposed = false;
    calls = 0;
    readGate = null;
    loadedCharge = 500;
    client = SupabaseClient(
      'https://settings-fixture.invalid',
      'fixture',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        calls++;
        final restaurant = request.url.path.endsWith('restaurants');
        final id = request.url.queryParameters[restaurant ? 'id' : 'auth_id']!
            .substring(3);
        final row = restaurant
            ? {
                'id': id,
                'name': id,
                'address': id,
                'operation_mode': 'standard',
                'per_person_charge': loadedCharge,
              }
            : {'full_name': id, 'role': 'store_admin'};
        if (restaurant) await readGate?.future;
        return http.Response(
          jsonEncode(row),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    n = SettingsNotifier(client: client, stores: stores, staff: staff);
  });
  tearDown(() async {
    if (!disposed) n.dispose();
    await client.dispose();
  });
  Future<bool> save() => n.saveRestaurant(
    name: 'changed-a',
    address: 'new',
    operationMode: 'standard',
    perPersonCharge: null,
  );

  test(
    'store save remains confirmed after switching to another store',
    () async {
      await n.loadSettings('store-a', 'actor-a');
      final saving = save();
      await n.loadSettings('store-b', 'actor-a');
      stores.done.complete();
      expect(await saving, isTrue);
      expect(stores.calls, ['store-a']);
      expect(n.state.restaurantName, 'store-b');
      expect(n.state.perPersonCharge, 500);
      expect(n.state.error, isNull);
    },
  );

  test(
    'A to B to A does not make an earlier settings write current again',
    () async {
      await n.loadSettings('store-a', 'actor-a');
      final saving = save();
      await n.loadSettings('store-b', 'actor-a');
      await n.loadSettings('store-a', 'actor-a');
      stores.done.complete();
      expect(await saving, isTrue);
      expect(n.state.restaurantName, 'store-a');
    },
  );

  for (final confirmed in [false, true]) {
    test(
      'store save ${confirmed ? 'confirmation' : 'failure'} after disposal does not touch state',
      () async {
        await n.loadSettings('store-a', 'actor-a');
        final saving = save();
        n.dispose();
        disposed = true;
        if (confirmed) {
          stores.done.complete();
        } else {
          stores.done.completeError(StateError('request failed'));
        }
        expect(await saving, confirmed);
        expect(await save(), isFalse);
        expect(stores.calls, hasLength(1));
      },
    );
  }

  test(
    'confirmed settings invalidate older reads and permit a fresh read',
    () async {
      await n.loadSettings('store-a', 'actor-a');
      readGate = Completer<void>();
      final old = n.loadSettings('store-a', 'actor-a', showLoading: false);
      final saving = save();
      await n.loadSettings('store-a', 'actor-a', showLoading: false);
      stores.done.complete();
      expect(await saving, isTrue);
      expect(n.state.restaurantName, 'changed-a');
      expect(n.state.perPersonCharge, isNull);
      readGate!.complete();
      await old;
      expect(n.state.restaurantName, 'changed-a');
      expect(
        calls,
        3,
        reason: 'the invalidated read must not send its user query',
      );
      readGate = null;
      loadedCharge = null;
      await n.loadSettings('store-a', 'actor-a');
      expect(
        calls,
        5,
        reason:
            'completed old Future must not remain the coalesced read forever',
      );
      expect(n.state.perPersonCharge, isNull);
    },
  );

  test('duplicate and simultaneous forms submit only one command', () async {
    await n.loadSettings('store-a', 'actor-a');
    final saving = save();
    expect(await save(), isFalse);
    expect(await n.updateFullName('changed'), isFalse);
    expect(stores.calls, hasLength(1));
    expect(staff.calls, 0);
    stores.done.complete();
    expect(await saving, isTrue);
  });

  test(
    'a profile confirmation cannot overwrite another account in the same store',
    () async {
      await n.loadSettings('store-a', 'actor-a');
      final saving = n.updateFullName('changed-a');
      await n.loadSettings('store-a', 'actor-b');
      staff.done.complete();
      expect(await saving, isTrue);
      expect(n.state.fullName, 'actor-b');
      expect(staff.calls, 1);
    },
  );

  test(
    'an old store failure cannot overwrite the new settings error/state',
    () async {
      await n.loadSettings('store-a', 'actor-a');
      final saving = save();
      await n.loadSettings('store-b', 'actor-a');
      stores.done.completeError(StateError('old failed'));
      expect(await saving, isFalse);
      expect(n.state.storeId, 'store-b');
      expect(n.state.error, isNull);
    },
  );

  test(
    'server and saved null charges actually clear the displayed value',
    () async {
      await n.loadSettings('store-a', 'actor-a');
      expect(n.state.perPersonCharge, 500);
      loadedCharge = null;
      await n.loadSettings('store-a', 'actor-a');
      expect(n.state.perPersonCharge, isNull);
      loadedCharge = 500;
      await n.loadSettings('store-a', 'actor-a');
      final saving = save();
      stores.done.complete();
      expect(await saving, isTrue);
      expect(stores.charge, isNull);
      expect(n.state.perPersonCharge, isNull);
    },
  );

  test(
    'a not-yet-loaded view cannot save settings during its first read',
    () async {
      readGate = Completer<void>();
      final read = n.loadSettings('store-a', 'actor-a');
      expect(await save(), isFalse);
      expect(await n.updateFullName('changed'), isFalse);
      expect(stores.calls, isEmpty);
      expect(staff.calls, 0);
      readGate!.complete();
      await read;
    },
  );
}
