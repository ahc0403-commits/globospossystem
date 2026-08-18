import '../../features/digital_receipt/digital_receipt_model.dart';
import '../constants/app_constants.dart';
import '../../main.dart';

class DigitalReceiptService {
  const DigitalReceiptService();

  Future<DigitalReceiptAccess> ensureAndIssue({
    required String orderId,
    double? receivedAmount,
    double? changeAmount,
  }) async {
    final ensuredRaw = await supabase.rpc(
      'ensure_digital_receipt',
      params: {
        'p_order_id': orderId,
        'p_received_amount': receivedAmount,
        'p_change_amount': changeAmount,
      },
    );
    return _accessFromEnsured(ensuredRaw);
  }

  Future<DigitalReceiptAccess> ensureCombinedAndIssue({
    required String combinedPaymentGroupId,
    double? receivedAmount,
    double? changeAmount,
  }) async {
    final ensuredRaw = await supabase.rpc(
      'ensure_combined_digital_receipt',
      params: {
        'p_group_id': combinedPaymentGroupId,
        'p_received_amount': receivedAmount,
        'p_change_amount': changeAmount,
      },
    );
    return _accessFromEnsured(ensuredRaw);
  }

  Future<DigitalReceiptAccess> _accessFromEnsured(Object? ensuredRaw) async {
    final ensured = Map<String, dynamic>.from(ensuredRaw as Map);
    final receiptId = ensured['receipt_id']?.toString() ?? '';
    if (receiptId.isEmpty) {
      throw StateError('DIGITAL_RECEIPT_ID_MISSING');
    }
    final link = await issueLink(receiptId);
    final snapshotRaw = ensured['snapshot'];
    return DigitalReceiptAccess(
      receiptId: receiptId,
      receiptNumber: ensured['receipt_number']?.toString() ?? '-',
      token: link.token,
      publicUrl: link.publicUrl,
      snapshot: snapshotRaw is Map
          ? DigitalReceipt.fromJson({
              ...Map<String, dynamic>.from(snapshotRaw),
              'receipt_id': receiptId,
            })
          : null,
    );
  }

  Future<DigitalReceiptAccess> issueLink(String receiptId) async {
    final raw = await supabase.rpc(
      'issue_digital_receipt_link',
      params: {'p_receipt_id': receiptId},
    );
    final result = Map<String, dynamic>.from(raw as Map);
    final token = result['token']?.toString() ?? '';
    if (token.isEmpty) {
      throw StateError('DIGITAL_RECEIPT_TOKEN_MISSING');
    }
    return DigitalReceiptAccess(
      receiptId: result['receipt_id']?.toString() ?? receiptId,
      receiptNumber: '-',
      token: token,
      publicUrl: publicUrlForToken(token),
    );
  }

  Future<DigitalReceipt?> fetchPublic(String token) async {
    final response = await supabase.functions.invoke(
      'public-receipt',
      body: {'token': token},
    );
    if (response.status == 404) return null;
    if (response.status < 200 || response.status >= 300) {
      throw StateError('DIGITAL_RECEIPT_LOOKUP_FAILED');
    }
    final raw = response.data;
    if (raw is! Map) return null;
    return DigitalReceipt.fromJson(Map<String, dynamic>.from(raw));
  }

  static String publicUrlForToken(String token) {
    return '${AppConstants.posPublicUrl}/receipt#token='
        '${Uri.encodeComponent(token)}';
  }
}

const digitalReceiptService = DigitalReceiptService();
