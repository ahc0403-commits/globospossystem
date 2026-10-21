import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/payments/cash_deposit_transfer.dart';
import 'package:globos_pos_system/core/payments/collection_bank.dart';

void main() {
  test('keeps the complete requested memo in brand/store order', () {
    expect(
      cashDepositPurpose(
        brandName: 'Bunsik Club',
        storeName: 'Binh Thanh',
        depositDate: DateTime(2026, 1, 5),
      ),
      'BC BT Cash Doanh thu 05/01',
    );
    expect(
      cashDepositPurpose(
        brandName: ' Bunsikclub ',
        storeName: '  Bunsikclub  Binh   Thanh ',
        depositDate: DateTime(2026, 10, 17),
      ),
      'BC BT Cash Doanh thu 17/10',
    );
    expect(
      cashDepositPurpose(
        brandName: 'Other Brand',
        storeName: 'Other Store',
        depositDate: DateTime(2026, 10, 17),
      ),
      'Other Brand Other Store Cash Doanh thu 17/10',
    );
  });

  test('missing store metadata never generates a guessed memo', () {
    expect(
      () => cashDepositPurpose(
        brandName: '',
        storeName: 'Binh Thanh',
        depositDate: DateTime(2026, 10, 17),
      ),
      throwsFormatException,
    );
  });

  test(
    'short memo preserves brand, store, cash, and day/month within 25 characters',
    () {
      for (final brand in ['Bunsikclub', 'BUNSIK CLUB', '분식클럽', 'BC']) {
        for (final store in [
          'Bunsikclub Binh Thanh',
          'Bunsik Club Binn Thanh',
          'Bình Thạnh',
          'BT',
        ]) {
          final purpose = cashDepositShortPurpose(
            brandName: brand,
            storeName: store,
            storeId: 'fixture-store',
            depositDate: DateTime(2026, 10, 16),
          );
          expect(purpose, 'BC BT C Doanh thu 16/10');
          expect(purpose.length, 23);
        }
      }
      expect(
        cashDepositShortPurpose(
          brandName: 'Bunsik Club',
          storeName: 'Bình Thạnh',
          storeId: 'fixture-store',
          depositDate: DateTime(2026, 1, 5),
        ),
        'BC BT C Doanh thu 05/01',
      );
    },
  );

  test(
    'long and non-Latin store names remain bounded and use stable store suffixes',
    () {
      for (final name in ['Nguyen Thi Minh Khai', '매장 이름']) {
        String purpose(String id) => cashDepositShortPurpose(
          brandName: 'Other Brand',
          storeName: name,
          storeId: id,
          depositDate: DateTime(2026, 12, 31),
        );
        expect(purpose('store-a'), purpose('store-a'));
        expect(purpose('store-a'), isNot(purpose('store-b')));
        expect(purpose('store-a').length, lessThanOrEqualTo(25));
        expect(purpose('store-a'), startsWith('OB '));
        expect(purpose('store-a'), endsWith(' C 31/12'));
        expect(
          RegExp(r'^[A-Za-z0-9 /]+$').hasMatch(purpose('store-a')),
          isTrue,
        );
      }
    },
  );

  test('rounds only the final cash deposit to the displayed whole VND', () {
    for (final amount in [1, 1622160.0, 9999999999999]) {
      expect(cashDepositReportAmount(amount), amount.toInt());
    }
    expect(cashDepositReportAmount(3389971.9), 3389972);
    expect(cashDepositReportAmount(1.5), 2);
    expect(cashDepositReportAmount(3389971.1), 3389971);
    for (final amount in [
      null,
      0,
      -1,
      0.49,
      double.nan,
      double.infinity,
      10000000000000,
    ]) {
      expect(cashDepositReportAmount(amount), isNull);
    }
  });

  test(
    'QR encodes the selected beneficiary, exact amount, and complete short memo',
    () {
      final payload = cashDepositQrPayload(
        bank: const CollectionBank(
          bin: '970426',
          accountNumber: '12345678901',
          accountHolder: 'FIXTURE COMPANY',
          label: 'Fixture Bank',
        ),
        amount: 1622160,
        purpose: 'BC BT C Doanh thu 16/10',
      );
      final fields = <String, String>{};
      for (var offset = 0; offset < payload.length;) {
        final id = payload.substring(offset, offset + 2);
        final length = int.parse(payload.substring(offset + 2, offset + 4));
        fields[id] = payload.substring(offset + 4, offset + 4 + length);
        offset += length + 4;
      }
      expect(fields['38'], contains('0006970426011112345678901'));
      expect(fields['54'], '1622160');
      expect(fields['53'], '704');
      expect(fields['62'], '0823BC BT C Doanh thu 16/10');
      // Independently check the CRC, including its tag and length.
      var crc = 0xFFFF;
      for (final byte in payload.substring(0, payload.length - 4).codeUnits) {
        crc ^= byte << 8;
        for (var i = 0; i < 8; i++) {
          crc = ((crc << 1) ^ ((crc & 0x8000) == 0 ? 0 : 0x1021)) & 0xFFFF;
        }
      }
      expect(fields['63'], crc.toRadixString(16).toUpperCase().padLeft(4, '0'));
    },
  );

  test(
    'QR rejects an oversized or modified memo instead of silently shortening it',
    () {
      const bank = CollectionBank(
        bin: '970426',
        accountNumber: '12345678901',
        accountHolder: 'FIXTURE',
        label: 'Fixture',
      );
      for (final purpose in [
        '',
        'AKJ BSC BinhThanh Cash 17/10',
        'AKJ BSC BinhThanh Cash 1710',
        'AKJ  BSC BT C 1710',
      ]) {
        expect(
          () =>
              cashDepositQrPayload(bank: bank, amount: 1000, purpose: purpose),
          throwsFormatException,
        );
      }
    },
  );
}
