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
        restaurantName,
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
        PosColumn(text: 'Table / Bàn: $tableNumber', width: 8),
        PosColumn(
          text: TimeUtils.formatTime(paidAt),  // UTC to Vietnam time
          width: 4,
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]),
    );
    bytes.addAll(
      generator.text(
        TimeUtils.formatDate(paidAt),  // UTC to Vietnam date
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
          text: 'Giá (₫)',
          width: 4,
          styles: const PosStyles(bold: true, align: PosAlign.right),
        ),
      ]),
    );
    bytes.addAll(generator.hr());

    for (final item in items) {
      bytes.addAll(
        generator.row([
          PosColumn(text: item.name, width: 6),
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
          text: isService ? 'DỊCH VỤ / Service' : 'TỔNG CỘNG / Total',
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
    bytes.addAll(generator.text('Thanh toán / Payment: $methodLabel'));

    if (isService) {
      bytes.addAll(generator.hr());
      bytes.addAll(
        generator.text(
          '* Service Provision — not counted in revenue',
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
    return '${buffer.toString()}₫';
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
        return method;
    }
  }
}

class ReceiptItem {
  const ReceiptItem({
    required this.name,
    required this.quantity,
    required this.unitPrice,
  });

  final String name;
  final int quantity;
  final double unitPrice;
}
