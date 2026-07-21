import '../../main.dart';
import '../../features/red_invoice_intake/red_invoice_intake_service.dart';

class EinvoiceService {
  /// Register complete buyer information for the separate red-invoice batch.
  /// The original all-receipts export remains unchanged and MISA dispatch is
  /// never part of payment completion.
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
    final intake = await redInvoiceIntakeService.save(
      orderId: orderId,
      storeId: storeId,
      source: 'cashier',
      status: 'ready',
      buyerTaxCode: buyerTaxCode,
      buyerUnitCode: unitCode,
      buyerLegalName: unitName ?? buyerName,
      buyerFullName: buyerFullName,
      buyerAddress: buyerAddress,
      buyerEmail: receiverEmail,
      buyerEmailCc: receiverEmailCc,
      buyerPhone: buyerTel,
      buyerId: buyerId,
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
