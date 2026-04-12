// 배달 정산 모델
// Deliberry → POS 정산 연동 데이터 모델
// 관련 문서: Deliberry볼트/Integration/POS-SETTLEMENT.md

// ─── 정산 차감 항목 ───────────────────────────

class DeliverySettlementItem {
  const DeliverySettlementItem({
    required this.id,
    required this.settlementId,
    required this.itemType,
    required this.amount,
    this.description,
    this.referenceRate,
    this.referenceBase,
    required this.createdAt,
  });

  final String id;
  final String settlementId;
  final String itemType;
  final double amount;
  final String? description;
  final double? referenceRate;
  final double? referenceBase;
  final DateTime createdAt;

  /// item_type → 한국어 라벨
  String get label => _itemTypeLabels[itemType] ?? itemType;

  factory DeliverySettlementItem.fromJson(Map<String, dynamic> json) {
    return DeliverySettlementItem(
      id: json['id'].toString(),
      settlementId: json['settlement_id'].toString(),
      itemType: json['item_type']?.toString() ?? '',
      amount: _toDouble(json['amount']),
      description: json['description']?.toString(),
      referenceRate: json['reference_rate'] != null
          ? _toDouble(json['reference_rate'])
          : null,
      referenceBase: json['reference_base'] != null
          ? _toDouble(json['reference_base'])
          : null,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

const Map<String, String> _itemTypeLabels = {
  'platform_commission': 'Platform Fee',
  'payment_fee': 'Payment Fee',
  'advertising': 'Ad Spend',
  'insight_report': 'Insight Report',
  'promo_subsidy': 'Promotion Subsidy',
  'delivery_subsidy': 'Delivery Fee Subsidy',
  'photo_service': 'Take Photo',
};

// ─── 정산 헤더 ──────────────────────────────

class DeliverySettlement {
  const DeliverySettlement({
    required this.id,
    required this.storeId,
    required this.periodLabel,
    required this.periodStart,
    required this.periodEnd,
    required this.grossTotal,
    required this.totalDeductions,
    required this.netSettlement,
    required this.status,
    this.receivedAt,
    this.notes,
    this.items = const [],
    this.orderCount = 0,
  });

  final String id;
  final String storeId;
  final String periodLabel;
  final DateTime periodStart;
  final DateTime periodEnd;
  final double grossTotal;
  final double totalDeductions;
  final double netSettlement;
  final String status;
  final DateTime? receivedAt;
  final String? notes;
  final List<DeliverySettlementItem> items;
  final int orderCount;

  /// 상태 배지
  String get statusEmoji => switch (status) {
    'pending' => '⏳',
    'calculated' => '📋',
    'received' => '✅',
    'disputed' => '⚠️',
    'adjusted' => '🔧',
    _ => '❓',
  };

  String get statusLabel => switch (status) {
    'pending' => 'Settlement Pending',
    'calculated' => 'Statement Generated',
    'received' => 'Settlement Complete',
    'disputed' => 'Dispute',
    'adjusted' => 'Adjustment Complete',
    _ => status,
  };

  bool get canConfirmReceived => status == 'calculated';

  /// v_settlement_summary 뷰에서 생성
  factory DeliverySettlement.fromJson(Map<String, dynamic> json) {
    final itemsRaw = json['items'];
    List<DeliverySettlementItem> items = [];
    if (itemsRaw is List) {
      items = itemsRaw.map<DeliverySettlementItem>((e) {
        final map = Map<String, dynamic>.from(e);
        return DeliverySettlementItem(
          id: map['item_type']?.toString() ?? '',
          settlementId: '',
          itemType: map['item_type']?.toString() ?? '',
          amount: _toDouble(map['amount']),
          description: map['description']?.toString(),
          referenceRate: map['reference_rate'] != null
              ? _toDouble(map['reference_rate'])
              : null,
          referenceBase: null,
          createdAt: DateTime.now(),
        );
      }).toList();
    }

    return DeliverySettlement(
      id: json['id'].toString(),
      storeId: json['restaurant_id'].toString(),
      periodLabel: json['period_label']?.toString() ?? '',
      periodStart: DateTime.tryParse(
              json['period_start']?.toString() ?? '') ??
          DateTime.now(),
      periodEnd:
          DateTime.tryParse(json['period_end']?.toString() ?? '') ??
              DateTime.now(),
      grossTotal: _toDouble(json['gross_total']),
      totalDeductions: _toDouble(json['total_deductions']),
      netSettlement: _toDouble(json['net_settlement']),
      status: json['status']?.toString() ?? 'pending',
      receivedAt: json['received_at'] != null
          ? DateTime.tryParse(json['received_at'].toString())
          : null,
      notes: json['notes']?.toString(),
      items: items,
      orderCount: json['order_count'] is int
          ? json['order_count'] as int
          : int.tryParse(json['order_count']?.toString() ?? '0') ?? 0,
    );
  }
}

// ─── 미수금 요약 ─────────────────────────────

class UnsettledRevenueSummary {
  const UnsettledRevenueSummary({
    required this.revenue,
    required this.orderCount,
  });

  final double revenue;
  final int orderCount;
}

// ─── 유틸 ────────────────────────────────────

double _toDouble(dynamic value) {
  return switch (value) {
    num v => v.toDouble(),
    String v => double.tryParse(v) ?? 0,
    _ => 0,
  };
}
