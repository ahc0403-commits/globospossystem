import 'package:flutter/foundation.dart';
import 'photo_sales_import.dart';

bool _running = false;
Future<PhotoSalesImportWorkbook> parsePhotoSalesOffThread(
  Uint8List bytes,
) async {
  if (_running) {
    throw const PhotoSalesImportValidationException([
      'Excel import is already running.',
    ]);
  }
  _running = true;
  try {
    return await compute(parsePhotoSalesImportWorkbook, bytes);
  } finally {
    _running = false;
  }
}
