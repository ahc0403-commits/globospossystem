import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../main.dart';
import 'direct_order_models.dart';

typedef DirectOrderInvoker =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> body);

class DirectOrderException implements Exception {
  const DirectOrderException(this.code);
  final String code;

  @override
  String toString() => code;
}

class DirectOrderSubmission {
  const DirectOrderSubmission({
    required this.requestId,
    required this.referenceCode,
  });
  final String requestId;
  final String referenceCode;
}

void _expectExactResponseFields(Map<String, dynamic> data, Set<String> fields) {
  final keys = data.keys.toSet();
  if (data.length != fields.length ||
      keys.difference(fields).isNotEmpty ||
      fields.difference(keys).isNotEmpty) {
    throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
  }
}

String _requiredResponseString(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is! String || value.isEmpty) {
    throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
  }
  return value;
}

class DirectOrderService {
  const DirectOrderService({DirectOrderInvoker? invoker}) : _invoker = invoker;

  static const _sessionKeyPrefix = 'direct_order_session_v1_';
  static const _addressKeyPrefix = 'direct_order_address_v1_';
  static const _requestKeyPrefix = 'direct_order_request_v1_';
  static const _pendingSubmitKeyPrefix = 'direct_order_pending_submit_v1_';
  final DirectOrderInvoker? _invoker;

  Future<Map<String, dynamic>> _invoke(Map<String, dynamic> body) async {
    final injected = _invoker;
    if (injected != null) return injected(body);
    final response = await supabase.functions.invoke(
      'direct-order-public',
      body: body,
    );
    final raw = response.data;
    if (response.status < 200 || response.status >= 300) {
      final code = raw is Map && raw.length == 1 && raw['error'] is String
          ? raw['error'] as String
          : null;
      throw DirectOrderException(
        code?.isNotEmpty == true
            ? code!
            : 'DIRECT_ORDER_TEMPORARILY_UNAVAILABLE',
      );
    }
    if (raw is! Map) {
      throw const DirectOrderException('DIRECT_ORDER_TEMPORARILY_UNAVAILABLE');
    }
    final envelope = Map<String, dynamic>.from(raw);
    if (envelope.length != 1 || !envelope.containsKey('data')) {
      throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
    }
    final data = envelope['data'];
    if (data is! Map) {
      throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
    }
    return Map<String, dynamic>.from(data);
  }

  Future<DirectOrderStorefront> fetchStorefront(String slug) async {
    final data = await _invoke({'action': 'storefront', 'slug': slug});
    return DirectOrderStorefront.fromJson(data);
  }

  Future<DirectOrderSession> ensureSession({
    required String slug,
    required String locale,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final cached = preferences.getString('$_sessionKeyPrefix$slug');
    if (cached != null) {
      try {
        final session = DirectOrderSession.fromJson(
          Map<String, dynamic>.from(jsonDecode(cached) as Map),
        );
        if (session.isValid) return session;
      } catch (_) {
        await preferences.remove('$_sessionKeyPrefix$slug');
      }
    }
    final data = await _invoke({
      'action': 'create_session',
      'slug': slug,
      'locale': locale,
    });
    final session = DirectOrderSession.fromJson(data);
    if (!session.isValid) {
      throw const DirectOrderException('DIRECT_ORDER_SESSION_INVALID');
    }
    await preferences.setString(
      '$_sessionKeyPrefix$slug',
      jsonEncode(session.toJson()),
    );
    return session;
  }

  Future<List<DirectOrderPlaceSuggestion>> autocomplete({
    required String slug,
    required String query,
    required String locale,
    required String sessionToken,
  }) async {
    final data = await _invoke({
      'action': 'places_autocomplete',
      'slug': slug,
      'query': query,
      'locale': locale,
      'session_token': sessionToken,
    });
    final rows = data['suggestions'];
    if (data.length != 1 || rows is! List) {
      throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
    }
    return rows
        .map((row) {
          if (row is! Map) {
            throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
          }
          return DirectOrderPlaceSuggestion.fromJson(
            Map<String, dynamic>.from(row),
          );
        })
        .toList(growable: false);
  }

  Future<DirectOrderPlace> placeDetails({
    required String placeId,
    required String locale,
    required String sessionToken,
  }) async {
    final data = await _invoke({
      'action': 'place_details',
      'place_id': placeId,
      'locale': locale,
      'session_token': sessionToken,
    });
    return DirectOrderPlace.fromJson(data);
  }

  String createPlacesSessionToken() => const Uuid().v4();

  Future<DirectOrderPlace> reverseGeocode({
    required double latitude,
    required double longitude,
    required String locale,
  }) async {
    final data = await _invoke({
      'action': 'reverse_geocode',
      'latitude': latitude,
      'longitude': longitude,
      'locale': locale,
    });
    return DirectOrderPlace.fromJson(data);
  }

  Future<DirectOrderSubmission> submit({
    required String slug,
    required DirectOrderSession session,
    required String locale,
    required Map<String, int> cart,
    required Map<String, String> itemNotes,
    required DirectOrderAddress address,
    required bool rememberAddress,
    String? customerNote,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final pendingKey = '$_pendingSubmitKeyPrefix$slug';
    var clientRequestId = preferences.getString(pendingKey);
    if (clientRequestId == null || !_uuidPattern.hasMatch(clientRequestId)) {
      clientRequestId = const Uuid().v4();
      final saved = await preferences.setString(pendingKey, clientRequestId);
      if (!saved) {
        throw const DirectOrderException('DIRECT_ORDER_RETRY_STATE_FAILED');
      }
    }
    final data = await _invoke({
      'action': 'submit',
      'session_id': session.id,
      'secret': session.secret,
      'client_request_id': clientRequestId,
      'payload': {
        'locale': locale,
        'customer_note': customerNote,
        'items': cart.entries
            .where((entry) => entry.value > 0)
            .map(
              (entry) => {
                'menu_item_id': entry.key,
                'quantity': entry.value,
                'note': itemNotes[entry.key],
              },
            )
            .toList(growable: false),
        'address': address.toJson(),
      },
    });
    _expectExactResponseFields(data, const {
      'request_id',
      'reference_code',
      'state',
      'idempotent',
    });
    final submission = DirectOrderSubmission(
      requestId: _requiredResponseString(data, 'request_id'),
      referenceCode: _requiredResponseString(data, 'reference_code'),
    );
    if (data['state'] is! String || data['idempotent'] is! bool) {
      throw const DirectOrderException('DIRECT_ORDER_SUBMISSION_INVALID');
    }
    final requestSaved = await preferences.setString(
      '$_requestKeyPrefix$slug',
      jsonEncode({
        'request_id': submission.requestId,
        'reference_code': submission.referenceCode,
      }),
    );
    if (!requestSaved) {
      throw const DirectOrderException('DIRECT_ORDER_RETRY_STATE_FAILED');
    }
    await preferences.remove(pendingKey);
    if (rememberAddress) {
      await saveAddress(slug, address);
    } else {
      await clearAddress(slug);
    }
    return submission;
  }

  Future<String?> loadActiveRequestId(String slug) async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString('$_requestKeyPrefix$slug');
    if (raw == null) return null;
    try {
      final json = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final value = json['request_id']?.toString();
      return value?.isNotEmpty == true ? value : null;
    } catch (_) {
      await preferences.remove('$_requestKeyPrefix$slug');
      return null;
    }
  }

  Future<void> clearActiveRequest(String slug) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('$_requestKeyPrefix$slug');
    await preferences.remove('$_pendingSubmitKeyPrefix$slug');
  }

  Future<DirectOrderStatus> fetchStatus({
    required DirectOrderSession session,
    required String requestId,
  }) async {
    final data = await _invoke({
      'action': 'status',
      'session_id': session.id,
      'secret': session.secret,
      'request_id': requestId,
    });
    return DirectOrderStatus.fromJson(data);
  }

  Future<void> sendMessage({
    required DirectOrderSession session,
    required String requestId,
    required String message,
  }) async {
    final data = await _invoke({
      'action': 'message',
      'session_id': session.id,
      'secret': session.secret,
      'request_id': requestId,
      'message': message,
    });
    _expectExactResponseFields(data, const {'message_id', 'created_at'});
    _requiredResponseString(data, 'message_id');
    _requiredResponseString(data, 'created_at');
  }

  Future<void> cancelRequest({
    required String slug,
    required DirectOrderSession session,
    required String requestId,
  }) async {
    final data = await _invoke({
      'action': 'cancel',
      'session_id': session.id,
      'secret': session.secret,
      'request_id': requestId,
    });
    _expectExactResponseFields(data, const {'request_id', 'state'});
    _requiredResponseString(data, 'request_id');
    if (_requiredResponseString(data, 'state') != 'cancelled') {
      throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
    }
    await clearActiveRequest(slug);
  }

  Future<void> uploadPaymentProof({
    required DirectOrderSession session,
    required String requestId,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    final upload = await _invoke({
      'action': 'proof_upload_url',
      'session_id': session.id,
      'secret': session.secret,
      'request_id': requestId,
      'mime_type': mimeType,
      'size_bytes': bytes.length,
    });
    const uploadFields = {
      'path',
      'token',
      'signed_url',
      'max_bytes',
      'mime_type',
    };
    final path = upload['path']?.toString() ?? '';
    final token = upload['token']?.toString() ?? '';
    if (upload.keys.toSet().difference(uploadFields).isNotEmpty ||
        !uploadFields.every(upload.containsKey) ||
        path.isEmpty ||
        token.isEmpty ||
        upload['signed_url'] is! String ||
        upload['max_bytes'] != 5242880 ||
        upload['mime_type'] != mimeType) {
      throw const DirectOrderException('PROOF_UPLOAD_TEMPORARILY_UNAVAILABLE');
    }
    await supabase.storage
        .from('direct-order-proofs')
        .uploadBinaryToSignedUrl(
          path,
          token,
          bytes,
          FileOptions(contentType: mimeType, upsert: false),
        );
    final commit = await _invoke({
      'action': 'proof_commit',
      'session_id': session.id,
      'secret': session.secret,
      'request_id': requestId,
      'path': path,
    });
    _expectExactResponseFields(commit, const {'message_id', 'state'});
    _requiredResponseString(commit, 'message_id');
    if (_requiredResponseString(commit, 'state') != 'awaiting_payment_review') {
      throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
    }
  }

  Future<DirectOrderAddress?> loadAddress(String slug) async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString('$_addressKeyPrefix$slug');
    if (raw == null) return null;
    try {
      return DirectOrderAddress.decode(raw);
    } catch (_) {
      await preferences.remove('$_addressKeyPrefix$slug');
      return null;
    }
  }

  Future<void> saveAddress(String slug, DirectOrderAddress address) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('$_addressKeyPrefix$slug', address.encode());
  }

  Future<void> clearAddress(String slug) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('$_addressKeyPrefix$slug');
  }
}

const directOrderService = DirectOrderService();

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);
