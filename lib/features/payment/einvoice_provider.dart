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
      status == 'dispatched' || status == 'dispatched_polling_disabled';
  bool get isFailed => status == 'failed_terminal' || status == 'stale';
  bool get isPending => status == 'pending';
  bool get isIssued => status == 'issued_by_portal' || status == 'reported';
}

final einvoiceJobStatusProvider =
    FutureProvider.autoDispose.family<EinvoiceJobStatus?, String>((ref, orderId) async {
  final result = await supabase
      .from('einvoice_jobs')
      .select('status, sid, lookup_url, error_classification, redinvoice_requested')
      .eq('order_id', orderId)
      .order('created_at', ascending: false)
      .limit(1)
      .maybeSingle();

  if (result == null) return null;

  return EinvoiceJobStatus(
    status: result['status'] ?? 'unknown',
    sid: result['sid']?.toString(),
    lookupUrl: result['lookup_url']?.toString(),
    errorClassification: result['error_classification']?.toString(),
    redinvoiceRequested: result['redinvoice_requested'] == true,
  );
});
