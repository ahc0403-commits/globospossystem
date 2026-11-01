import 'package:intl/intl.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../core/payments/payment_method_contract.dart';

String? paymentRecoveryErrorText(AppLocalizations l10n, String code) =>
    switch (code) {
      'PAYMENT_RECOVERY_REQUIRED' => l10n.paymentRecoveryRequired,
      'PAYMENT_RECOVERY_STORAGE_UNAVAILABLE' =>
        l10n.paymentRecoveryStorageUnavailable,
      'PAYMENT_COMMAND_SCOPE_CHANGED' => l10n.paymentRecoveryScopeChanged,
      'PAYMENT_ORDER_CHANGED' => l10n.paymentRecoveryOrderChanged,
      'PAYMENT_OPERATION_CANCELLED' => l10n.paymentRecoveryCancelled,
      'PAYMENT_OPERATION_CONFLICT' => l10n.paymentRecoveryConflict,
      _ => null,
    };

class PaymentRecoveryPanel extends StatelessWidget {
  const PaymentRecoveryPanel({
    super.key,
    required this.records,
    required this.busy,
    required this.onCheck,
    required this.onCancel,
    required this.onReload,
  });
  final List<Map<String, dynamic>> records;
  final bool busy;
  final void Function(Map<String, dynamic>) onCheck;
  final void Function(Map<String, dynamic>) onCancel;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      key: const Key('cashier_payment_recovery'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.paymentRecoveryTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(l10n.paymentRecoveryRequired),
            if (records.isEmpty)
              TextButton(
                onPressed: busy ? null : onReload,
                child: Text(l10n.paymentRecoveryReload),
              ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: records.length,
                itemBuilder: (context, index) {
                  final record = records[index];
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (record['tableNumber'] is String)
                          Text(
                            l10n.cashierTableLabel(
                              record['tableNumber'] as String,
                            ),
                          ),
                        Text(
                          '${NumberFormat.decimalPattern('vi_VN').format(record['amount'])} VND · ${paymentMethodDisplayLabel(record['method'] as String)}',
                        ),
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: busy ? null : () => onCheck(record),
                              child: Text(l10n.paymentRecoveryCheck),
                            ),
                            TextButton(
                              onPressed: busy ? null : () => onCancel(record),
                              child: Text(l10n.paymentRecoveryCancel),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
