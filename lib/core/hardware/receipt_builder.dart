import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import '../utils/floor_label.dart';
import '../utils/time_utils.dart';

class ReceiptBuilder {
  static const bankTransferQrAsset = 'assets/images/woori_bank_account_qr.jpg';
  static const internalBuzzerAlertBytes = <int>[0x1B, 0x42, 5, 9];

  static Future<List<int>> buildPaymentReceipt({
    required String restaurantName,
    required String tableNumber,
    required List<ReceiptItem> items,
    required double totalAmount,
    required String paymentMethod,
    required DateTime paidAt,
    bool isService = false,
    String? legalName,
    String? taxCode,
    List<String> addressLines = const [],
    String? receiptNumber,
    String? cashierCode,
    double? subtotalAmount,
    double discountAmount = 0,
    double vatAmount = 0,
    double? receivedAmount,
    double changeAmount = 0,
    String? directFulfillmentType,
    String? directDeliveryPaymentMode,
    String? directReferenceCode,
    int? dinerCount,
    bool utensilsRequested = true,
    String? fulfillmentMethod,
    String? directOrderReference,
    String? orderNotes,
    double refundedTotal = 0,
  }) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    final bytes = <int>[];

    bytes.addAll(
      generator.text(
        _escText(restaurantName.toUpperCase()),
        styles: const PosStyles(
          bold: true,
          align: PosAlign.center,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
    );
    if (legalName != null && legalName.trim().isNotEmpty) {
      bytes.addAll(
        generator.text(
          _escText(legalName),
          styles: const PosStyles(align: PosAlign.center),
        ),
      );
    }
    if (taxCode != null && taxCode.trim().isNotEmpty) {
      bytes.addAll(
        generator.text(
          'MST: ${_escText(taxCode)}',
          styles: const PosStyles(align: PosAlign.center),
        ),
      );
    }
    if (addressLines.isNotEmpty) {
      bytes.addAll(
        generator.text(
          'Dia chi:',
          styles: const PosStyles(align: PosAlign.center),
        ),
      );
      for (final line in addressLines.where((line) => line.trim().isNotEmpty)) {
        bytes.addAll(
          generator.text(
            _escText(line),
            styles: const PosStyles(align: PosAlign.center),
          ),
        );
      }
    }
    bytes.addAll(generator.hr());

    bytes.addAll(
      generator.text(
        'PHIEU THANH TOAN',
        styles: const PosStyles(
          bold: true,
          align: PosAlign.center,
          height: PosTextSize.size2,
        ),
      ),
    );
    bytes.addAll(generator.hr());

    if (receiptNumber != null) {
      bytes.addAll(generator.text('So phieu : ${_escText(receiptNumber)}'));
    }
    bytes.addAll(
      generator.text(
        'Ngay/Gio  : ${TimeUtils.formatDate(paidAt)} ${TimeUtils.formatTime(paidAt)}',
      ),
    );
    if (cashierCode != null) {
      bytes.addAll(generator.text('Thu ngan  : ${_escText(cashierCode)}'));
    }
    bytes.addAll(generator.hr());

    if (directFulfillmentType != null) {
      bytes.addAll(
        generator.text(
          directFulfillmentType == 'pickup'
              ? 'MANG DI - NHAN TAI CUA HANG'
              : 'GIAO HANG',
          styles: const PosStyles(bold: true),
        ),
      );
      if (directReferenceCode != null) {
        bytes.addAll(
          generator.text('Ma don: ${_escText(directReferenceCode)}'),
        );
      }
      if (directFulfillmentType == 'delivery') {
        bytes.addAll(
          generator.text(
            directDeliveryPaymentMode == 'customer_direct'
                ? 'Phi Grab: khach tra truc tiep tai xe'
                : 'Phi Grab da tra truoc - khong tra them',
          ),
        );
      }
    } else {
      bytes.addAll(generator.text(_escText('Ban: $tableNumber')));
    }
    bytes.addAll(generator.hr());
    if (directOrderReference != null &&
        directOrderReference != directReferenceCode) {
      bytes.addAll(generator.text('Ma don: ${_escText(directOrderReference)}'));
    }
    if (fulfillmentMethod != null ||
        directFulfillmentType != null ||
        dinerCount != null ||
        directOrderReference != null) {
      bytes.addAll(
        _buildPackingHeader(
          generator,
          dinerCount,
          fulfillmentMethod == directFulfillmentType ? null : fulfillmentMethod,
          utensilsRequested,
        ),
      );
      if (refundedTotal > 0) {
        bytes.addAll(generator.text('Da hoan: ${_formatVnd(refundedTotal)}'));
        bytes.addAll(
          generator.text(
            'Thuc nhan: ${_formatVnd(totalAmount - refundedTotal)}',
          ),
        );
      }
      bytes.addAll(generator.hr());
    }

    final request = orderNotes?.trim();
    if (request != null && request.isNotEmpty) {
      bytes.addAll(
        generator.text(
          _escText('GHI CHU: $request'),
          styles: const PosStyles(bold: true),
        ),
      );
      bytes.addAll(generator.hr());
    }

    bytes.addAll(
      generator.row([
        PosColumn(text: 'Mon', width: 5, styles: const PosStyles(bold: true)),
        PosColumn(
          text: 'SL',
          width: 1,
          styles: const PosStyles(bold: true, align: PosAlign.center),
        ),
        PosColumn(
          text: 'Don gia  Thanh tien',
          width: 6,
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
          PosColumn(text: _escText(item.name), width: 5),
          PosColumn(
            text: '${item.quantity}',
            width: 1,
            styles: const PosStyles(align: PosAlign.center),
          ),
          PosColumn(
            text:
                '${_formatVnd(item.unitPrice)} ${_formatVnd(item.unitPrice * item.quantity)}',
            width: 6,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]),
      );
      final notes = item.notes?.trim();
      if (notes != null && notes.isNotEmpty) {
        bytes.addAll(generator.text(_escText('  * $notes')));
      }
    }

    bytes.addAll(generator.hr());
    final subtotal =
        subtotalAmount ??
        billableItems.fold<double>(
          0,
          (sum, item) => sum + item.unitPrice * item.quantity,
        );
    bytes.addAll(_amountRow(generator, 'Tam tinh', subtotal));
    bytes.addAll(_amountRow(generator, 'Giam gia', discountAmount));
    bytes.addAll(_amountRow(generator, 'VAT (da gom)', vatAmount));
    bytes.addAll(
      generator.row([
        PosColumn(
          text: isService ? 'DICH VU' : 'TONG CONG',
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
    bytes.addAll(generator.text('Phuong thuc : $methodLabel'));
    bytes.addAll(
      generator.text(
        'Khach tra   : ${_formatVnd(receivedAmount ?? totalAmount)}',
      ),
    );
    bytes.addAll(generator.text('Tien thua   : ${_formatVnd(changeAmount)}'));

    if (isService) {
      bytes.addAll(generator.hr());
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
          '* Mon phuc vu: $serviceItemCount',
          styles: const PosStyles(align: PosAlign.center),
        ),
      );
    }

    if (!isService) {
      bytes.addAll(generator.hr());
      bytes.addAll(
        generator.text(
          'CHUYEN KHOAN',
          styles: const PosStyles(bold: true, align: PosAlign.center),
        ),
      );
      bytes.addAll(
        generator.text(
          'WOORI BANK - 100202042976',
          styles: const PosStyles(bold: true, align: PosAlign.center),
        ),
      );
      bytes.addAll(
        generator.text(
          'AHN HYOCHANG',
          styles: const PosStyles(align: PosAlign.center),
        ),
      );
      bytes.addAll(generator.imageRaster(await _loadBankTransferQr()));
    }

    bytes.addAll(generator.hr());
    bytes.addAll(
      generator.text(
        'Cam on quy khach!',
        styles: const PosStyles(align: PosAlign.center),
      ),
    );
    bytes.addAll(generator.feed(2));
    bytes.addAll(generator.cut());

    return bytes;
  }

  static Future<List<int>> buildDeliveryDriverReceipt({
    required String restaurantName,
    required String referenceCode,
    required String customerName,
    required String customerPhone,
    required String formattedAddress,
    required String detailAddress,
    required List<ReceiptItem> items,
    required double menuTotal,
    required double serviceChargeTotal,
    required double deliveryFeeTotal,
    required double finalTotal,
    required DateTime printedAt,
    String deliveryPaymentMode = 'store_prepaid',
    int? dinerCount,
    bool utensilsRequested = true,
    bool isPickup = false,
    double refundedTotal = 0,
    String? orderNotes,
  }) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    final bytes = <int>[];

    bytes.addAll(
      generator.text(
        _escText(restaurantName.toUpperCase()),
        styles: const PosStyles(bold: true, align: PosAlign.center),
      ),
    );
    bytes.addAll(
      generator.text(
        isPickup ? 'PHIEU NHAN MANG VE' : 'PHIEU GIAO HANG',
        styles: const PosStyles(
          bold: true,
          align: PosAlign.center,
          height: PosTextSize.size2,
        ),
      ),
    );
    bytes.addAll(
      generator.text(
        'DA THANH TOAN',
        styles: const PosStyles(bold: true, align: PosAlign.center),
      ),
    );
    bytes.addAll(generator.hr());
    bytes.addAll(generator.text('Ma don   : ${_escText(referenceCode)}'));
    bytes.addAll(
      generator.text(
        'Ngay/Gio : ${TimeUtils.formatDate(printedAt)} ${TimeUtils.formatTime(printedAt)}',
      ),
    );
    bytes.addAll(generator.hr());
    bytes.addAll(
      generator.text(
        'THONG TIN GIAO HANG',
        styles: const PosStyles(bold: true, align: PosAlign.center),
      ),
    );
    bytes.addAll(generator.text('Khach: ${_escText(customerName)}'));
    bytes.addAll(generator.text('SDT  : ${_escText(customerPhone)}'));
    if (!isPickup) {
      bytes.addAll(generator.text('Dia chi giao hang:'));
      bytes.addAll(generator.text(_escText(formattedAddress)));
      bytes.addAll(generator.text('Chi tiet: ${_escText(detailAddress)}'));
    }
    bytes.addAll(
      _buildPackingHeader(
        generator,
        dinerCount,
        isPickup ? 'pickup' : 'delivery',
        utensilsRequested,
      ),
    );
    if (refundedTotal > 0) {
      bytes.addAll(generator.text('Da hoan: ${_formatVnd(refundedTotal)}'));
      bytes.addAll(
        generator.text('Thuc nhan: ${_formatVnd(finalTotal - refundedTotal)}'),
      );
    }
    bytes.addAll(generator.hr());
    bytes.addAll(
      generator.text(
        'MON GIAO',
        styles: const PosStyles(bold: true, align: PosAlign.center),
      ),
    );
    for (final item in items) {
      bytes.addAll(
        generator.text(
          _escText(item.name),
          styles: const PosStyles(bold: true),
        ),
      );
      bytes.addAll(
        generator.row([
          PosColumn(
            text: '${item.quantity} x ${_formatVnd(item.unitPrice)}',
            width: 6,
          ),
          PosColumn(
            text: _formatVnd(item.unitPrice * item.quantity),
            width: 6,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]),
      );
    }
    bytes.addAll(generator.hr());
    if (orderNotes?.trim().isNotEmpty == true) {
      bytes.addAll(
        generator.text(_escText('Yeu cau da thong nhat: $orderNotes')),
      );
      bytes.addAll(generator.hr());
    }
    bytes.addAll(_amountRow(generator, 'Tien mon', menuTotal));
    bytes.addAll(_amountRow(generator, 'Phi dich vu', serviceChargeTotal));
    if (deliveryPaymentMode == 'store_prepaid') {
      bytes.addAll(
        _amountRow(generator, 'Phi giao hang Grab', deliveryFeeTotal),
      );
    }
    bytes.addAll(
      generator.row([
        PosColumn(
          text: 'TONG DA THANH TOAN',
          width: 7,
          styles: const PosStyles(bold: true),
        ),
        PosColumn(
          text: _formatVnd(finalTotal),
          width: 5,
          styles: const PosStyles(bold: true, align: PosAlign.right),
        ),
      ]),
    );
    bytes.addAll(generator.hr());
    bytes.addAll(
      generator.text(
        deliveryPaymentMode == 'customer_direct'
            ? 'Khach tra phi Grab truc tiep tai xe'
            : 'Khach can tra: ${_formatVnd(0)}',
        styles: const PosStyles(bold: true, align: PosAlign.center),
      ),
    );
    bytes.addAll(
      generator.text(
        deliveryPaymentMode == 'customer_direct'
            ? 'KHONG THU LAI TIEN MON'
            : 'KHONG THU THEM TIEN CUA KHACH',
        styles: const PosStyles(bold: true, align: PosAlign.center),
      ),
    );
    bytes.addAll(generator.feed(2));
    bytes.addAll(generator.cut());
    return bytes;
  }

  static Future<img.Image> _loadBankTransferQr() async {
    final data = await rootBundle.load(bankTransferQrAsset);
    final decoded = img.decodeImage(data.buffer.asUint8List());
    if (decoded == null) {
      throw StateError('BANK_TRANSFER_QR_ASSET_INVALID');
    }
    return img.copyResize(
      decoded,
      width: 512,
      interpolation: img.Interpolation.average,
    );
  }

  static List<int> _amountRow(
    Generator generator,
    String label,
    double amount,
  ) => generator.row([
    PosColumn(text: label, width: 7),
    PosColumn(
      text: _formatVnd(amount),
      width: 5,
      styles: const PosStyles(align: PosAlign.right),
    ),
  ]);

  static List<int> _buildPackingHeader(
    Generator generator,
    int? count,
    String? method,
    bool utensilsRequested,
  ) {
    final bytes = <int>[];
    if (method != null) {
      bytes.addAll(
        generator.text(method == 'pickup' ? 'TU DEN LAY' : 'GIAO HANG'),
      );
    }
    if (count == null || count < 1 || count > 100) {
      bytes.addAll(
        generator.text(
          'SO NGUOI: CHUA NHAP',
          styles: const PosStyles(bold: true),
        ),
      );
      bytes.addAll(
        generator.text(
          utensilsRequested ? 'DUNG CU: CAN KIEM TRA' : 'DUNG CU: KHONG CAN',
          styles: const PosStyles(bold: true, height: PosTextSize.size2),
        ),
      );
    } else {
      bytes.addAll(
        generator.text('SO NGUOI: $count', styles: const PosStyles(bold: true)),
      );
      bytes.addAll(
        generator.text(
          utensilsRequested ? 'DUNG CU: $count BO' : 'DUNG CU: KHONG CAN',
          styles: const PosStyles(bold: true, height: PosTextSize.size2),
        ),
      );
    }
    return bytes;
  }

  static List<int> _buildTicketPackingHeader(
    Generator generator,
    PrintTicket ticket,
  ) {
    if (ticket.fulfillmentMethod == null &&
        ticket.directFulfillmentType == null &&
        ticket.dinerCount == null &&
        ticket.directOrderReference == null) {
      return const [];
    }
    return [
      if (ticket.directOrderReference != null)
        ...generator.text('Ma don: ${_escText(ticket.directOrderReference!)}'),
      ..._buildPackingHeader(
        generator,
        ticket.dinerCount,
        ticket.fulfillmentMethod,
        ticket.utensilsRequested,
      ),
    ];
  }

  static Future<List<int>> buildRequestUpdate(PrintTicket ticket) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    final confirmedAt = DateTime.tryParse(ticket.printedAt);
    return [
      ...generator.text(
        'YEU CAU BO SUNG DA THONG NHAT',
        styles: const PosStyles(bold: true, align: PosAlign.center),
      ),
      ...generator.text(
        _escText('Ma don: ${ticket.directOrderReference ?? ticket.ticketCode}'),
      ),
      if (confirmedAt != null)
        ...generator.text(
          _escText('Xac nhan: ${TimeUtils.formatDateTime(confirmedAt)}'),
        ),
      ...generator.hr(),
      ...generator.text(
        _escText(ticket.orderNotes ?? ''),
        styles: const PosStyles(bold: true),
      ),
      ...generator.hr(),
      ...generator.text('Phieu bo sung - khong thu tien'),
      ...generator.feed(3),
      ...generator.cut(),
    ];
  }

  static Future<List<int>> buildKitchenTicket(PrintTicket ticket) async {
    final driverReceipt = ticket.deliveryDriverReceipt;
    if (ticket.ticket == 'delivery_driver_receipt' && driverReceipt != null) {
      return buildDeliveryDriverReceipt(
        restaurantName: driverReceipt.restaurantName,
        referenceCode: driverReceipt.referenceCode,
        customerName: driverReceipt.customerName,
        customerPhone: driverReceipt.customerPhone,
        formattedAddress: driverReceipt.formattedAddress,
        detailAddress: driverReceipt.detailAddress,
        items: driverReceipt.items,
        menuTotal: driverReceipt.menuTotal,
        serviceChargeTotal: driverReceipt.serviceChargeTotal,
        deliveryFeeTotal: driverReceipt.deliveryFeeTotal,
        finalTotal: driverReceipt.finalTotal,
        printedAt: driverReceipt.printedAt,
        deliveryPaymentMode: driverReceipt.deliveryPaymentMode,
        dinerCount: driverReceipt.dinerCount,
        utensilsRequested: driverReceipt.utensilsRequested,
        isPickup: driverReceipt.isPickup,
        refundedTotal: driverReceipt.refundedTotal,
        orderNotes: driverReceipt.orderNotes,
      );
    }

    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    final bytes = <int>[];

    bytes.addAll(
      generator.text(
        _escText('PHIEU BEP'),
        styles: const PosStyles(
          bold: true,
          align: PosAlign.center,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
    );
    bytes.addAll(generator.text(_escText('#${ticket.ticketCode}')));
    bytes.addAll(_buildTicketPackingHeader(generator, ticket));
    bytes.addAll(
      generator.text(
        _escText(
          '${displayFloorLabel(ticket.floorLabel)} / ${ticket.tableNumber}',
        ),
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
        _escText('PHIEU TANG #${ticket.ticketCode}'),
        styles: const PosStyles(align: PosAlign.center),
      ),
    );
    bytes.addAll(_buildTicketPackingHeader(generator, ticket));
    bytes.addAll(_buildTicketBody(generator, ticket));
    return bytes;
  }

  static Future<List<int>> buildConfirmationSlip(PrintTicket ticket) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    final bytes = <int>[];

    bytes.addAll(_buildLargeTableHeader(generator, ticket));
    bytes.addAll(
      generator.text(
        _escText('XAC NHAN DON #${ticket.ticketCode}'),
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
        _escText('Chi thanh toan tai quay thu ngan'),
        styles: const PosStyles(align: PosAlign.center),
      ),
    );
    bytes.addAll(_buildTicketPackingHeader(generator, ticket));
    bytes.addAll(
      _buildTicketBody(generator, ticket, finish: false, showPrices: true),
    );
    bytes.addAll(
      generator.text(
        _escText('Vui long mang phieu nay den quay thu ngan.'),
        styles: const PosStyles(align: PosAlign.center),
      ),
    );
    bytes.addAll(
      generator.text(
        _escText('Day khong phai hoa don. Chi thanh toan tai quay.'),
        styles: const PosStyles(bold: true, align: PosAlign.center),
      ),
    );
    bytes.addAll(generator.feed(2));
    bytes.addAll(generator.cut());
    return bytes;
  }

  static Future<List<int>> buildTrayLabel(PrintTicket ticket) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    final bytes = <int>[];

    bytes.addAll(_buildLargeTableHeader(generator, ticket));
    bytes.addAll(
      generator.text(
        _escText('KHAY / THANG MAY DO AN'),
        styles: const PosStyles(bold: true, align: PosAlign.center),
      ),
    );
    bytes.addAll(_buildTicketPackingHeader(generator, ticket));
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
        _escText(
          '${displayFloorLabel(ticket.floorLabel)} / ${ticket.tableNumber}',
        ),
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
    bool finish = true,
    bool showPrices = false,
  }) {
    final bytes = <int>[];
    if (ticket.directFulfillmentType != null) {
      bytes.addAll(
        generator.text(
          ticket.directFulfillmentType == 'pickup'
              ? 'MANG DI - NHAN TAI CUA HANG'
              : 'GIAO HANG',
          styles: const PosStyles(bold: true),
        ),
      );
      bytes.addAll(
        generator.text(
          'Ma don: ${_escText(ticket.directReferenceCode ?? ticket.ticketCode)}',
        ),
      );
    }
    if (ticket.printedReason == 'added_items') {
      bytes.addAll(
        generator.text(
          _escText('*** MON THEM (DOT ${ticket.batchNo}) ***'),
          styles: const PosStyles(bold: true, align: PosAlign.center),
        ),
      );
    } else {
      bytes.addAll(
        generator.text(
          _escText(
            'Dot ${ticket.batchNo} / ${_printedReasonLabel(ticket.printedReason)}',
          ),
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
      if (showPrices && item.unitPrice != null) {
        final lineTotal = item.unitPrice! * item.quantity;
        bytes.addAll(
          generator.text(
            _escText(
              '  ${item.quantity} x ${_formatVnd(item.unitPrice!)} = ${_formatVnd(lineTotal)}',
            ),
            styles: const PosStyles(align: PosAlign.right),
          ),
        );
      }
      final notes = item.notes?.trim();
      if (notes != null && notes.isNotEmpty) {
        bytes.addAll(generator.text(_escText('  * $notes')));
      }
      for (final component in item.components) {
        bytes.addAll(
          generator.row([
            PosColumn(
              text: _escText('  - ${component.label}'),
              width: compact ? 8 : 9,
            ),
            PosColumn(
              text: 'x${component.displayQuantity(item.quantity)}',
              width: compact ? 4 : 3,
              styles: const PosStyles(align: PosAlign.right, bold: true),
            ),
          ]),
        );
      }
    }

    final orderNotes = ticket.orderNotes?.trim();
    if (orderNotes != null && orderNotes.isNotEmpty) {
      bytes.addAll(generator.hr());
      bytes.addAll(generator.text(_escText('Ghi chu: $orderNotes')));
    }

    if (showPrices && ticket.items.every((item) => item.unitPrice != null)) {
      final total = ticket.items.fold<double>(
        0,
        (sum, item) => sum + item.unitPrice! * item.quantity,
      );
      bytes.addAll(generator.hr());
      bytes.addAll(_amountRow(generator, 'Tong cong', total));
    }

    bytes.addAll(generator.hr());
    bytes.addAll(generator.text(_escText(ticket.printedAt)));
    if (finish) {
      bytes.addAll(generator.feed(2));
      bytes.addAll(generator.cut());
    } else {
      bytes.addAll(generator.hr());
    }
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
    switch (method.trim().toLowerCase()) {
      case 'cash':
        return 'Tien mat';
      case 'card':
        return 'The';
      case 'pay':
        return 'Vi dien tu';
      case 'bank_transfer':
        return 'Chuyen khoan';
      case 'service':
        return 'Dich vu';
      case 'split':
        return 'Thanh toan tach';
      default:
        return 'Khac';
    }
  }

  static String _printedReasonLabel(String reason) {
    return switch (reason.trim().toLowerCase()) {
      'initial' => 'Lan dau',
      'serving' => 'Phuc vu',
      'reprint' => 'In lai',
      'added_items' => 'Mon them',
      _ => 'Cap nhat',
    };
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
    this.dinerCount,
    this.utensilsRequested = true,
    this.fulfillmentMethod,
    this.directOrderReference,
    this.deliveryDriverReceipt,
    this.directFulfillmentType,
    this.directReferenceCode,
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
  final int? dinerCount;
  final bool utensilsRequested;
  final String? fulfillmentMethod;
  final String? directOrderReference;
  final QueuedDeliveryDriverReceipt? deliveryDriverReceipt;
  final String? directFulfillmentType;
  final String? directReferenceCode;

  factory PrintTicket.fromPayload(Map<String, dynamic> payload) {
    final rawItems = payload['items'];
    final itemRows = rawItems is List ? rawItems : const <Object?>[];
    final ticket = payload['ticket']?.toString() ?? 'kitchen';
    return PrintTicket(
      ticket: ticket,
      directFulfillmentType: payload['direct_fulfillment_type']?.toString(),
      directReferenceCode: payload['direct_reference_code']?.toString(),
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
      dinerCount: _packingDinerCount(payload['diner_count']),
      utensilsRequested: payload['utensils_requested'] != false,
      fulfillmentMethod: payload['fulfillment_method']?.toString(),
      directOrderReference: payload['direct_order_reference']?.toString(),
      deliveryDriverReceipt: ticket == 'delivery_driver_receipt'
          ? QueuedDeliveryDriverReceipt.fromPayload(payload)
          : null,
    );
  }
}

class PrintTicketItem {
  const PrintTicketItem({
    required this.label,
    required this.quantity,
    this.unitPrice,
    this.notes,
    this.supplemental = false,
    this.components = const [],
  });

  final String label;
  final int quantity;
  final double? unitPrice;
  final String? notes;
  final bool supplemental;
  final List<PrintTicketComboComponent> components;

  factory PrintTicketItem.fromPayload(Map<String, dynamic> payload) {
    return PrintTicketItem(
      label: payload['label']?.toString() ?? 'Mon',
      quantity: switch (payload['qty'] ?? payload['quantity']) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 1,
        _ => 1,
      },
      unitPrice: switch (payload['unit_price']) {
        num value => value.toDouble(),
        String value => double.tryParse(value),
        _ => null,
      },
      notes: payload['notes']?.toString(),
      supplemental: switch (payload['supplemental']) {
        bool value => value,
        String value => value.toLowerCase() == 'true',
        _ => false,
      },
      components: switch (payload['components']) {
        final List value =>
          value
              .whereType<Map>()
              .map(
                (component) => PrintTicketComboComponent.fromPayload(
                  Map<String, dynamic>.from(component),
                ),
              )
              .toList(growable: false),
        _ => const [],
      },
    );
  }
}

class PrintTicketComboComponent {
  const PrintTicketComboComponent({
    required this.label,
    required this.quantity,
    this.isTotalQuantity = false,
  });

  final String label;
  final int quantity;
  final bool isTotalQuantity;

  int displayQuantity(int orderItemQuantity) =>
      isTotalQuantity ? quantity : quantity * orderItemQuantity;

  factory PrintTicketComboComponent.fromPayload(Map<String, dynamic> payload) {
    return PrintTicketComboComponent(
      label: payload['label']?.toString() ?? 'Mon',
      quantity: switch (payload['quantity']) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 1,
        _ => 1,
      },
      isTotalQuantity: switch (payload['is_total_quantity']) {
        bool value => value,
        String value => value.toLowerCase() == 'true',
        _ => false,
      },
    );
  }
}

class QueuedPaymentReceipt {
  const QueuedPaymentReceipt({
    this.directFulfillmentType,
    this.directDeliveryPaymentMode,
    this.directReferenceCode,
    required this.restaurantName,
    required this.tableNumber,
    required this.items,
    required this.totalAmount,
    required this.paymentMethod,
    required this.paidAt,
    required this.isService,
    required this.legalName,
    required this.taxCode,
    required this.addressLines,
    required this.receiptNumber,
    required this.cashierCode,
    required this.subtotalAmount,
    required this.discountAmount,
    required this.vatAmount,
    required this.receivedAmount,
    required this.changeAmount,
    this.dinerCount,
    this.utensilsRequested = true,
    this.fulfillmentMethod,
    this.directOrderReference,
    this.orderNotes,
    this.refundedTotal = 0,
  });

  final String? directFulfillmentType;
  final String? directDeliveryPaymentMode;
  final String? directReferenceCode;
  final String restaurantName;
  final String tableNumber;
  final List<ReceiptItem> items;
  final double totalAmount;
  final String paymentMethod;
  final DateTime paidAt;
  final bool isService;
  final String? legalName;
  final String? taxCode;
  final List<String> addressLines;
  final String? receiptNumber;
  final String? cashierCode;
  final double? subtotalAmount;
  final double discountAmount;
  final double vatAmount;
  final double? receivedAmount;
  final double changeAmount;
  final int? dinerCount;
  final bool utensilsRequested;
  final String? fulfillmentMethod;
  final String? directOrderReference;
  final String? orderNotes;
  final double refundedTotal;

  factory QueuedPaymentReceipt.fromPayload(Map<String, dynamic> payload) {
    final rawItems = payload['items'];
    final itemRows = rawItems is List ? rawItems : const <Object?>[];
    final method = payload['payment_method']?.toString() ?? 'other';
    final isCombined =
        payload['is_combined'] == true ||
        payload['is_combined']?.toString().toLowerCase() == 'true';
    Object? receiptValue(String standardKey, String combinedKey) => isCombined
        ? payload[combinedKey] ?? payload[standardKey]
        : payload[standardKey];
    return QueuedPaymentReceipt(
      orderNotes: payload['order_notes']?.toString(),
      directFulfillmentType: payload['direct_fulfillment_type']?.toString(),
      directDeliveryPaymentMode: payload['direct_delivery_payment_mode']
          ?.toString(),
      directReferenceCode: payload['direct_reference_code']?.toString(),
      dinerCount: _packingDinerCount(payload['diner_count']),
      utensilsRequested: payload['utensils_requested'] != false,
      fulfillmentMethod: payload['fulfillment_method']?.toString(),
      directOrderReference: payload['direct_order_reference']?.toString(),
      refundedTotal: _payloadDouble(payload['refunded_total']) ?? 0,
      restaurantName: payload['restaurant_name']?.toString() ?? 'GLOBOS POS',
      tableNumber: payload['table_number']?.toString() ?? '-',
      items: itemRows.whereType<Map>().map((item) {
        final row = Map<String, dynamic>.from(item);
        return ReceiptItem(
          notes: row['notes']?.toString(),
          name: row['label']?.toString() ?? 'Mon',
          quantity: switch (row['quantity'] ?? row['qty']) {
            int value => value,
            num value => value.toInt(),
            String value => int.tryParse(value) ?? 1,
            _ => 1,
          },
          unitPrice: switch (row['unit_price']) {
            num value => value.toDouble(),
            String value => double.tryParse(value) ?? 0,
            _ => 0,
          },
          isServiceItem: switch (row['is_service_item']) {
            bool value => value,
            String value => value.toLowerCase() == 'true',
            _ => false,
          },
        );
      }).toList(),
      totalAmount: switch (payload['total_amount']) {
        num value => value.toDouble(),
        String value => double.tryParse(value) ?? 0,
        _ => 0,
      },
      paymentMethod: method,
      paidAt:
          DateTime.tryParse(payload['at']?.toString() ?? '') ?? DateTime.now(),
      isService: switch (payload['is_service']) {
        bool value => value,
        String value => value.toLowerCase() == 'true',
        _ => method.toUpperCase() == 'SERVICE',
      },
      legalName: payload['legal_name']?.toString(),
      taxCode: payload['tax_code']?.toString(),
      addressLines:
          (payload['address_lines'] is List
                  ? payload['address_lines'] as List
                  : const [])
              .map((value) => value.toString())
              .toList(),
      receiptNumber: receiptValue(
        'receipt_number',
        'combined_receipt_number',
      )?.toString(),
      cashierCode: receiptValue(
        'cashier_code',
        'combined_cashier_code',
      )?.toString(),
      subtotalAmount: _payloadDouble(
        receiptValue('subtotal_amount', 'combined_subtotal_amount'),
      ),
      discountAmount:
          _payloadDouble(
            receiptValue('discount_amount', 'combined_discount_amount'),
          ) ??
          0,
      vatAmount:
          _payloadDouble(
            isCombined
                ? payload['combined_vat_amount'] ?? payload['vat_amount']
                : payload['vat_amount'],
          ) ??
          0,
      receivedAmount: _payloadDouble(
        receiptValue('received_amount', 'combined_received_amount'),
      ),
      changeAmount:
          _payloadDouble(
            receiptValue('change_amount', 'combined_change_amount'),
          ) ??
          0,
    );
  }

  static double? _payloadDouble(Object? value) => switch (value) {
    num number => number.toDouble(),
    String text => double.tryParse(text),
    _ => null,
  };
}

class QueuedDeliveryDriverReceipt {
  const QueuedDeliveryDriverReceipt({
    this.deliveryPaymentMode = 'store_prepaid',
    required this.restaurantName,
    required this.referenceCode,
    required this.customerName,
    required this.customerPhone,
    required this.formattedAddress,
    required this.detailAddress,
    required this.items,
    required this.menuTotal,
    required this.serviceChargeTotal,
    required this.deliveryFeeTotal,
    required this.finalTotal,
    required this.printedAt,
    this.dinerCount,
    this.utensilsRequested = true,
    this.isPickup = false,
    this.refundedTotal = 0,
    this.orderNotes,
  });

  final String restaurantName;
  final String referenceCode;
  final String customerName;
  final String customerPhone;
  final String formattedAddress;
  final String detailAddress;
  final List<ReceiptItem> items;
  final double menuTotal;
  final double serviceChargeTotal;
  final double deliveryFeeTotal;
  final double finalTotal;
  final DateTime printedAt;
  final String deliveryPaymentMode;
  final int? dinerCount;
  final bool utensilsRequested;
  final bool isPickup;
  final double refundedTotal;
  final String? orderNotes;

  factory QueuedDeliveryDriverReceipt.fromPayload(
    Map<String, dynamic> payload,
  ) {
    final rawItems = payload['items'];
    final itemRows = rawItems is List ? rawItems : const <Object?>[];
    return QueuedDeliveryDriverReceipt(
      deliveryPaymentMode:
          payload['direct_delivery_payment_mode']?.toString() ??
          'store_prepaid',
      orderNotes: payload['order_notes']?.toString(),
      dinerCount: _packingDinerCount(payload['diner_count']),
      utensilsRequested: payload['utensils_requested'] != false,
      isPickup: payload['fulfillment_method'] == 'pickup',
      refundedTotal: _payloadDouble(payload['refunded_total']) ?? 0,
      restaurantName: payload['restaurant_name']?.toString() ?? 'GLOBOS POS',
      referenceCode:
          payload['reference_code']?.toString() ??
          payload['ticket_code']?.toString() ??
          '-',
      customerName: payload['customer_name']?.toString() ?? '-',
      customerPhone: payload['customer_phone']?.toString() ?? '-',
      formattedAddress: payload['formatted_address']?.toString() ?? '-',
      detailAddress: payload['detail_address']?.toString() ?? '-',
      items: itemRows
          .whereType<Map>()
          .map((item) {
            final row = Map<String, dynamic>.from(item);
            return ReceiptItem(
              name: row['label']?.toString() ?? 'Mon',
              quantity: switch (row['quantity'] ?? row['qty']) {
                int value => value,
                num value => value.toInt(),
                String value => int.tryParse(value) ?? 1,
                _ => 1,
              },
              unitPrice: _payloadDouble(row['unit_price']) ?? 0,
            );
          })
          .toList(growable: false),
      menuTotal: _payloadDouble(payload['menu_total']) ?? 0,
      serviceChargeTotal: _payloadDouble(payload['service_charge_total']) ?? 0,
      deliveryFeeTotal: _payloadDouble(payload['delivery_fee_total']) ?? 0,
      finalTotal: _payloadDouble(payload['final_total']) ?? 0,
      printedAt:
          DateTime.tryParse(payload['at']?.toString() ?? '') ?? DateTime.now(),
    );
  }

  static double? _payloadDouble(Object? value) => switch (value) {
    num number => number.toDouble(),
    String text => double.tryParse(text),
    _ => null,
  };
}

class ReceiptItem {
  const ReceiptItem({
    required this.name,
    required this.quantity,
    required this.unitPrice,
    this.isServiceItem = false,
    this.notes,
  });

  final String name;
  final int quantity;
  final double unitPrice;
  final bool isServiceItem;
  final String? notes;
}

int? _packingDinerCount(Object? value) {
  if (value is! num || !value.isFinite || value != value.toInt()) return null;
  final count = value.toInt();
  return count >= 1 && count <= 100 ? count : null;
}
