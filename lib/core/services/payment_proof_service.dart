import 'dart:convert';
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

  Future<PaymentProofSaveResult> saveProof({
    required String paymentId,
    required String storeId,
    required XFile originalFile,
    DateTime? takenAt,
  }) async {
    final capturedAt = takenAt ?? DateTime.now();
    final bytes = await originalFile.readAsBytes();

    try {
      final signedUrl = await _uploadAndAttachBytes(
        paymentId: paymentId,
        storeId: storeId,
        bytes: bytes,
        takenAt: capturedAt,
      );
      return PaymentProofSaveResult(queued: false, signedUrl: signedUrl);
    } catch (_) {
      final compressed = _compressImage(bytes);
      String? localPath;
      String? imageBytesBase64;

      if (kIsWeb) {
        imageBytesBase64 = base64Encode(compressed);
      } else {
        final persistedFile = await _persistQueueFile(
          paymentId: paymentId,
          bytes: compressed,
        );
        localPath = persistedFile.path;
      }

      await _enqueue(
        _QueuedPaymentProof(
          paymentId: paymentId,
          storeId: storeId,
          localPath: localPath,
          imageBytesBase64: imageBytesBase64,
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
      try {
        final takenAt =
            DateTime.tryParse(item.takenAtIso)?.toLocal() ?? DateTime.now();
        final encodedBytes = item.imageBytesBase64;
        final localPath = item.localPath;

        if (encodedBytes != null && encodedBytes.isNotEmpty) {
          await _uploadCompressedAndAttach(
            paymentId: item.paymentId,
            storeId: item.storeId,
            compressed: base64Decode(encodedBytes),
            takenAt: takenAt,
          );
        } else if (localPath != null && localPath.isNotEmpty && !kIsWeb) {
          final file = File(localPath);
          if (!file.existsSync()) {
            continue;
          }
          await _uploadCompressedAndAttach(
            paymentId: item.paymentId,
            storeId: item.storeId,
            compressed: await file.readAsBytes(),
            takenAt: takenAt,
          );
          await file.delete().catchError((_) => file);
        } else {
          continue;
        }

        uploadedCount += 1;
      } catch (_) {
        remaining.add(item);
      }
    }

    await _writeQueue(remaining);
    return uploadedCount;
  }

  Future<String> _uploadAndAttachBytes({
    required String paymentId,
    required String storeId,
    required Uint8List bytes,
    required DateTime takenAt,
  }) async {
    final compressed = _compressImage(bytes);
    return _uploadCompressedAndAttach(
      paymentId: paymentId,
      storeId: storeId,
      compressed: compressed,
      takenAt: takenAt,
    );
  }

  Future<String> _uploadCompressedAndAttach({
    required String paymentId,
    required String storeId,
    required Uint8List compressed,
    required DateTime takenAt,
  }) async {
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
    this.localPath,
    this.imageBytesBase64,
    required this.takenAtIso,
  });

  final String paymentId;
  final String storeId;
  final String? localPath;
  final String? imageBytesBase64;
  final String takenAtIso;

  factory _QueuedPaymentProof.fromJson(Map<String, dynamic> json) {
    return _QueuedPaymentProof(
      paymentId: json['payment_id'].toString(),
      storeId: json['store_id'].toString(),
      localPath: json['local_path']?.toString(),
      imageBytesBase64: json['image_bytes_base64']?.toString(),
      takenAtIso: json['taken_at_iso'].toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'payment_id': paymentId,
      'store_id': storeId,
      if (localPath != null) 'local_path': localPath,
      if (imageBytesBase64 != null) 'image_bytes_base64': imageBytesBase64,
      'taken_at_iso': takenAtIso,
    };
  }
}

final paymentProofService = PaymentProofService();
