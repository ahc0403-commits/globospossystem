import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
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

  Future<PaymentProofSaveResult> saveProof({
    required String paymentId,
    required String storeId,
    required File originalFile,
    DateTime? takenAt,
  }) async {
    final capturedAt = takenAt ?? DateTime.now();

    try {
      final signedUrl = await _uploadAndAttach(
        paymentId: paymentId,
        storeId: storeId,
        file: originalFile,
        takenAt: capturedAt,
      );
      return PaymentProofSaveResult(queued: false, signedUrl: signedUrl);
    } catch (_) {
      final persistedFile = await _persistQueueFile(
        paymentId: paymentId,
        originalFile: originalFile,
      );
      await _enqueue(
        _QueuedPaymentProof(
          paymentId: paymentId,
          storeId: storeId,
          localPath: persistedFile.path,
          takenAtIso: capturedAt.toUtc().toIso8601String(),
        ),
      );
      return const PaymentProofSaveResult(queued: true);
    }
  }

  Future<int> flushPendingUploads() async {
    final queue = await _readQueue();
    if (queue.isEmpty) return 0;

    final remaining = <_QueuedPaymentProof>[];
    var uploadedCount = 0;

    for (final item in queue) {
      final file = File(item.localPath);
      if (!file.existsSync()) {
        continue;
      }

      try {
        await _uploadAndAttach(
          paymentId: item.paymentId,
          storeId: item.storeId,
          file: file,
          takenAt:
              DateTime.tryParse(item.takenAtIso)?.toLocal() ?? DateTime.now(),
        );
        uploadedCount += 1;
        await file.delete().catchError((_) => file);
      } catch (_) {
        remaining.add(item);
      }
    }

    await _writeQueue(remaining);
    return uploadedCount;
  }

  Future<String> _uploadAndAttach({
    required String paymentId,
    required String storeId,
    required File file,
    required DateTime takenAt,
  }) async {
    final bytes = await file.readAsBytes();
    final compressed = _compressImage(bytes);
    final taxEntityId = await _lookupTaxEntityId(storeId);
    final date = takenAt.toUtc();
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final path = '$taxEntityId/$storeId/$dateStr/$paymentId.jpg';

    await supabase.storage
        .from('payment-proofs')
        .uploadBinary(
          path,
          compressed,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: true,
          ),
        );

    final signedUrl = await supabase.storage
        .from('payment-proofs')
        .createSignedUrl(path, 60 * 60 * 24 * 365 * 10);

    await supabase.rpc(
      'attach_payment_proof',
      params: {
        'p_payment_id': paymentId,
        'p_store_id': storeId,
        'p_proof_photo_url': signedUrl,
        'p_taken_at': takenAt.toUtc().toIso8601String(),
      },
    );

    return signedUrl;
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

  Future<String> _lookupTaxEntityId(String storeId) async {
    final row = await supabase
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
    required File originalFile,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final queueDir = Directory('${dir.path}/payment_proof_queue');
    if (!queueDir.existsSync()) {
      queueDir.createSync(recursive: true);
    }

    final target = File('${queueDir.path}/$paymentId.jpg');
    await originalFile.copy(target.path);
    return target;
  }

  Future<void> _enqueue(_QueuedPaymentProof item) async {
    final queue = await _readQueue();
    final merged = [
      ...queue.where((existing) => existing.paymentId != item.paymentId),
      item,
    ];
    await _writeQueue(merged);
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
    await prefs.setString(_queueKey, raw);
  }
}

class _QueuedPaymentProof {
  const _QueuedPaymentProof({
    required this.paymentId,
    required this.storeId,
    required this.localPath,
    required this.takenAtIso,
  });

  final String paymentId;
  final String storeId;
  final String localPath;
  final String takenAtIso;

  factory _QueuedPaymentProof.fromJson(Map<String, dynamic> json) {
    return _QueuedPaymentProof(
      paymentId: json['payment_id'].toString(),
      storeId: json['store_id'].toString(),
      localPath: json['local_path'].toString(),
      takenAtIso: json['taken_at_iso'].toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'payment_id': paymentId,
    'store_id': storeId,
    'local_path': localPath,
    'taken_at_iso': takenAtIso,
  };
}

final paymentProofService = PaymentProofService();
