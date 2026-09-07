import 'dart:js_interop';

@JS('globosLoadGoogleMaps')
external JSPromise<JSAny?> _globosLoadGoogleMaps(JSString apiKey);

@JS('globosDidGoogleMapsAuthenticationFail')
external JSBoolean _globosDidGoogleMapsAuthenticationFail();

Future<bool> loadDirectOrderGoogleMaps(String apiKey) async {
  if (apiKey.trim().isEmpty) return false;
  try {
    await _globosLoadGoogleMaps(apiKey.trim().toJS).toDart;
    return true;
  } catch (_) {
    return false;
  }
}

bool didDirectOrderGoogleMapsAuthenticationFail() {
  try {
    return _globosDidGoogleMapsAuthenticationFail().toDart;
  } catch (_) {
    return false;
  }
}
