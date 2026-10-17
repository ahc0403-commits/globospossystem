import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/payments/cash_deposit_transfer.dart';
import '../../core/payments/collection_bank.dart';

class CashDepositQrDialog extends StatefulWidget {
  const CashDepositQrDialog({
    super.key,
    required this.brandName,
    required this.storeName,
    required this.storeId,
    required this.loadBank,
    required this.reportDate,
    required this.amount,
  });

  final String brandName, storeName, storeId;
  final Future<CollectionBank> Function() loadBank;
  final DateTime reportDate;
  final int amount;

  @override
  State<CashDepositQrDialog> createState() => _CashDepositQrDialogState();
}

class _CashDepositQrDialogState extends State<CashDepositQrDialog> {
  late final _shortPurpose = cashDepositShortPurpose(
    brandName: widget.brandName,
    storeName: widget.storeName,
    storeId: widget.storeId,
    depositDate: widget.reportDate,
  );
  late Future<CollectionBank> _bank = widget.loadBank();
  bool _generated = false;
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final qrSize = (MediaQuery.sizeOf(context).width - 128).clamp(0.0, 280.0);
    return AlertDialog(
      key: const Key('cash_deposit_qr_dialog'),
      scrollable: true,
      title: Text(l.cashDepositQrTitle),
      content: SizedBox(
        width: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${widget.brandName} · ${widget.storeName}'),
            const SizedBox(height: 8),
            Text(
              '${l.cashDepositToday}: ${DateFormat('dd/MM/yyyy').format(widget.reportDate)}',
            ),
            const SizedBox(height: 16),
            Text(l.cashDepositAmount),
            SelectableText(
              '${NumberFormat('#,##0', 'vi_VN').format(widget.amount)} VND',
              key: const Key('cash_deposit_amount'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            Text(l.cashDepositQrPurpose),
            const SizedBox(height: 6),
            SelectableText(
              _shortPurpose,
              key: const Key('cash_deposit_short_purpose'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(l.cashDepositMemoHelp),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('cash_deposit_copy_purpose'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _shortPurpose));
                  if (mounted) setState(() => _copied = true);
                },
                icon: Icon(_copied ? Icons.check : Icons.copy_outlined),
                label: Text(
                  _copied ? l.cashDepositCopied : l.cashDepositCopyPurpose,
                ),
              ),
            ),
            const SizedBox(height: 8),
            FutureBuilder<CollectionBank>(
              future: _bank,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final bank = snapshot.data;
                if (snapshot.hasError || bank == null) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(l.collectionBankUnavailable),
                      TextButton(
                        key: const Key('cash_deposit_retry_bank'),
                        onPressed: () => setState(() {
                          _bank = widget.loadBank();
                          _generated = false;
                        }),
                        child: Text(l.retry),
                      ),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SelectableText(
                      '${bank.label} · ${bank.accountNumber}\n${bank.accountHolder}',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      key: const Key('cash_deposit_generate_qr'),
                      onPressed: () => setState(() => _generated = true),
                      icon: const Icon(Icons.qr_code_2),
                      label: Text(l.cashDepositGenerateQr),
                    ),
                    if (_generated) ...[
                      const SizedBox(height: 16),
                      Center(
                        child: SizedBox.square(
                          dimension: qrSize,
                          child: QrImageView(
                            key: const Key('cash_deposit_qr'),
                            data: cashDepositQrPayload(
                              bank: bank,
                              amount: widget.amount,
                              purpose: _shortPurpose,
                            ),
                            size: qrSize,
                            backgroundColor: Colors.white,
                            semanticsLabel: l.cashDepositQrTitle,
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.close),
        ),
      ],
    );
  }
}
