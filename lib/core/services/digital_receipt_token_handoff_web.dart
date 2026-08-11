import 'dart:js_interop';

@JS('globosTakeDigitalReceiptToken')
external JSString _takeDigitalReceiptToken();

abstract final class DigitalReceiptTokenHandoff {
  static final RegExp _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{32}$');
  static String? _cachedToken;

  static String take() {
    final cached = _cachedToken;
    if (cached != null) return cached;
    try {
      final token = _takeDigitalReceiptToken().toDart;
      if (_tokenPattern.hasMatch(token)) {
        _cachedToken = token;
        return token;
      }
    } catch (_) {
      // The public page will render the same unavailable state as an invalid,
      // expired, or revoked link without exposing why the token is absent.
    }
    return '';
  }
}
