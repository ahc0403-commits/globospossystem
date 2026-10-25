import 'package:flutter_test/flutter_test.dart';
import 'package:pos_payroll/pos_payroll.dart';
import 'fixtures/photo_office_payroll_input.dart';

class _Source implements PayrollDataSource {
  _Source(this.data);
  final Map<String, dynamic> data;
  @override
  Future<List<Map<String, dynamic>>> fetchStaffList(
    String storeId, {
    String? employeeId,
  }) async => List<Map<String, dynamic>>.from(data['staff'] as List);
  @override
  Future<List<Map<String, dynamic>>> fetchPayrollLogs({
    required String storeId,
    required DateTime from,
    required DateTime to,
    String? employeeId,
  }) async => List<Map<String, dynamic>>.from(data['logs'] as List);
  @override
  Future<List<Map<String, dynamic>>> fetchDailyAllowances({
    required String storeId,
    required DateTime from,
    required DateTime to,
    String? employeeId,
  }) async => List<Map<String, dynamic>>.from(data['allowances'] as List);
  @override
  Future<Set<DateTime>> fetchVietnamPublicHolidays({
    required DateTime from,
    required DateTime to,
  }) async => (data['holidays'] as List)
      .map((d) => DateTime.parse(d as String))
      .toSet();
  @override
  Future<Map<String, Map<String, dynamic>?>> fetchHourlyPayRules({
    required String storeId,
    required Iterable<String> employeeIds,
  }) async =>
      Map<String, Map<String, dynamic>?>.from(data['hourly_rules'] as Map);
}

Future<StaffPayroll> calculate(Map<String, dynamic> data) async =>
    (await PosPayrollCalculator(
          attendanceSource: _Source(data),
        ).calculatePayroll(
          storeId: 'pos-A',
          employeeId: 'pos-employee',
          periodStart: DateTime(2026, 10, 1),
          periodEnd: DateTime(2026, 10, 15),
        ))
        .single;

void main() {
  test(
    'Postgres time values with seconds preserve regular and night pay boundaries',
    () async {
      final data = photoInput(end: 17);
      data['hourly_rules']['pos-employee']['scheduled_start'] = '09:00:00';
      data['hourly_rules']['pos-employee']['night_start'] = '22:00:00';
      final p = await calculate(data);
      expect(p.grossAmount, 200000);
      expect(p.dailyRecords.single.nightMinutes, 0);
    },
  );
  test('Photo PT uses 25000 and flags a 25 VND unit error', () async {
    expect((await calculate(photoInput())).grossAmount, 25000);
    expect((await calculate(photoInput(rate: 25))).basisComplete, false);
  });
  test('Photo FT uses all recorded hours and the 208-hour basis', () async {
    final p = await calculate(photoInput(role: 'full_time', start: 7, end: 17));
    expect(p.hourlyRate, 31250);
    expect(p.grossAmount, 312500);
  });
  test('Photo Sunday public holiday pays three times for PT and FT', () async {
    expect(
      (await calculate(
        photoInput(date: '2026-10-04', holiday: true),
      )).grossAmount,
      75000,
    );
    expect(
      (await calculate(
        photoInput(role: 'full_time', date: '2026-10-04', holiday: true),
      )).grossAmount,
      93750,
    );
  });
  test(
    'FT monthly basis changes never affect PT payroll completeness',
    () async {
      for (final role in ['part_timer', 'full_time']) {
        final data = photoInput(role: role);
        data['staff'][0]['pay_policies'].add({
          'effective_from': '2026-10-10',
          'monthly_salary': 6500000,
          'standard_monthly_minutes': 12000,
        });
        expect((await calculate(data)).basisComplete, role == 'part_timer');
      }
    },
  );
}
