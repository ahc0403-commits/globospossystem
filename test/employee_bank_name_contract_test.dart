import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('employee bank name is wired from the form through persistence', () {
    final staffTab = File(
      'lib/features/admin/tabs/staff_tab.dart',
    ).readAsStringSync();
    final provider = File(
      'lib/features/admin/providers/staff_provider.dart',
    ).readAsStringSync();
    final service = File(
      'lib/core/services/staff_service.dart',
    ).readAsStringSync();
    final migration = File(
      'supabase/migrations/20260722040000_employee_bank_name.sql',
    ).readAsStringSync();
    final deploy = File('scripts/deploy_pos_production.sh').readAsStringSync();

    expect(staffTab, contains("Key('staff_employee_bank_name_field')"));
    expect(staffTab, contains('staffEmployeeBankName'));
    expect(staffTab, contains('bankName: _nullable(bankName.text)'));
    expect(provider, contains("bankName: json['bank_name']?.toString()"));
    expect(service, contains("'p_bank_name': bankName"));
    expect(migration, contains('ADD COLUMN IF NOT EXISTS bank_name text'));
    expect(migration, contains('NEW.bank_name IS DISTINCT FROM OLD.bank_name'));
    expect(migration, contains('e.bank_name'));
    expect(deploy, contains('20260722040000_employee_bank_name.sql'));
    expect(deploy, contains('preflight_employee_bank_name.sql'));
    expect(deploy, contains('verify_employee_bank_name.sql'));
  });

  test('employee bank name is localized in supported languages', () {
    final translations = {
      'lib/l10n/app_en.arb': 'Bank name',
      'lib/l10n/app_ko.arb': '은행이름',
      'lib/l10n/app_vi.arb': 'Tên ngân hàng',
    };

    for (final entry in translations.entries) {
      final arb = File(entry.key).readAsStringSync();
      expect(arb, contains('"staffEmployeeBankName": "${entry.value}"'));
    }
  });
}
