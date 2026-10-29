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
    this.onTap,
    this.secondaryActionLabel,
    this.onSecondaryAction,
    this.warning = false,
  });
  final String id, title;
  final double? amount;
  final String? status, actionLabel, secondaryActionLabel;
  final List<String> details;
  final CollectionBank? bank;
  final VoidCallback? onAction;
  final VoidCallback? onTap, onSecondaryAction;
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
      if (cards.isEmpty) return const SizedBox.shrink();
      final columns = layout.balancedColumns(
        itemCount: cards.length,
        maxColumns: maxColumns,
      );
      final width = (layout.availableWidth - (columns - 1) * 12) / columns;
      final titleStyle = Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700);
      final rows = <Widget>[];
      for (var start = 0; start < cards.length; start += columns) {
        final row = cards.sublist(
          start,
          math.min(start + columns, cards.length),
        );
        var titleHeight = 0.0;
        for (final card in row) {
          final painter = TextPainter(
            text: TextSpan(text: card.title, style: titleStyle),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            locale: Localizations.localeOf(context),
          )..layout(maxWidth: math.max(0, width - 32));
          titleHeight = math.max(titleHeight, painter.height);
          painter.dispose();
        }
        if (rows.isNotEmpty) rows.add(const SizedBox(height: 12));
        rows.add(
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var column = 0; column < columns; column++) ...[
                  if (column > 0) const SizedBox(width: 12),
                  Expanded(
                    child: column < row.length
                        ? _AmountCard(
                            card: row[column],
                            titleHeight: titleHeight,
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
        );
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [...rows],
      );
    },
  );
}

class _AmountCard extends StatelessWidget {
  const _AmountCard({required this.card, required this.titleHeight});
  final FinancialAmountCardData card;
  final double titleHeight;
  @override
  Widget build(BuildContext context) {
    final content = Container(
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
          SizedBox(
            height: titleHeight,
            child: Text(
              card.title,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            card.amount == null
                ? '—'
                : '${NumberFormat('#,##0', 'vi_VN').format(card.amount)} VND',
            key: ValueKey('${card.id}_amount'),
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          if (card.status != null) ...[
            const SizedBox(height: 8),
            Text(
              card.status!,
              style: TextStyle(
                color: card.warning
                    ? PosColors.warning
                    : PosColors.textSecondary,
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
          const Spacer(),
          if (card.actionLabel != null && card.onAction != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: card.onAction,
                child: Text(card.actionLabel!),
              ),
            ),
          if (card.secondaryActionLabel != null &&
              card.onSecondaryAction != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: ValueKey('${card.id}_secondary_action'),
                onPressed: card.onSecondaryAction,
                child: Text(card.secondaryActionLabel!),
              ),
            ),
        ],
      ),
    );
    if (card.onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: card.onTap,
        borderRadius: BorderRadius.circular(12),
        child: content,
      ),
    );
  }
}
