import '../../core/services/payment_service.dart';
import '../../main.dart';
import 'receipt_ledger_model.dart';

class ReceiptLedgerService {
  const ReceiptLedgerService();

  Future<ReceiptLedgerPage> load({
    required String businessDate,
    String? storeId,
    String? query,
    String? status,
    int limit = 50,
    int offset = 0,
    DateTime? afterAt,
    String? afterId,
    ReceiptLedgerSummary? knownSummary,
  }) async {
    final response = await supabase.rpc(
      'get_receipt_ledger_page',
      params: {
        'p_business_date': businessDate,
        'p_store_id': storeId,
        'p_query': query,
        'p_status': status,
        'p_limit': limit,
        'p_offset': offset,
        'p_after_at': afterAt?.toUtc().toIso8601String(),
        'p_after_id': afterId,
        'p_include_summary': knownSummary == null,
      },
    );
    if (response is! Map) {
      throw const FormatException('RECEIPT_LEDGER_INVALID_RESPONSE');
    }
    final data = Map<String, dynamic>.from(response);
    if (knownSummary != null) {
      data['summary'] = {
        'receipt_count': knownSummary.receiptCount,
        'gross_amount': knownSummary.grossAmount,
        'adjusted_amount': knownSummary.adjustedAmount,
        'net_amount': knownSummary.netAmount,
      };
    }
    if (data['receipts'] is! List ||
        (data['receipts'] as List).length > limit ||
        data['has_more'] is! bool) {
      throw const FormatException('RECEIPT_LEDGER_INVALID_RESPONSE');
    }
    return ReceiptLedgerPage.fromJson(data);
  }

  Future<Map<String, dynamic>> reprint(ReceiptLedgerEntry entry) {
    final combinedPaymentGroupId = entry.combinedPaymentGroupId;
    if (combinedPaymentGroupId != null) {
      return paymentService.enqueueCombinedReceiptPrintJob(
        combinedPaymentGroupId: combinedPaymentGroupId,
        receivedAmount: entry.receivedAmount,
        reprint: true,
      );
    }
    final orderId = entry.orderId;
    if (orderId == null) {
      throw const FormatException('RECEIPT_LEDGER_REPRINT_ANCHOR_REQUIRED');
    }
    return paymentService.enqueueReceiptPrintJob(
      orderId: orderId,
      reprint: true,
    );
  }
}

const receiptLedgerService = ReceiptLedgerService();
