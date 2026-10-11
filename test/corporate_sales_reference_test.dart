import 'dart:convert';
import 'dart:io';
import 'fixtures/sales_invoice_fixture.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export.dart';

void main() {
  test('real Dart workbooks retain contacts and every payment combination', () {
    final methods =
        (jsonDecode(
                  File(
                    'test/fixtures/invoice_payment_contract.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>)['methods']
            as Map<String, dynamic>;
    final keys = methods.keys.toList()..sort();
    final groups = <List<String>>[
      for (final key in keys) [key],
      for (var i = 0; i < keys.length; i++)
        for (var j = i + 1; j < keys.length; j++) [keys[i], keys[j]],
    ];
    final contacts = [
      {'email': 'fixture@example.com', 'phone': '0123456789'},
      {'email': 'fixture@example.com', 'phone': ''},
      {'email': '', 'phone': '0123456789'},
      {'email': '', 'phone': ''},
    ];
    final output = Platform.environment['GLOBOS_CONTACT_PAYMENT_OUTPUT'];
    if (output != null) Directory(output).createSync(recursive: true);
    final cases = <Map<String, Object?>>[];
    for (var index = 0; index < groups.length; index++) {
      final group = groups[index];
      final contact = contacts[index % contacts.length];
      final labels =
          group.map((m) => methods[m]['label'] as String).toSet().toList()
            ..sort();
      final label =
          group.length == 2 &&
              group.contains('CASH') &&
              group.contains('BANKTRANSFER')
          ? 'TM/CK'
          : labels.join('/');
      final payload =
          jsonDecode(
                File(
                  'test/fixtures/corporate_sales_reference.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final raw = (payload['receipts'] as List).single as Map<String, dynamic>;
      raw.addAll({
        'payment_methods': group,
        'payment_method': label,
        'payment_code': group.length > 1
            ? 'MIXED'
            : methods[group.single]['code'],
        'is_red_invoice': false,
        'buyer_email': contact['email'],
        'buyer_phone': contact['phone'],
      });
      final export = _fixtureExport(payload);
      expect(export.isReadyForDownload, isTrue, reason: group.toString());
      final bytes = buildRestaurantSalesWorkbook(export);
      final book = Excel.decodeBytes(bytes);
      final rows = book.tables['Hóa đơn GTGT']!.rows.skip(8).toList();
      expect(rows.length, 9);
      expect(
        rows
            .skip(1)
            .every((r) => r.sublist(1, 10).every((c) => c?.value == null)),
        isTrue,
      );
      expect(
        rows.take(1).every((r) => r[9]!.value.toString() == label),
        isTrue,
      );
      expect(
        rows
            .take(1)
            .every((r) => (r[6]?.value.toString() ?? '') == contact['email']),
        isTrue,
      );
      expect(
        rows
            .take(1)
            .every((r) => (r[7]?.value.toString() ?? '') == contact['phone']),
        isTrue,
      );
      expect(rows[0][15]!.value.toString(), '10');
      expect(rows[1][15]!.value.toString(), '8');
      final name = group.join('_');
      cases.add({
        'name': name,
        'email_target_count': contact['email']!.isEmpty ? 0 : 1,
      });
      if (output != null) {
        File('$output/$name.json').writeAsStringSync(jsonEncode(payload));
        File('$output/$name.xlsx').writeAsBytesSync(bytes);
      }
    }
    expect(cases.length, 91);
    if (output != null) {
      File('$output/cases.json').writeAsStringSync(jsonEncode(cases));
    }
  });
  test(
    'BC-20261008-023320 retains 9 lines, 10 units, all amounts and beverage VAT',
    () {
      final export = _fixtureExport(
        jsonDecode(
              File(
                'test/fixtures/corporate_sales_reference.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>,
      );
      final bytes = buildRestaurantSalesWorkbook(export);
      if (Platform.environment['GLOBOS_REFERENCE_OUTPUT'] case final output?) {
        File(output).writeAsBytesSync(bytes);
      }
      final book = Excel.decodeBytes(buildRestaurantSalesWorkbook(export));
      final rows = book.tables['Hóa đơn GTGT']!.rows.skip(8).toList();
      num n(int r, int c) => num.parse(rows[r][c]!.value.toString());
      expect(rows.length, 9);
      expect(
        rows
            .skip(1)
            .every((r) => r.sublist(1, 10).every((c) => c?.value == null)),
        isTrue,
      );
      expect(List.generate(9, (i) => n(i, 12)).reduce((a, b) => a + b), 10);
      expect(List.generate(9, (i) => n(i, 14)).reduce((a, b) => a + b), 406000);
      expect(List.generate(9, (i) => n(i, 16)).reduce((a, b) => a + b), 33560);
      expect(rows.take(1).every((r) => r[9]!.value.toString() == 'CK'), isTrue);
      expect(n(0, 15), 10);
      expect(n(1, 15), 8);
      final ledger = book.tables['POS Ledger']!.rows;
      expect(ledger.length, 10);
      expect(ledger[1][4]!.value.toString(), 'original-order-id');
      expect(ledger[1][5]!.value.toString(), 'BC-20261008-023320');
      expect(ledger[1][9]!.value.toString(), '9');
      expect(ledger[1][1]!.value.toString(), '2026-10-08');
      expect(ledger[1][2]!.value.toString(), 'akj');
    },
  );
}

RestaurantSalesExport _fixtureExport(Map<String, dynamic> p) =>
    createRestaurantSalesExport(approvedSalesFixturePayload(p));
