import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/vendor_portal_url.dart';

void main() {
  test('allows documented HTTPS WeTax portal hosts', () {
    expect(
      validatedVendorPortalUri(
        'https://test.wetax.com.vn/self-issuance/webcashvn?bill_no=abc',
      ),
      isNotNull,
    );
    expect(
      validatedVendorPortalUri('https://wetax.com.vn/invoices/abc'),
      isNotNull,
    );
  });

  test('rejects unsafe schemes hosts credentials ports and IP literals', () {
    for (final value in [
      'http://test.wetax.com.vn/invoices/abc',
      'javascript:alert(1)',
      'https://wetax.com.vn.evil.example/invoices/abc',
      'https://user:pass@test.wetax.com.vn/invoices/abc',
      'https://test.wetax.com.vn:8443/invoices/abc',
      'https://127.0.0.1/invoices/abc',
      'not a uri',
    ]) {
      expect(validatedVendorPortalUri(value), isNull, reason: value);
    }
  });
}
