import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/services/digital_receipt_pdf_service.dart';
import '../../core/services/digital_receipt_service.dart';
import '../../core/ui/pos_design_tokens.dart';
import 'digital_receipt_model.dart';

class DigitalReceiptScreen extends StatefulWidget {
  const DigitalReceiptScreen({super.key, required this.token, this.loader});

  final String token;
  final Future<DigitalReceipt?> Function(String token)? loader;

  @override
  State<DigitalReceiptScreen> createState() => _DigitalReceiptScreenState();
}

class _DigitalReceiptScreenState extends State<DigitalReceiptScreen> {
  late Future<DigitalReceipt?> _receiptFuture;
  bool _saving = false;
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    _receiptFuture = _load();
  }

  Future<DigitalReceipt?> _load() =>
      widget.loader?.call(widget.token) ??
      digitalReceiptService.fetchPublic(widget.token);

  void _retry() {
    setState(() {
      _receiptFuture = _load();
    });
  }

  Future<void> _save(DigitalReceipt receipt) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await digitalReceiptPdfService.saveOrShare(receipt);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _print(DigitalReceipt receipt) async {
    if (_printing) return;
    setState(() => _printing = true);
    try {
      await digitalReceiptPdfService.printReceipt(receipt);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const copy = _ReceiptCopy();
    return Scaffold(
      key: const Key('digital_receipt_root'),
      backgroundColor: PosSurfaceRole.background.fill,
      body: SafeArea(
        child: FutureBuilder<DigitalReceipt?>(
          future: _receiptFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return _ReceiptMessage(
                icon: Icons.cloud_off_rounded,
                title: copy.loadFailed,
                body: copy.tryAgain,
                action: copy.retry,
                onAction: _retry,
              );
            }
            final receipt = snapshot.data;
            if (receipt == null) {
              return _ReceiptMessage(
                icon: Icons.link_off_rounded,
                title: copy.unavailable,
                body: copy.unavailableBody,
              );
            }
            return _ReceiptContent(
              receipt: receipt,
              copy: copy,
              saving: _saving,
              printing: _printing,
              onSave: () => _save(receipt),
              onPrint: () => _print(receipt),
            );
          },
        ),
      ),
    );
  }
}

class _ReceiptContent extends StatelessWidget {
  const _ReceiptContent({
    required this.receipt,
    required this.copy,
    required this.saving,
    required this.printing,
    required this.onSave,
    required this.onPrint,
  });

  final DigitalReceipt receipt;
  final _ReceiptCopy copy;
  final bool saving;
  final bool printing;
  final VoidCallback onSave;
  final VoidCallback onPrint;

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat('#,###', 'vi_VN');
    final paidAt = DateFormat(
      'dd/MM/yyyy HH:mm',
    ).format(receipt.paidAt.toLocal());
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              sliver: SliverToBoxAdapter(
                child: _ReceiptPaper(
                  receipt: receipt,
                  copy: copy,
                  currency: currency,
                  paidAt: paidAt,
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              sliver: SliverToBoxAdapter(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final saveButton = FilledButton.icon(
                      key: const Key('digital_receipt_save_pdf'),
                      onPressed: saving ? null : onSave,
                      icon: saving
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_rounded),
                      label: Text(copy.savePdf),
                    );
                    final printButton = OutlinedButton.icon(
                      key: const Key('digital_receipt_browser_print'),
                      onPressed: printing ? null : onPrint,
                      icon: printing
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.print_rounded),
                      label: Text(copy.print),
                    );
                    if (constraints.maxWidth < 480) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          saveButton,
                          const SizedBox(height: 10),
                          printButton,
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: saveButton),
                        const SizedBox(width: 12),
                        Expanded(child: printButton),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReceiptPaper extends StatelessWidget {
  const _ReceiptPaper({
    required this.receipt,
    required this.copy,
    required this.currency,
    required this.paidAt,
  });

  final DigitalReceipt receipt;
  final _ReceiptCopy copy;
  final NumberFormat currency;
  final String paidAt;

  @override
  Widget build(BuildContext context) {
    final billableItems = receipt.items
        .where((item) => !item.isServiceItem)
        .toList(growable: false);
    return Material(
      key: const Key('digital_receipt_paper'),
      color: PosColors.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(
              Icons.receipt_long_rounded,
              color: PosColors.accent,
              size: 36,
            ),
            const SizedBox(height: 10),
            Text(
              receipt.restaurantName,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w900,
                color: PosColors.textPrimary,
              ),
            ),
            if (receipt.legalName != null)
              Text(receipt.legalName!, textAlign: TextAlign.center),
            if (receipt.taxCode != null)
              Text('MST: ${receipt.taxCode}', textAlign: TextAlign.center),
            for (final line in receipt.addressLines)
              Text(line, textAlign: TextAlign.center),
            const SizedBox(height: 18),
            const Divider(),
            _MetaRow(label: copy.receiptNumber, value: receipt.receiptNumber),
            _MetaRow(label: copy.paidAt, value: paidAt),
            _MetaRow(label: copy.cashier, value: receipt.cashierCode),
            _MetaRow(label: copy.table, value: receipt.tableNumber),
            const Divider(height: 28),
            for (final item in billableItems)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        digitalReceiptItemLabelVi(item.label),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('× ${item.quantity}'),
                    const SizedBox(width: 14),
                    SizedBox(
                      width: 112,
                      child: Text(
                        '₫${currency.format(item.lineTotal)}',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
              ),
            const Divider(height: 28),
            _AmountRow(
              label: copy.subtotal,
              value: receipt.subtotalAmount,
              currency: currency,
            ),
            if (receipt.serviceChargeAmount > 0)
              _AmountRow(
                label: copy.serviceCharge,
                value: receipt.serviceChargeAmount,
                currency: currency,
              ),
            if (receipt.discountAmount > 0)
              _AmountRow(
                label: copy.discount,
                value: -receipt.discountAmount,
                currency: currency,
              ),
            _AmountRow(
              label: copy.vat,
              value: receipt.vatAmount,
              currency: currency,
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: PosColors.accent,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      copy.total,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    '₫${currency.format(receipt.totalAmount)}',
                    key: const Key('digital_receipt_total'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _MetaRow(
              label: copy.paymentMethod,
              value: digitalReceiptPaymentMethodVi(receipt.paymentMethod),
            ),
            for (final payment in receipt.payments)
              _MetaRow(
                label: digitalReceiptPaymentMethodVi(payment.method),
                value: '₫${currency.format(payment.amount)}',
              ),
            _MetaRow(
              label: copy.received,
              value: '₫${currency.format(receipt.receivedAmount)}',
            ),
            _MetaRow(
              label: copy.change,
              value: '₫${currency.format(receipt.changeAmount)}',
            ),
            const SizedBox(height: 22),
            Text(
              copy.thanks,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              copy.proofNotice,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: PosColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: const TextStyle(color: PosColors.textSecondary),
          ),
        ),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({
    required this.label,
    required this.value,
    required this.currency,
  });

  final String label;
  final double value;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(
          '${value < 0 ? '-' : ''}₫${currency.format(value.abs())}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

class _ReceiptMessage extends StatelessWidget {
  const _ReceiptMessage({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: PosColors.textSecondary),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(body, textAlign: TextAlign.center),
          if (action != null && onAction != null) ...[
            const SizedBox(height: 18),
            FilledButton(onPressed: onAction, child: Text(action!)),
          ],
        ],
      ),
    ),
  );
}

class _ReceiptCopy {
  const _ReceiptCopy();

  String get receiptNumber => 'Số phiếu';
  String get paidAt => 'Ngày/Giờ';
  String get cashier => 'Thu ngân';
  String get table => 'Bàn';
  String get subtotal => 'Tạm tính';
  String get serviceCharge => 'Phí dịch vụ';
  String get discount => 'Giảm giá';
  String get vat => 'VAT (đã gồm)';
  String get total => 'Tổng cộng';
  String get paymentMethod => 'Phương thức';
  String get received => 'Khách trả';
  String get change => 'Tiền thừa';
  String get thanks => digitalReceiptFooterThanksVi;
  String get proofNotice => digitalReceiptFooterNoticeVi;
  String get savePdf => 'Lưu/chia sẻ PDF';
  String get print => 'Tự in';
  String get loadFailed => 'Không thể tải biên lai';
  String get tryAgain => 'Kiểm tra kết nối rồi thử lại.';
  String get retry => 'Thử lại';
  String get unavailable => 'Biên lai không khả dụng';
  String get unavailableBody => 'Liên kết không hợp lệ hoặc đã bị thu hồi.';
}
