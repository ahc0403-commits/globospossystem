import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  const migrationPath =
      'supabase/migrations/20260630001000_meinvoice_buyer_fields.sql';

  test('buyer-field migration stores the MISA cash-register buyer fields', () {
    final sql = readRepoFile(migrationPath);

    expect(sql, contains('ADD COLUMN IF NOT EXISTS buyer_unit_code'));
    expect(sql, contains('ADD COLUMN IF NOT EXISTS buyer_full_name'));
    expect(sql, contains('ADD COLUMN IF NOT EXISTS buyer_id'));
    expect(sql, contains('ADD COLUMN IF NOT EXISTS buyer_phone'));
    expect(sql, contains('p_unit_code text DEFAULT NULL'));
    expect(sql, contains('p_unit_name text DEFAULT NULL'));
    expect(sql, contains('p_buyer_full_name text DEFAULT NULL'));
    expect(sql, contains('p_buyer_id text DEFAULT NULL'));
    expect(sql, contains("'tin_cic_household_head_id'"));
    expect(sql, contains("'unit_code'"));
    expect(sql, contains("'unit_name'"));
    expect(sql, contains("'buyer_full_name'"));
    expect(sql, contains("'buyer_id'"));
  });

  test('buyer cache lookup returns the extended fields to POS', () {
    final sql = readRepoFile(migrationPath);

    expect(sql, contains('CREATE OR REPLACE FUNCTION public.lookup_b2b_buyer'));
    expect(sql, contains("'buyer_unit_code', v_row.buyer_unit_code"));
    expect(sql, contains("'buyer_full_name'"));
    expect(sql, contains("'buyer_id', v_row.buyer_id"));
    expect(sql, contains("'buyer_phone', v_row.buyer_phone"));
  });

  test('service forwards extended buyer fields to red-invoice intake', () {
    final source = readRepoFile('lib/core/services/einvoice_service.dart');

    expect(source, contains('String? unitCode'));
    expect(source, contains('String? unitName'));
    expect(source, contains('String? buyerFullName'));
    expect(source, contains('String? buyerId'));
    expect(source, contains('redInvoiceIntakeService.save('));
    expect(source, contains('buyerUnitCode: unitCode'));
    expect(source, contains('buyerLegalName: unitName ?? buyerName'));
    expect(source, contains('buyerFullName: buyerFullName'));
    expect(source, contains('buyerId: buyerId'));
    expect(source, isNot(contains("'request_red_invoice'")));
    expect(source, isNot(contains('lookupCompanyByTaxCode')));
    expect(source, isNot(contains('wetax-onboarding')));
  });

  test('cashier red invoice modal captures MISA buyer fields manually', () {
    final source = readRepoFile('lib/features/cashier/red_invoice_modal.dart');

    expect(source, contains('_unitCodeCtrl'));
    expect(source, contains('_buyerFullNameCtrl'));
    expect(source, contains('_phoneCtrl'));
    expect(source, contains('_buyerIdCtrl'));
    expect(source, contains('unitCode: _unitCodeCtrl.text.trim()'));
    expect(source, contains('unitName: _companyCtrl.text.trim()'));
    expect(source, contains('buyerFullName: _buyerFullNameCtrl.text.trim()'));
    expect(source, contains('buyerTel: _phoneCtrl.text.trim()'));
    expect(source, contains('buyerId: _buyerIdCtrl.text.trim()'));
    expect(source, contains('SingleChildScrollView'));
    expect(source, isNot(contains('lookupCompanyByTaxCode')));
    expect(source, isNot(contains('_BuyerLookupState.wt09Hit')));
  });

  test('localized labels expose the extended MISA buyer fields', () {
    final en = readRepoFile('lib/l10n/app_en.arb');
    final ko = readRepoFile('lib/l10n/app_ko.arb');
    final vi = readRepoFile('lib/l10n/app_vi.arb');

    for (final source in [en, ko, vi]) {
      expect(source, contains('redInvoiceUnitCode'));
      expect(source, contains('redInvoiceBuyerFullName'));
      expect(source, contains('redInvoicePhone'));
      expect(source, contains('redInvoiceBuyerId'));
      expect(source, isNot(contains('WT09')));
    }
  });
}
