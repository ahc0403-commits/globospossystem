import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/store_setup/store_operating_profile.dart';
import 'package:globos_pos_system/features/store_setup/widgets/operating_profile_card.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> _json({String store = 'jgb', bool captured = false}) => {
  'restaurant_id': store,
  'revision': captured ? 1 : 0,
  'definition_schema_version': 1,
  'runtime_authority': 'legacy',
  'source_matches': captured,
  'workflow': 'kitchen_floor',
  'baseline_version_id': captured ? 'version-1' : null,
  'stations': captured
      ? [
          {
            'id': 'kitchen',
            'kind': 'kitchen',
            'user_ids': ['chef'],
          },
          {
            'id': 'floor',
            'kind': 'floor',
            'area_id': 'area-3',
            'stored_floor': '3F',
            'user_ids': ['floor-2', 'floor-3'],
          },
        ]
      : [],
};

Widget _app(_Backend backend, {String store = 'jgb', String locale = 'ko'}) =>
    MaterialApp(
      locale: Locale(locale),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: OperatingProfileCard(restaurantId: store, backend: backend),
        ),
      ),
    );

class _Backend implements StoreOperatingProfileBackend {
  int loads = 0, captures = 0;
  int? receivedRevision;
  bool available = true;
  Completer<StoreOperatingProfile?>? pending;
  @override
  Future<StoreOperatingProfile?> load(String restaurantId) async {
    loads++;
    if (pending != null) return pending!.future;
    return available
        ? StoreOperatingProfile.fromJson(_json(store: restaurantId))
        : null;
  }

  @override
  Future<StoreOperatingProfile> capture(
    String restaurantId,
    int revision,
  ) async {
    captures++;
    receivedRevision = revision;
    return StoreOperatingProfile.fromJson(
      _json(store: restaurantId, captured: true),
    );
  }
}

void main() {
  test('configuration schema and runtime authority fail closed', () {
    for (final invalid in [
      {..._json(), 'definition_schema_version': 2},
      {..._json(), 'runtime_authority': 'v2'},
      {..._json(), 'workflow': 'unknown'},
      {..._json(), 'revision': 2},
    ]) {
      expect(
        () => StoreOperatingProfile.fromJson(invalid),
        throwsFormatException,
      );
    }
  });

  test(
    'one scoped RPC loads a profile and capture carries expected revision',
    () async {
      final requests = <http.Request>[];
      final client = SupabaseClient(
        'https://fixture.invalid',
        'fixture',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode(_json(captured: requests.length > 1)),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final backend = SupabaseStoreOperatingProfileBackend(client);
      final baseline = await backend.load('jgb');
      expect(requests, hasLength(1));
      expect(jsonDecode(requests.single.body), {'p_store_id': 'jgb'});
      await backend.capture('jgb', baseline!.revision);
      expect(jsonDecode(requests.last.body), {
        'p_store_id': 'jgb',
        'p_expected_revision': 0,
      });
      expect(
        requests.last.url.path,
        endsWith('/admin_capture_store_operating_baseline_v1'),
      );
    },
  );

  test('only the missing optional endpoint permits an older server', () async {
    final cases = <(int, Map<String, dynamic>, bool)>[
      (
        404,
        {
          'code': 'PGRST202',
          'message': 'admin_get_store_operating_profile_v1 missing',
        },
        true,
      ),
      (403, {'code': '42501', 'message': 'forbidden'}, false),
      (400, {'code': '42883', 'message': 'missing internal dependency'}, false),
      (200, {..._json(), 'restaurant_id': 'other'}, false),
    ];
    for (final (status, body, optional) in cases) {
      final client = SupabaseClient(
        'https://fixture.invalid',
        'fixture',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode(body),
            status,
            headers: {'content-type': 'application/json'},
            request: request,
          ),
        ),
      );
      final backend = SupabaseStoreOperatingProfileBackend(client);
      if (optional) {
        expect(await backend.load('jgb'), isNull);
      } else {
        await expectLater(backend.load('jgb'), throwsA(anything));
      }
      await client.dispose();
    }
  });

  testWidgets(
    'review is opt-in; capture preserves guest floor and both accounts',
    (tester) async {
      final backend = _Backend();
      await tester.pumpWidget(_app(backend));
      await tester.pumpAndSettle();
      expect(backend.loads, 0);
      await tester.tap(find.byKey(const Key('operating_profile_load')));
      await tester.pumpAndSettle();
      expect(find.text('주방 → 층 → 고객'), findsOneWidget);
      await tester.tap(find.byKey(const Key('operating_profile_capture')));
      await tester.pumpAndSettle();
      expect(backend.captures, 1);
      expect(backend.receivedRevision, 0);
      expect(find.text('마지막으로 기록한 담당 배정'), findsOneWidget);
      expect(find.textContaining('담당 계정 2개'), findsOneWidget);
      expect(find.textContaining('2F'), findsOneWidget);
      expect(find.textContaining('3F'), findsNothing);
      expect(find.byKey(const Key('operating_profile_capture')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'in-flight response cannot revive another store or duplicate load',
    (tester) async {
      final backend = _Backend()..pending = Completer<StoreOperatingProfile?>();
      await tester.pumpWidget(_app(backend));
      await tester.tap(find.byKey(const Key('operating_profile_load')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('operating_profile_load')));
      expect(backend.loads, 1);
      await tester.pumpWidget(_app(backend, store: 'bunsik'));
      backend.pending!.complete(
        StoreOperatingProfile.fromJson(_json(captured: true)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('담당 계정'), findsNothing);
      expect(find.byKey(const Key('operating_profile_capture')), findsNothing);
    },
  );

  for (final locale in ['en', 'vi', 'ko']) {
    testWidgets('older server is explicit and non-blocking in $locale', (
      tester,
    ) async {
      final backend = _Backend()..available = false;
      await tester.pumpWidget(_app(backend, locale: locale));
      await tester.tap(find.byKey(const Key('operating_profile_load')));
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byKey(const Key('operating_profile_capture')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
