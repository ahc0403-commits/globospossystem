import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'collection_bank.dart';
import 'vietqr_payload.dart';

/// Cash deposits are separate from customer payments and daily-close records.
String cashDepositPurpose({
  required String brandName,
  required String storeName,
  required DateTime depositDate,
}) {
  final (brand, store) = _cashDepositNames(brandName, storeName);
  final day = depositDate.day.toString().padLeft(2, '0');
  final month = depositDate.month.toString().padLeft(2, '0');
  return '$brand $store Cash Doanh thu $day/$month';
}

(String, String) _cashDepositNames(String brandName, String storeName) {
  String clean(String text) => text.trim().replaceAll(RegExp(r'\s+'), ' ');
  final rawBrand = clean(brandName);
  var store = clean(storeName);
  if (rawBrand.isEmpty || store.isEmpty) {
    throw const FormatException('CASH_DEPOSIT_STORE_REQUIRED');
  }
  final brand = switch (rawBrand.toLowerCase().replaceAll(' ', '')) {
    'bunsikclub' || '분식클럽' || 'bc' => 'BC',
    _ => rawBrand,
  };
  // Some registered store names already include their brand.
  for (final prefix in {
    rawBrand,
    brand,
    if (brand == 'BC') ...['Bunsikclub', 'Bunsik Club', '분식클럽'],
  }) {
    if (store.toLowerCase().startsWith('${prefix.toLowerCase()} ')) {
      store = store.substring(prefix.length).trim();
      break;
    }
  }
  if (const {
    'binhthanh',
    'binnthanh',
    'bt',
  }.contains(_asciiName(store).replaceAll(' ', '').toLowerCase())) {
    store = 'BT';
  }
  return (brand, store);
}

/// Brand, store, cash revenue, and ddMM fit the VietQR purpose field.
String cashDepositShortPurpose({
  required String brandName,
  required String storeName,
  required String storeId,
  required DateTime depositDate,
}) {
  if (storeId.trim().isEmpty) {
    throw const FormatException('CASH_DEPOSIT_STORE_REQUIRED');
  }
  final (brand, store) = _cashDepositNames(brandName, storeName);
  final words = _asciiName(
    brand,
  ).split(' ').where((word) => word.isNotEmpty).toList();
  final initials = words.length > 1
      ? words.map((word) => word[0]).join()
      : words.join();
  final brandCode = initials.isEmpty
      ? 'BR'
      : initials.substring(0, initials.length.clamp(0, 3)).toUpperCase();
  var storeCode = _asciiName(store).replaceAll(' ', '');
  if (storeCode.isEmpty || storeCode.length > 10) {
    // A stable store suffix keeps long or non-Latin names distinguishable
    // without fetching a separate code or dropping the date from the memo.
    final suffix = sha256
        .convert(utf8.encode(storeId))
        .toString()
        .substring(0, 4)
        .toUpperCase();
    storeCode = storeCode.isEmpty
        ? 'S$suffix'
        : '${storeCode.substring(0, 6)}$suffix';
  }
  final day = depositDate.day.toString().padLeft(2, '0');
  final month = depositDate.month.toString().padLeft(2, '0');
  final purpose = '$brandCode $storeCode Cash Doanh thu $day$month';
  return purpose.length <= 25 ? purpose : '$brandCode $storeCode C $day$month';
}

String _asciiName(String value) {
  const vowels = {
    'a': 'àáạảãâầấậẩẫăằắặẳẵ',
    'e': 'èéẹẻẽêềếệểễ',
    'i': 'ìíịỉĩ',
    'o': 'òóọỏõôồốộổỗơờớợởỡ',
    'u': 'ùúụủũưừứựửữ',
    'y': 'ỳýỵỷỹ',
    'd': 'đ',
  };
  var text = value;
  for (final group in vowels.entries) {
    for (final rune in group.value.runes) {
      final letter = String.fromCharCode(rune);
      text = text
          .replaceAll(letter, group.key)
          .replaceAll(letter.toUpperCase(), group.key.toUpperCase());
    }
  }
  return text
      .replaceAll(RegExp(r'[^A-Za-z0-9 ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String cashDepositQrPayload({
  required CollectionBank bank,
  required int amount,
  required String purpose,
}) {
  if (!RegExp(r'^[A-Za-z0-9 ]{1,25}$').hasMatch(purpose) ||
      purpose.trim() != purpose ||
      purpose.contains('  ')) {
    throw const FormatException('CASH_DEPOSIT_PURPOSE_INVALID');
  }
  return VietQrPayload.bankTransfer(
    bankBin: bank.bin,
    accountNumber: bank.accountNumber,
    amount: amount,
    purpose: purpose,
  );
}

int? parseCashDepositAmount(String input) {
  final text = input.trim();
  if (!RegExp(
    r'^(?:[0-9]+|[0-9]{1,3}(?:\.[0-9]{3})+|[0-9]{1,3}(?:,[0-9]{3})+)$',
  ).hasMatch(text)) {
    return null;
  }
  final amount = int.tryParse(text.replaceAll(RegExp(r'[.,]'), ''));
  return amount != null && amount > 0 && amount <= 9999999999999
      ? amount
      : null;
}
