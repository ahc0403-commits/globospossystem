import '../../main.dart';

typedef LateInvoiceRpc =
    Future<dynamic> Function(String name, Map<String, dynamic> params);

class LateInvoiceTarget {
  const LateInvoiceTarget({
    required this.storeId,
    required this.receiptNumber,
    this.orderId,
    this.combinedPaymentGroupId,
  });

  final String storeId;
  final String receiptNumber;
  final String? orderId;
  final String? combinedPaymentGroupId;

  Map<String, dynamic> get params => {
    'p_store_id': storeId,
    'p_order_id': combinedPaymentGroupId == null ? orderId : null,
    'p_combined_payment_group_id': combinedPaymentGroupId,
  };
}

class LateInvoiceContext {
  LateInvoiceContext(Map<String, dynamic> json)
    : state = json['state']?.toString() ?? 'review',
      canEdit = json['can_edit'] == true,
      buyer = Map<String, dynamic>.from(json['buyer'] as Map? ?? const {}),
      versions = Map<String, dynamic>.from(
        json['versions'] as Map? ?? const {},
      ),
      orderIds = (json['order_ids'] as List? ?? const []).cast<String>(),
      storeName = json['store_name']?.toString() ?? '',
      waitReason = json['wait_reason']?.toString() ?? 'operator',
      grossAmount = (json['gross_amount'] as num?)?.toDouble() ?? 0;

  final String state;
  final bool canEdit;
  final Map<String, dynamic> buyer;
  final Map<String, dynamic> versions;
  final List<String> orderIds;
  final String storeName;
  final String waitReason;
  final double grossAmount;
}

class LateInvoiceService {
  LateInvoiceService({LateInvoiceRpc? rpc, String Function()? sessionScope})
    : _rpc = rpc ?? ((name, params) => supabase.rpc(name, params: params)),
      _sessionScope =
          sessionScope ??
          (() => supabase.auth.currentSession?.accessToken ?? '');

  final LateInvoiceRpc _rpc;
  final String Function() _sessionScope;

  Future<LateInvoiceContext> _call(
    String name,
    Map<String, dynamic> params,
  ) async {
    final session = _sessionScope();
    final value = await _rpc(name, params);
    if (session != _sessionScope()) {
      throw StateError('POS_LEDGER_SESSION_CHANGED');
    }
    if (value is! Map) {
      throw const FormatException('LATE_INVOICE_INVALID_RESPONSE');
    }
    return LateInvoiceContext(Map<String, dynamic>.from(value));
  }

  Future<LateInvoiceContext> load(LateInvoiceTarget target) =>
      _call('pos_late_invoice_context', target.params);

  Future<LateInvoiceContext> submit({
    required LateInvoiceTarget target,
    required String requestId,
    required Map<String, dynamic> versions,
    required Map<String, dynamic> patch,
    required bool confirm,
  }) => _call('pos_submit_late_invoice', {
    ...target.params,
    'p_request_id': requestId,
    'p_expected_versions': versions,
    'p_patch': patch,
    'p_confirm': confirm,
  });
}
