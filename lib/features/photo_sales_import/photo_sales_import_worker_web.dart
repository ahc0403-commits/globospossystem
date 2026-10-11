import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;
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
  web.Worker? worker;
  try {
    worker = web.Worker(
      Uri.parse(
        web.document.baseURI,
      ).resolve('photo_import_worker.js').toString().toJS,
    );
    final result = Completer<PhotoSalesImportWorkbook>();
    worker.onmessage = ((web.MessageEvent event) {
      if (result.isCompleted) return;
      try {
        final data =
            jsonDecode((event.data as JSString).toDart) as Map<String, dynamic>;
        if (data['error'] is List) {
          result.completeError(
            PhotoSalesImportValidationException(
              List<String>.from(data['error'] as List),
            ),
          );
        } else {
          result.complete(PhotoSalesImportWorkbook.fromJson(data));
        }
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    }).toJS;
    worker.onerror = ((web.Event event) {
      if (!result.isCompleted) {
        result.completeError(
          const PhotoSalesImportValidationException([
            'Excel worker could not read this file.',
          ]),
        );
      }
    }).toJS;
    worker.postMessage(bytes.toJS);
    return await result.future.timeout(const Duration(seconds: 30));
  } finally {
    worker?.terminate();
    _running = false;
  }
}
