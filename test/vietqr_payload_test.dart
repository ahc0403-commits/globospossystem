import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/payments/vietqr_payload.dart';

void main() {
  test('matches the published VietQR transfer payload example', () {
    final payload = VietQrPayload.bankTransfer(
      bankBin: '970415',
      accountNumber: '113366668888',
      amount: 79000,
      purpose: 'Ung Ho Quy Vac Xin',
    );

    expect(
      payload,
      '00020101021238560010A000000727012600069704150112113366668888'
      '0208QRIBFTTA53037045405790005802VN62220818Ung Ho Quy Vac Xin'
      '63043ACF',
    );
  });

  test('customer payment payload changes with the payable amount', () {
    final first = VietQrPayload.bankTransfer(
      bankBin: '970457',
      accountNumber: '100202042976',
      amount: 181000,
      purpose: VietQrPayload.paymentPurpose('order-123'),
    );
    final second = VietQrPayload.bankTransfer(
      bankBin: '970457',
      accountNumber: '100202042976',
      amount: 182000,
      purpose: VietQrPayload.paymentPurpose('order-123'),
    );

    expect(first, isNot(second));
    expect(first, contains('5406181000'));
    expect(first, contains('GLOBOS ORDER123'));
    expect(RegExp(r'[0-9A-F]{4}$').hasMatch(first), isTrue);
  });

  test('rejects invalid or non-positive transfer details', () {
    expect(
      () => VietQrPayload.bankTransfer(
        bankBin: '97045',
        accountNumber: '100202042976',
        amount: 1000,
      ),
      throwsArgumentError,
    );
    expect(
      () => VietQrPayload.bankTransfer(
        bankBin: '970457',
        accountNumber: '100202042976',
        amount: 0,
      ),
      throwsArgumentError,
    );
  });
}
