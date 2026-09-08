import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

const int maxDirectOrderVndAmount = 999999999999;

int? parseDirectOrderVnd(String input) {
  final normalized = input.replaceAll(RegExp(r'[^0-9]'), '');
  if (normalized.isEmpty) return null;
  final value = int.tryParse(normalized);
  if (value == null || value > maxDirectOrderVndAmount) return null;
  return value;
}

String formatDirectOrderVnd(num value) =>
    NumberFormat('#,###', 'vi_VN').format(value.round());

class DirectOrderVndInputFormatter extends TextInputFormatter {
  const DirectOrderVndInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) return newValue;
    final value = parseDirectOrderVnd(newValue.text);
    if (value == null) return oldValue;
    final formatted = formatDirectOrderVnd(value);
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
