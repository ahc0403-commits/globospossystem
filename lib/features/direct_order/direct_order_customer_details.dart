import 'package:flutter/material.dart';

import '../../core/ui/pos_design_tokens.dart';
import 'direct_order_copy.dart';
import 'direct_order_models.dart';
import 'direct_order_translation.dart';

class DirectOrderInstructions extends StatelessWidget {
  const DirectOrderInstructions({
    super.key,
    required this.label,
    this.note,
    this.translations = const {},
    this.status,
  });

  final String label;
  final String? note;
  final Map<String, dynamic> translations;
  final String? status;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: PosColors.warningMuted,
      borderRadius: BorderRadius.circular(8),
    ),
    child: translations.isEmpty && (status == null || status == 'original')
        ? Text(
            '$label: $note',
            style: const TextStyle(fontWeight: FontWeight.w700),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
              DirectOrderTranslatedText(
                original: note ?? '',
                translations: translations,
                status: status,
              ),
            ],
          ),
  );
}

class DirectOrderCustomerDetailsBody extends StatelessWidget {
  const DirectOrderCustomerDetailsBody({
    super.key,
    required this.customer,
    required this.languageCode,
    required this.isPickup,
    this.noteTranslations = const {},
    this.noteTranslationStatus,
  });

  final DirectOrderCustomerDetails? customer;
  final String languageCode;
  final bool isPickup;
  final Map<String, dynamic> noteTranslations;
  final String? noteTranslationStatus;

  @override
  Widget build(BuildContext context) {
    final copy = DirectOrderCopy(languageCode);
    final details = customer;
    if (details == null) return Text(copy.noCustomerSnapshot);
    Widget field(String label, String? value) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        '$label: ${value?.trim().isNotEmpty == true ? value : copy.notProvided}',
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field(copy.customerName, details.customerName),
        field(copy.phone, details.customerPhone),
        if (!isPickup ||
            details.formattedAddress?.trim().isNotEmpty == true) ...[
          field(
            isPickup ? copy.enteredAddress : copy.deliveryAddress,
            details.formattedAddress,
          ),
          field(copy.detailAddress, details.detailAddress),
          if (details.district?.trim().isNotEmpty == true)
            field(copy.district, details.district),
          if (details.ward?.trim().isNotEmpty == true)
            field(copy.ward, details.ward),
        ],
        DirectOrderInstructions(
          label: copy.orderRequest,
          translations: noteTranslations,
          status: noteTranslationStatus,
          note: details.customerNote?.trim().isNotEmpty == true
              ? details.customerNote
              : copy.noInstructions,
        ),
      ],
    );
  }
}
