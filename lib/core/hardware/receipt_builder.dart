import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import '../utils/time_utils.dart';

class ReceiptBuilder {
  static Future<List<int>> buildPaymentReceipt({
    required String restaurantName,
    required String tableNumber,
    required List<ReceiptItem> items,
    required double totalAmount,
    required String paymentMethod,
    required DateTime paidAt,
    bool isService = false,
  }) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    final bytes = <int>[];

    bytes.addAll(
      generator.text(
        _escText(restaurantName),
        styles: const PosStyles(
          bold: true,
          align: PosAlign.center,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
    );
    bytes.addAll(
      generator.text(
        'GLOBOSVN POS',
        styles: const PosStyles(align: PosAlign.center),
      ),
    );
    bytes.addAll(generator.hr());

    bytes.addAll(
      generator.row([
        PosColumn(text: _escText('Table / Ban: $tableNumber'), width: 8),
        PosColumn(
          text: TimeUtils.formatTime(paidAt), // UTC to Vietnam time
          width: 4,
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]),
    );
    bytes.addAll(
      generator.text(
        TimeUtils.formatDate(paidAt), // UTC to Vietnam date
      ),
    );
    bytes.addAll(generator.hr());

    bytes.addAll(
      generator.row([
        PosColumn(
          text: 'Menu / Món',
          width: 6,
          styles: const PosStyles(bold: true),
        ),
        PosColumn(
          text: 'SL',
          width: 2,
          styles: const PosStyles(bold: true, align: PosAlign.center),
        ),
        PosColumn(
          text: 'Gia (VND)',
          width: 4,
          styles: const PosStyles(bold: true, align: PosAlign.right),
        ),
      ]),
    );
    bytes.addAll(generator.hr());

    final serviceItemCount = items
        .where((item) => item.isServiceItem)
        .fold<int>(0, (sum, item) => sum + item.quantity);
    final billableItems = items
        .where((item) => !item.isServiceItem)
        .toList(growable: false);

    for (final item in billableItems) {
      bytes.addAll(
        generator.row([
          PosColumn(text: _escText(item.name), width: 6),
          PosColumn(
            text: '${item.quantity}',
            width: 2,
            styles: const PosStyles(align: PosAlign.center),
          ),
          PosColumn(
            text: _formatVnd(item.unitPrice * item.quantity),
            width: 4,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]),
      );
    }

    bytes.addAll(generator.hr());
    bytes.addAll(
      generator.row([
        PosColumn(
          text: isService ? 'DICH VU / Service' : 'TONG CONG / Total',
          width: 6,
          styles: const PosStyles(bold: true),
        ),
        PosColumn(
          text: _formatVnd(totalAmount),
          width: 6,
          styles: const PosStyles(bold: true, align: PosAlign.right),
        ),
      ]),
    );

    final methodLabel = _methodLabel(paymentMethod);
    bytes.addAll(generator.text('Thanh toan / Payment: $methodLabel'));

    if (isService) {
      bytes.addAll(generator.hr());
      bytes.addAll(
        generator.text(
          '* Service Provision - not counted in revenue',
          styles: const PosStyles(align: PosAlign.center),
        ),
      );
      bytes.addAll(
        generator.text(
          '* Phuc vu noi bo - Khong tinh doanh thu',
          styles: const PosStyles(align: PosAlign.center),
        ),
      );
    }

    if (serviceItemCount > 0) {
      bytes.addAll(generator.hr());
      bytes.addAll(
        generator.text(
          '* Service provided: $serviceItemCount item(s)',
          styles: const PosStyles(align: PosAlign.center),
        ),
      );
      bytes.addAll(
        generator.text(
          '* Mon phuc vu: $serviceItemCount',
          styles: const PosStyles(align: PosAlign.center),
        ),
      );
    }

    bytes.addAll(generator.hr());
    bytes.addAll(
      generator.text(
        'Cam on quy khach! / Thank you!',
        styles: const PosStyles(align: PosAlign.center),
      ),
    );
    bytes.addAll(generator.feed(2));
    bytes.addAll(generator.cut());

    return bytes;
  }

  static Future<List<int>> buildKitchenTicket(PrintTicket ticket) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    final bytes = <int>[];

    bytes.addAll(
      generator.text(
        _escText('KITCHEN TICKET'),
        styles: const PosStyles(
          bold: true,
          align: PosAlign.center,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
    );
    bytes.addAll(generator.text(_escText('#${ticket.ticketCode}')));
    bytes.addAll(
      generator.text(
        _escText('${ticket.floorLabel} / ${ticket.tableNumber}'),
        styles: const PosStyles(bold: true),
      ),
    );
    bytes.addAll(_buildTicketBody(generator, ticket));
    return bytes;
  }

  static Future<List<int>> buildFloorTicket(PrintTicket ticket) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    final bytes = <int>[];

    bytes.addAll(_buildLargeTableHeader(generator, ticket));
    bytes.addAll(
      generator.text(
        _escText('FLOOR COPY #${ticket.ticketCode}'),
        styles: const PosStyles(align: PosAlign.center),
      ),
    );
    bytes.addAll(_buildTicketBody(generator, ticket));
    return bytes;
  }

  static Future<List<int>> buildTrayLabel(PrintTicket ticket) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    final bytes = <int>[];

    bytes.addAll(_buildLargeTableHeader(generator, ticket));
    bytes.addAll(
      generator.text(
        _escText('TRAY / DUMBWAITER'),
        styles: const PosStyles(bold: true, align: PosAlign.center),
      ),
    );
    bytes.addAll(_buildTicketBody(generator, ticket, compact: true));
    return bytes;
  }

  static List<int> _buildLargeTableHeader(
    Generator generator,
    PrintTicket ticket,
  ) {
    final bytes = <int>[];
    bytes.addAll(
      generator.text(
        _escText('${ticket.floorLabel} / ${ticket.tableNumber}'),
        styles: const PosStyles(
          bold: true,
          align: PosAlign.center,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
    );
    bytes.addAll(generator.hr());
    return bytes;
  }

  static List<int> _buildTicketBody(
    Generator generator,
    PrintTicket ticket, {
    bool compact = false,
  }) {
    final bytes = <int>[];
    if (ticket.printedReason == 'added_items') {
      bytes.addAll(
        generator.text(
          _escText('*** ADDED ITEMS (batch ${ticket.batchNo}) ***'),
          styles: const PosStyles(bold: true, align: PosAlign.center),
        ),
      );
    } else {
      bytes.addAll(
        generator.text(
          _escText('Batch ${ticket.batchNo} / ${ticket.printedReason}'),
          styles: const PosStyles(align: PosAlign.center),
        ),
      );
    }
    bytes.addAll(generator.hr());

    for (final item in ticket.items) {
      final linePrefix = item.supplemental ? '+ ' : '';
      bytes.addAll(
        generator.row([
          PosColumn(
            text: _escText('$linePrefix${item.label}'),
            width: compact ? 8 : 9,
            styles: const PosStyles(bold: true),
          ),
          PosColumn(
            text: 'x${item.quantity}',
            width: compact ? 4 : 3,
            styles: const PosStyles(align: PosAlign.right, bold: true),
          ),
        ]),
      );
      final notes = item.notes?.trim();
      if (notes != null && notes.isNotEmpty) {
        bytes.addAll(generator.text(_escText('  * $notes')));
      }
    }

    final orderNotes = ticket.orderNotes?.trim();
    if (orderNotes != null && orderNotes.isNotEmpty) {
      bytes.addAll(generator.hr());
      bytes.addAll(generator.text(_escText('Note: $orderNotes')));
    }

    bytes.addAll(generator.hr());
    bytes.addAll(generator.text(_escText(ticket.printedAt)));
    bytes.addAll(generator.feed(2));
    bytes.addAll(generator.cut());
    return bytes;
  }

  static String _formatVnd(double amount) {
    final n = amount.toInt();
    final s = n.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) {
        buffer.write(',');
      }
      buffer.write(s[i]);
    }
    return '${buffer.toString()} VND';
  }

  static String _methodLabel(String method) {
    switch (method) {
      case 'cash':
        return 'Cash / Tien mat';
      case 'card':
        return 'Card / The';
      case 'pay':
        return 'E-wallet / Vi dien tu';
      case 'service':
        return 'Service / Dich vu';
      default:
        return _escText(method);
    }
  }

  static String _escText(String value) {
    const replacements = {
      '₫': 'VND',
      'đ': 'd',
      'Đ': 'D',
      'à': 'a',
      'á': 'a',
      'ạ': 'a',
      'ả': 'a',
      'ã': 'a',
      'â': 'a',
      'ầ': 'a',
      'ấ': 'a',
      'ậ': 'a',
      'ẩ': 'a',
      'ẫ': 'a',
      'ă': 'a',
      'ằ': 'a',
      'ắ': 'a',
      'ặ': 'a',
      'ẳ': 'a',
      'ẵ': 'a',
      'è': 'e',
      'é': 'e',
      'ẹ': 'e',
      'ẻ': 'e',
      'ẽ': 'e',
      'ê': 'e',
      'ề': 'e',
      'ế': 'e',
      'ệ': 'e',
      'ể': 'e',
      'ễ': 'e',
      'ì': 'i',
      'í': 'i',
      'ị': 'i',
      'ỉ': 'i',
      'ĩ': 'i',
      'ò': 'o',
      'ó': 'o',
      'ọ': 'o',
      'ỏ': 'o',
      'õ': 'o',
      'ô': 'o',
      'ồ': 'o',
      'ố': 'o',
      'ộ': 'o',
      'ổ': 'o',
      'ỗ': 'o',
      'ơ': 'o',
      'ờ': 'o',
      'ớ': 'o',
      'ợ': 'o',
      'ở': 'o',
      'ỡ': 'o',
      'ù': 'u',
      'ú': 'u',
      'ụ': 'u',
      'ủ': 'u',
      'ũ': 'u',
      'ư': 'u',
      'ừ': 'u',
      'ứ': 'u',
      'ự': 'u',
      'ử': 'u',
      'ữ': 'u',
      'ỳ': 'y',
      'ý': 'y',
      'ỵ': 'y',
      'ỷ': 'y',
      'ỹ': 'y',
      'À': 'A',
      'Á': 'A',
      'Ạ': 'A',
      'Ả': 'A',
      'Ã': 'A',
      'Â': 'A',
      'Ầ': 'A',
      'Ấ': 'A',
      'Ậ': 'A',
      'Ẩ': 'A',
      'Ẫ': 'A',
      'Ă': 'A',
      'Ằ': 'A',
      'Ắ': 'A',
      'Ặ': 'A',
      'Ẳ': 'A',
      'Ẵ': 'A',
      'È': 'E',
      'É': 'E',
      'Ẹ': 'E',
      'Ẻ': 'E',
      'Ẽ': 'E',
      'Ê': 'E',
      'Ề': 'E',
      'Ế': 'E',
      'Ệ': 'E',
      'Ể': 'E',
      'Ễ': 'E',
      'Ì': 'I',
      'Í': 'I',
      'Ị': 'I',
      'Ỉ': 'I',
      'Ĩ': 'I',
      'Ò': 'O',
      'Ó': 'O',
      'Ọ': 'O',
      'Ỏ': 'O',
      'Õ': 'O',
      'Ô': 'O',
      'Ồ': 'O',
      'Ố': 'O',
      'Ộ': 'O',
      'Ổ': 'O',
      'Ỗ': 'O',
      'Ơ': 'O',
      'Ờ': 'O',
      'Ớ': 'O',
      'Ợ': 'O',
      'Ở': 'O',
      'Ỡ': 'O',
      'Ù': 'U',
      'Ú': 'U',
      'Ụ': 'U',
      'Ủ': 'U',
      'Ũ': 'U',
      'Ư': 'U',
      'Ừ': 'U',
      'Ứ': 'U',
      'Ự': 'U',
      'Ử': 'U',
      'Ữ': 'U',
      'Ỳ': 'Y',
      'Ý': 'Y',
      'Ỵ': 'Y',
      'Ỷ': 'Y',
      'Ỹ': 'Y',
    };

    final buffer = StringBuffer();
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      final replacement = replacements[char];
      if (replacement != null) {
        buffer.write(replacement);
      } else if (rune <= 255) {
        buffer.write(char);
      } else {
        buffer.write('?');
      }
    }
    return buffer.toString();
  }
}

class PrintTicket {
  const PrintTicket({
    required this.ticket,
    required this.floorLabel,
    required this.tableNumber,
    required this.ticketCode,
    required this.batchNo,
    required this.printedReason,
    required this.printedAt,
    required this.items,
    this.orderNotes,
  });

  final String ticket;
  final String floorLabel;
  final String tableNumber;
  final String ticketCode;
  final int batchNo;
  final String printedReason;
  final String printedAt;
  final List<PrintTicketItem> items;
  final String? orderNotes;

  factory PrintTicket.fromPayload(Map<String, dynamic> payload) {
    final rawItems = payload['items'];
    final itemRows = rawItems is List ? rawItems : const <Object?>[];
    return PrintTicket(
      ticket: payload['ticket']?.toString() ?? 'kitchen',
      floorLabel: payload['floor_label']?.toString() ?? '-',
      tableNumber: payload['table_number']?.toString() ?? '-',
      ticketCode: payload['ticket_code']?.toString() ?? '-',
      batchNo: switch (payload['batch_no']) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 1,
        _ => 1,
      },
      printedReason: payload['printed_reason']?.toString() ?? 'initial',
      printedAt: payload['at']?.toString() ?? '',
      items: itemRows
          .whereType<Map>()
          .map(
            (item) =>
                PrintTicketItem.fromPayload(Map<String, dynamic>.from(item)),
          )
          .toList(),
      orderNotes: payload['order_notes']?.toString(),
    );
  }
}

class PrintTicketItem {
  const PrintTicketItem({
    required this.label,
    required this.quantity,
    this.notes,
    this.supplemental = false,
  });

  final String label;
  final int quantity;
  final String? notes;
  final bool supplemental;

  factory PrintTicketItem.fromPayload(Map<String, dynamic> payload) {
    return PrintTicketItem(
      label: payload['label']?.toString() ?? 'Item',
      quantity: switch (payload['qty'] ?? payload['quantity']) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 1,
        _ => 1,
      },
      notes: payload['notes']?.toString(),
      supplemental: switch (payload['supplemental']) {
        bool value => value,
        String value => value.toLowerCase() == 'true',
        _ => false,
      },
    );
  }
}

class ReceiptItem {
  const ReceiptItem({
    required this.name,
    required this.quantity,
    required this.unitPrice,
    this.isServiceItem = false,
  });

  final String name;
  final int quantity;
  final double unitPrice;
  final bool isServiceItem;
}
