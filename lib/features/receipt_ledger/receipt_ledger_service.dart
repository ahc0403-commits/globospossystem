import '../../core/services/payment_service.dart';
import '../../main.dart';
import 'receipt_ledger_model.dart';

class ReceiptLedgerService {
  const ReceiptLedgerService();

  Future<ReceiptLedgerPage> loadToday({
    String? storeId,
    String? query,
    String? status,
    int limit = 100,
    int offset = 0,
  }) async {
    final response = await supabase.rpc(
      'get_today_receipt_ledger',
      params: {
        'p_store_id': storeId,
        'p_query': query,
        'p_status': status,
        'p_limit': limit,
        'p_offset': offset,
      },
    );
    if (response is! Map) {
      throw const FormatException('TODAY_RECEIPT_LEDGER_INVALID_RESPONSE');
    }
    return ReceiptLedgerPage.fromJson(Map<String, dynamic>.from(response));
  }

  Future<Map<String, dynamic>> reprint(String orderId) =>
      paymentService.enqueueReceiptPrintJob(orderId: orderId, reprint: true);
}

const receiptLedgerService = ReceiptLedgerService();
