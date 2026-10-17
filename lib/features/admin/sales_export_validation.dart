/// Validation data deliberately excludes buyer contact and tax information.
class SalesExportIssue {
  const SalesExportIssue({
    required this.receiptId,
    required this.receiptNumber,
    required this.source,
    required this.itemId,
    required this.itemName,
    required this.field,
    required this.code,
    required this.soldAt,
    this.mappingVersion = '',
    this.lineNumber = 0,
    this.menuId = '',
  });
  final String receiptId, receiptNumber, source, itemId, itemName, field, code;
  final String soldAt, mappingVersion;
  final int lineNumber;
  final String menuId;
  String get resolution =>
      field.startsWith('invoice_') || field == 'misa_unit_name'
      ? 'invoice_mapping'
      : 'source_receipt';
  @override
  String toString() => '$receiptNumber / $itemId / $itemName / $field: $code';
}

class SalesExportValidationException extends FormatException {
  SalesExportValidationException(List<SalesExportIssue> issues)
    : issues = List.unmodifiable(issues),
      super(issues.first.code);
  final List<SalesExportIssue> issues;
  int get receiptCount =>
      issues.map((e) => '${e.source}:${e.receiptId}').toSet().length;
  int get missingMenuCount => issues
      .where((e) => e.resolution == 'invoice_mapping' && e.menuId.isNotEmpty)
      .map((e) => e.menuId)
      .toSet()
      .length;
  int get itemCount => issues
      .where((e) => e.itemId.isNotEmpty || e.lineNumber > 0)
      .map(
        (e) =>
            '${e.source}:${e.receiptId}:${e.itemId.isEmpty ? '#${e.lineNumber}' : e.itemId}',
      )
      .toSet()
      .length;
}

double? salesExportNumber(Object? value) {
  final n = value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value.trim())
      : null;
  return n != null && n.isFinite ? n : null;
}

/// Keeps the first spelling and order, including invalid addresses for validation.
List<String> normalizeMisaEmailAddresses(Object? value) {
  final seen = <String>{};
  return [
    for (final part in '${value ?? ''}'.split(';'))
      if (part.trim().isNotEmpty && seen.add(part.trim().toLowerCase()))
        part.trim(),
  ];
}

bool isValidMisaEmailAddress(String address) {
  if (address.length > 254) return false;
  final parts = address.split('@');
  if (parts.length != 2 || parts[0].length > 64) return false;
  // Accept a mailbox address, without display names, whitespace or separators.
  if (!RegExp(
    r"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*$",
  ).hasMatch(parts[0])) {
    return false;
  }
  final labels = parts[1].split('.');
  return labels.length >= 2 &&
      labels.every(
        (label) =>
            label.length <= 63 &&
            RegExp(
              r'^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$',
            ).hasMatch(label),
      );
}

List<SalesExportIssue> validateSalesExportJobs(
  List<Map<String, dynamic>> jobs,
) {
  final issues = <SalesExportIssue>[];
  final receipts = <String>{};
  for (final job in jobs) {
    final source = '${job['source_system'] ?? ''}';
    final photo = source == 'photo_objet_moers';
    final receiptId = '${job['receipt_id'] ?? job['id'] ?? ''}';
    final number = '${job['receipt_number'] ?? ''}'.trim();
    final soldAt = '${job['created_at'] ?? ''}';
    final sale = DateTime.tryParse(soldAt);
    var currentLine = 0;
    void add(Map line, String field, String code) => issues.add(
      SalesExportIssue(
        receiptId: receiptId,
        receiptNumber: number.isEmpty ? receiptId : number,
        source: source,
        itemId: '${line['order_item_id'] ?? ''}',
        itemName: '${line['invoice_name_vi'] ?? line['display_name'] ?? ''}',
        field: field,
        code: code,
        soldAt: soldAt,
        mappingVersion: '${line['invoice_mapping_version'] ?? ''}',
        lineNumber: currentLine,
        menuId: '${line['menu_item_id'] ?? ''}',
      ),
    );
    if (job['externally_reported'] == true) {
      add({}, 'receipt_id', 'SALES_EXPORT_EXTERNALLY_REPORTED');
    }
    if (receiptId.isEmpty) {
      add({}, 'receipt_id', 'SALES_EXPORT_RECEIPT_ID_REQUIRED');
    }
    if (!receipts.add('${job['tax_entity_id']}:$source:$receiptId')) {
      add({}, 'receipt_id', 'SALES_EXPORT_DUPLICATE_RECEIPT');
    }
    if (sale == null) add({}, 'created_at', 'SALES_EXPORT_SALE_DATE_REQUIRED');
    final buyer = job['buyer_snapshot'];
    final emails = normalizeMisaEmailAddresses(
      buyer is Map ? buyer['email'] : null,
    );
    for (var index = 0; index < emails.length; index++) {
      if (!isValidMisaEmailAddress(emails[index])) {
        add(
          {},
          'buyer_snapshot.email[${index + 1}]',
          'MISA_EXPORT_INVALID_EMAIL',
        );
      }
    }
    if (emails.join(';').length > 255) {
      add(
        {},
        'buyer_snapshot.email',
        'MISA_EXPORT_DELIVERY_EMAILS_TOO_LONG_255',
      );
    }
    final raw = job['line_items_snapshot'];
    if (raw is! List || raw.isEmpty) {
      add({}, 'line_items', 'MISA_EXPORT_EMPTY_LINES');
      continue;
    }
    final itemIds = <String>{};
    final vatTotals = <double, ({double supply, double vat})>{};
    double gross = 0;
    for (final entry in raw) {
      currentLine++;
      if (entry is! Map) {
        add({}, 'line_items', 'MISA_EXPORT_INVALID_LINE');
        continue;
      }
      final line = entry;
      if (!photo) {
        for (final field in [
          'order_item_id',
          'invoice_name_vi',
          'misa_unit_name',
          'invoice_profile_id',
          'invoice_approval_type',
          'invoice_mapping_version',
          'invoice_source_reference',
          'invoice_store_id',
        ]) {
          if ('${line[field] ?? ''}'.trim().isEmpty) {
            add(line, field, 'MISA_APPROVED_ITEM_METADATA_REQUIRED');
          }
        }
        final type = line['invoice_approval_type'];
        final wet = line['item_type'] == 'wet_tissue_charge';
        if (type != (wet ? 'item_type' : 'menu_item')) {
          add(
            line,
            'invoice_approval_type',
            'SALES_EXPORT_APPROVAL_TYPE_INVALID',
          );
        }
        if (wet
            ? '${line['menu_item_id'] ?? ''}'.isNotEmpty
            : '${line['menu_item_id'] ?? ''}'.isEmpty) {
          add(line, 'menu_item_id', 'SALES_EXPORT_MENU_MAPPING_INVALID');
        }
        if (job['store_id'] != null &&
            line['invoice_store_id'] != job['store_id']) {
          add(line, 'invoice_store_id', 'SALES_EXPORT_APPROVAL_SCOPE_INVALID');
        }
        final from = DateTime.tryParse(
          '${line['invoice_effective_from'] ?? ''}',
        );
        final toText = '${line['invoice_effective_to'] ?? ''}';
        final to = DateTime.tryParse(toText);
        if (from == null ||
            sale == null ||
            sale.isBefore(from) ||
            (toText.isNotEmpty && (to == null || !sale.isBefore(to)))) {
          add(
            line,
            'invoice_effective_from',
            'SALES_EXPORT_APPROVAL_PERIOD_INVALID',
          );
        }
      }
      final itemId = '${line['order_item_id'] ?? ''}';
      if (itemId.isNotEmpty && !itemIds.add(itemId)) {
        add(line, 'order_item_id', 'SALES_EXPORT_DUPLICATE_ITEM');
      }
      final fields = photo
          ? ['quantity', 'paying_amount_inc_tax']
          : [
              'quantity',
              'unit_price',
              'misa_unit_price',
              'misa_discount_amount',
              'total_amount_ex_tax',
              'vat_rate',
              'vat_amount',
            ];
      for (final field in fields) {
        final n = salesExportNumber(line[field]);
        if (n == null ||
            n < 0 ||
            (field == 'quantity' && n <= 0) ||
            (field == 'vat_rate' && n > 100)) {
          add(line, field, 'MISA_EXPORT_INVALID_LINE');
        }
      }
      if (!photo) {
        final supply = salesExportNumber(line['total_amount_ex_tax']);
        final vat = salesExportNumber(line['vat_amount']);
        final rate = salesExportNumber(line['vat_rate']);
        if (supply != null &&
            vat != null &&
            rate != null &&
            supply >= 0 &&
            vat >= 0 &&
            rate >= 0 &&
            rate <= 100) {
          if (!(supply * rate / 100).isFinite ||
              (supply * rate / 100).round() != vat.round()) {
            add(line, 'vat_amount', 'MISA_EXPORT_SOURCE_AMOUNT_MISMATCH');
          }
          final prev = vatTotals[rate] ?? (supply: 0.0, vat: 0.0);
          vatTotals[rate] = (supply: prev.supply + supply, vat: prev.vat + vat);
          gross += supply + vat;
        }
        final q = salesExportNumber(line['quantity']);
        final price = salesExportNumber(line['misa_unit_price']);
        final discount = salesExportNumber(line['misa_discount_amount']);
        final net = salesExportNumber(line['total_amount_ex_tax']);
        if (q != null &&
            price != null &&
            discount != null &&
            net != null &&
            ((q * price - discount) - net).abs() > 0.005) {
          add(line, 'misa_unit_price', 'MISA_EXPORT_SOURCE_AMOUNT_MISMATCH');
        }
      }
    }
    currentLine = 0;
    for (final total in vatTotals.entries) {
      if (!total.value.vat.isFinite ||
          !(total.value.supply * total.key / 100).isFinite ||
          (total.value.supply * total.key / 100).round() !=
              total.value.vat.round()) {
        add({}, 'vat_amount', 'MISA_EXPORT_SOURCE_VAT_SUMMARY_MISMATCH');
      }
    }
    final receiptGross = salesExportNumber(job['gross_sales']);
    if (!photo &&
        receiptGross != null &&
        (gross - receiptGross).abs() > 0.005) {
      add({}, 'gross_sales', 'MISA_EXPORT_SOURCE_AMOUNT_MISMATCH');
    }
  }
  return issues;
}
