import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/photo_sales_import/photo_sales_registered_export.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/combined_sales_export.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export.dart';

void main() {
  test('combines Restaurant and Photo sales only inside one tax entity', () {
    final combined = combineSalesExportsByTaxEntity(
      restaurantExports: [_restaurantExport()],
      photoExports: [_photoExport()],
    );

    expect(combined, hasLength(1));
    expect(combined.single.receiptCount, 2);
    expect(combined.single.restaurantReceiptCount, 1);
    expect(combined.single.photoReceiptCount, 1);
    expect(combined.single.grossSales, 162000);
    expect(combined.single.supplyAmount, 150000);
    expect(combined.single.vatAmount, 12000);

    final workbook = Excel.decodeBytes(
      buildCombinedSalesWorkbook(combined.single),
    );
    final rows = workbook.tables['Hóa đơn GTGT']!.rows;
    expect(rows, hasLength(10));
    expect(_cell(rows[8], 0), '1');
    expect(_cell(rows[8], 10), 'Dịch vụ ăn uống');
    expect(_cell(rows[8], 11), 'Lần');
    expect(_cell(rows[8], 14), '100000');
    expect(_cell(rows[8], 16), '8000');
    expect(_cell(rows[9], 0), '2');
    expect(_cell(rows[9], 10), 'Dịch vụ chụp ảnh');
    expect(_cell(rows[9], 11), 'Lần');
    expect(_cell(rows[9], 14), '50000');
    expect(_cell(rows[9], 16), '4000');
  });

  test('preserves the existing Restaurant red-invoice MISA columns', () {
    final restaurant = _restaurantExport(
      receipt: _restaurantReceipt(
        isRedInvoice: true,
        buyerTaxCode: '0312345678',
        buyerLegalName: 'BUYER COMPANY',
        buyerAddress: 'Ho Chi Minh City',
        buyerEmail: 'buyer@example.com',
        buyerPhone: '0900000000',
      ),
    );
    final combined = combineSalesExportsByTaxEntity(
      restaurantExports: [restaurant],
      photoExports: const [],
    ).single;
    final rows = Excel.decodeBytes(
      buildCombinedSalesWorkbook(combined),
    ).tables['Hóa đơn GTGT']!.rows;

    expect(_cell(rows[8], 2), 'BUYER COMPANY');
    expect(_cell(rows[8], 3), '0312345678');
    expect(_cell(rows[8], 5), isEmpty);
    expect(_cell(rows[8], 11), 'Lần');
    expect(_cell(rows[8], 15), '8');
  });

  test('keeps different seller tax entities in different workbooks', () {
    final combined = combineSalesExportsByTaxEntity(
      restaurantExports: [_restaurantExport()],
      photoExports: [
        _photoExport(
          taxEntityId: 'photo-entity',
          sellerTaxCode: 'PHOTO-TAX',
          sellerLegalName: 'PHOTO COMPANY',
        ),
      ],
    );

    expect(combined, hasLength(2));
    expect(combined.map((export) => export.taxEntityId).toSet(), {
      'entity-production',
      'photo-entity',
    });
    expect(combined.every((export) => export.receiptCount == 1), isTrue);
  });

  test('keeps Photo sales downloadable when Restaurant has no rows', () {
    final combined = combineSalesExportsByTaxEntity(
      restaurantExports: const [],
      photoExports: [_photoExport()],
    );

    expect(combined, hasLength(1));
    expect(combined.single.restaurantReceiptCount, 0);
    expect(combined.single.photoReceiptCount, 1);
    expect(combined.single.isReadyForDownload, isTrue);
    expect(buildCombinedSalesWorkbook(combined.single), isNotEmpty);
  });

  test('validates the registered Photo export response before MISA use', () {
    final exports = createPhotoSalesRegisteredExports({
      'business_date': '2026-09-02',
      'entity_count': 1,
      'entities': [
        {
          'tax_entity_id': 'entity-production',
          'seller_tax_code': '0318453298',
          'seller_legal_name': 'AKJ INTERNATIONAL',
          'store_count': 1,
          'receipt_count': 1,
          'gross_sales': 54000,
          'receipts': [
            {
              'source_hash': 'photo-hash',
              'store_id': 'photo-store',
              'store_name': 'PHOTO OBJET BIEN HOA',
              'device_name': 'BH-1',
              'sold_at': '2026-09-02T11:00:00+07:00',
              'amount': 54000,
            },
          ],
        },
      ],
    });

    expect(exports.single.receiptCount, 1);
    expect(exports.single.supplyAmount, 50000);
    expect(exports.single.vatAmount, 4000);

    final altered = {
      'business_date': '2026-09-02',
      'entity_count': 1,
      'entities': [
        {
          'tax_entity_id': 'entity-production',
          'seller_tax_code': '0318453298',
          'seller_legal_name': 'AKJ INTERNATIONAL',
          'store_count': 1,
          'receipt_count': 1,
          'gross_sales': 1,
          'receipts': [
            {
              'source_hash': 'photo-hash',
              'store_id': 'photo-store',
              'store_name': 'PHOTO OBJET BIEN HOA',
              'device_name': 'BH-1',
              'sold_at': '2026-09-02T11:00:00+07:00',
              'amount': 54000,
            },
          ],
        },
      ],
    };
    expect(
      () => createPhotoSalesRegisteredExports(altered),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'PHOTO_SALES_EXPORT_GROSS_SALES_MISMATCH',
        ),
      ),
    );
  });
}

RestaurantSalesExport _restaurantExport({RestaurantSalesReceipt? receipt}) =>
    RestaurantSalesExport(
      businessDate: '2026-09-02',
      taxEntityId: 'entity-production',
      sellerTaxCode: '0318453298',
      sellerLegalName: 'AKJ INTERNATIONAL',
      isSampleEntity: false,
      storeCount: 1,
      receiptCount: 1,
      grossSales: 108000,
      finalizedAt: DateTime.parse('2026-09-02T22:20:00+07:00'),
      receipts: [receipt ?? _restaurantReceipt()],
    );

RestaurantSalesReceipt _restaurantReceipt({
  bool isRedInvoice = false,
  String buyerTaxCode = '',
  String buyerLegalName = '',
  String buyerAddress = '',
  String buyerEmail = '',
  String buyerPhone = '',
}) => RestaurantSalesReceipt(
  storeId: 'restaurant-store',
  storeName: 'Restaurant A',
  receiptId: 'restaurant-receipt',
  receiptSource: 'pos_payment',
  salesChannel: 'dine_in',
  grossSales: 108000,
  soldAt: DateTime.parse('2026-09-02T10:00:00+07:00'),
  paymentMethod: 'cash',
  isRedInvoice: isRedInvoice,
  buyerTaxCode: buyerTaxCode,
  buyerLegalName: buyerLegalName,
  buyerAddress: buyerAddress,
  buyerEmail: buyerEmail,
  buyerPhone: buyerPhone,
  lineItems: const [
    RestaurantSalesLineItem(
      name: 'Food',
      quantity: 1,
      unitPrice: 100000,
      supplyAmount: 100000,
      vatRate: 8,
      vatAmount: 8000,
    ),
  ],
  issues: const [],
);

PhotoSalesRegisteredExport _photoExport({
  String taxEntityId = 'entity-production',
  String sellerTaxCode = '0318453298',
  String sellerLegalName = 'AKJ INTERNATIONAL',
}) => PhotoSalesRegisteredExport(
  businessDate: '2026-09-02',
  taxEntityId: taxEntityId,
  sellerTaxCode: sellerTaxCode,
  sellerLegalName: sellerLegalName,
  storeCount: 1,
  receiptCount: 1,
  grossSales: 54000,
  receipts: [
    PhotoSalesRegisteredReceipt(
      sourceHash: 'photo-hash',
      storeId: 'photo-store',
      storeName: 'PHOTO OBJET BIEN HOA',
      deviceName: 'BH-1',
      soldAt: DateTime.parse('2026-09-02T11:00:00+07:00'),
      amount: 54000,
    ),
  ],
);

String _cell(List<Data?> row, int index) => row[index]?.value.toString() ?? '';
