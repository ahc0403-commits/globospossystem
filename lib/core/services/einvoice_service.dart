import '../../main.dart';
import '../../features/red_invoice_intake/red_invoice_intake_service.dart';

class EinvoiceService {
  /// Register the mandatory buyer information used by the unified MISA report.
  /// MISA dispatch remains asynchronous and never blocks payment completion.
  Future<String> requestRedInvoice({
    required String orderId,
    required String storeId,
    required String buyerTaxCode,
    required String buyerLegalName,
    required String buyerAddress,
    required String buyerEmail,
    required String buyerPhone,
  }) async {
    final intake = await redInvoiceIntakeService.save(
      orderId: orderId,
      storeId: storeId,
      source: 'cashier',
      status: 'ready',
      buyerTaxCode: buyerTaxCode,
      buyerLegalName: buyerLegalName,
      buyerAddress: buyerAddress,
      buyerEmail: buyerEmail,
      buyerPhone: buyerPhone,
    );
    return intake.meInvoiceJobId ?? intake.id;
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
      'buyer_phone': map['buyer_phone']?.toString(),
    };
  }
}

final einvoiceService = EinvoiceService();
