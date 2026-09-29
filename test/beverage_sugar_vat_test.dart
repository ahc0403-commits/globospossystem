import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/payments/beverage_tax.dart';
import 'package:globos_pos_system/core/payments/payment_total_calculator.dart';
import 'package:globos_pos_system/core/payments/vat_allocation.dart';
import 'package:globos_pos_system/features/admin/menu_import/menu_excel_import.dart';
import 'package:globos_pos_system/features/admin/menu_import/menu_excel_roundtrip.dart';
import 'package:globos_pos_system/features/admin/widgets/beverage_tax_editor.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

void main() {
  test('label boundary is strictly greater than 5 and unknown is not zero', () {
    for (final grams in [0.0, 4.99, 5.0, 5.01]) {
      final tax = BeverageTax(
        sugarClass: grams > 5 ? 'gt_5' : 'lte_5',
        sugarGrams: grams,
      );
      expect(tax.isValid, isTrue);
      expect(tax.vatRate(), grams > 5 ? 10 : 8);
    }
    expect(const BeverageTax(sugarClass: 'gt_5').isValid, isFalse);
    expect(
      const BeverageTax(
        sugarClass: 'gt_5',
        basisNote: 'Confirmed product label',
      ).isValid,
      isTrue,
    );
    expect(
      const BeverageTax(sugarClass: 'gt_5', sugarGrams: 5).isValid,
      isFalse,
    );
    expect(
      const BeverageTax(sugarClass: 'lte_5', sugarGrams: -1).isValid,
      isFalse,
    );
    expect(
      const BeverageTax(sugarClass: 'lte_5', sugarGrams: double.nan).isValid,
      isFalse,
    );
  });

  test('food-classified high sugar drink uses its persisted 10% snapshot', () {
    final result = calculatePaymentQuote(
      lines: [
        const PaymentQuoteLine(
          unitPrice: 100000,
          quantity: 1,
          status: 'served',
          itemType: 'menu_item',
          vatCategory: 'food',
          vatRate: 8,
        ),
        const PaymentQuoteLine(
          unitPrice: 100000,
          quantity: 1,
          status: 'served',
          itemType: 'menu_item',
          vatCategory: 'food',
          vatRate: 10,
        ),
      ],
      vatPricingMode: 'exclusive',
      serviceChargeEnabled: true,
      serviceChargeRate: 5,
    );
    expect(result.payableTotal, 228900);
    expect(result.vatTotal, 18900);
    expect(result.serviceChargeTotal, 10900);
  });

  test(
    'mixed combo VAT, discount and service charge match server fixtures',
    () {
      const profile = [
        {'rate': 8, 'weight': 100000},
        {'rate': 10, 'weight': 100000},
      ];
      final result = calculatePaymentQuote(
        lines: [
          const PaymentQuoteLine(
            id: 'combo',
            unitPrice: 200000,
            quantity: 1,
            status: 'served',
            itemType: 'menu_item',
            vatRate: -1,
            vatProfile: profile,
            discountAmount: 21800,
          ),
        ],
        vatPricingMode: 'exclusive',
        serviceChargeEnabled: false,
        serviceChargeRate: 0,
      );
      expect(result.payableTotal, 196200);
      expect(result.vatTotal, 16200);
      final included = calculateItemVat(
        profile: const [
          {'rate': 8, 'weight': 108000},
          {'rate': 10, 'weight': 110000},
        ],
        amount: 218000,
        pricingMode: 'inclusive',
      );
      expect(included.fold<double>(0, (sum, p) => sum + p.supply), 200000);
      expect(included.fold<double>(0, (sum, p) => sum + p.vat), 18000);
    },
  );

  test('cent remainders conserve total and use stable rate order', () {
    expect(allocateVatCents(5, [1, 1]), [3, 2]);
    expect(allocateVatCents(10000000001, [10000000000, 10000000000]), [
      5000000001,
      5000000000,
    ]);
    expect(
      calculateItemVat(
        profile: const [
          {'rate': 10, 'weight': 1},
        ],
        amount: 0.35,
        pricingMode: 'exclusive',
      ).single.vat,
      0.04,
    );
    for (var cents = 0; cents < 400; cents++) {
      final parts = calculateItemVat(
        profile: const [
          {'rate': 8, 'weight': 59000},
          {'rate': 10, 'weight': 18000},
        ],
        amount: cents / 100,
        pricingMode: 'inclusive',
        discount: cents / 300,
      );
      expect(
        (parts.fold<double>(0, (sum, p) => sum + p.total) * 100).round(),
        cents - (cents / 3).round(),
      );
    }
  });

  test(
    'old Excel omits tax mutation and inconsistent new columns are rejected',
    () {
      final issues = <String>[];
      expect(parseBeverageTaxExcelRow({}, (_) => '', 2, issues), isNull);
      expect(issues, isEmpty);
      final values = {'음료당류분류': 'gt_5', '총당류(g/100ml)': '5', '세금분류근거': 'label'};
      expect(
        parseBeverageTaxExcelRow(
          {for (final key in values.keys) key: 0},
          (key) => values[key]!,
          2,
          issues,
        ),
        isNull,
      );
      expect(issues, hasLength(1));
    },
  );

  testWidgets('typing sugar selects the band and preserves entered basis', (
    tester,
  ) async {
    var tax = const BeverageTax(sugarClass: 'lte_5');
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => BeverageTaxEditor(
              value: tax,
              onChanged: (value) => setState(() => tax = value),
            ),
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('menu_tax_basis')),
      'Bottle label',
    );
    await tester.enterText(find.byKey(const Key('menu_sugar_grams')), '5.01');
    await tester.pump();
    expect(tax.sugarClass, 'gt_5');
    expect(tax.basisNote, 'Bottle label');
    expect(find.text('VAT 10%'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('menu_sugar_grams')), '5');
    await tester.pump();
    expect(tax.sugarClass, 'lte_5');
    expect(find.text('VAT 8%'), findsOneWidget);
  });

  test(
    'Excel export and reimport retain both measured and confirmed tax bands',
    () {
      const store = '11111111-1111-4111-8111-111111111111';
      const category = '22222222-2222-4222-8222-222222222222';
      final taxes = [
        const BeverageTax(
          sugarClass: 'gt_5',
          sugarGrams: 5.01,
          basisNote: 'Label',
        ),
        const BeverageTax(sugarClass: 'lte_5', basisNote: 'Confirmed SKU'),
      ];
      final bytes = buildMenuRoundTripWorkbook(
        storeId: store,
        categories: [
          {'id': category, 'name': 'Drinks'},
        ],
        items: [
          for (var i = 0; i < taxes.length; i++)
            {
              'id': '33333333-3333-4333-8333-33333333333$i',
              'category_id': category,
              'name': 'Drink $i',
              'price': 18000,
              ...taxes[i].toJson(),
            },
        ],
      );
      final parsed = tryParseMenuRoundTripWorkbook(Uint8List.fromList(bytes))!;
      expect(
        parsed.items.map((item) => item.beverageTax!.toJson()),
        taxes.map((tax) => tax.toJson()),
      );
    },
  );
}
