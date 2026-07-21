import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';
import 'red_invoice_intake_models.dart';

class RedInvoiceIntakeService {
  static const _bucket = 'red-invoice-intake';

  Future<List<RedInvoiceIntake>> load(String businessDate) async {
    final result = await supabase.rpc(
      'list_red_invoice_intakes',
      params: {'p_business_date': businessDate},
    );
    return parseRedInvoiceIntakeList(Map<String, dynamic>.from(result as Map));
  }

  Future<RedInvoiceDailyExport> loadExport(String businessDate) async {
    final result = await supabase.rpc(
      'get_red_invoice_daily_export',
      params: {'p_business_date': businessDate},
    );
    return RedInvoiceDailyExport.fromJson(
      Map<String, dynamic>.from(result as Map),
    );
  }

  Future<RedInvoiceIntake> save({
    required String orderId,
    required String storeId,
    required String source,
    required String status,
    String? buyerTaxCode,
    String? buyerUnitCode,
    String? buyerLegalName,
    String? buyerFullName,
    String? buyerAddress,
    String? buyerEmail,
    String? buyerEmailCc,
    String? buyerPhone,
    String? buyerId,
    String? sourceNote,
  }) async {
    final result = await supabase.rpc(
      'upsert_red_invoice_intake',
      params: {
        'p_order_id': orderId,
        'p_store_id': storeId,
        'p_source': source,
        'p_status': status,
        'p_buyer_tax_code': _nullableText(buyerTaxCode),
        'p_buyer_unit_code': _nullableText(buyerUnitCode),
        'p_buyer_legal_name': _nullableText(buyerLegalName),
        'p_buyer_full_name': _nullableText(buyerFullName),
        'p_buyer_address': _nullableText(buyerAddress),
        'p_buyer_email': _nullableText(buyerEmail),
        'p_buyer_email_cc': _nullableText(buyerEmailCc),
        'p_buyer_phone': _nullableText(buyerPhone),
        'p_buyer_id': _nullableText(buyerId),
        'p_source_note': _nullableText(sourceNote),
      },
    );
    return RedInvoiceIntake.fromJson(Map<String, dynamic>.from(result as Map));
  }

  Future<String> uploadEvidence({
    required String intakeId,
    required String storeId,
    required XFile file,
  }) async {
    final compressed = _compress(await file.readAsBytes());
    final objectId = DateTime.now().toUtc().microsecondsSinceEpoch;
    final path = '$storeId/$intakeId/$objectId.jpg';

    await supabase.storage
        .from(_bucket)
        .uploadBinary(
          path,
          compressed,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: false,
          ),
        );
    final signedUrl = await supabase.storage
        .from(_bucket)
        .createSignedUrl(path, 60 * 60 * 24 * 365 * 10);
    await supabase.rpc(
      'attach_red_invoice_intake_evidence',
      params: {'p_intake_id': intakeId, 'p_attachment_url': signedUrl},
    );
    return signedUrl;
  }

  Future<int> markExported({
    required List<String> intakeIds,
    required String exportBatchId,
  }) async {
    final result = await supabase.rpc(
      'mark_red_invoice_intakes_exported',
      params: {'p_intake_ids': intakeIds, 'p_export_batch_id': exportBatchId},
    );
    final payload = Map<String, dynamic>.from(result as Map);
    return (payload['exported_count'] as num?)?.toInt() ?? 0;
  }

  Uint8List _compress(Uint8List bytes) {
    final original = img.decodeImage(bytes);
    if (original == null) {
      throw const FormatException('RED_INVOICE_ATTACHMENT_INVALID');
    }
    final widthDominant = original.width >= original.height;
    final resized = img.copyResize(
      original,
      width: widthDominant && original.width > 1600 ? 1600 : null,
      height: !widthDominant && original.height > 1600 ? 1600 : null,
    );
    return Uint8List.fromList(img.encodeJpg(resized, quality: 80));
  }

  String? _nullableText(String? value) {
    final normalized = value?.trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }
}

final redInvoiceIntakeService = RedInvoiceIntakeService();
