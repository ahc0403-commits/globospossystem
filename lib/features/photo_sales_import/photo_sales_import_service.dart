import '../../main.dart';
import 'photo_sales_import.dart';
import 'photo_sales_registered_export.dart';

class PhotoSalesRegistrationBranch {
  const PhotoSalesRegistrationBranch({
    required this.branchCode,
    required this.storeId,
    required this.storeName,
    required this.receiptCount,
    required this.totalAmount,
  });

  final String branchCode;
  final String storeId;
  final String storeName;
  final int receiptCount;
  final int totalAmount;

  factory PhotoSalesRegistrationBranch.fromJson(Map<String, dynamic> json) =>
      PhotoSalesRegistrationBranch(
        branchCode: json['branch_code']?.toString() ?? '',
        storeId: json['store_id']?.toString() ?? '',
        storeName: json['store_name']?.toString() ?? '',
        receiptCount: _intValue(json['receipt_count']),
        totalAmount: _intValue(json['total_amount']),
      );
}

class PhotoSalesRegistrationResult {
  const PhotoSalesRegistrationResult({
    required this.saleDate,
    required this.sourceRows,
    required this.insertedRows,
    required this.duplicateRows,
    required this.totalAmount,
    required this.branches,
  });

  final String saleDate;
  final int sourceRows;
  final int insertedRows;
  final int duplicateRows;
  final int totalAmount;
  final List<PhotoSalesRegistrationBranch> branches;

  factory PhotoSalesRegistrationResult.fromJson(Map<String, dynamic> json) {
    final rawBranches = json['branches'];
    return PhotoSalesRegistrationResult(
      saleDate: json['sale_date']?.toString() ?? '',
      sourceRows: _intValue(json['source_rows']),
      insertedRows: _intValue(json['inserted_rows']),
      duplicateRows: _intValue(json['duplicate_rows']),
      totalAmount: _intValue(json['total_amount']),
      branches: rawBranches is List
          ? rawBranches
                .whereType<Map>()
                .map(
                  (row) => PhotoSalesRegistrationBranch.fromJson(
                    Map<String, dynamic>.from(row),
                  ),
                )
                .toList(growable: false)
          : const [],
    );
  }
}

class PhotoSalesImportService {
  Future<PhotoSalesRegistrationResult> register({
    required PhotoSalesImportWorkbook workbook,
    required DateTime saleDate,
    required String sourceFileName,
  }) async {
    final response = await supabase.rpc(
      'import_photo_objet_sales_excel',
      params: {
        'p_sale_date': _dateText(saleDate),
        'p_source_file_name': sourceFileName,
        'p_rows': buildPhotoSalesRegistrationRows(
          source: workbook,
          saleDate: saleDate,
        ),
      },
    );
    if (response is! Map) {
      throw const FormatException('PHOTO_SALES_IMPORT_RESPONSE_INVALID');
    }
    return PhotoSalesRegistrationResult.fromJson(
      Map<String, dynamic>.from(response),
    );
  }

  Future<List<PhotoSalesRegisteredExport>> loadRegistered(
    String businessDate,
  ) async {
    final response = await supabase.rpc(
      'get_photo_sales_misa_exports_by_tax_entity',
      params: {'p_business_date': businessDate},
    );
    if (response is! Map) {
      throw const FormatException('PHOTO_SALES_EXPORT_RESPONSE_INVALID');
    }
    return createPhotoSalesRegisteredExports(
      Map<String, dynamic>.from(response),
    );
  }
}

final photoSalesImportService = PhotoSalesImportService();

int _intValue(dynamic value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

String _dateText(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
