import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

Future<bool> sharePaymentQrPng(Uint8List bytes, String name) async {
  try {
    final file = web.File(
      [bytes.toJS].toJS,
      name,
      web.FilePropertyBag(type: 'image/png'),
    );
    final data = web.ShareData(files: [file].toJS);
    if (!web.window.navigator.canShare(data)) return false;
    await web.window.navigator.share(data).toDart;
    return true;
  } catch (error) {
    // Cancelling the native share sheet must not trigger an unwanted download.
    if (error.toString().contains('AbortError')) return true;
    return false;
  }
}
