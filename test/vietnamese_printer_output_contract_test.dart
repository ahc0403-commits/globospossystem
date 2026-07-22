import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('DB print queue forces every physical ticket label to Vietnamese', () {
    final migration = _read(
      'supabase/migrations/20260722100000_vietnamese_only_printer_output.sql',
    );
    final translatedRows = RegExp(
      r"\('[0-9a-f-]{36}', '8bc9eef5-dcd5-46b1-b931-23f77132322c', '",
    ).allMatches(migration);

    expect(translatedRows.length, 99);
    expect(
      migration,
      contains('CREATE TRIGGER force_print_job_menu_labels_vi'),
    );
    expect(migration, contains("btrim(menu.name_vi) !~ '[가-힣]'"));
    expect(migration, contains("ELSE 'Món'"));
    expect(migration, contains("status IN ('pending', 'failed')"));
    expect(migration, isNot(contains("THEN btrim(menu.name)")));
  });

  test(
    'native payment receipt reads Vietnamese names without Korean fallback',
    () {
      final provider = _read('lib/features/payment/payment_provider.dart');
      final service = _read('lib/core/services/payment_service.dart');
      final screen = _read('lib/features/payment/payment_detail_screen.dart');
      final receiptItemsBody = RegExp(
        r'List<ReceiptItem> _receiptItems\([\s\S]*?\n  \}',
      ).firstMatch(screen)?.group(0);

      expect(provider, contains('menu_items(name, name_vi, vat_category)'));
      expect(service, contains('menu_items(name, name_vi)'));
      expect(receiptItemsBody, isNotNull);
      expect(receiptItemsBody, contains("menuItem['name_vi']"));
      expect(receiptItemsBody, contains("RegExp(r'[\\uac00-\\ud7a3]')"));
      expect(receiptItemsBody, contains("'Món'"));
      expect(receiptItemsBody, isNot(contains("item['label']")));
      expect(receiptItemsBody, isNot(contains("menuItem['name']")));
    },
  );

  test('production deploy runs dedicated preflight and verification', () {
    final deploy = _read('scripts/deploy_pos_production.sh');
    final preflight = _read('scripts/preflight_vietnamese_printer_output.sql');
    final verification = _read('scripts/verify_vietnamese_printer_output.sql');

    expect(
      deploy,
      contains('20260722100000_vietnamese_only_printer_output.sql'),
    );
    expect(deploy, contains('preflight_vietnamese_printer_output.sql'));
    expect(deploy, contains('verify_vietnamese_printer_output.sql'));
    expect(preflight, contains('VIETNAMESE_PRINTER_PREFLIGHT_STORE_MISSING'));
    expect(
      verification,
      contains('VIETNAMESE_PRINTER_VERIFY_TRANSLATIONS_INCOMPLETE'),
    );
  });
}
