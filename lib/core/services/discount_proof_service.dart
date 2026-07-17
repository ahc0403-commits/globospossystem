import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';

class DiscountProofService {
  Future<String> uploadProof({
    required String orderId,
    required String storeId,
    required XFile originalFile,
    DateTime? takenAt,
  }) async {
    final capturedAt = takenAt ?? DateTime.now();
    final compressed = _compressImage(await originalFile.readAsBytes());
    final taxEntityId = await _lookupTaxEntityId(storeId);
    final date = capturedAt.toUtc();
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final objectId = DateTime.now().toUtc().millisecondsSinceEpoch;
    final path = '$taxEntityId/$storeId/$dateStr/$orderId/$objectId.jpg';

    await supabase.storage
        .from('discount-proofs')
        .uploadBinary(
          path,
          compressed,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: false,
          ),
        );

    return path;
  }

  Uint8List _compressImage(Uint8List bytes) {
    final original = img.decodeImage(bytes);
    if (original == null) {
      throw const FormatException('Invalid image bytes');
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

final discountProofService = DiscountProofService();
