import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

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
        PosColumn(text: '테이블 / Bàn: $tableNumber', width: 8),
        PosColumn(
          text:
              '${paidAt.hour.toString().padLeft(2, '0')}:${paidAt.minute.toString().padLeft(2, '0')}',
          width: 4,
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]),
    );
    bytes.addAll(
      generator.text(
        '${paidAt.year}-${paidAt.month.toString().padLeft(2, '0')}-${paidAt.day.toString().padLeft(2, '0')}',
      ),
    );
    bytes.addAll(generator.hr());

    bytes.addAll(
      generator.row([
        PosColumn(
          text: '메뉴 / Món',
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
          text: isService ? 'DỊCH VỤ / 서비스' : 'TỔNG CỘNG / 합계',
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
    bytes.addAll(generator.text('Thanh toán / 결제: $methodLabel'));

    if (isService) {
      bytes.addAll(generator.hr());
      bytes.addAll(
        generator.text(
          '* 서비스 제공 - 매출 미반영',
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
        'Cam on quy khach! / 감사합니다!',
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
        return '현금 / Tien mat';
      case 'card':
        return '카드 / The';
      case 'pay':
        return '간편결제 / Vi dien tu';
      case 'service':
        return '서비스 / Dich vu';
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
