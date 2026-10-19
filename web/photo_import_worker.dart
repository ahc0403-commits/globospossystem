import 'dart:convert';
import 'dart:js_interop';
import 'package:globos_pos_system/features/photo_sales_import/photo_sales_import.dart';

@JS('self')
external WorkerScope get scope;
extension type WorkerScope(JSObject _) implements JSObject {
  external set onmessage(JSFunction callback);
  external void postMessage(JSAny data);
}
extension type WorkerMessage(JSObject _) implements JSObject {
  external JSAny get data;
}
void main() {
  scope.onmessage = ((WorkerMessage event) {
    try {
      final result = parsePhotoSalesImportWorkbook(
        (event.data as JSUint8Array).toDart,
      );
      scope.postMessage(jsonEncode(result.toJson()).toJS);
    } catch (error) {
      final issues = error is PhotoSalesImportValidationException
          ? error.issues
          : ['Excel file could not be read.'];
      scope.postMessage(jsonEncode({'error': issues}).toJS);
    }
  }).toJS;
}
