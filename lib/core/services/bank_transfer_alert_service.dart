import '../../main.dart';

class BankTransferAlert {
  const BankTransferAlert({
    required this.transactionId,
    required this.providerTransactionId,
    required this.amount,
    required this.gateway,
    required this.receivedAt,
    this.paymentCode,
    this.transactionAt,
  });

  final String transactionId;
  final int providerTransactionId;
  final int amount;
  final String gateway;
  final String? paymentCode;
  final DateTime? transactionAt;
  final DateTime receivedAt;

  factory BankTransferAlert.fromJson(Map<String, dynamic> json) {
    return BankTransferAlert(
      transactionId: json['transaction_id'].toString(),
      providerTransactionId: _toInt(json['provider_transaction_id']),
      amount: _toInt(json['amount']),
      paymentCode: json['payment_code']?.toString(),
      gateway: json['gateway']?.toString() ?? '',
      transactionAt: DateTime.tryParse(
        json['transaction_at']?.toString() ?? '',
      ),
      receivedAt:
          DateTime.tryParse(json['received_at']?.toString() ?? '') ??
          DateTime.now().toUtc(),
    );
  }

  static int _toInt(dynamic value) => switch (value) {
    int number => number,
    num number => number.toInt(),
    String text => int.tryParse(text) ?? 0,
    _ => 0,
  };
}

class BankTransferAlertService {
  Future<BankTransferAlert?> fetchLatest(String storeId) async {
    final result = await supabase.rpc(
      'get_latest_sepay_payment_alert',
      params: {'p_store_id': storeId},
    );
    if (result is! List || result.isEmpty) return null;
    return BankTransferAlert.fromJson(
      Map<String, dynamic>.from(result.first as Map),
    );
  }
}

class BankTransferAlertCursor {
  BankTransferAlertCursor({required this.startedAt});

  final DateTime startedAt;
  String? _lastTransactionId;

  String? get lastTransactionId => _lastTransactionId;

  bool shouldNotify(BankTransferAlert alert) {
    if (alert.transactionId == _lastTransactionId) return false;

    final hasBaseline = _lastTransactionId != null;
    _lastTransactionId = alert.transactionId;
    return hasBaseline || !alert.receivedAt.isBefore(startedAt);
  }
}

final bankTransferAlertService = BankTransferAlertService();
