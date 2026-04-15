import '../../main.dart';

class EinvoiceService {
  Future<Map<String, String?>?> lookupCompanyByTaxCode(String taxCode) async {
    final response = await supabase.functions.invoke(
      'wetax-onboarding',
      body: {'operation': 'company_lookup', 'tax_code': taxCode},
    );

    if (response.status != 200) {
      throw Exception('WT09 lookup failed');
    }

    final payload = response.data;
    if (payload is! Map) return null;
    final result = Map<String, dynamic>.from(payload);
    final inner = result['result'];
    if (inner is! Map) return null;

    final httpStatus = inner['http_status'];
    if (httpStatus is int && httpStatus >= 400) {
      return null;
    }

    final body = inner['body'];
    if (body is! Map) return null;
    final data = body['data'];
    if (data is! Map) return null;

    final normalized = Map<String, dynamic>.from(data);
    return {
      'tax_company_name':
          normalized['vietnam_name']?.toString() ??
          normalized['english_name']?.toString(),
      'tax_address': normalized['address']?.toString(),
      'receiver_email': normalized['email']?.toString(),
      'tax_id':
          normalized['tax_id']?.toString() ??
          normalized['tax_code']?.toString(),
    };
  }

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
      'tax_company_name': map['tax_company_name']?.toString(),
      'tax_address': map['tax_address']?.toString(),
      'receiver_email': map['receiver_email']?.toString(),
      'receiver_email_cc': map['receiver_email_cc']?.toString(),
    };
  }
}

final einvoiceService = EinvoiceService();
