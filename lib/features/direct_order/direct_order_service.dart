import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../main.dart';
import 'direct_order_models.dart';

typedef DirectOrderInvoker =
    Future<Object?> Function(Map<String, dynamic> body);

typedef DirectOrderProofUploader =
    Future<void> Function(
      String path,
      String token,
      Uint8List bytes,
      String mimeType,
    );

enum DirectOrderProofStage { preparing, uploading, confirming, complete }

/// A screen-owned attempt. Reuse it after a lost response to commit the same
/// object, rather than create a second photo or change its quote/review owner.
class DirectOrderProofAttempt {
  DirectOrderProofAttempt({
    required this.requestId,
    required this.quoteId,
    required this.bytes,
    required this.mimeType,
    this.reviewRequestId,
  });

  final String requestId;
  final String quoteId;
  final String? reviewRequestId;
  final Uint8List bytes;
  final String mimeType;
  String? path;
  String? token;
  bool storageAttempted = false;
  bool uploaded = false;
  bool complete = false;
  bool outcomeUncertain = false;
  DirectOrderProofStage stage = DirectOrderProofStage.preparing;
}

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
  const DirectOrderService({
    DirectOrderInvoker? invoker,
    DirectOrderProofUploader? proofUploader,
  }) : _invoker = invoker,
       _proofUploader = proofUploader;

  static const _sessionKeyPrefix = 'direct_order_session_v1_';
  static const _addressKeyPrefix = 'direct_order_address_v1_';
  static const _requestKeyPrefix = 'direct_order_request_v1_';
  static const _pendingSubmitKeyPrefix = 'direct_order_pending_submit_v1_';
  static const _alertEnabledKeyPrefix = 'direct_order_payment_alert_v1_';
  static const _seenAlertKeyPrefix = 'direct_order_seen_alerts_v1_';
  final DirectOrderInvoker? _invoker;
  final DirectOrderProofUploader? _proofUploader;

  Future<Object?> _invokeValue(Map<String, dynamic> body) async {
    try {
      final injected = _invoker;
      if (injected != null) return await injected(body);
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
        throw const DirectOrderException(
          'DIRECT_ORDER_TEMPORARILY_UNAVAILABLE',
        );
      }
      final envelope = Map<String, dynamic>.from(raw);
      if (envelope.length != 1 || !envelope.containsKey('data')) {
        throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
      }
      final data = envelope['data'];
      return data;
    } on FunctionException catch (error) {
      final details = error.details;
      final code =
          details is Map && details.length == 1 && details['error'] is String
          ? details['error'] as String
          : 'DIRECT_ORDER_TEMPORARILY_UNAVAILABLE';
      throw DirectOrderException(code);
    }
  }

  Future<Map<String, dynamic>> _invoke(Map<String, dynamic> body) async {
    final data = await _invokeValue(body);
    if (data is! Map) {
      throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
    }
    return Map<String, dynamic>.from(data);
  }

  Future<DirectOrderStorefront> fetchStorefront(String slug) async {
    final data = await _invoke({'action': 'storefront_v2', 'slug': slug});
    return DirectOrderStorefront.fromJson(data);
  }

  Future<DirectOrderSession?> loadCachedSession(String slug) async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString('$_sessionKeyPrefix$slug');
    if (raw == null) return null;
    try {
      final session = DirectOrderSession.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
      return session.isValid ? session : null;
    } catch (_) {
      return null;
    }
  }

  Future<DirectOrderStorefront> resumeStorefront(
    DirectOrderSession session,
  ) async => DirectOrderStorefront.fromJson(
    await _invoke({
      'action': 'resume_storefront',
      'session_id': session.id,
      'secret': session.secret,
    }),
  );

  Future<void> decidePickup({
    required DirectOrderSession session,
    required String requestId,
    required String offerId,
    required bool accept,
    bool alreadyPaid = false,
  }) async {
    await _invoke({
      'action': 'decide_pickup',
      'session_id': session.id,
      'secret': session.secret,
      'request_id': requestId,
      'offer_id': offerId,
      'accept': accept,
      'already_paid': alreadyPaid,
    });
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

  Future<DirectOrderSubmission> submit({
    required String slug,
    required DirectOrderSession session,
    String? draftId,
    required String locale,
    required Map<String, int> cart,
    required Map<String, String> itemNotes,
    required DirectOrderAddress address,
    required bool rememberAddress,
    DirectOrderFulfillmentType fulfillmentType =
        DirectOrderFulfillmentType.delivery,
    String? customerNote,
    int? dinerCount,
  }) async {
    if (dinerCount == null || dinerCount < 1 || dinerCount > 100) {
      throw const DirectOrderException('DIRECT_ORDER_DINER_COUNT_INVALID');
    }
    final preferences = await SharedPreferences.getInstance();
    final pendingKey = draftId == null
        ? '$_pendingSubmitKeyPrefix$slug'
        : '$_pendingSubmitKeyPrefix${slug}_$draftId';
    var clientRequestId = preferences.getString(pendingKey);
    final pendingTypeKey = '${pendingKey}_fulfillment_type';
    final pendingType = preferences.getString(pendingTypeKey);
    if (clientRequestId != null &&
        pendingType != null &&
        pendingType != fulfillmentType.name) {
      throw const DirectOrderException('DIRECT_ORDER_FULFILLMENT_TYPE_LOCKED');
    }
    if (!await preferences.setString(pendingTypeKey, fulfillmentType.name)) {
      throw const DirectOrderException('DIRECT_ORDER_RETRY_STATE_FAILED');
    }
    if (clientRequestId == null || !_uuidPattern.hasMatch(clientRequestId)) {
      clientRequestId = const Uuid().v4();
      final saved = await preferences.setString(pendingKey, clientRequestId);
      if (!saved) {
        throw const DirectOrderException('DIRECT_ORDER_RETRY_STATE_FAILED');
      }
    }
    final data = await _invoke({
      'action': 'submit_v3',
      'session_id': session.id,
      'secret': session.secret,
      'client_request_id': clientRequestId,
      'payload': {
        'locale': locale,
        'fulfillment_type': fulfillmentType.name,
        'diner_count': dinerCount,
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
        'address': fulfillmentType == DirectOrderFulfillmentType.pickup
            ? {
                'customer_name': address.customerName,
                'customer_phone': address.customerPhone,
                'address_source': 'pickup',
              }
            : address.toJson(),
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
    await preferences.remove(pendingTypeKey);
    if (fulfillmentType == DirectOrderFulfillmentType.delivery) {
      if (rememberAddress) {
        await saveAddress(slug, address);
      } else {
        await clearAddress(slug);
      }
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

  Future<void> saveSelectedRequest(String slug, String requestId) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setString(
      '$_requestKeyPrefix$slug',
      jsonEncode({'request_id': requestId}),
    );
    if (!saved) {
      throw const DirectOrderException('DIRECT_ORDER_RETRY_STATE_FAILED');
    }
  }

  Future<void> clearActiveRequest(String slug) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('$_requestKeyPrefix$slug');
    await preferences.remove('$_pendingSubmitKeyPrefix$slug');
  }

  Future<bool> loadPaymentAlertEnabled(String slug) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool('$_alertEnabledKeyPrefix$slug') ?? true;
  }

  Future<void> setPaymentAlertEnabled(String slug, bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('$_alertEnabledKeyPrefix$slug', enabled);
  }

  Future<bool> markAlertSeen(String slug, String eventKey) async {
    final preferences = await SharedPreferences.getInstance();
    final key = '$_seenAlertKeyPrefix$slug';
    final seen = preferences.getStringList(key) ?? const <String>[];
    if (seen.contains(eventKey)) return false;
    final updated = [...seen, eventKey];
    final trimmed = updated.length > 100
        ? updated.sublist(updated.length - 100)
        : updated;
    await preferences.setStringList(key, trimmed);
    return true;
  }

  Future<DirectOrderStatus> fetchStatus({
    required DirectOrderSession session,
    required String requestId,
  }) async {
    final data = await _invoke({
      'action': 'status_v3',
      'session_id': session.id,
      'secret': session.secret,
      'request_id': requestId,
    });
    return DirectOrderStatus.fromJson(data);
  }

  Future<List<DirectOrderSummary>> listOrders({
    required DirectOrderSession session,
  }) async {
    final data = await _invokeValue({
      'action': 'orders_v3',
      'session_id': session.id,
      'secret': session.secret,
    });
    if (data is! List) {
      throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
    }
    return data
        .map((row) {
          if (row is! Map) {
            throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
          }
          return DirectOrderSummary.fromJson(Map<String, dynamic>.from(row));
        })
        .toList(growable: false);
  }

  Future<DirectOrderMessage> sendMessage({
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
    return DirectOrderMessage(
      id: _requiredResponseString(data, 'message_id'),
      senderType: 'customer',
      messageType: 'text',
      body: message,
      hasAttachment: false,
      createdAt: DateTime.parse(_requiredResponseString(data, 'created_at')),
    );
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
  }

  Future<void> uploadPaymentProof({
    required DirectOrderSession session,
    required String requestId,
    required String quoteId,
    String? reviewRequestId,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    await resumePaymentProof(
      session: session,
      attempt: DirectOrderProofAttempt(
        requestId: requestId,
        quoteId: quoteId,
        reviewRequestId: reviewRequestId,
        bytes: bytes,
        mimeType: mimeType,
      ),
    );
  }

  Future<void> resumePaymentProof({
    required DirectOrderSession session,
    required DirectOrderProofAttempt attempt,
    void Function()? onChanged,
    bool allowUpload = true,
  }) async {
    if (attempt.complete) return;
    if (!const {
          'image/jpeg',
          'image/png',
          'image/webp',
        }.contains(attempt.mimeType) ||
        attempt.bytes.isEmpty ||
        attempt.bytes.length > 5242880) {
      throw const DirectOrderException('INVALID_PROOF');
    }
    final identity = <String, dynamic>{
      'session_id': session.id,
      'secret': session.secret,
      'request_id': attempt.requestId,
      'quote_id': attempt.quoteId,
      'review_request_id': attempt.reviewRequestId,
    };
    Future<void> commit() async {
      attempt.outcomeUncertain = true;
      attempt.stage = DirectOrderProofStage.confirming;
      onChanged?.call();
      Map<String, dynamic> response;
      try {
        response = await _invoke({
          ...identity,
          'action': 'proof_commit_v2',
          'path': attempt.path,
        });
      } on DirectOrderException catch (error) {
        if (const {
          'INVALID_PROOF',
          'PROOF_UPLOAD_INCOMPLETE',
          'DIRECT_ORDER_PROOF_NOT_ALLOWED',
          'DIRECT_ORDER_PROOF_REVIEW_NOT_ALLOWED',
          'DIRECT_ORDER_QUOTE_CHANGED',
          'DIRECT_ORDER_PROOF_PATH_INVALID',
        }.contains(error.code)) {
          attempt.outcomeUncertain = false;
        }
        rethrow;
      }
      _expectExactResponseFields(response, const {
        'message_id',
        'state',
        'review_request_id',
        'idempotent',
      });
      _requiredResponseString(response, 'message_id');
      if (_requiredResponseString(response, 'state') !=
              'awaiting_payment_review' ||
          response['idempotent'] is! bool ||
          response['review_request_id'] != attempt.reviewRequestId) {
        throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
      }
      attempt.complete = true;
      attempt.stage = DirectOrderProofStage.complete;
      attempt.outcomeUncertain = false;
      onChanged?.call();
    }

    // A Storage response can be lost after the bytes were saved. Commit first;
    // only a definite missing object permits uploading to the same path again.
    if (attempt.storageAttempted) {
      try {
        await commit();
        return;
      } on DirectOrderException catch (error) {
        if (error.code != 'PROOF_UPLOAD_INCOMPLETE') rethrow;
        attempt.outcomeUncertain = false;
        attempt.uploaded = false;
      }
    }
    if (!allowUpload) {
      throw const DirectOrderException('DIRECT_ORDER_PROOF_NOT_ALLOWED');
    }
    if (attempt.path == null) {
      attempt.stage = DirectOrderProofStage.preparing;
      onChanged?.call();
      final upload = await _invoke({
        ...identity,
        'action': 'proof_upload_url_v2',
        'mime_type': attempt.mimeType,
        'size_bytes': attempt.bytes.length,
      });
      _expectExactResponseFields(upload, const {
        'path',
        'token',
        'signed_url',
        'max_bytes',
        'mime_type',
      });
      if (upload['signed_url'] is! String ||
          upload['max_bytes'] != 5242880 ||
          upload['mime_type'] != attempt.mimeType) {
        throw const DirectOrderException(
          'PROOF_UPLOAD_TEMPORARILY_UNAVAILABLE',
        );
      }
      final path = _requiredResponseString(upload, 'path');
      final token = _requiredResponseString(upload, 'token');
      attempt.path = path;
      attempt.token = token;
    }
    attempt.storageAttempted = true;
    attempt.stage = DirectOrderProofStage.uploading;
    attempt.outcomeUncertain = true;
    onChanged?.call();
    final uploader = _proofUploader;
    if (uploader != null) {
      await uploader(
        attempt.path!,
        attempt.token!,
        attempt.bytes,
        attempt.mimeType,
      );
    } else {
      await supabase.storage
          .from('direct-order-proofs')
          .uploadBinaryToSignedUrl(
            attempt.path!,
            attempt.token!,
            attempt.bytes,
            FileOptions(contentType: attempt.mimeType, upsert: false),
          );
    }
    attempt.uploaded = true;
    await commit();
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
