import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('web bootstrap uses customer-safe route-aware loading copy', () {
    final bootstrap = File('web/flutter_bootstrap.js').readAsStringSync();

    expect(bootstrap, contains("window.location.hash.startsWith('#/qr/')"));
    expect(bootstrap, contains("languageCode.startsWith('ko')"));
    expect(bootstrap, contains("languageCode.startsWith('vi')"));
    expect(bootstrap, contains('주문 화면을 준비하고 있습니다'));
    expect(bootstrap, contains('Đang chuẩn bị trang gọi món'));
    expect(bootstrap, contains('Preparing your order screen'));
    expect(bootstrap, contains('매장 운영 화면을 준비하고 있습니다'));
    expect(bootstrap, contains('Đang chuẩn bị màn hình vận hành'));
    expect(bootstrap, contains('Preparing the store workspace'));
  });

  test('web bootstrap does not expose developer troubleshooting commands', () {
    final bootstrap = File('web/flutter_bootstrap.js').readAsStringSync();

    expect(bootstrap, isNot(contains('flutter run')));
    expect(bootstrap, isNot(contains('--web-port')));
    expect(bootstrap, isNot(contains('WebGL context')));
    expect(bootstrap, isNot(contains('lastBootstrapError')));
  });
}
