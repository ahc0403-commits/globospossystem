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

String? normalizeGrabTrackingUrl(String input) {
  var value = input.trim();
  if (value.isEmpty) return null;
  if (!value.contains('://')) value = 'https://$value';
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  final host = uri.host.toLowerCase();
  final validHost =
      host == 'grab.com' ||
      host.endsWith('.grab.com') ||
      host == 'grab.onelink.me';
  return validHost ? uri.toString() : null;
}

class DirectOrderStaffService {
  const DirectOrderStaffService();

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
    int limit = 100,
  }) async {
    final raw = await supabase.rpc(
      'direct_order_staff_list',
      params: {'p_store_id': storeId, 'p_states': states, 'p_limit': limit},
    );
    return _list(raw);
  }

  Future<Map<String, dynamic>> requestDetail({
    required String storeId,
    required String requestId,
  }) async {
    return _map(
      await supabase.rpc(
        'direct_order_staff_detail',
        params: {'p_store_id': storeId, 'p_request_id': requestId},
      ),
    );
  }

  Future<Map<String, dynamic>> quote({
    required String storeId,
    required String requestId,
    required double deliveryFee,
    String? note,
  }) async {
    return _map(
      await supabase.rpc(
        'direct_order_staff_quote',
        params: {
          'p_store_id': storeId,
          'p_request_id': requestId,
          'p_delivery_fee_total': deliveryFee,
          'p_cashier_note': note,
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
        'direct_order_staff_sepay_candidates',
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

  Future<Map<String, dynamic>> approve({
    required String storeId,
    required String requestId,
    required double confirmedAmount,
    String? bankReference,
  }) async {
    return _map(
      await supabase.rpc(
        'direct_order_approve_payment',
        params: {
          'p_store_id': storeId,
          'p_request_id': requestId,
          'p_confirmed_amount': confirmedAmount,
          'p_confirmed_bank_reference': bankReference,
        },
      ),
    );
  }

  Future<void> setDispatch({
    required String storeId,
    required String requestId,
    required String grabUrl,
    double? actualGrabFee,
  }) async {
    await supabase.rpc(
      'direct_order_set_dispatch',
      params: {
        'p_store_id': storeId,
        'p_request_id': requestId,
        'p_grab_tracking_url': grabUrl,
        'p_actual_grab_fee': actualGrabFee,
      },
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
        'direct_delivery_ticket_list',
        params: {'p_store_id': storeId, 'p_statuses': statuses, 'p_limit': 200},
      ),
    );
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
        'direct_order_analytics',
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
          'p_ordering_starts_at': '10:00',
          'p_ordering_cutoff_at': '21:30',
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
