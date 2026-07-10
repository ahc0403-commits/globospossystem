import '../../main.dart';

class EinvoiceService {
  /// Request a red invoice for an already-paid order.
  /// Returns the job_id on success.
  Future<String> requestRedInvoice({
    required String orderId,
    required String storeId,
    required String receiverEmail,
    String? buyerTaxCode,
    String? buyerName,
    String? buyerAddress,
    String? receiverEmailCc,
    String? buyerTel,
    String? unitCode,
    String? unitName,
    String? buyerFullName,
    String? buyerId,
  }) async {
    final result = await supabase.rpc(
      'request_red_invoice',
      params: {
        'p_order_id': orderId,
        'p_store_id': storeId,
        'p_buyer_tax_code': buyerTaxCode ?? '',
        'p_buyer_name': buyerName ?? '',
        'p_buyer_address': buyerAddress ?? '',
        'p_receiver_email': receiverEmail,
        'p_receiver_email_cc': receiverEmailCc,
        'p_buyer_tel': buyerTel,
        'p_unit_code': unitCode,
        'p_unit_name': unitName,
        'p_buyer_full_name': buyerFullName,
        'p_buyer_id': buyerId,
      },
    );
    final map = Map<String, dynamic>.from(result as Map);
    if (map['ok'] != true) throw Exception('request_red_invoice failed');
    return map['job_id'].toString();
  }

  /// Look up cached buyer data for autocomplete.
  /// Returns null if not found.
  Future<Map<String, String?>?> lookupB2bBuyer({
    required String storeId,
    required String taxCode,
  }) async {
    final result = await supabase.rpc(
      'lookup_b2b_buyer',
      params: {'p_store_id': storeId, 'p_tax_code': taxCode},
    );
    if (result == null) return null;
    final map = Map<String, dynamic>.from(result as Map);
    return {
      'buyer_tax_code': map['buyer_tax_code']?.toString(),
      'buyer_unit_code': map['buyer_unit_code']?.toString(),
      'tax_company_name': map['tax_company_name']?.toString(),
      'tax_address': map['tax_address']?.toString(),
      'tax_buyer_name': map['tax_buyer_name']?.toString(),
      'buyer_full_name': map['buyer_full_name']?.toString(),
      'buyer_id': map['buyer_id']?.toString(),
      'buyer_phone': map['buyer_phone']?.toString(),
      'receiver_email': map['receiver_email']?.toString(),
      'receiver_email_cc': map['receiver_email_cc']?.toString(),
    };
  }
}

final einvoiceService = EinvoiceService();
