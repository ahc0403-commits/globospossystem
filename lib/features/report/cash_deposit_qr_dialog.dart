import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/payments/cash_deposit_transfer.dart';
import '../../core/payments/collection_bank.dart';
import '../../core/utils/time_utils.dart';

class CashDepositQrDialog extends StatefulWidget {
  const CashDepositQrDialog({
    super.key,
    required this.brandName,
    required this.storeName,
    required this.storeId,
    required this.loadBank,
    this.now,
  });

  final String brandName, storeName, storeId;
  final Future<CollectionBank> Function() loadBank;
  final DateTime? now;

  @override
  State<CashDepositQrDialog> createState() => _CashDepositQrDialogState();
}

class _CashDepositQrDialogState extends State<CashDepositQrDialog> {
  final _amount = TextEditingController();
  final _form = GlobalKey<FormState>();
  late final _date = TimeUtils.toVietnam(widget.now ?? DateTime.now());
  late final _purpose = cashDepositPurpose(
    brandName: widget.brandName,
    storeName: widget.storeName,
    depositDate: _date,
  );
  late final _shortPurpose = cashDepositShortPurpose(
    brandName: widget.brandName,
    storeName: widget.storeName,
    storeId: widget.storeId,
    depositDate: _date,
  );
  late Future<CollectionBank> _bank = widget.loadBank();
  int? _generatedAmount;
  bool _copied = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

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
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${widget.brandName} · ${widget.storeName}'),
              const SizedBox(height: 8),
              Text(
                '${l.cashDepositToday}: ${DateFormat('dd/MM/yyyy').format(_date)}',
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('cash_deposit_amount'),
                controller: _amount,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: l.cashDepositAmount,
                  suffixText: 'VND',
                  border: const OutlineInputBorder(),
                ),
                validator: (value) =>
                    parseCashDepositAmount(value ?? '') == null
                    ? l.cashDepositInvalidAmount
                    : null,
                onChanged: (_) => setState(() => _generatedAmount = null),
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
              Text(l.cashDepositPurpose),
              const SizedBox(height: 6),
              SelectableText(_purpose, key: const Key('cash_deposit_purpose')),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('cash_deposit_copy_purpose'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _purpose));
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
                            _generatedAmount = null;
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
                        onPressed: () {
                          if (_form.currentState!.validate()) {
                            FocusScope.of(context).unfocus();
                            setState(
                              () => _generatedAmount = parseCashDepositAmount(
                                _amount.text,
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.qr_code_2),
                        label: Text(l.cashDepositGenerateQr),
                      ),
                      if (_generatedAmount case final amount?) ...[
                        const SizedBox(height: 16),
                        Center(
                          child: SizedBox.square(
                            dimension: qrSize,
                            child: QrImageView(
                              key: const Key('cash_deposit_qr'),
                              data: cashDepositQrPayload(
                                bank: bank,
                                amount: amount,
                                purpose: _shortPurpose,
                              ),
                              size: qrSize,
                              backgroundColor: Colors.white,
                              semanticsLabel: l.cashDepositQrTitle,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${NumberFormat('#,##0', 'vi_VN').format(amount)} VND',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ],
          ),
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
