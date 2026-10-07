import 'package:intl/intl.dart';
import '../../core/utils/time_utils.dart';

String procurementDate(dynamic value, {bool includeTime = false}) {
  final text = value?.toString() ?? '';
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) return text;
  final date = DateTime.tryParse(text);
  if (date == null) return '—';
  return includeTime
      ? TimeUtils.formatDateTime(date)
      : TimeUtils.formatDate(date);
}

String procurementNumber(dynamic value, {int decimals = 2}) {
  final number = value is num ? value : num.tryParse(value?.toString() ?? '');
  if (number == null || !number.isFinite) return '—';
  return NumberFormat(
    decimals == 3 ? '#,##0.###' : '#,##0.##',
    'en',
  ).format(number);
}

Map<String, dynamic>? procurementEstimateItem(
  List<Map<String, dynamic>> items,
  String? productId,
  String? supplierId,
) {
  final candidates = items
      .where(
        (item) =>
            item['product_id'] == productId &&
            (supplierId == null || item['supplier_id'] == supplierId),
      )
      .toList();
  candidates.sort((a, b) {
    final rank =
        (b['is_preferred'] == true ? 1 : 0) -
        (a['is_preferred'] == true ? 1 : 0);
    return rank != 0 ? rank : a['id'].toString().compareTo(b['id'].toString());
  });
  if (candidates.isEmpty) return null;
  if (supplierId != null) return candidates.first;
  final preferred = candidates
      .where((item) => item['is_preferred'] == true)
      .toList();
  final choices = preferred.isEmpty ? candidates : preferred;
  return choices.length == 1 ? choices.single : null;
}

Map<String, String> procurementRecentMonth({DateTime? nowUtc}) {
  final today = TimeUtils.toVietnam((nowUtc ?? DateTime.now()).toUtc());
  final lastDay = DateTime(today.year, today.month, 0).day;
  final from = DateTime(
    today.year,
    today.month - 1,
    today.day > lastDay ? lastDay : today.day,
  );
  String date(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  return {'created_from': date(from), 'created_to': date(today)};
}
