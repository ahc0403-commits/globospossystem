import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/report/menu_sales_analytics.dart';

Map<String, dynamic> _menuRow({
  required int rank,
  required String key,
  required String name,
  required dynamic quantity,
  required dynamic revenue,
  required dynamic orders,
  bool isCombo = false,
}) {
  return {
    'rank': rank,
    'menu_key': key,
    'display_name': name,
    'identity_quality': key.startsWith('name:') ? 'name_fallback' : 'stable_id',
    'name_changed_in_period': false,
    'sold_quantity': quantity,
    'order_count': orders,
    'menu_sales_amount': revenue,
    'quantity_share': 50,
    'revenue_share': 50,
    'peak_hour': 12,
    'dine_in_quantity': quantity,
    'takeaway_quantity': 0,
    'delivery_quantity': 0,
    'is_combo': isCombo,
  };
}

void main() {
  test('parses mixed numeric JSON and zero-fills all 24 HCM hours', () {
    final analytics = MenuSalesAnalytics.fromJson({
      'summary': {
        'order_count': '2',
        'sold_quantity': 7,
        'sold_menu_count': 2,
        'menu_sales_amount': '225000.50',
        'combo_menu_sales_amount': '0',
        'unallocated_adjustment_count': 1,
        'unallocated_adjustment_amount': '10000',
      },
      'menu_rows': [
        _menuRow(
          rank: 1,
          key: 'menu-a',
          name: 'Pho',
          quantity: '5',
          revenue: '125000.50',
          orders: '2',
        ),
        _menuRow(
          rank: 2,
          key: 'name:legacy',
          name: 'Legacy Tea',
          quantity: 2,
          revenue: 100000,
          orders: 1,
        ),
      ],
      'hour_rows': [
        {
          'hour': 12,
          'sold_quantity': '7',
          'menu_sales_amount': '225000.50',
          'order_count': 2,
        },
      ],
      'top_menu_hour_rows': const [],
      'scope': {'timezone': 'Asia/Ho_Chi_Minh'},
    });

    expect(analytics.summary.orderCount, 2);
    expect(analytics.summary.menuSalesAmount, 225000.50);
    expect(analytics.menuRows, hasLength(2));
    expect(analytics.menuRows.last.usesNameFallback, isTrue);
    expect(analytics.menuRows.first.isCombo, isFalse);
    expect(analytics.hourRows, hasLength(24));
    expect(analytics.hourRows[11].soldQuantity, 0);
    expect(analytics.hourRows[12].soldQuantity, 7);
    expect(analytics.scope['timezone'], 'Asia/Ho_Chi_Minh');
  });

  test('supports quantity, revenue, and included-order sorting', () {
    final analytics = MenuSalesAnalytics.fromJson({
      'summary': const {},
      'menu_rows': [
        _menuRow(
          rank: 1,
          key: 'a',
          name: 'A',
          quantity: 10,
          revenue: 100000,
          orders: 3,
        ),
        _menuRow(
          rank: 2,
          key: 'b',
          name: 'B',
          quantity: 4,
          revenue: 300000,
          orders: 4,
        ),
        _menuRow(
          rank: 3,
          key: 'c',
          name: 'C',
          quantity: 6,
          revenue: 200000,
          orders: 6,
        ),
      ],
      'hour_rows': const [],
      'top_menu_hour_rows': const [],
      'scope': const {},
    });

    expect(
      analytics
          .sortedRows(MenuSalesSort.quantity)
          .map((row) => row.displayName),
      ['A', 'C', 'B'],
    );
    expect(
      analytics.sortedRows(MenuSalesSort.revenue).map((row) => row.displayName),
      ['B', 'C', 'A'],
    );
    expect(
      analytics.sortedRows(MenuSalesSort.orders).map((row) => row.displayName),
      ['C', 'B', 'A'],
    );
  });

  test('menu analytics date range uses HCM midnight and exclusive end', () {
    final range = menuSalesUtcRange(
      DateTime(2026, 8, 13),
      DateTime(2026, 8, 13, 23, 59),
    );

    expect(range.startUtc, DateTime.utc(2026, 8, 12, 17));
    expect(range.endExclusiveUtc, DateTime.utc(2026, 8, 13, 17));
  });

  test('menu scope participates in provider identity and copies safely', () {
    final allMenus = MenuSalesAnalyticsParams(
      storeId: 'store-a',
      startDate: DateTime(2026, 8, 13),
      endDate: DateTime(2026, 8, 13),
    );
    final regular = allMenus.copyWith(scope: MenuSalesScope.regular);
    final combo = allMenus.copyWith(scope: MenuSalesScope.combo);

    expect(allMenus.scope, MenuSalesScope.all);
    expect(regular.scope, MenuSalesScope.regular);
    expect(combo.scope.rpcValue, 'combo');
    expect(allMenus, isNot(regular));
    expect(regular, isNot(combo));
    expect(allMenus.hashCode, isNot(combo.hashCode));
  });

  test('parses combo revenue and finds the top-selling combo', () {
    final analytics = MenuSalesAnalytics.fromJson({
      'summary': const {
        'combo_sold_quantity': 7,
        'combo_sold_menu_count': 2,
        'combo_menu_sales_amount': 510000,
      },
      'menu_rows': [
        _menuRow(
          rank: 1,
          key: 'combo-a',
          name: 'Lunch Combo',
          quantity: 4,
          revenue: 300000,
          orders: 3,
          isCombo: true,
        ),
        _menuRow(
          rank: 2,
          key: 'combo-b',
          name: 'Dinner Combo',
          quantity: 3,
          revenue: 210000,
          orders: 2,
          isCombo: true,
        ),
      ],
    });

    expect(analytics.summary.comboSoldQuantity, 7);
    expect(analytics.summary.comboSoldMenuCount, 2);
    expect(analytics.summary.comboMenuSalesAmount, 510000);
    expect(analytics.topCombo?.displayName, 'Lunch Combo');
    expect(analytics.topCombo?.menuSalesAmount, 300000);
  });
}
