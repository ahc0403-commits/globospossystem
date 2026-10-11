import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../utils/deadline_http_client.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';

class PaymentProofSaveResult {
  const PaymentProofSaveResult({required this.queued, this.signedUrl});

  final bool queued;
  final String? signedUrl;

  bool get uploaded => !queued && signedUrl != null;
}

class PaymentProofService {
  static const _queueKey = 'payment_proof_upload_queue_v1';

  Future<void> markProofRequired({
    required String paymentId,
    required String storeId,
  }) async {
    await supabase.rpc(
      'mark_payment_proof_required',
      params: {'p_payment_id': paymentId, 'p_store_id': storeId},
    );
  }

  static Future<void> _queueTail = Future.value();
  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _queueTail.then((_) => operation());
    _queueTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<PaymentProofSaveResult> saveProof({
    required String paymentId,
    required String storeId,
    required XFile originalFile,
    DateTime? takenAt,
  }) => _serialized(() async {
    final capturedAt = takenAt ?? DateTime.now();
    final compressed = _compressImage(await originalFile.readAsBytes());
    final item = _QueuedPaymentProof(
      paymentId: paymentId,
      storeId: storeId,
      ownerId: supabase.auth.currentUser?.id,
      jobId: sha256.convert(compressed).toString(),
      takenAtIso: capturedAt.toUtc().toIso8601String(),
      imageBytesBase64: kIsWeb ? base64Encode(compressed) : null,
      localPath: kIsWeb
          ? null
          : (await _persistQueueFile(
              paymentId: paymentId,
              bytes: compressed,
            )).path,
    );
    final queue = [...await _readQueue()];
    queue.removeWhere((existing) => existing.paymentId == paymentId);
    queue.add(item);
    await _writeQueue(queue);
    try {
      final signedUrl = await _process(
        item,
        queue,
        DateTime.now().add(const Duration(seconds: 30)),
      );
      queue.remove(item);
      await _writeQueue(queue);
      await _deleteLocal(item);
      return PaymentProofSaveResult(queued: false, signedUrl: signedUrl);
    } catch (error) {
      _recordFailure(item, error);
      await _writeQueue(queue);
      return const PaymentProofSaveResult(queued: true);
    }
  });

  /// Preserve permanently failed work until an explicit user retry/permission fix.
  Future<void> resumePendingUploads({String? storeId}) => _serialized(() async {
    final queue = await _readQueue();
    for (final item in queue) {
      if ((storeId != null && item.storeId != storeId) || !_owns(item)) {
        continue;
      }
      item.blocked = false;
      item.attempts = 0;
      item.nextAttemptAt = null;
    }
    await _writeQueue(queue);
  });

  bool _owns(_QueuedPaymentProof item) =>
      item.ownerId == null || item.ownerId == supabase.auth.currentUser?.id;
  Future<int> pendingActionCount(String storeId) => _serialized(
    () async => (await _readQueue())
        .where((item) => item.storeId == storeId && _owns(item) && item.blocked)
        .length,
  );

  Future<int> flushPendingUploads() => _serialized(() async {
    final queue = [...await _readQueue()];
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var completed = 0, attempted = 0;
    for (final item in [...queue]) {
      if (attempted >= 10 || !DateTime.now().isBefore(deadline)) break;
      if (!_owns(item) ||
          item.blocked ||
          item.attempts >= 3 ||
          (item.nextAttemptAt?.isAfter(DateTime.now()) ?? false)) {
        continue;
      }
      attempted++;
      try {
        await _process(item, queue, deadline);
        queue.remove(item);
        await _writeQueue(queue);
        await _deleteLocal(item);
        completed++;
      } catch (error) {
        _recordFailure(item, error);
        await _writeQueue(queue);
      }
    }
    return completed;
  });

  Future<String> _process(
    _QueuedPaymentProof item,
    List<_QueuedPaymentProof> queue,
    DateTime deadline,
  ) async {
    final transport = DeadlineHttpClient(supabase.rest.httpClient!, deadline);
    final db = PostgrestClient(
      supabase.rest.url,
      headers: supabase.rest.headers,
      httpClient: transport,
    );
    final storage = SupabaseStorageClient(
      supabase.storage.url,
      supabase.storage.headers,
      httpClient: transport,
      retryAttempts: 0,
    );
    try {
      item.attempts++;
      await _writeQueue(queue);
      if (item.storagePath == null) {
        final taxEntity = await _lookupTaxEntityId(item.storeId, db);
        final date = DateTime.parse(item.takenAtIso).toUtc();
        final dateStr =
            '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
        // Persist the immutable object identity before any upload (response loss safe).
        item.storagePath =
            '$taxEntity/${item.storeId}/$dateStr/${item.paymentId}/${item.jobId}.jpg';
        await _writeQueue(queue);
      }
      if (!item.uploaded) {
        final Uint8List bytes;
        if (item.imageBytesBase64 != null) {
          bytes = base64Decode(item.imageBytesBase64!);
        } else if (!kIsWeb && item.localPath != null) {
          bytes = await File(item.localPath!).readAsBytes();
        } else {
          throw const FileSystemException('Queued proof file is unavailable');
        }
        try {
          await storage
              .from('payment-proofs')
              .uploadBinary(
                item.storagePath!,
                bytes,
                fileOptions: const FileOptions(
                  contentType: 'image/jpeg',
                  upsert: false,
                ),
              );
        } on StorageException catch (error) {
          // Stable content digest and immutable path make an existing object safe.
          if (error.statusCode != '409' &&
              !error.message.toLowerCase().contains('already exists')) {
            rethrow;
          }
        }
        item.uploaded = true;
        await _writeQueue(queue);
      }
      item.signedUrl ??= await storage
          .from('payment-proofs')
          .createSignedUrl(item.storagePath!, 60 * 60 * 24 * 365 * 10);
      await _writeQueue(queue);
      await db.rpc(
        'attach_payment_proof',
        params: {
          'p_payment_id': item.paymentId,
          'p_store_id': item.storeId,
          'p_proof_photo_url': item.signedUrl,
          'p_taken_at': item.takenAtIso,
        },
      );
      return item.signedUrl!;
    } finally {
      await db.dispose();
    }
  }

  void _recordFailure(_QueuedPaymentProof item, Object error) {
    final transient =
        error is TimeoutException ||
        error is SocketException ||
        error is http.ClientException ||
        (error is PostgrestException &&
            (error.code == '429' ||
                ((int.tryParse(error.code ?? '') ?? 0) >= 500 &&
                    (int.tryParse(error.code ?? '') ?? 0) <= 599) ||
                (error.code?.startsWith('08') ?? false) ||
                const {
                  '40001',
                  '40P01',
                  '53300',
                  '57P01',
                }.contains(error.code))) ||
        (error is StorageException &&
            (error.statusCode == '429' ||
                ((int.tryParse(error.statusCode ?? '') ?? 0) >= 500 &&
                    (int.tryParse(error.statusCode ?? '') ?? 0) <= 599)));
    item.blocked = !transient || item.attempts >= 3;
    item.lastError = error is PostgrestException
        ? error.code
        : error.runtimeType.toString();
    item.nextAttemptAt = DateTime.now().add(
      Duration(seconds: (1 << item.attempts) * 5 + Random().nextInt(5)),
    );
  }

  Future<void> _deleteLocal(_QueuedPaymentProof item) async {
    if (!kIsWeb && item.localPath != null) {
      final file = File(item.localPath!);
      if (await file.exists()) await file.delete();
    }
  }

  Uint8List _compressImage(Uint8List bytes) {
    final original = img.decodeImage(bytes);
    if (original == null) {
      throw const FileSystemException('Invalid image bytes');
    }

    final widthDominant = original.width >= original.height;
    final resized = img.copyResize(
      original,
      width: widthDominant ? 1400 : null,
      height: widthDominant ? null : 1400,
    );

    return Uint8List.fromList(img.encodeJpg(resized, quality: 78));
  }

  Future<String> _lookupTaxEntityId(String storeId, PostgrestClient db) async {
    final row = await db
        .from('restaurants')
        .select('tax_entity_id')
        .eq('id', storeId)
        .maybeSingle();

    final taxEntityId = row?['tax_entity_id']?.toString();
    return (taxEntityId == null || taxEntityId.isEmpty)
        ? 'unknown-tax-entity'
        : taxEntityId;
  }

  Future<File> _persistQueueFile({
    required String paymentId,
    required Uint8List bytes,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final queueDir = Directory('${dir.path}/payment_proof_queue');
    if (!queueDir.existsSync()) {
      queueDir.createSync(recursive: true);
    }

    final target = File('${queueDir.path}/$paymentId.jpg');
    await target.writeAsBytes(bytes);
    return target;
  }

  Future<List<_QueuedPaymentProof>> _readQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_queueKey);
    if (raw == null || raw.isEmpty) return const [];

    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];

    return decoded
        .whereType<Map>()
        .map(
          (item) =>
              _QueuedPaymentProof.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList();
  }

  Future<void> _writeQueue(List<_QueuedPaymentProof> queue) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(queue.map((item) => item.toJson()).toList());
    if (!await prefs.setString(_queueKey, raw)) {
      throw StateError('PAYMENT_PROOF_QUEUE_STORAGE_FAILED');
    }
  }
}

class _QueuedPaymentProof {
  _QueuedPaymentProof({
    required this.paymentId,
    required this.storeId,
    this.ownerId,
    this.localPath,
    this.imageBytesBase64,
    required this.takenAtIso,
    String? jobId,
    this.storagePath,
    this.uploaded = false,
    this.signedUrl,
    this.attempts = 0,
    this.blocked = false,
    this.nextAttemptAt,
    this.lastError,
  }) : jobId =
           jobId ??
           sha256
               .convert(utf8.encode('$storeId/$paymentId/$takenAtIso'))
               .toString();
  final String paymentId, storeId, takenAtIso, jobId;
  final String? localPath, imageBytesBase64, ownerId;
  String? storagePath, signedUrl, lastError;
  bool uploaded, blocked;
  int attempts;
  DateTime? nextAttemptAt;
  factory _QueuedPaymentProof.fromJson(Map<String, dynamic> json) =>
      _QueuedPaymentProof(
        paymentId: json['payment_id'].toString(),
        storeId: json['store_id'].toString(),
        ownerId: json['owner_id']?.toString(),
        localPath: json['local_path']?.toString(),
        imageBytesBase64: json['image_bytes_base64']?.toString(),
        takenAtIso: json['taken_at_iso'].toString(),
        jobId: json['job_id']?.toString(),
        storagePath: json['storage_path']?.toString(),
        uploaded: json['uploaded'] == true,
        signedUrl: json['signed_url']?.toString(),
        attempts: (json['attempts'] as num?)?.toInt() ?? 0,
        blocked: json['blocked'] == true,
        nextAttemptAt: DateTime.tryParse(
          json['next_attempt_at']?.toString() ?? '',
        ),
        lastError: json['last_error']?.toString(),
      );
  Map<String, dynamic> toJson() => {
    'payment_id': paymentId,
    'store_id': storeId,
    'owner_id': ownerId,
    'taken_at_iso': takenAtIso,
    'job_id': jobId,
    'local_path': localPath,
    'image_bytes_base64': imageBytesBase64,
    'storage_path': storagePath,
    'uploaded': uploaded,
    'signed_url': signedUrl,
    'attempts': attempts,
    'blocked': blocked,
    'next_attempt_at': nextAttemptAt?.toIso8601String(),
    'last_error': lastError,
  };
}

final paymentProofService = PaymentProofService();
