import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/printer_destination_service.dart';

void main() {
  test('printer destinations require a complete IPv4 address', () {
    expect(isValidPrinterIpv4Address('192.168.1.253'), isTrue);
    expect(isValidPrinterIpv4Address(' 192.168.1.253 '), isTrue);
    expect(isValidPrinterIpv4Address('192.168.253'), isFalse);
    expect(isValidPrinterIpv4Address('192.168.1.256'), isFalse);
    expect(isValidPrinterIpv4Address('printer.local'), isFalse);
  });
}
