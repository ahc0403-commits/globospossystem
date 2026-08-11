import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/payments/cash_tender.dart';
import '../../core/payments/payment_method_contract.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../digital_receipt/digital_receipt_model.dart';
import '../payment/payment_provider.dart';

class PaymentCompletionDialog extends StatefulWidget {
  const PaymentCompletionDialog({
    super.key,
    required this.order,
    required this.paymentMethod,
    this.cashTender,
    required this.onReprint,
    this.receiptAccess,
    this.onPaperReceipt,
  });

  final CashierOrder order;
  final String paymentMethod;
  final CashTender? cashTender;
  final Future<void> Function() onReprint;
  final DigitalReceiptAccess? receiptAccess;
  final Future<void> Function()? onPaperReceipt;

  @override
  State<PaymentCompletionDialog> createState() =>
      _PaymentCompletionDialogState();
}

class _PaymentCompletionDialogState extends State<PaymentCompletionDialog> {
  bool _isReprinting = false;
  bool _isPrintingPaper = false;

  Future<void> _reprint() async {
    if (_isReprinting) return;
    setState(() => _isReprinting = true);
    try {
      await widget.onReprint();
    } finally {
      if (mounted) setState(() => _isReprinting = false);
    }
  }

  Future<void> _printPaper() async {
    if (_isPrintingPaper || widget.onPaperReceipt == null) return;
    setState(() => _isPrintingPaper = true);
    try {
      await widget.onPaperReceipt!();
    } finally {
      if (mounted) setState(() => _isPrintingPaper = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final currency = NumberFormat('#,###', 'vi_VN');
    final methodLabel = paymentMethodDisplayLabel(widget.paymentMethod);
    final activeItems = widget.order.items
        .where((item) => item.status.toLowerCase() != 'cancelled')
        .toList();
    final paperless = widget.order.fulfillmentMode.isPaperless;
    final copy = _CompletionCopy.of(context);

    return Dialog(
      key: const Key('cashier_payment_completion_dialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      backgroundColor: PosColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: PosColors.success.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      color: PosColors.success,
                      size: 32,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.cashierCompletedStatus,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                color: PosColors.textPrimary,
                                fontWeight: FontWeight.w900,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.cashierPaymentProcessed,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: PosColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('cashier_payment_completion_close_icon'),
                    tooltip: l10n.close,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: PosColors.accentMuted,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: PosColors.border),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final summary = [
                      _CompletionMetric(
                        label: l10n.cashierTableLabel(widget.order.tableNumber),
                        value: l10n.cashierItemsCount(activeItems.length),
                        icon: Icons.table_restaurant_rounded,
                      ),
                      if (widget.cashTender != null)
                        _CompletionMetric(
                          label: l10n.cashierCashReceived,
                          value:
                              '₫${currency.format(widget.cashTender!.receivedAmount)}',
                          icon: Icons.account_balance_wallet_rounded,
                        ),
                      if (widget.cashTender != null)
                        _CompletionMetric(
                          label: l10n.cashierCashChange,
                          value:
                              '₫${currency.format(widget.cashTender!.changeAmount)}',
                          icon: Icons.change_circle_rounded,
                          emphasized: true,
                        ),
                      _CompletionMetric(
                        label: l10n.cashierPaymentMethod,
                        value: methodLabel,
                        icon: Icons.payments_rounded,
                      ),
                      _CompletionMetric(
                        label: l10n.cashierPaymentDue,
                        value: '₫${currency.format(widget.order.remainingDue)}',
                        icon: Icons.receipt_long_rounded,
                        emphasized: true,
                      ),
                    ];
                    if (constraints.maxWidth < 540) {
                      return Column(
                        children: [
                          for (
                            var index = 0;
                            index < summary.length;
                            index++
                          ) ...[
                            summary[index],
                            if (index != summary.length - 1)
                              const SizedBox(height: 12),
                          ],
                        ],
                      );
                    }
                    return Row(
                      children: [
                        for (
                          var index = 0;
                          index < summary.length;
                          index++
                        ) ...[
                          Expanded(child: summary[index]),
                          if (index != summary.length - 1)
                            const SizedBox(width: 12),
                        ],
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              if (paperless) ...[
                Container(
                  key: const Key('cashier_digital_receipt_panel'),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: PosColors.info.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: PosColors.border),
                  ),
                  child: Row(
                    children: [
                      SizedBox.square(
                        dimension: 132,
                        child: widget.receiptAccess == null
                            ? const Center(
                                child: Icon(Icons.qr_code_2_rounded, size: 54),
                              )
                            : QrImageView(
                                data: widget.receiptAccess!.publicUrl,
                                version: QrVersions.auto,
                                backgroundColor: Colors.white,
                              ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.receiptAccess == null
                                  ? copy.digitalUnavailable
                                  : copy.scanReceipt,
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                color: PosColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              copy.receiptHelp,
                              style: const TextStyle(
                                color: PosColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Flexible(
                child: Container(
                  decoration: BoxDecoration(
                    color: PosSurfaceRole.background.fill,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: PosSurfaceRole.background.stroke),
                  ),
                  child: activeItems.isEmpty
                      ? const SizedBox(height: 1)
                      : ListView.separated(
                          shrinkWrap: true,
                          padding: const EdgeInsets.all(14),
                          itemCount: activeItems.length,
                          separatorBuilder: (_, _) => const Divider(height: 18),
                          itemBuilder: (context, index) {
                            final item = activeItems[index];
                            return Row(
                              children: [
                                Container(
                                  width: 32,
                                  height: 32,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: PosColors.surface,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: PosColors.border),
                                  ),
                                  child: Text(
                                    '${item.quantity}',
                                    style: const TextStyle(
                                      color: PosColors.accent,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    item.itemType == 'wet_tissue_charge'
                                        ? l10n.cashierWetTissueCharge
                                        : item.localizedName(
                                            Localizations.localeOf(
                                              context,
                                            ).languageCode,
                                          ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodyLarge
                                        ?.copyWith(
                                          color: PosColors.textPrimary,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: PosColors.info.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Icon(
                      paperless ? Icons.eco_rounded : Icons.print_rounded,
                      color: PosColors.info,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        paperless
                            ? copy.paperlessDefault
                            : l10n.cashierReceiptQueued,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: PosColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: paperless
                          ? const Key(
                              'cashier_payment_completion_paper_receipt',
                            )
                          : const Key('cashier_payment_completion_reprint'),
                      onPressed: paperless
                          ? (_isPrintingPaper ? null : _printPaper)
                          : (_isReprinting ? null : _reprint),
                      icon: (paperless ? _isPrintingPaper : _isReprinting)
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.print_outlined),
                      label: Text(
                        paperless ? copy.paperReceipt : l10n.cashierReprint,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      key: const Key('cashier_payment_completion_close'),
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.check_rounded),
                      label: Text(l10n.close),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompletionCopy {
  const _CompletionCopy(this.code);

  final String code;

  static _CompletionCopy of(BuildContext context) =>
      _CompletionCopy(Localizations.localeOf(context).languageCode);

  String pick(String ko, String vi, String en) => switch (code) {
    'vi' => vi,
    'en' => en,
    _ => ko,
  };

  String get scanReceipt => pick(
    'QR을 스캔하면 영수증 확인·PDF 저장·직접 인쇄가 가능합니다.',
    'Quét QR để xem, lưu PDF hoặc tự in biên lai.',
    'Scan the QR to view, save PDF, or print the receipt.',
  );
  String get digitalUnavailable => pick(
    '디지털 영수증을 준비하지 못했습니다.',
    'Chưa thể chuẩn bị biên lai điện tử.',
    'The digital receipt is not ready.',
  );
  String get receiptHelp => pick(
    '종이가 필요한 고객에게만 아래 버튼으로 출력하세요.',
    'Chỉ in giấy bằng nút bên dưới khi khách yêu cầu.',
    'Use the button below only when the customer requests paper.',
  );
  String get paperlessDefault => pick(
    '디지털 영수증이 기본입니다. 종이 출력은 선택 사항입니다.',
    'Biên lai điện tử là mặc định; in giấy là tùy chọn.',
    'Digital receipt is the default; paper is optional.',
  );
  String get paperReceipt =>
      pick('종이 영수증 출력', 'In biên lai giấy', 'Print paper receipt');
}

class _CompletionMetric extends StatelessWidget {
  const _CompletionMetric({
    required this.label,
    required this.value,
    required this.icon,
    this.emphasized = false,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: PosColors.accent, size: 20),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: PosColors.textSecondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: emphasized ? PosColors.accent : PosColors.textPrimary,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
