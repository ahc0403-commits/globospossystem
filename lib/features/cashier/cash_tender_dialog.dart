import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/payments/cash_tender.dart';
import '../../core/ui/pos_design_tokens.dart';

class CashTenderDialog extends StatefulWidget {
  const CashTenderDialog({super.key, required this.amountDue});

  final double amountDue;

  @override
  State<CashTenderDialog> createState() => _CashTenderDialogState();
}

class _CashTenderDialogState extends State<CashTenderDialog> {
  late final TextEditingController _controller;
  double? _receivedAmount;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final currency = NumberFormat('#,###', 'vi_VN');
    final tender = _receivedAmount == null
        ? null
        : CashTender(
            amountDue: widget.amountDue,
            receivedAmount: _receivedAmount!,
          );
    final change = tender?.isSufficient == true ? tender!.changeAmount : 0;

    return AlertDialog(
      key: const Key('cashier_cash_tender_dialog'),
      title: Text(l10n.cashierCashTenderTitle),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _AmountRow(
              label: l10n.cashierPaymentDue,
              value: '₫${currency.format(widget.amountDue)}',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('cashier_cash_received_input'),
              controller: _controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: l10n.cashierCashReceived,
                prefixText: '₫ ',
                errorText: tender != null && !tender.isSufficient
                    ? l10n.cashierCashInsufficient
                    : null,
              ),
              onChanged: (value) => setState(() {
                _receivedAmount = parseCashAmount(value);
              }),
              onSubmitted: (_) {
                if (tender?.isSufficient == true) {
                  Navigator.of(context).pop(tender);
                }
              },
            ),
            const SizedBox(height: 18),
            Container(
              key: const Key('cashier_cash_change_amount'),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: PosColors.success.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: _AmountRow(
                label: l10n.cashierCashChange,
                value: '₫${currency.format(change)}',
                emphasized: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          key: const Key('cashier_cash_tender_confirm'),
          onPressed: tender?.isSufficient == true
              ? () => Navigator.of(context).pop(tender)
              : null,
          child: Text(l10n.cashierPayNow),
        ),
      ],
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({
    required this.label,
    required this.value,
    this.emphasized = false,
  });

  final String label;
  final String value;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: emphasized ? PosColors.success : PosColors.textPrimary,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}
