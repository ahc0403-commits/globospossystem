import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants/app_constants.dart';
import '../../main.dart';
import 'direct_order_service.dart';

String directOrderStaffErrorCode(Object error) {
  if (error is DirectOrderException) return error.code;
  if (error is PostgrestException) {
    final match = RegExp(
      r'\b(?:DIRECT_ORDER|DIRECT_DELIVERY)_[A-Z0-9_]+\b',
    ).firstMatch(error.message);
    if (match != null) return match.group(0)!;
  }
  return 'DIRECT_ORDER_TEMPORARILY_UNAVAILABLE';
}

String? normalizeDeliveryTrackingUrl(String input) {
  var value = input.trim();
  if (value.isEmpty || value.length > 2000 || RegExp(r'\s').hasMatch(value)) {
    return null;
  }
  if (!value.contains('://')) value = 'https://$value';
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      !RegExp(
        r'^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$',
      ).hasMatch(uri.host) ||
      value.length > 2000) {
    return null;
  }
  return uri.toString();
}

// Kept for existing callers; provider identity is independent of URL validation.
String? normalizeGrabTrackingUrl(String input) =>
    normalizeDeliveryTrackingUrl(input);

class DirectOrderAvailability {
  const DirectOrderAvailability({
    required this.configured,
    required this.enabled,
    required this.paused,
    required this.updatedAt,
    this.hoursOpen = true,
  });

  final bool configured;
  final bool enabled;
  final bool paused;
  final DateTime? updatedAt;
  final bool hoursOpen;

  bool get acceptingOrders => configured && enabled && !paused && hoursOpen;
  bool get canChange => configured && enabled && hoursOpen;

  factory DirectOrderAvailability.fromJson(Map<String, dynamic> json) {
    const expected = {'configured', 'enabled', 'paused', 'updated_at'};
    const allowed = {...expected, 'hours_open'};
    if (json.keys.toSet().difference(allowed).isNotEmpty ||
        expected.difference(json.keys.toSet()).isNotEmpty ||
        json['configured'] is! bool ||
        json['enabled'] is! bool ||
        json['paused'] is! bool ||
        (json.containsKey('hours_open') && json['hours_open'] is! bool)) {
      throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
    }
    final rawUpdatedAt = json['updated_at'];
    final updatedAt = rawUpdatedAt == null
        ? null
        : rawUpdatedAt is String
        ? DateTime.tryParse(rawUpdatedAt)
        : null;
    if (rawUpdatedAt != null && updatedAt == null) {
      throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
    }
    return DirectOrderAvailability(
      configured: json['configured'] as bool,
      enabled: json['enabled'] as bool,
      paused: json['paused'] as bool,
      updatedAt: updatedAt,
      hoursOpen: json['hours_open'] as bool? ?? true,
    );
  }
}

class DirectOrderDriverReceiptStatus {
  const DirectOrderDriverReceiptStatus({
    required this.exists,
    required this.status,
    required this.batchNo,
    required this.lastErrorCode,
    required this.canReprint,
  });

  const DirectOrderDriverReceiptStatus.empty()
    : exists = false,
      status = null,
      batchNo = null,
      lastErrorCode = null,
      canReprint = false;

  final bool exists;
  final String? status;
  final int? batchNo;
  final String? lastErrorCode;
  final bool canReprint;

  factory DirectOrderDriverReceiptStatus.fromJson(Map<String, dynamic> json) {
    return DirectOrderDriverReceiptStatus(
      exists: json['exists'] == true,
      status: json['status']?.toString(),
      batchNo: switch (json['batch_no']) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value),
        _ => null,
      },
      lastErrorCode: json['last_error_code']?.toString(),
      canReprint: json['can_reprint'] == true,
    );
  }
}

enum DirectOrderDeliveryPaymentMode {
  customerDirect('customer_direct'),
  storePrepaid('store_prepaid'),
  notApplicable('not_applicable');

  const DirectOrderDeliveryPaymentMode(this.value);

  final String value;

  static DirectOrderDeliveryPaymentMode fromValue(Object? value) =>
      value == notApplicable.value
      ? notApplicable
      : value == storePrepaid.value
      ? storePrepaid
      : customerDirect;
}

class DirectOrderStaffService {
  const DirectOrderStaffService();

  Future<Map<String, dynamic>?> fetchOrderPackingContext({
    required String orderId,
    required String storeId,
  }) async {
    final result = await supabase.rpc(
      'direct_order_receipt_packing_context',
      params: {'p_order_id': orderId, 'p_store_id': storeId},
    );
    return result == null ? null : Map<String, dynamic>.from(result as Map);
  }

  Map<String, dynamic> _map(Object? raw) {
    if (raw is! Map) {
      throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
    }
    return Map<String, dynamic>.from(raw);
  }

  List<Map<String, dynamic>> _list(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> listRequests({
    required String storeId,
    List<String>? states,
    String? fulfillmentType,
    int limit = 100,
  }) async {
    final raw = await supabase.rpc(
      'direct_order_staff_list_v3',
      params: {
        'p_store_id': storeId,
        'p_states': states,
        'p_limit': limit,
        'p_fulfillment_type': fulfillmentType,
      },
    );
    return _list(raw);
  }

  Future<Map<String, dynamic>> requestDetail({
    required String storeId,
    required String requestId,
  }) async {
    return _map(
      await supabase.rpc(
        'direct_order_staff_detail_v4',
        params: {'p_store_id': storeId, 'p_request_id': requestId},
      ),
    );
  }

  Future<Map<String, dynamic>> quote({
    required String storeId,
    required String requestId,
    required double deliveryFee,
    required DirectOrderDeliveryPaymentMode deliveryPaymentMode,
    String? note,
  }) async {
    return _map(
      await supabase.rpc(
        'direct_order_staff_quote_with_payment_mode',
        params: {
          'p_store_id': storeId,
          'p_request_id': requestId,
          'p_delivery_fee_total': deliveryFee,
          'p_cashier_note': note,
          'p_delivery_payment_mode': deliveryPaymentMode.value,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> sendMessage({
    required String storeId,
    required String requestId,
    required String message,
  }) async {
    return _map(
      await supabase.rpc(
        'direct_order_staff_message',
        params: {
          'p_store_id': storeId,
          'p_request_id': requestId,
          'p_body': message,
        },
      ),
    );
  }

  Future<void> reject({
    required String storeId,
    required String requestId,
    required String reason,
  }) async {
    await supabase.rpc(
      'direct_order_staff_reject',
      params: {
        'p_store_id': storeId,
        'p_request_id': requestId,
        'p_reason': reason,
      },
    );
  }

  Future<List<Map<String, dynamic>>> sepayCandidates({
    required String storeId,
    required String requestId,
  }) async {
    return _list(
      await supabase.rpc(
        'direct_order_staff_sepay_candidates_v2',
        params: {'p_store_id': storeId, 'p_request_id': requestId},
      ),
    );
  }

  Future<void> linkSepay({
    required String storeId,
    required String requestId,
    required String transactionId,
  }) async {
    await supabase.rpc(
      'direct_order_staff_link_sepay',
      params: {
        'p_store_id': storeId,
        'p_request_id': requestId,
        'p_transaction_id': transactionId,
      },
    );
  }

  Future<Map<String, dynamic>?> verifiedPaymentEvidence({
    required String storeId,
    required String requestId,
  }) async {
    final result = await supabase.rpc(
      'direct_order_staff_verified_payment_evidence',
      params: {'p_store_id': storeId, 'p_request_id': requestId},
    );
    if (result == null) return null;
    return _map(result);
  }

  Future<Map<String, dynamic>> recordReceipt({
    required String storeId,
    required String requestId,
    required String quoteId,
    required String proofMessageId,
    required num amount,
    required String bankReference,
  }) async => _map(
    await supabase.rpc(
      'direct_order_record_receipt',
      params: {
        'p_store_id': storeId,
        'p_request_id': requestId,
        'p_quote_id': quoteId,
        'p_proof_message_id': proofMessageId,
        'p_amount': amount,
        'p_bank_reference': bankReference,
      },
    ),
  );

  Future<Map<String, dynamic>> supportAction({
    required String storeId,
    required String requestId,
    required int expectedVersion,
    required String action,
    Map<String, dynamic> payload = const {},
  }) async => _map(
    await supabase.rpc(
      'direct_order_staff_support_action',
      params: {
        'p_store_id': storeId,
        'p_request_id': requestId,
        'p_expected_version': expectedVersion,
        'p_action': action,
        'p_payload': payload,
      },
    ),
  );

  Future<Map<String, dynamic>> attachmentRequest({
    required String storeId,
    required String requestId,
    required String action,
    Map<String, dynamic> payload = const {},
  }) async {
    try {
      final response = await supabase.functions.invoke(
        'direct-order-public',
        body: {
          ...payload,
          'action': action,
          'store_id': storeId,
          'request_id': requestId,
        },
      );
      if (response.status != 200) {
        throw DirectOrderException(
          response.data is Map
              ? response.data['error'].toString()
              : 'DIRECT_ORDER_ATTACHMENT_INVALID',
        );
      }
      final envelope = _map(response.data);
      if (envelope['data'] is! Map) {
        throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
      }
      return _map(envelope['data']);
    } on FunctionException catch (error) {
      throw DirectOrderException(
        error.details is Map
            ? error.details['error'].toString()
            : 'DIRECT_ORDER_ATTACHMENT_INVALID',
      );
    }
  }

  Future<void> uploadChatAttachment({
    required String storeId,
    required String requestId,
    required String path,
    required String filename,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    final payload = {'path': path, 'filename': filename, 'mime_type': mimeType};
    // A previous upload or commit may have succeeded despite a lost response.
    // Recover the same immutable path first; only a missing object needs upload.
    try {
      await attachmentRequest(
        storeId: storeId,
        requestId: requestId,
        action: 'staff_attachment_commit',
        payload: payload,
      );
      return;
    } on DirectOrderException catch (error) {
      if (error.code != 'PROOF_UPLOAD_INCOMPLETE') rethrow;
    }
    final upload = await attachmentRequest(
      storeId: storeId,
      requestId: requestId,
      action: 'staff_attachment_upload',
      payload: payload,
    );
    await supabase.storage
        .from('direct-order-chat')
        .uploadBinaryToSignedUrl(
          path,
          upload['token'] as String,
          bytes,
          FileOptions(contentType: mimeType),
        );
    await attachmentRequest(
      storeId: storeId,
      requestId: requestId,
      action: 'staff_attachment_commit',
      payload: payload,
    );
  }

  Future<Map<String, dynamic>> approve({
    required String storeId,
    required String requestId,
    required num confirmedAmount,
    required String quoteId,
    required String proofMessageId,
  }) async {
    return _map(
      await supabase.rpc(
        'direct_order_approve_photo_payment',
        params: {
          'p_store_id': storeId,
          'p_request_id': requestId,
          'p_confirmed_amount': confirmedAmount,
          'p_quote_id': quoteId,
          'p_proof_message_id': proofMessageId,
        },
      ),
    );
  }

  Future<void> setDispatch({
    required String storeId,
    required String requestId,
    required String grabUrl,
    double? actualGrabFee,
    int? expectedVersion,
    String provider = 'grab',
    String? providerName,
    String? driverContact,
  }) async {
    await supabase.rpc(
      'direct_order_set_dispatch_v3',
      params: {
        'p_store_id': storeId,
        'p_request_id': requestId,
        'p_tracking_url': grabUrl,
        'p_actual_fee': actualGrabFee,
        'p_expected_version': expectedVersion,
        'p_provider': provider,
        'p_provider_name': providerName,
        'p_driver_contact': driverContact,
      },
    );
  }

  Future<void> setDinerCount({
    required String storeId,
    required String requestId,
    required int expectedVersion,
    required int dinerCount,
  }) async {
    await supabase.rpc(
      'direct_order_staff_set_diner_count',
      params: {
        'p_store_id': storeId,
        'p_request_id': requestId,
        'p_expected_version': expectedVersion,
        'p_diner_count': dinerCount,
      },
    );
  }

  Future<void> offerPickup({
    required String storeId,
    required String requestId,
    required int expectedVersion,
    required String reason,
  }) async {
    await supabase.rpc(
      'direct_order_staff_offer_pickup',
      params: {
        'p_store_id': storeId,
        'p_request_id': requestId,
        'p_expected_version': expectedVersion,
        'p_reason': reason,
      },
    );
  }

  Future<void> recordPickupRefund({
    required String storeId,
    required String requestId,
    required String offerId,
    required String reference,
  }) async {
    await supabase.rpc(
      'direct_order_staff_record_pickup_refund',
      params: {
        'p_store_id': storeId,
        'p_request_id': requestId,
        'p_offer_id': offerId,
        'p_reference': reference,
      },
    );
  }

  Future<DirectOrderDriverReceiptStatus> driverReceiptStatus({
    required String storeId,
    required String requestId,
  }) async {
    final result = _map(
      await supabase.rpc(
        'direct_order_driver_receipt_status',
        params: {'p_store_id': storeId, 'p_request_id': requestId},
      ),
    );
    return DirectOrderDriverReceiptStatus.fromJson(result);
  }

  Future<Map<String, dynamic>> enqueueDriverReceipt({
    required String storeId,
    required String requestId,
    bool reprint = false,
  }) async {
    return _map(
      await supabase.rpc(
        'enqueue_direct_delivery_driver_receipt',
        params: {
          'p_store_id': storeId,
          'p_request_id': requestId,
          'p_reprint': reprint,
        },
      ),
    );
  }

  Future<DirectOrderDriverReceiptStatus> customerReceiptStatus({
    required String storeId,
    required String requestId,
  }) async {
    final result = _map(
      await supabase.rpc(
        'direct_order_customer_receipt_status',
        params: {'p_store_id': storeId, 'p_request_id': requestId},
      ),
    );
    return DirectOrderDriverReceiptStatus.fromJson(result);
  }

  Future<Map<String, dynamic>> enqueueCustomerReceipt({
    required String storeId,
    required String requestId,
    bool reprint = false,
  }) async {
    return _map(
      await supabase.rpc(
        'enqueue_direct_order_customer_receipt',
        params: {
          'p_store_id': storeId,
          'p_request_id': requestId,
          'p_reprint': reprint,
        },
      ),
    );
  }

  Future<String> proofSignedUrl({
    required String storeId,
    required String requestId,
    required String messageId,
  }) async {
    final response = await supabase.functions.invoke(
      'direct-order-public',
      body: {
        'action': 'staff_proof_url',
        'store_id': storeId,
        'request_id': requestId,
        'message_id': messageId,
      },
    );
    if (response.status < 200 ||
        response.status >= 300 ||
        response.data is! Map) {
      throw const DirectOrderException('PROOF_TEMPORARILY_UNAVAILABLE');
    }
    final envelope = Map<String, dynamic>.from(response.data as Map);
    final data = envelope['data'];
    if (data is! Map) {
      throw const DirectOrderException('PROOF_TEMPORARILY_UNAVAILABLE');
    }
    final url = data['signed_url']?.toString() ?? '';
    if (url.isEmpty) {
      throw const DirectOrderException('PROOF_TEMPORARILY_UNAVAILABLE');
    }
    return url;
  }

  Future<List<Map<String, dynamic>>> listTickets({
    required String storeId,
    List<String>? statuses,
  }) async {
    return _list(
      await supabase.rpc(
        'direct_delivery_ticket_list_v3',
        params: {'p_store_id': storeId, 'p_statuses': statuses, 'p_limit': 200},
      ),
    );
  }

  Future<DirectOrderAvailability> getAvailability({
    required String storeId,
  }) async {
    final result = _map(
      await supabase.rpc(
        'direct_order_staff_get_availability_v2',
        params: {'p_store_id': storeId},
      ),
    );
    return DirectOrderAvailability.fromJson(result);
  }

  Future<DirectOrderAvailability> setPaused({
    required String storeId,
    required bool paused,
  }) async {
    await supabase.rpc(
      'direct_order_staff_set_paused',
      params: {'p_store_id': storeId, 'p_is_paused': paused},
    );
    return getAvailability(storeId: storeId);
  }

  Future<Map<String, dynamic>> transitionTicket({
    required String storeId,
    required String ticketId,
    required int expectedVersion,
    required String nextStatus,
  }) async {
    return _map(
      await supabase.rpc(
        'direct_delivery_ticket_transition',
        params: {
          'p_store_id': storeId,
          'p_ticket_id': ticketId,
          'p_expected_version': expectedVersion,
          'p_next_status': nextStatus,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> requestProofResubmission({
    required String storeId,
    required String requestId,
    required String targetMessageId,
    required String reasonCode,
    String? reasonNote,
  }) async {
    return _map(
      await supabase.rpc(
        'direct_order_staff_request_proof_resubmission',
        params: {
          'p_store_id': storeId,
          'p_request_id': requestId,
          'p_target_message_id': targetMessageId,
          'p_reason_code': reasonCode,
          'p_reason_note': reasonNote,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> completePickup({
    required String storeId,
    required String requestId,
    required int expectedVersion,
  }) async => _map(
    await supabase.rpc(
      'direct_order_cashier_complete_pickup',
      params: {
        'p_store_id': storeId,
        'p_request_id': requestId,
        'p_expected_version': expectedVersion,
      },
    ),
  );

  Future<Map<String, dynamic>> completeDelivery({
    required String storeId,
    required String requestId,
    required int expectedVersion,
  }) async {
    return _map(
      await supabase.rpc(
        'direct_order_cashier_complete_delivery',
        params: {
          'p_store_id': storeId,
          'p_request_id': requestId,
          'p_expected_version': expectedVersion,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> analytics({
    required String storeId,
    required DateTime from,
    required DateTime to,
  }) async {
    String date(DateTime value) =>
        '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
    return _map(
      await supabase.rpc(
        'direct_order_analytics_v3',
        params: {
          'p_store_id': storeId,
          'p_from_date': date(from),
          'p_to_date': date(to),
        },
      ),
    );
  }

  Future<Map<String, dynamic>> storefrontConfig(String storeId) async {
    return _map(
      await supabase.rpc(
        'direct_order_admin_get_storefront',
        params: {'p_store_id': storeId},
      ),
    );
  }

  Future<Map<String, dynamic>> saveStorefrontConfig({
    required String storeId,
    required String slug,
    required bool enabled,
    required bool paused,
    required String bankBin,
    required String bankAccount,
    required String bankHolder,
    required String bankLabel,
    required double minimumOrder,
    required bool accountingApproved,
    double? latitude,
    double? longitude,
    double deliveryFeeVatRate = 0,
  }) async {
    return _map(
      await supabase.rpc(
        'direct_order_admin_upsert_storefront',
        params: {
          'p_store_id': storeId,
          'p_public_slug': slug,
          'p_is_enabled': enabled,
          'p_is_paused': paused,
          'p_ordering_starts_at': '11:00',
          'p_ordering_cutoff_at': '22:00',
          'p_minimum_order_amount': minimumOrder,
          'p_quote_ttl_minutes': 20,
          'p_default_latitude': latitude,
          'p_default_longitude': longitude,
          'p_bank_bin': bankBin,
          'p_bank_account_number': bankAccount,
          'p_bank_account_holder': bankHolder,
          'p_bank_label': bankLabel,
          'p_delivery_fee_vat_rate': deliveryFeeVatRate,
          'p_pii_retention_days': 90,
          'p_analytics_min_cell_count': 3,
          'p_accounting_approved': accountingApproved,
        },
      ),
    );
  }

  String publicUrl(String slug) =>
      '${AppConstants.posPublicUrl}/order/${Uri.encodeComponent(slug)}';
}

const directOrderStaffService = DirectOrderStaffService();
