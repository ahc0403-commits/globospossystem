import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:globos_pos_system/core/services/store_revenue_summary_service.dart';
import 'package:globos_pos_system/features/super_admin/super_admin_provider.dart';

SuperRestaurant store(
  String id, {
  bool active = true,
  String? entity,
  String? name,
}) => SuperRestaurant(
  id: id,
  name: name ?? id,
  slug: id,
  address: '',
  operationMode: 'standard',
  perPersonCharge: null,
  isActive: active,
  createdAt: DateTime(2026),
  taxEntityId: entity,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'network scope hides closed and sample identities without altering the management archive',
    () {
      final real = store('real', name: 'JeonGabok Binh Thanh');
      final closed = store('closed', active: false, name: 'JeonGabok');
      final renamedSample = store(
        'sample',
        entity: sampleReportingTaxEntityId,
        name: 'Renamed training store',
      );
      final state = SuperAdminState(
        restaurants: [real, closed, renamedSample],
        selectedRestaurant: closed,
        reportStart: DateTime(2026),
        reportEnd: DateTime(2026),
      );
      expect(state.reportingRestaurants, [real]);
      expect(state.restaurants, hasLength(3));
      expect(state.selectedReportingRestaurant, isNull);
      expect(
        store('real-word', name: 'Sample Road Restaurant').isReportable,
        isTrue,
      );
    },
  );

  test(
    'network response requires complete explicit exclusions, never a silently partial aggregate',
    () async {
      var excluded = <dynamic>['closed'];
      var rows = <Map<String, dynamic>>[
        {'store_id': 'real', 'dine_in': 100, 'delivery': 20},
      ];
      final client = SupabaseClient(
        'https://fixture.supabase.co',
        'fixture-key',
        httpClient: MockClient((request) async {
          expect(
            request.url.path,
            endsWith('/get_network_store_revenue_summary'),
          );
          return http.Response(
            jsonEncode({
              'version': 1,
              'from_date': '2026-10-01',
              'to_date': '2026-10-30',
              'store_count': 2,
              'rows': rows,
              'excluded_store_ids': excluded,
            }),
            200,
          request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      Future<Map<String, StoreRevenueTotals>> fetch() =>
          StoreRevenueSummaryService(client).fetch(
            storeIds: ['real', 'closed'],
            fromDate: DateTime(2026, 10),
            toDate: DateTime(2026, 10, 30),
            networkOnly: true,
          );
      expect((await fetch()).keys, ['real']);
      for (final invalid in [
        <dynamic>[],
        ['closed', 'closed'],
        ['foreign'],
        [42],
        ['real'],
      ]) {
        excluded = invalid;
        await expectLater(fetch(), throwsFormatException);
      }
      excluded = ['closed'];
      rows = [];
      await expectLater(fetch(), throwsFormatException);
    },
  );
}
