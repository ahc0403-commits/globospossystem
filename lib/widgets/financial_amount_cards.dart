import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/layout/adaptive_layout.dart';
import '../core/payments/collection_bank.dart';
import '../core/ui/pos_design_tokens.dart';

class FinancialAmountCardData {
  const FinancialAmountCardData({
    required this.id,
    required this.title,
    required this.amount,
    this.status,
    this.details = const [],
    this.bank,
    this.actionLabel,
    this.onAction,
    this.warning = false,
  });
  final String id, title;
  final double? amount;
  final String? status, actionLabel;
  final List<String> details;
  final CollectionBank? bank;
  final VoidCallback? onAction;
  final bool warning;
}

/// The same values stay visible on phone, tablet, browser and native POS.
class FinancialAmountCards extends StatelessWidget {
  const FinancialAmountCards({
    super.key,
    required this.cards,
    this.maxColumns = 3,
  });
  final List<FinancialAmountCardData> cards;
  final int maxColumns;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final layout = PosLayoutSpec.from(context, constraints);
      final columns = math.min(
        math.max(cards.length, 1),
        layout.isCompact || layout.usesLargeText
            ? 1
            : math.min(maxColumns, layout.isMedium ? 2 : maxColumns),
      );
      final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final card in cards)
            SizedBox(
              width: width,
              child: _AmountCard(card: card),
            ),
        ],
      );
    },
  );
}

class _AmountCard extends StatelessWidget {
  const _AmountCard({required this.card});
  final FinancialAmountCardData card;
  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey(card.id),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: PosColors.surface,
      border: Border.all(
        color: card.warning ? PosColors.warning : PosColors.border,
      ),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          card.title,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            card.amount == null
                ? '—'
                : '${NumberFormat('#,##0', 'vi_VN').format(card.amount)} VND',
            key: ValueKey('${card.id}_amount'),
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        if (card.status != null) ...[
          const SizedBox(height: 8),
          Text(
            card.status!,
            style: TextStyle(
              color: card.warning ? PosColors.warning : PosColors.textSecondary,
            ),
          ),
        ],
        for (final detail in card.details) ...[
          const SizedBox(height: 6),
          Text(detail),
        ],
        if (card.bank case final bank?) ...[
          const SizedBox(height: 8),
          SelectableText(
            '${bank.label} · ${bank.accountNumber}\n${bank.accountHolder}',
          ),
        ],
        if (card.actionLabel != null && card.onAction != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: card.onAction,
              child: Text(card.actionLabel!),
            ),
          ),
      ],
    ),
  );
}
