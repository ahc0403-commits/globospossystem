import 'dart:convert';

/// Builds an EMVCo/NAPAS VietQR bank-transfer payload locally.
class VietQrPayload {
  VietQrPayload._();

  static const _napasGuid = 'A000000727';
  static const _transferToAccountService = 'QRIBFTTA';

  static String bankTransfer({
    required String bankBin,
    required String accountNumber,
    int? amount,
    String? purpose,
  }) {
    if (!RegExp(r'^\d{6}$').hasMatch(bankBin)) {
      throw ArgumentError.value(bankBin, 'bankBin', 'Must be 6 digits.');
    }
    if (!RegExp(r'^[A-Za-z0-9]{5,19}$').hasMatch(accountNumber)) {
      throw ArgumentError.value(
        accountNumber,
        'accountNumber',
        'Must be 5-19 letters or digits.',
      );
    }
    if (amount != null && (amount <= 0 || amount.toString().length > 13)) {
      throw ArgumentError.value(
        amount,
        'amount',
        'Must be a positive integer with at most 13 digits.',
      );
    }

    final beneficiary = _tlv('00', bankBin) + _tlv('01', accountNumber);
    final merchantAccount =
        _tlv('00', _napasGuid) +
        _tlv('01', beneficiary) +
        _tlv('02', _transferToAccountService);
    final normalizedPurpose = _normalizePurpose(purpose);

    final payload = StringBuffer()
      ..write(_tlv('00', '01'))
      ..write(_tlv('01', amount == null ? '11' : '12'))
      ..write(_tlv('38', merchantAccount))
      ..write(_tlv('53', '704'));
    if (amount != null) payload.write(_tlv('54', amount.toString()));
    payload.write(_tlv('58', 'VN'));
    if (normalizedPurpose.isNotEmpty) {
      payload.write(_tlv('62', _tlv('08', normalizedPurpose)));
    }
    payload.write('6304');

    final withoutChecksum = payload.toString();
    final checksum = _crc16CcittFalse(
      utf8.encode(withoutChecksum),
    ).toRadixString(16).toUpperCase().padLeft(4, '0');
    return '$withoutChecksum$checksum';
  }

  static String paymentPurpose(String orderId) {
    final normalized = orderId.toUpperCase().replaceAll(
      RegExp(r'[^A-Z0-9]'),
      '',
    );
    final suffix = normalized.length > 18
        ? normalized.substring(0, 18)
        : normalized;
    return suffix.isEmpty ? 'GLOBOS' : 'GLOBOS $suffix';
  }

  static String _normalizePurpose(String? value) {
    final normalized = (value ?? '')
        .replaceAll(RegExp(r'[^A-Za-z0-9 ]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return normalized.length > 25 ? normalized.substring(0, 25) : normalized;
  }

  static String _tlv(String id, String value) {
    final length = utf8.encode(value).length;
    if (length > 99) {
      throw ArgumentError.value(value, id, 'TLV value is too long.');
    }
    return '$id${length.toString().padLeft(2, '0')}$value';
  }

  static int _crc16CcittFalse(List<int> bytes) {
    var crc = 0xFFFF;
    for (final byte in bytes) {
      crc ^= byte << 8;
      for (var bit = 0; bit < 8; bit += 1) {
        crc = (crc & 0x8000) != 0
            ? ((crc << 1) ^ 0x1021) & 0xFFFF
            : (crc << 1) & 0xFFFF;
      }
    }
    return crc;
  }
}
