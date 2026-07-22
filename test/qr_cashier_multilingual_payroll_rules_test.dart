import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/payroll_service.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test(
    'QR completion, two-print routing, and multilingual contracts are wired',
    () {
      final migration = _read(
        'supabase/migrations/20260722060000_qr_cashier_multilingual_payroll_rules.sql',
      );
      final qrScreen = _read('lib/features/qr_order/qr_order_screen.dart');
      final menuTab = _read('lib/features/admin/tabs/menu_tab.dart');
      final kitchen = _read('lib/features/kitchen/kitchen_screen.dart');
      final deploy = _read('scripts/deploy_pos_production.sh');

      expect(migration, contains("NEW.status := 'ready'"));
      expect(migration, contains("NEW.copy_type = 'floor'"));
      expect(
        migration,
        contains(
          'public.vietnam_public_holidays FROM PUBLIC, anon, authenticated',
        ),
      );
      expect(migration, contains('admin_create_menu_category_i18n'));
      expect(migration, contains('admin_create_menu_item_i18n'));
      expect(migration, contains("'name_vi'"));
      expect(migration, contains("'name_en'"));
      expect(qrScreen, contains("String _languageCode = 'vi'"));
      expect(qrScreen, contains("Key('qr_language_selector')"));
      expect(menuTab, contains("Key('admin_menu_item_name_ko')"));
      expect(menuTab, contains("Key('admin_menu_item_name_vi')"));
      expect(menuTab, contains("Key('admin_menu_item_name_en')"));
      expect(kitchen, contains("Key('kitchen_paused_screen')"));
      expect(kitchen, contains('class KitchenOperationalScreen'));
      expect(
        deploy,
        contains('20260722060000_qr_cashier_multilingual_payroll_rules.sql'),
      );
      expect(
        deploy,
        contains('preflight_qr_cashier_multilingual_payroll_rules.sql'),
      );
      expect(
        deploy,
        contains('verify_qr_cashier_multilingual_payroll_rules.sql'),
      );
    },
  );

  test('hourly rules stack night and holiday premiums and exclude Sunday', () {
    final service = PayrollService();
    final holiday = DateTime(2026, 9, 2);
    final holidayNight = service.calcRuleBasedHourlyAmount(
      clockIn: DateTime(2026, 9, 2, 22),
      clockOut: DateTime(2026, 9, 2, 23),
      hourlyRate: 100,
      nightStartMinute: 22 * 60,
      nightMultiplier: 1.3,
      holidayMultiplier: 3,
      excludeSunday: true,
      holidays: {holiday},
    );
    expect(holidayNight.amount, 390);
    expect(holidayNight.nightHours, 1);
    expect(holidayNight.holidayHours, 1);

    final sunday = DateTime(2026, 4, 26);
    final sundayNight = service.calcRuleBasedHourlyAmount(
      clockIn: DateTime(2026, 4, 26, 22),
      clockOut: DateTime(2026, 4, 26, 23),
      hourlyRate: 100,
      nightStartMinute: 22 * 60,
      nightMultiplier: 1.3,
      holidayMultiplier: 3,
      excludeSunday: true,
      holidays: {sunday},
    );
    expect(sundayNight.amount, 130);
    expect(sundayNight.holidayHours, 0);
  });

  test('lateness threshold creates review amount without deducting wages', () {
    final payroll = StaffPayroll(
      userId: 'employee',
      userName: 'Employee',
      lateMinutes: 60,
      lateReviewAmount: 200,
      dailyRecords: [
        DailyRecord(
          userId: 'employee',
          userName: 'Employee',
          date: DateTime(2026, 7, 22),
          clockIn: DateTime(2026, 7, 22, 9),
          clockOut: DateTime(2026, 7, 22, 10),
          hours: 1,
          amount: 100,
          isUnpaired: false,
        ),
      ],
    );

    expect(payroll.grossAmount, 100);
    expect(payroll.totalAmount, 100);
    expect(payroll.lateReviewAmount, 200);
  });

  test('pay rules enforce statutory floor and official holiday calendar', () {
    final migration = _read(
      'supabase/migrations/20260722060000_qr_cashier_multilingual_payroll_rules.sql',
    );
    expect(migration, contains('holiday_multiplier >= 3'));
    expect(migration, contains('vietnam_public_holidays'));
    expect(migration, contains("'2026-09-02'"));
    expect(migration, contains('late_review_hourly_multiplier'));
    expect(migration, contains('clear_hourly_pay_rule_for_non_part_timer'));
    expect(migration, isNot(contains('late_penalty_hourly_multiplier')));
  });
}
