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

  test('service forwards required invoice delivery contact fields', () {
    final source = readRepoFile('lib/core/services/einvoice_service.dart');

    expect(source, contains('required String buyerTaxCode'));
    expect(source, contains('required String buyerLegalName'));
    expect(source, contains('required String buyerAddress'));
    expect(source, contains('required String buyerEmail'));
    expect(source, contains('required String buyerPhone'));
    expect(source, contains('redInvoiceIntakeService.save('));
    expect(source, isNot(contains('buyerUnitCode:')));
    expect(source, isNot(contains('buyerFullName:')));
    expect(source, isNot(contains('buyerId:')));
    expect(source, contains('buyerEmail:'));
    expect(source, contains('buyerPhone:'));
    expect(source, isNot(contains("'request_red_invoice'")));
    expect(source, isNot(contains('lookupCompanyByTaxCode')));
    expect(source, isNot(contains('wetax-onboarding')));
  });

  test(
    'cashier red invoice modal captures delivery email and contact phone',
    () {
      final source = readRepoFile(
        'lib/features/cashier/red_invoice_modal.dart',
      );

      expect(source, contains('BuyerInformationFields('));
      expect(source, contains('controller: _buyer'));
      expect(source, contains('storeId: widget.storeId'));
      expect(source, isNot(contains('_unitCodeCtrl')));
      expect(source, isNot(contains('_buyerFullNameCtrl')));
      expect(source, isNot(contains('_buyerIdCtrl')));
      final fields = readRepoFile(
        'lib/features/red_invoice_intake/buyer_information_form.dart',
      );
      for (final key in [
        'buyer_number_value',
        'buyer_legal_name',
        'buyer_address',
        'buyer_phone',
        'buyer_email',
      ]) {
        expect(fields, contains(key));
      }
      expect(fields, contains('TextInputType.emailAddress'));
      expect(fields, contains('TextInputType.phone'));
      expect(source, contains('saveBuyerInformation'));
      expect(fields, contains('buyer_unit_code'));
      expect(fields, contains('buyer_full_name'));
      expect(fields, contains('buyer_email_cc'));
      expect(fields, contains('buyer_id'));
      expect(source, contains('SingleChildScrollView'));
      expect(source, isNot(contains('lookupCompanyByTaxCode')));
      expect(source, isNot(contains('_BuyerLookupState.wt09Hit')));
    },
  );

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
