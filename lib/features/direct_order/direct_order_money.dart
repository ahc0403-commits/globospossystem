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
    if (newValue.text.isEmpty || !newValue.composing.isCollapsed) {
      return newValue;
    }
    final value = parseDirectOrderVnd(newValue.text);
    if (value == null) return oldValue;
    final formatted = formatDirectOrderVnd(value);
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final removedLeadingZeros = digits.length - value.toString().length;

    // Keep each selection endpoint at the same digit while adding separators.
    int formattedOffset(int offset) {
      final prefix = newValue.text.substring(
        0,
        offset.clamp(0, newValue.text.length),
      );
      var remaining =
          prefix.replaceAll(RegExp(r'[^0-9]'), '').length - removedLeadingZeros;
      if (remaining <= 0) return 0;
      for (var index = 0; index < formatted.length; index++) {
        final character = formatted.codeUnitAt(index);
        if (character >= 48 && character <= 57) {
          remaining--;
          if (remaining == 0) return index + 1;
        }
      }
      return formatted.length;
    }

    return newValue.copyWith(
      text: formatted,
      selection: newValue.selection.isValid
          ? newValue.selection.copyWith(
              baseOffset: formattedOffset(newValue.selection.baseOffset),
              extentOffset: formattedOffset(newValue.selection.extentOffset),
            )
          : TextSelection.collapsed(offset: formatted.length),
      composing: TextRange.empty,
    );
  }
}
