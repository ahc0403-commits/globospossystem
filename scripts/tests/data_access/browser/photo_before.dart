import 'dart:convert';
import 'dart:js_interop';
// The measurement runner substitutes an immutable pre-change source path.
import 'package:globos_pos_system/features/photo_sales_import/photo_sales_import.dart';

@JS('parsePhotoFixture')
external set parsePhotoFixture(JSFunction callback);
void main() {
  parsePhotoFixture = ((JSUint8Array input) {
    try {
      final result = parsePhotoSalesImportWorkbook(input.toDart);
      return jsonEncode({'rows': result.rows.length}).toJS;
    } catch (e) {
      return jsonEncode({'error': e.toString()}).toJS;
    }
  }).toJS;
}
