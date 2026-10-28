import 'package:intl/intl.dart';
import '../../core/utils/time_utils.dart';

/// PR-only display aliases approved in the 2026-10-27 source attachment.
/// Keep the registered store and immutable requesting actor unchanged.
Map<String, String> procurementRequestHeader(Map<String, dynamic> data) {
  final storeId = data['restaurant_id'] ?? data['store_id'];
  final actor = data['created_actor'] as Map?;
  final department = data['request_department_name']?.toString().trim();
  final result = <String, String>{
    'store_name': data['store_name']?.toString() ?? '—',
    'requester_label': 'requester',
    'requester_value': department != null && department.isNotEmpty
        ? department
        : (actor?['display_name'] ?? actor?['role'])?.toString() ?? '—',
  };
  if (storeId == '8bc9eef5-dcd5-46b1-b931-23f77132322c') {
    result.addAll({
      'store_name': 'BUNSIKCLUB',
      'store_address': '69/1A2 Nguyễn Gia Trí, phường Thạnh Mỹ Tây',
      'requester_label': 'requestDepartment',
    });
  } else if (storeId == '273b057e-3b69-46e3-93c1-6194c2802849') {
    result.addAll({
      'store_name': 'JEONGABOK (TOÀN GIA PHÚC)',
      'store_address': '29A Nguyễn Gia Trí, phường Thạnh Mỹ Tây',
    });
  }
  if (department != null && department.isNotEmpty) {
    result['requester_label'] = 'requestDepartment';
  }
  return result;
}

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

num procurementShortageBase(Map<String, dynamic> line) =>
    (line['shortage_sources'] as List? ?? []).fold<num>(
      0,
      (sum, source) =>
          sum + (num.tryParse(source['quantity_base'].toString()) ?? 0),
    );

List<Map<String, dynamic>> procurementCarryoverLines(
  List<Map<String, dynamic>> shortages,
) {
  final grouped = <String, Map<String, dynamic>>{};
  for (final q in shortages) {
    final key = '${q['product_id']}:${q['supplier_id']}';
    final line = grouped.putIfAbsent(
      key,
      () => {
        'product_id': q['product_id'],
        'unit': q['base_unit'],
        'quantity': '0',
        'preferred_supplier_id': q['supplier_id'],
        'shortage_sources': <Map<String, dynamic>>[],
      },
    );
    (line['shortage_sources'] as List).add({
      'original_order_line_id': q['original_order_line_id'],
      'quantity_base': q['shortage_quantity_base'],
      'purchase_order_no': q['purchase_order_no'],
    });
    line['quantity'] = procurementShortageBase(line).toString();
  }
  for (final line in grouped.values) {
    final product = shortages.firstWhere(
      (q) => q['product_id'] == line['product_id'],
    );
    final factor = num.tryParse(product['conversion']?.toString() ?? '') ?? 0;
    final base = procurementShortageBase(line);
    final stockQuantity = factor > 0 ? base / factor : base;
    final rounded = num.parse(stockQuantity.toStringAsFixed(3));
    if (product['stock_unit'] != null &&
        factor > 0 &&
        (rounded * factor - base).abs() < .0001) {
      line['unit'] = product['stock_unit'];
      line['quantity'] = rounded.toString();
    }
  }
  return grouped.values.toList();
}

/// Display the price in the requested unit, while retaining server line totals.
num? procurementDisplayUnitPrice(Map line) {
  final price = num.tryParse(line['estimated_unit_price']?.toString() ?? '');
  final factor = num.tryParse(line['estimated_conversion']?.toString() ?? '');
  final requestedFactor = num.tryParse(
    line['conversion_snapshot']?.toString() ?? '',
  );
  if (price == null) return null;
  if (factor == null || factor <= 0 || requestedFactor == null) return price;
  return price * requestedFactor / factor;
}

/// Refresh only existing reservations; keep the explicitly requested new demand.
List<Map<String, dynamic>> procurementRefreshCarryoverLines(
  List<Map<String, dynamic>> lines,
  List<Map<String, dynamic>> current,
) {
  num number(dynamic value) => num.tryParse(value?.toString() ?? '') ?? 0;
  final available = {for (final q in current) q['original_order_line_id']: q};
  final result = <Map<String, dynamic>>[];
  for (final original in lines) {
    final line = Map<String, dynamic>.from(original);
    final old = (line['shortage_sources'] as List? ?? []);
    if (old.isEmpty) {
      result.add(line);
      continue;
    }
    final previous = procurementShortageBase(line);
    final revised = <Map<String, dynamic>>[];
    for (final source in old) {
      final latest = available[source['original_order_line_id']];
      final quantity = latest == null
          ? 0
          : number(latest['shortage_quantity_base']);
      final carried = quantity < number(source['quantity_base'])
          ? quantity
          : number(source['quantity_base']);
      if (carried > 0) {
        revised.add({
          ...Map<String, dynamic>.from(source as Map),
          'quantity_base': carried,
        });
      }
    }
    line['shortage_sources'] = revised;
    final base =
        number(line['quantity_base']) -
        previous +
        procurementShortageBase(line);
    if (base <= 0) continue;
    final factor = number(line['conversion_snapshot']);
    line['requested_quantity'] = num.parse(
      (base / (factor > 0 ? factor : 1)).toStringAsFixed(3),
    );
    line['quantity_base'] = base;
    result.add(line);
  }
  return result;
}
