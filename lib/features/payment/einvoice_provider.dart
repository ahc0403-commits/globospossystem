import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../main.dart';

class EinvoiceJobStatus {
  const EinvoiceJobStatus({
    required this.status,
    this.sid,
    this.lookupUrl,
    this.errorClassification,
    this.redinvoiceRequested = false,
  });

  final String status;
  final String? sid;
  final String? lookupUrl;
  final String? errorClassification;
  final bool redinvoiceRequested;

  bool get isDispatched =>
      status == 'sent_to_misa' || status == 'sent_to_tax_authority';
  bool get isFailed => status == 'failed' || status == 'manual_action_required';
  bool get isPending =>
      status == 'pending' ||
      status == 'pending_manual_config' ||
      status == 'dispatch_paused';
  bool get isIssued => status == 'valid_invoice';
}

final einvoiceJobStatusProvider = FutureProvider.autoDispose
    .family<EinvoiceJobStatus?, String>((ref, orderId) async {
      final result = await supabase
          .from('meinvoice_jobs')
          .select('status, transaction_id, manual_action_type, buyer_kind')
          .eq('order_id', orderId)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();

      if (result == null) return null;

      return EinvoiceJobStatus(
        status: result['status'] ?? 'unknown',
        sid: result['transaction_id']?.toString(),
        lookupUrl: null,
        errorClassification: result['manual_action_type']?.toString(),
        redinvoiceRequested: result['buyer_kind']?.toString() != 'anonymous',
      );
    });
