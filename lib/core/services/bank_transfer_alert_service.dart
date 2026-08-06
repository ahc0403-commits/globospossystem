import '../../main.dart';
import '../layout/platform_info.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

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
  static const _cursorReceivedAtPrefix = 'sepay_alert_received_at_';
  static const _cursorProviderIdPrefix = 'sepay_alert_provider_id_';
  static const _installationIdKey = 'sepay_alert_installation_id';

  Future<String> installationId() async {
    final preferences = await SharedPreferences.getInstance();
    final existing = preferences.getString(_installationIdKey)?.trim();
    if (existing != null && existing.length >= 8) return existing;

    final created = const Uuid().v4();
    await preferences.setString(_installationIdKey, created);
    return created;
  }

  Future<void> registerPollingDevice(String storeId) async {
    final id = await installationId();
    await supabase.rpc(
      'upsert_sepay_alert_device',
      params: {
        'p_store_id': storeId,
        'p_installation_id': id,
        'p_platform': PlatformInfo.alertPlatform,
        'p_push_provider': 'polling',
      },
    );
  }

  Future<void> registerPushDevice(String storeId, String pushToken) async {
    final id = await installationId();
    await supabase.rpc(
      'upsert_sepay_alert_device',
      params: {
        'p_store_id': storeId,
        'p_installation_id': id,
        'p_platform': PlatformInfo.alertPlatform,
        'p_push_provider': 'fcm',
        'p_push_token': pushToken,
      },
    );
  }

  Future<bool> acknowledge(String transactionId, {required bool spoken}) async {
    final result = await supabase.rpc(
      'ack_sepay_alert_delivery',
      params: {
        'p_transaction_id': transactionId,
        'p_installation_id': await installationId(),
        'p_status': spoken ? 'spoken' : 'seen',
      },
    );
    return result == true;
  }

  Future<List<BankTransferAlert>> fetchAfter(
    String storeId,
    BankTransferAlertCursor cursor, {
    int limit = 100,
  }) async {
    final result = await supabase.rpc(
      'get_sepay_payment_alerts_after',
      params: {
        'p_store_id': storeId,
        'p_after_received_at': cursor.receivedAt.toIso8601String(),
        'p_after_provider_transaction_id': cursor.providerTransactionId,
        'p_limit': limit,
      },
    );
    if (result is! List) return const [];
    return result
        .map(
          (row) =>
              BankTransferAlert.fromJson(Map<String, dynamic>.from(row as Map)),
        )
        .toList(growable: false);
  }

  Future<BankTransferAlertCursor?> loadCursor(String storeId) async {
    final preferences = await SharedPreferences.getInstance();
    final receivedAt = DateTime.tryParse(
      preferences.getString('$_cursorReceivedAtPrefix$storeId') ?? '',
    );
    final providerTransactionId = int.tryParse(
      preferences.getString('$_cursorProviderIdPrefix$storeId') ?? '',
    );
    if (receivedAt == null || providerTransactionId == null) return null;
    return BankTransferAlertCursor(
      receivedAt: receivedAt.toUtc(),
      providerTransactionId: providerTransactionId,
    );
  }

  Future<void> saveCursor(
    String storeId,
    BankTransferAlertCursor cursor,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      '$_cursorReceivedAtPrefix$storeId',
      cursor.receivedAt.toIso8601String(),
    );
    await preferences.setString(
      '$_cursorProviderIdPrefix$storeId',
      cursor.providerTransactionId.toString(),
    );
  }
}

class BankTransferAlertCursor {
  BankTransferAlertCursor({
    required DateTime receivedAt,
    required this.providerTransactionId,
  }) : receivedAt = receivedAt.toUtc();

  factory BankTransferAlertCursor.startedNow() => BankTransferAlertCursor(
    receivedAt: DateTime.now().toUtc(),
    providerTransactionId: 0,
  );

  DateTime receivedAt;
  int providerTransactionId;

  bool isBefore(BankTransferAlert alert) {
    final receivedComparison = receivedAt.compareTo(alert.receivedAt.toUtc());
    return receivedComparison < 0 ||
        (receivedComparison == 0 &&
            providerTransactionId < alert.providerTransactionId);
  }

  void advance(BankTransferAlert alert) {
    if (!isBefore(alert)) return;
    receivedAt = alert.receivedAt.toUtc();
    providerTransactionId = alert.providerTransactionId;
  }
}

final bankTransferAlertService = BankTransferAlertService();
