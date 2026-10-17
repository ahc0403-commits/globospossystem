import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/i18n/locale_extensions.dart';
import '../../core/utils/time_utils.dart';
import '../../widgets/financial_amount_cards.dart';
import 'daily_sales_summary.dart';

class DailyDepositPanel extends StatelessWidget {
  const DailyDepositPanel({
    super.key,
    required this.summary,
    this.onPhoto,
    this.onPhotoQr,
    this.onClosing,
    this.onBank,
  });
  final DailySalesSummary summary;
  final VoidCallback? onPhoto, onPhotoQr, onClosing, onBank;
  @override
  Widget build(BuildContext context) {
    final l = context.l10n, s = summary;
    String money(num n) => '${NumberFormat('#,##0', 'vi_VN').format(n)} VND';
    final source = l.salesDepositSourceDate(s.businessDate);
    final due = l.salesDepositDate(s.depositDate);
    final cashStatus = (s.bunsikShortfallStores ?? 0) > 0
        ? l.salesDepositShortfall
        : s.cashDepositConfirmed
        ? (s.cashNeedsReview ? l.salesDepositReview : l.salesDepositConfirmed)
        : s.pendingBunsikStores == null ||
              (s.pendingBunsikStores == 0 && s.bunsikExpectedDeposit == null)
        ? l.salesDepositUnavailable
        : l.salesDepositPending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FinancialAmountCards(
          cards: [
            FinancialAmountCardData(
              id: 'sales_deposit_bank',
              title: l.salesDepositBankTitle,
              amount: s.restaurantBankTransfer,
              details: [source, l.salesDepositBankNote],
              actionLabel: l.salesDepositOpenBank,
              onAction: onBank,
            ),
            FinancialAmountCardData(
              id: 'sales_deposit_photo',
              title: l.salesDepositPhotoTitle,
              amount: s.photoDeposit,
              status: s.photoComplete
                  ? l.salesDepositPhotoComplete
                  : l.salesDepositPhotoMissing,
              warning: !s.photoComplete,
              bank: s.bank,
              details: [
                source,
                due,
                if (!s.photoComplete)
                  l.salesDepositKnownAmount(money(s.photoGross)),
                if ((s.missingPhotoStores ?? 0) > 0)
                  l.salesDepositMissingStores(s.missingPhotoStores!),
                if (s.bank == null) l.salesDepositNoAccount,
              ],
              actionLabel: l.salesDepositOpenPhoto,
              onAction: onPhoto,
              secondaryActionLabel: l.cashDepositQrTitle,
              onSecondaryAction: onPhotoQr,
              onTap: onPhotoQr,
            ),
            FinancialAmountCardData(
              id: 'sales_deposit_cash',
              title: l.salesDepositCashTitle,
              amount: s.cashDeposit,
              status: cashStatus,
              warning: s.cashNeedsReview || !s.cashDepositConfirmed,
              bank: s.bank,
              details: [
                source,
                due,
                if (s.bunsikCash != null)
                  '${l.reportsCashSales}: ${money(s.bunsikCash!)}',
                if (s.bunsikClosedDeposit != null)
                  l.salesDepositCountedAmount(money(s.bunsikClosedDeposit!)),
                if (!s.cashDepositConfirmed && s.bunsikExpectedDeposit != null)
                  l.salesDepositExpectedAmount(money(s.bunsikExpectedDeposit!)),
                if ((s.pendingBunsikStores ?? 0) > 0)
                  l.salesDepositPendingStores(s.pendingBunsikStores!),
                if (s.bunsikVariance != null)
                  '${l.reportsCashVariance}: ${money(s.bunsikVariance!)}',
                if ((s.bunsikLateLedgerStores ?? 0) > 0)
                  l.reportsClosingLateLedgerWarning,
                if (s.bank == null) l.salesDepositNoAccount,
              ],
              actionLabel: l.salesDepositOpenClosing,
              onAction: onClosing,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '${l.salesDepositTotalTitle}: ${s.nextDeposit == null ? '—' : money(s.nextDeposit!)}',
          key: const Key('sales_next_day_deposit_amount'),
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (!s.depositConfirmed) Text(l.salesDepositUnavailable),
        if (s.asOf != null)
          Text(
            l.salesDepositAsOf(
              DateFormat(
                'yyyy-MM-dd HH:mm',
              ).format(TimeUtils.toVietnam(s.asOf!)),
            ),
          ),
      ],
    );
  }
}
