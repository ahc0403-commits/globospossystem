import 'package:excel/excel.dart';
import 'fixtures/sales_invoice_fixture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/payments/payment_total_calculator.dart';
import 'package:globos_pos_system/features/admin/einvoice_misa_workbook.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/combined_sales_export.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export.dart';

void main() {
  for (final food in [295000, 218000]) {
    test('charges wet-tissue VAT on the $food example', () {
      final quote = calculatePaymentQuote(
        vatPricingMode: 'exclusive',
        serviceChargeEnabled: false,
        serviceChargeRate: 0,
        lines: [
          PaymentQuoteLine(
            unitPrice: food.toDouble(),
            quantity: 1,
            status: 'served',
            itemType: 'menu_item',
          ),
          const PaymentQuoteLine(
            unitPrice: 2000,
            quantity: 2,
            status: 'ready',
            itemType: 'wet_tissue_charge',
          ),
          const PaymentQuoteLine(
            unitPrice: 59000,
            quantity: 1,
            status: 'served',
            itemType: 'menu_item',
            isServiceItem: true,
          ),
        ],
      );
      expect(quote.fixedChargeTotal, 4320);
      expect(quote.vatTotal, food * .08 + 320);
      expect(quote.payableTotal, food == 295000 ? 322920 : 239760);
    });
  }
  test('inclusive wet-tissue pricing extracts VAT without adding it twice', () {
    final amounts = wetTissueAmounts(
      unitPrice: 2000,
      quantity: 2,
      vatPricingMode: 'inclusive',
    );
    expect(amounts, (supply: 3703.70, vat: 296.30, total: 4000.0));
  });
  test('discounts reduce food VAT and leave wet-tissue VAT intact', () {
    final quote = calculatePaymentQuote(
      vatPricingMode: 'exclusive',
      serviceChargeEnabled: true,
      serviceChargeRate: 10,
      discountTotal: 10800,
      lines: const [
        PaymentQuoteLine(
          unitPrice: 100000,
          quantity: 1,
          status: 'served',
          itemType: 'menu_item',
        ),
        PaymentQuoteLine(
          unitPrice: 2000,
          quantity: 2,
          vatRate: 8,
          payingAmountIncTax: 4320,
          status: 'ready',
          itemType: 'wet_tissue_charge',
        ),
      ],
    );
    expect(quote.discountTotal, 10800);
    expect(quote.vatTotal, 7200 + 800 + 320);
    expect(quote.payableTotal, 97200 + 10800 + 4320);
  });
  for (final combined in [false, true]) {
    List<int> build(RestaurantSalesExport export) => combined
        ? buildCombinedSalesWorkbook(
            combineSalesExportsByTaxEntity(
              restaurantExports: [export],
              photoExports: [],
            ).single,
          )
        : buildRestaurantSalesWorkbook(export);
    test('blocks historical untaxed tissues, combined=$combined', () {
      final export = _export([
        _line(295000, 8),
        _line(4000, 0, type: 'wet_tissue_charge'),
      ]);
      expect(export.isReadyForDownload, isFalse);
      expect(
        export.receipts.single.issues,
        contains('WET_TISSUE_VAT_MISMATCH'),
      );
      expect(() => build(export), throwsFormatException);
    });
    test('blocks inconsistent historical VAT, combined=$combined', () {
      final line = _line(299000, 8)..['vat_amount'] = 23600;
      final export = _export([line]);
      expect(export.receipts.single.issues, contains('VAT_AMOUNT_MISMATCH'));
      expect(export.isReadyForDownload, isFalse);
      expect(() => build(export), throwsFormatException);
      expect(export.receipts.single.lineItems.single.vatAmount, 23600);
    });
    test(
      'exports a balanced half-dong allocation with source audit, combined=$combined',
      () {
        final amounts = <(double, double)>[
          (9187.48, 735),
          (15006.21, 1200.50),
          (15006.21, 1200.50),
          (17456.21, 1396.50),
          (18068.71, 1445.50),
          (18987.45, 1519),
          (21131.20, 1690.50),
          (21131.20, 1690.50),
          (24193.69, 1935.50),
          (38587.41, 3086.99),
        ];
        final source = [
          for (final (supply, vat) in amounts)
            _line(supply, 8)..['vat_amount'] = vat,
        ];
        final export = _export(source);
        expect(export.isReadyForDownload, isTrue);
        final book = Excel.decodeBytes(build(export));
        final rows = book.tables['Hóa đơn GTGT']!.rows.skip(8).toList();
        final audit = book.tables['Invoice Mapping']!.rows.skip(1).toList();
        expect(rows, hasLength(amounts.length));
        for (var i = 0; i < rows.length; i++) {
          final supply = _value(rows[i], 14), vat = _value(rows[i], 16);
          expect(isMisaVatConsistent(supply, 8, vat), isTrue);
          expect(
            supply + vat,
            closeTo(amounts[i].$1 + amounts[i].$2, 0.000001),
          );
          expect(_value(audit[i], 13), amounts[i].$1);
          expect(_value(audit[i], 14), amounts[i].$2);
          expect(_value(audit[i], 15), closeTo(vat - amounts[i].$2, 0.000001));
        }
        expect(
          rows.fold<double>(0, (n, r) => n + _value(r, 14)),
          closeTo(198755.77, 0.000001),
        );
        expect(
          rows.fold<double>(0, (n, r) => n + _value(r, 16)),
          closeTo(15900.49, 0.000001),
        );
        expect(export.receipts.single.lineItems[1].vatAmount, 1200.50);
      },
    );
    test(
      'blocks a boundary mismatch that cannot preserve totals, combined=$combined',
      () {
        final export = _export([_line(15006.21, 8)..['vat_amount'] = 1200.50]);
        expect(export.isReadyForDownload, isFalse);
        expect(() => build(export), throwsFormatException);
      },
    );
    test('blocks a paid amount mismatch, combined=$combined', () {
      final export = _export([_line(100, 8)], paidGross: 110);
      expect(export.receipts.single.issues, contains('AMOUNT_MISMATCH'));
      expect(export.isReadyForDownload, isFalse);
      expect(() => build(export), throwsFormatException);
    });
    test(
      'retains actual rates and net discounted bases, combined=$combined',
      () {
        final discounted = _line(80000, 8)..['unit_price'] = 100000;
        final export = _export([
          discounted,
          _line(50000, 10),
          _line(4000, 8, type: 'wet_tissue_charge'),
        ]);
        final rows = Excel.decodeBytes(
          build(export),
        ).tables['Hóa đơn GTGT']!.rows.skip(8).toList();
        expect(rows, hasLength(3));
        expect(rows.map((r) => _value(r, 0)).toSet(), {1});
        expect(rows.map((r) => _value(r, 15)).toSet(), {8, 10});
        expect(rows.fold<double>(0, (sum, r) => sum + _value(r, 14)), 134000);
        expect(rows.fold<double>(0, (sum, r) => sum + _value(r, 16)), 11720);
        for (final row in rows) {
          expect(_value(row, 14) * _value(row, 15) / 100, _value(row, 16));
        }
      },
    );
    test('blocks inconsistent same-rate VAT totals, combined=$combined', () {
      final export = _export(
        List.generate(4, (_) => _line(10, 8)..['vat_amount'] = 1.3),
      );
      expect(export.isReadyForDownload, isFalse);
      expect(export.receipts.single.issues, contains('VAT_SUMMARY_MISMATCH'));
      expect(() => build(export), throwsFormatException);
    });
  }
  test('pending workbook blocks invalid original arithmetic', () {
    expect(
      () => buildMisaPendingInvoiceWorkbook([
        {
          'source_system': 'restaurant_pos',
          'payment_method_snapshot': 'TM',
          'line_items_snapshot': [_line(299000, 8)..['vat_amount'] = 23600],
        },
      ]),
      throwsFormatException,
    );
  });
}

double _value(List<Data?> row, int column) =>
    double.parse(row[column]!.value.toString());
var _fixtureLineNo = 0;
Map<String, dynamic> _line(
  double supply,
  double rate, {
  String type = 'menu_item',
}) => {
  'order_item_id': 'line-${_fixtureLineNo++}',
  'menu_item_id': type == 'wet_tissue_charge' ? null : 'menu',
  'invoice_name_vi': 'Food',
  'misa_unit_name': type == 'wet_tissue_charge' ? 'Cái' : 'Phần',
  'display_name': 'Food',
  'item_type': type,
  'quantity': 1,
  'unit_price': supply,
  'total_amount_ex_tax': supply,
  'vat_rate': rate,
  'vat_amount': supply * rate / 100,
};
RestaurantSalesExport _export(
  List<Map<String, dynamic>> lines, {
  double? paidGross,
}) {
  final lineGross = lines.fold<double>(
    0,
    (sum, l) =>
        sum + (l['total_amount_ex_tax'] as num) + (l['vat_amount'] as num),
  );
  final gross = paidGross ?? lineGross;
  return createRestaurantSalesExport({
    'business_date': '2026-09-05',
    'status': 'finalized',
    'tax_entity_id': 'seller',
    'seller_tax_code': 'TAX',
    'seller_legal_name': 'Seller',
    'store_count': 1,
    'receipt_count': 1,
    'gross_sales': gross,
    'finalized_at': '2026-09-05T22:20:00+07:00',
    'receipts': [
      {
        'receipt_id': 'receipt',
        'store_id': 'store',
        'store_name': 'Store',
        'gross_sales': gross,
        'sold_at': '2026-09-05T20:00:00+07:00',
        'payment_method': 'CASH',
        'line_items': [
          for (final l in lines) approvedSalesFixtureLine(l, storeId: 'store'),
        ],
      },
    ],
  });
}
