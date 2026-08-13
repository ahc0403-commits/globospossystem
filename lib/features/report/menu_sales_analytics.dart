import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../main.dart';

enum MenuSalesSort { quantity, revenue, orders }

enum MenuSalesScope {
  all('all'),
  regular('regular'),
  combo('combo');

  const MenuSalesScope(this.rpcValue);

  final String rpcValue;
}

class MenuSalesAnalyticsParams {
  const MenuSalesAnalyticsParams({
    required this.storeId,
    required this.startDate,
    required this.endDate,
    this.scope = MenuSalesScope.all,
  });

  final String storeId;
  final DateTime startDate;
  final DateTime endDate;
  final MenuSalesScope scope;

  MenuSalesAnalyticsParams copyWith({MenuSalesScope? scope}) {
    return MenuSalesAnalyticsParams(
      storeId: storeId,
      startDate: startDate,
      endDate: endDate,
      scope: scope ?? this.scope,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is MenuSalesAnalyticsParams &&
        other.storeId == storeId &&
        other.startDate == startDate &&
        other.endDate == endDate &&
        other.scope == scope;
  }

  @override
  int get hashCode => Object.hash(storeId, startDate, endDate, scope);
}

class MenuSalesSummary {
  const MenuSalesSummary({
    required this.orderCount,
    required this.soldQuantity,
    required this.soldMenuCount,
    required this.comboSoldQuantity,
    required this.comboSoldMenuCount,
    required this.comboMenuSalesAmount,
    required this.menuSalesAmount,
    required this.unallocatedAdjustmentCount,
    required this.unallocatedAdjustmentAmount,
  });

  final int orderCount;
  final int soldQuantity;
  final int soldMenuCount;
  final int comboSoldQuantity;
  final int comboSoldMenuCount;
  final double comboMenuSalesAmount;
  final double menuSalesAmount;
  final int unallocatedAdjustmentCount;
  final double unallocatedAdjustmentAmount;

  factory MenuSalesSummary.fromJson(Map<String, dynamic> json) {
    return MenuSalesSummary(
      orderCount: menuSalesInt(json['order_count']),
      soldQuantity: menuSalesInt(json['sold_quantity']),
      soldMenuCount: menuSalesInt(json['sold_menu_count']),
      comboSoldQuantity: menuSalesInt(json['combo_sold_quantity']),
      comboSoldMenuCount: menuSalesInt(json['combo_sold_menu_count']),
      comboMenuSalesAmount: menuSalesDouble(json['combo_menu_sales_amount']),
      menuSalesAmount: menuSalesDouble(json['menu_sales_amount']),
      unallocatedAdjustmentCount: menuSalesInt(
        json['unallocated_adjustment_count'],
      ),
      unallocatedAdjustmentAmount: menuSalesDouble(
        json['unallocated_adjustment_amount'],
      ),
    );
  }
}

class MenuSalesRow {
  const MenuSalesRow({
    required this.rank,
    required this.menuKey,
    required this.displayName,
    required this.identityQuality,
    required this.nameChangedInPeriod,
    required this.soldQuantity,
    required this.orderCount,
    required this.menuSalesAmount,
    required this.quantityShare,
    required this.revenueShare,
    required this.peakHour,
    required this.dineInQuantity,
    required this.takeawayQuantity,
    required this.deliveryQuantity,
    required this.isCombo,
  });

  final int rank;
  final String menuKey;
  final String displayName;
  final String identityQuality;
  final bool nameChangedInPeriod;
  final int soldQuantity;
  final int orderCount;
  final double menuSalesAmount;
  final double quantityShare;
  final double revenueShare;
  final int peakHour;
  final int dineInQuantity;
  final int takeawayQuantity;
  final int deliveryQuantity;
  final bool isCombo;

  bool get usesNameFallback => identityQuality == 'name_fallback';

  factory MenuSalesRow.fromJson(Map<String, dynamic> json) {
    return MenuSalesRow(
      rank: menuSalesInt(json['rank']),
      menuKey: json['menu_key']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? '',
      identityQuality: json['identity_quality']?.toString() ?? 'stable_id',
      nameChangedInPeriod: json['name_changed_in_period'] == true,
      soldQuantity: menuSalesInt(json['sold_quantity']),
      orderCount: menuSalesInt(json['order_count']),
      menuSalesAmount: menuSalesDouble(json['menu_sales_amount']),
      quantityShare: menuSalesDouble(json['quantity_share']),
      revenueShare: menuSalesDouble(json['revenue_share']),
      peakHour: menuSalesInt(json['peak_hour']).clamp(0, 23).toInt(),
      dineInQuantity: menuSalesInt(json['dine_in_quantity']),
      takeawayQuantity: menuSalesInt(json['takeaway_quantity']),
      deliveryQuantity: menuSalesInt(json['delivery_quantity']),
      isCombo: json['is_combo'] == true,
    );
  }
}

class MenuSalesHour {
  const MenuSalesHour({
    required this.hour,
    required this.soldQuantity,
    required this.menuSalesAmount,
    required this.orderCount,
  });

  final int hour;
  final int soldQuantity;
  final double menuSalesAmount;
  final int orderCount;

  factory MenuSalesHour.fromJson(Map<String, dynamic> json) {
    return MenuSalesHour(
      hour: menuSalesInt(json['hour']).clamp(0, 23).toInt(),
      soldQuantity: menuSalesInt(json['sold_quantity']),
      menuSalesAmount: menuSalesDouble(json['menu_sales_amount']),
      orderCount: menuSalesInt(json['order_count']),
    );
  }
}

class TopMenuSalesHour {
  const TopMenuSalesHour({
    required this.rank,
    required this.menuKey,
    required this.displayName,
    required this.hour,
    required this.soldQuantity,
    required this.menuSalesAmount,
  });

  final int rank;
  final String menuKey;
  final String displayName;
  final int hour;
  final int soldQuantity;
  final double menuSalesAmount;

  factory TopMenuSalesHour.fromJson(Map<String, dynamic> json) {
    return TopMenuSalesHour(
      rank: menuSalesInt(json['rank']),
      menuKey: json['menu_key']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? '',
      hour: menuSalesInt(json['hour']).clamp(0, 23).toInt(),
      soldQuantity: menuSalesInt(json['sold_quantity']),
      menuSalesAmount: menuSalesDouble(json['menu_sales_amount']),
    );
  }
}

class MenuSalesAnalytics {
  const MenuSalesAnalytics({
    required this.summary,
    required this.menuRows,
    required this.hourRows,
    required this.topMenuHourRows,
    required this.scope,
  });

  final MenuSalesSummary summary;
  final List<MenuSalesRow> menuRows;
  final List<MenuSalesHour> hourRows;
  final List<TopMenuSalesHour> topMenuHourRows;
  final Map<String, dynamic> scope;

  MenuSalesRow? get topMenu => menuRows.isEmpty ? null : menuRows.first;

  MenuSalesRow? get topCombo {
    MenuSalesRow? result;
    for (final row in menuRows.where((row) => row.isCombo)) {
      if (result == null ||
          row.soldQuantity > result.soldQuantity ||
          (row.soldQuantity == result.soldQuantity &&
              row.menuSalesAmount > result.menuSalesAmount)) {
        result = row;
      }
    }
    return result;
  }

  List<MenuSalesRow> sortedRows(MenuSalesSort sort) {
    final rows = List<MenuSalesRow>.from(menuRows);
    rows.sort((left, right) {
      final primary = switch (sort) {
        MenuSalesSort.quantity => right.soldQuantity.compareTo(
          left.soldQuantity,
        ),
        MenuSalesSort.revenue => right.menuSalesAmount.compareTo(
          left.menuSalesAmount,
        ),
        MenuSalesSort.orders => right.orderCount.compareTo(left.orderCount),
      };
      if (primary != 0) return primary;

      final quantity = right.soldQuantity.compareTo(left.soldQuantity);
      if (quantity != 0) return quantity;
      final revenue = right.menuSalesAmount.compareTo(left.menuSalesAmount);
      if (revenue != 0) return revenue;
      return left.displayName.toLowerCase().compareTo(
        right.displayName.toLowerCase(),
      );
    });
    return List.unmodifiable(rows);
  }

  factory MenuSalesAnalytics.fromJson(Map<String, dynamic> json) {
    final summary = menuSalesMap(json['summary']);
    final menuRows = menuSalesList(json['menu_rows'])
        .map((row) => MenuSalesRow.fromJson(menuSalesMap(row)))
        .toList(growable: false);
    final parsedHours = <int, MenuSalesHour>{};
    for (final row in menuSalesList(json['hour_rows'])) {
      final parsed = MenuSalesHour.fromJson(menuSalesMap(row));
      parsedHours[parsed.hour] = parsed;
    }
    final hourRows = List<MenuSalesHour>.generate(
      24,
      (hour) =>
          parsedHours[hour] ??
          MenuSalesHour(
            hour: hour,
            soldQuantity: 0,
            menuSalesAmount: 0,
            orderCount: 0,
          ),
      growable: false,
    );

    return MenuSalesAnalytics(
      summary: MenuSalesSummary.fromJson(summary),
      menuRows: menuRows,
      hourRows: hourRows,
      topMenuHourRows: menuSalesList(json['top_menu_hour_rows'])
          .map((row) => TopMenuSalesHour.fromJson(menuSalesMap(row)))
          .toList(growable: false),
      scope: menuSalesMap(json['scope']),
    );
  }
}

int menuSalesInt(dynamic value) {
  return switch (value) {
    num number => number.toInt(),
    String text => int.tryParse(text) ?? 0,
    _ => 0,
  };
}

double menuSalesDouble(dynamic value) {
  return switch (value) {
    num number => number.toDouble(),
    String text => double.tryParse(text) ?? 0,
    _ => 0,
  };
}

Map<String, dynamic> menuSalesMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return const <String, dynamic>{};
}

List<dynamic> menuSalesList(dynamic value) {
  return value is List ? value : const <dynamic>[];
}

({DateTime startUtc, DateTime endExclusiveUtc}) menuSalesUtcRange(
  DateTime start,
  DateTime end,
) {
  const hcmOffset = Duration(hours: 7);
  return (
    startUtc: DateTime.utc(
      start.year,
      start.month,
      start.day,
    ).subtract(hcmOffset),
    endExclusiveUtc: DateTime.utc(
      end.year,
      end.month,
      end.day + 1,
    ).subtract(hcmOffset),
  );
}

final menuSalesAnalyticsProvider = FutureProvider.autoDispose
    .family<MenuSalesAnalytics, MenuSalesAnalyticsParams>((ref, params) async {
      final range = menuSalesUtcRange(params.startDate, params.endDate);
      final response = await supabase.rpc(
        'get_store_menu_sales_analytics',
        params: {
          'p_store_id': params.storeId,
          'p_start_at': range.startUtc.toIso8601String(),
          'p_end_at': range.endExclusiveUtc.toIso8601String(),
          'p_menu_scope': params.scope.rpcValue,
        },
      );
      return MenuSalesAnalytics.fromJson(menuSalesMap(response));
    });
