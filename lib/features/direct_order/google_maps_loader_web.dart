import 'dart:js_interop';

@JS('globosLoadGoogleMaps')
external JSPromise<JSAny?> _globosLoadGoogleMaps(JSString apiKey);

Future<bool> loadDirectOrderGoogleMaps(String apiKey) async {
  if (apiKey.trim().isEmpty) return false;
  try {
    await _globosLoadGoogleMaps(apiKey.trim().toJS).toDart;
    return true;
  } catch (_) {
    return false;
  }
}
