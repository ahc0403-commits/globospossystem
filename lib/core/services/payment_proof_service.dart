import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';

class PaymentProofSaveResult {
  const PaymentProofSaveResult({required this.queued, this.objectPath});

  final bool queued;
  final String? objectPath;

  bool get uploaded => !queued && objectPath != null;
}

typedef LegacyProofUploadAndAttach =
    Future<String> Function({
      required String paymentId,
      required String storeId,
      required File file,
      required DateTime takenAt,
    });

class LegacyProofMigrationResult {
  const LegacyProofMigrationResult({
    required this.migrated,
    required this.retained,
    required this.quarantined,
  });

  final int migrated;
  final int retained;
  final int quarantined;
}

class LegacyPaymentProofQueueMigrator {
  const LegacyPaymentProofQueueMigrator({
    required this.preferences,
    required this.queueDirectory,
    required this.uploadAndAttach,
  });

  final SharedPreferences preferences;
  final Directory queueDirectory;
  final LegacyProofUploadAndAttach uploadAndAttach;

  Future<LegacyProofMigrationResult> migrate() async {
    final raw = preferences.getString(PaymentProofService.legacyQueueKey);
    if (raw == null || raw.isEmpty) {
      return const LegacyProofMigrationResult(
        migrated: 0,
        retained: 0,
        quarantined: 0,
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const LegacyProofMigrationResult(
        migrated: 0,
        retained: 1,
        quarantined: 1,
      );
    }
    if (decoded is! List) {
      return const LegacyProofMigrationResult(
        migrated: 0,
        retained: 1,
        quarantined: 1,
      );
    }

    final remaining = <dynamic>[];
    var migrated = 0;
    var quarantined = 0;
    final queueRoot = await _canonicalQueueRoot();

    for (final rawItem in decoded) {
      final item = rawItem is Map
          ? _QueuedPaymentProof.tryParse(Map<String, dynamic>.from(rawItem))
          : null;
      if (item == null || queueRoot == null) {
        remaining.add(rawItem);
        quarantined += 1;
        continue;
      }

      final file = File(item.localPath);
      if (!await file.exists() ||
          !await _isDedicatedQueueFile(file, queueRoot, item)) {
        remaining.add(rawItem);
        quarantined += 1;
        continue;
      }

      try {
        await uploadAndAttach(
          paymentId: item.paymentId,
          storeId: item.storeId,
          file: file,
          takenAt: item.takenAt,
        );
        await file.delete();
        migrated += 1;
      } catch (_) {
        remaining.add(rawItem);
      }
    }

    if (remaining.isEmpty) {
      await preferences.remove(PaymentProofService.legacyQueueKey);
    } else {
      await preferences.setString(
        PaymentProofService.legacyQueueKey,
        jsonEncode(remaining),
      );
    }
    return LegacyProofMigrationResult(
      migrated: migrated,
      retained: remaining.length,
      quarantined: quarantined,
    );
  }

  Future<String?> _canonicalQueueRoot() async {
    if (!await queueDirectory.exists()) return null;
    try {
      return p.normalize(await queueDirectory.resolveSymbolicLinks());
    } on FileSystemException {
      return null;
    }
  }

  Future<bool> _isDedicatedQueueFile(
    File file,
    String queueRoot,
    _QueuedPaymentProof item,
  ) async {
    try {
      final canonicalFile = p.normalize(await file.resolveSymbolicLinks());
      return p.dirname(canonicalFile) == queueRoot &&
          p.basename(canonicalFile) == '${item.paymentId}.jpg';
    } on FileSystemException {
      return false;
    }
  }
}

class PaymentProofViewResult {
  const PaymentProofViewResult._({this.bytes, this.legacyUri});

  factory PaymentProofViewResult.downloaded(Uint8List bytes) =>
      PaymentProofViewResult._(bytes: bytes);

  factory PaymentProofViewResult.legacy(Uri uri) =>
      PaymentProofViewResult._(legacyUri: uri);

  final Uint8List? bytes;
  final Uri? legacyUri;
}

class PaymentProofViewerService {
  PaymentProofViewerService({
    Future<Uint8List> Function(String path)? downloadObject,
  }) : _downloadObject =
           downloadObject ??
           ((path) => supabase.storage.from('payment-proofs').download(path));

  final Future<Uint8List> Function(String path) _downloadObject;

  Future<PaymentProofViewResult?> load({
    required String storeId,
    required String? objectPath,
    required String? legacyUrl,
  }) async {
    final normalizedPath = objectPath?.trim();
    if (normalizedPath != null && normalizedPath.isNotEmpty) {
      if (!_validObjectPath(normalizedPath, storeId)) {
        throw ArgumentError.value(
          objectPath,
          'objectPath',
          'Invalid proof path',
        );
      }
      final bytes = await _downloadObject(normalizedPath);
      return PaymentProofViewResult.downloaded(bytes);
    }

    final normalizedUrl = legacyUrl?.trim();
    if (normalizedUrl == null || normalizedUrl.isEmpty) return null;
    final uri = Uri.tryParse(normalizedUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.host.isEmpty ||
        !(uri.host == 'supabase.co' || uri.host.endsWith('.supabase.co'))) {
      throw ArgumentError.value(
        legacyUrl,
        'legacyUrl',
        'Invalid legacy proof URL',
      );
    }
    return PaymentProofViewResult.legacy(uri);
  }

  bool _validObjectPath(String value, String storeId) {
    if (value.contains('..') || value.contains('://')) return false;
    final segments = value.split('/');
    return segments.length == 4 &&
        segments[0].isNotEmpty &&
        segments[1] == storeId &&
        RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(segments[2]) &&
        RegExp(r'^[0-9A-Za-z-]+\.jpg$').hasMatch(segments[3]);
  }
}

class PaymentProofService {
  static const legacyQueueKey = 'payment_proof_upload_queue_v1';

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
    final objectPath = await _uploadAndAttach(
      paymentId: paymentId,
      storeId: storeId,
      file: originalFile,
      takenAt: takenAt ?? DateTime.now(),
    );
    return PaymentProofSaveResult(queued: false, objectPath: objectPath);
  }

  Future<int> flushPendingUploads() async {
    final preferences = await SharedPreferences.getInstance();
    final documents = await getApplicationDocumentsDirectory();
    final result = await LegacyPaymentProofQueueMigrator(
      preferences: preferences,
      queueDirectory: Directory(p.join(documents.path, 'payment_proof_queue')),
      uploadAndAttach: _uploadAndAttach,
    ).migrate();
    return result.migrated;
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

    await supabase.rpc(
      'attach_payment_proof_v2',
      params: {
        'p_payment_id': paymentId,
        'p_store_id': storeId,
        'p_proof_object_path': path,
        'p_taken_at': takenAt.toUtc().toIso8601String(),
      },
    );
    return path;
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
}

class _QueuedPaymentProof {
  const _QueuedPaymentProof({
    required this.paymentId,
    required this.storeId,
    required this.localPath,
    required this.takenAt,
  });

  final String paymentId;
  final String storeId;
  final String localPath;
  final DateTime takenAt;

  static _QueuedPaymentProof? tryParse(Map<String, dynamic> json) {
    final paymentId = json['payment_id']?.toString().trim();
    final storeId = json['store_id']?.toString().trim();
    final localPath = json['local_path']?.toString().trim();
    final takenAt = DateTime.tryParse(json['taken_at_iso']?.toString() ?? '');
    if (paymentId == null ||
        paymentId.isEmpty ||
        storeId == null ||
        storeId.isEmpty ||
        localPath == null ||
        localPath.isEmpty ||
        takenAt == null ||
        paymentId.contains('/') ||
        paymentId.contains(Platform.pathSeparator)) {
      return null;
    }
    return _QueuedPaymentProof(
      paymentId: paymentId,
      storeId: storeId,
      localPath: localPath,
      takenAt: takenAt,
    );
  }
}

final paymentProofService = PaymentProofService();
final paymentProofViewerService = PaymentProofViewerService();
