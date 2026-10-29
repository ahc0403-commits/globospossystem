import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:globos_pos_system/core/services/attendance_service.dart';

void main() {
  test(
    'manual attendance uses the scoped client and preserves store, employee and manager PIN',
    () async {
      var calls = 0;
      final client = SupabaseClient(
        'https://attendance.invalid',
        'fixture-key',
        httpClient: MockClient((request) async {
          calls++;
          expect(
            request.url.path,
            '/rest/v1/rpc/admin_record_employee_attendance',
          );
          final body = jsonDecode(request.body) as Map;
          expect(body['p_store_id'], 'fixture-store');
          expect(body['p_employee_id'], 'workforce-employee');
          expect(body['p_type'], 'clock_out');
          expect(body['p_logged_at'], '2026-10-28T11:00:00.000Z');
          expect(body['p_reason'], 'Missed checkout');
          expect(body['p_manager_pin'], '2468');
          return http.Response(
            jsonEncode({
              'id': 'created-log',
              'employee_id': 'workforce-employee',
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final result = await AttendanceService(client: client)
          .recordManualAttendance(
            storeId: 'fixture-store',
            employeeId: 'workforce-employee',
            type: 'clock_out',
            loggedAt: DateTime.utc(2026, 10, 28, 11),
            reason: '  Missed checkout  ',
            managerPin: '2468',
          );
      expect(result['id'], 'created-log');
      expect(calls, 1);
    },
  );
}
