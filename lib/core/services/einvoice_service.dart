import '../../main.dart';

class EinvoiceService {
  /// Request a red invoice for an already-paid order.
  /// Returns the job_id on success.
  Future<String> requestRedInvoice({
    required String orderId,
    required String receiverEmail,
    String? buyerTaxCode,
    String? buyerName,
    String? buyerAddress,
    String? receiverEmailCc,
    String? buyerTel,
  }) async {
    final result = await supabase.rpc('request_red_invoice', params: {
      'p_order_id': orderId,
      'p_buyer_tax_code': buyerTaxCode ?? '',
      'p_buyer_name': buyerName ?? '',
      'p_buyer_address': buyerAddress ?? '',
      'p_receiver_email': receiverEmail,
      'p_receiver_email_cc': receiverEmailCc,
      'p_buyer_tel': buyerTel,
    });
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
    final result = await supabase.rpc('lookup_b2b_buyer', params: {
      'p_store_id': storeId,
      'p_tax_code': taxCode,
    });
    if (result == null) return null;
    final map = Map<String, dynamic>.from(result as Map);
    return {
      'tax_company_name': map['tax_company_name']?.toString(),
      'tax_address': map['tax_address']?.toString(),
      'receiver_email': map['receiver_email']?.toString(),
      'receiver_email_cc': map['receiver_email_cc']?.toString(),
    };
  }
}

final einvoiceService = EinvoiceService();
