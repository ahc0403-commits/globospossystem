import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../core/ui/app_fonts.dart';
import '../../../core/ui/pos_design_tokens.dart';
import '../../../core/ui/toast/toast.dart';
import '../providers/admin_audit_provider.dart';

class OwnerOverviewTab extends ConsumerWidget {
  const OwnerOverviewTab({
    super.key,
    required this.storeId,
    required this.onSelectTab,
    this.storeName,
  });

  final String? storeId;
  final String? storeName;
  final ValueChanged<int> onSelectTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final storeId = this.storeId;
    if (storeId == null) {
      return ToastResponsiveScrollBody(
        key: const Key('owner_overview_root'),
        maxWidth: 1180,
        children: [
          _OverviewHeader(storeName: storeName),
          const SizedBox(height: 16),
          _OverviewEmptyState(
            icon: Icons.store_mall_directory_outlined,
            title: l10n.adminOverviewNoStoreTitle,
            body: l10n.adminOverviewNoStoreBody,
          ),
        ],
      );
    }

    final summaryAsync = ref.watch(adminTodaySummaryProvider(storeId));
    return ToastResponsiveScrollBody(
      key: const Key('owner_overview_root'),
      maxWidth: 1180,
      children: [
        _OverviewHeader(
          storeName: storeName,
          trailing: IconButton(
            key: const Key('owner_overview_refresh'),
            tooltip: l10n.refresh,
            onPressed: () => ref.invalidate(adminTodaySummaryProvider(storeId)),
            icon: const Icon(Icons.refresh),
          ),
        ),
        const SizedBox(height: 16),
        summaryAsync.when(
          data: (summary) =>
              _OverviewContent(summary: summary, onSelectTab: onSelectTab),
          loading: () => const SizedBox(
            height: 320,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (_, _) => _OverviewEmptyState(
            icon: Icons.sync_problem_outlined,
            title: l10n.adminOverviewLoadFailed,
            body: l10n.adminOverviewLoadFailedBody,
            action: OutlinedButton.icon(
              key: const Key('owner_overview_retry'),
              onPressed: () =>
                  ref.invalidate(adminTodaySummaryProvider(storeId)),
              icon: const Icon(Icons.refresh),
              label: Text(l10n.retry),
            ),
          ),
        ),
      ],
    );
  }
}

class _OverviewHeader extends StatelessWidget {
  const _OverviewHeader({this.storeName, this.trailing});

  final String? storeName;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.adminOverviewTitle,
                style: AppFonts.system(
                  color: PosColors.textPrimary,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                storeName?.trim().isNotEmpty == true
                    ? l10n.adminOverviewSubtitleWithStore(storeName!)
                    : l10n.adminOverviewSubtitle,
                style: AppFonts.system(
                  color: PosColors.textSecondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Text(
          DateFormat('yyyy.MM.dd').format(DateTime.now()),
          style: AppFonts.system(
            color: PosColors.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 4), trailing!],
      ],
    );
  }
}

class _OverviewContent extends StatelessWidget {
  const _OverviewContent({required this.summary, required this.onSelectTab});

  final TodaySummary summary;
  final ValueChanged<int> onSelectTab;

  int get _openOrders =>
      summary.ordersPending + summary.ordersConfirmed + summary.ordersServing;

  String _money(num value) =>
      '${NumberFormat('#,###', 'vi_VN').format(value)} ₫';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: PosColors.heroTint,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: PosColors.accentMuted),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 620;
              final revenue = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.adminOverviewRevenue,
                    style: AppFonts.system(
                      color: PosColors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 8),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _money(summary.paymentsTotal),
                      style: AppFonts.system(
                        color: PosColors.textPrimary,
                        fontSize: 36,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l10n.adminOverviewPayments(summary.paymentsCount),
                    style: AppFonts.system(
                      color: PosColors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              );
              final paymentMix = Wrap(
                spacing: 24,
                runSpacing: 12,
                children: [
                  _PaymentMetric(
                    label: l10n.adminOverviewCash,
                    value: _money(summary.paymentsCash),
                    icon: Icons.payments_outlined,
                  ),
                  _PaymentMetric(
                    label: l10n.adminOverviewCard,
                    value: _money(summary.paymentsCard),
                    icon: Icons.credit_card,
                  ),
                ],
              );

              if (narrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [revenue, const SizedBox(height: 20), paymentMix],
                );
              }
              return Row(
                children: [
                  Expanded(flex: 3, child: revenue),
                  Container(width: 1, height: 76, color: PosColors.border),
                  const SizedBox(width: 28),
                  Expanded(flex: 2, child: paymentMix),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        _MetricGrid(
          metrics: [
            _OverviewMetric(
              label: l10n.reportsOrder,
              value: '${summary.ordersTotal}',
              color: PosColors.info,
            ),
            _OverviewMetric(
              label: l10n.reportsInProgress,
              value: '$_openOrders',
              color: _openOrders > 0 ? PosColors.warning : PosColors.success,
            ),
            _OverviewMetric(
              label: l10n.reportsDone,
              value: '${summary.ordersCompleted}',
              color: PosColors.success,
            ),
            _OverviewMetric(
              label: l10n.table,
              value: l10n.reportsTablesInUse(
                summary.tablesOccupied,
                summary.tablesTotal,
              ),
              color: PosColors.accent,
            ),
          ],
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final attention = _AttentionPanel(
              openOrders: _openOrders,
              cancelledOrders: summary.ordersCancelled,
              lowStockCount: summary.lowStockCount,
              onSelectTab: onSelectTab,
            );
            final quickActions = _QuickActions(onSelectTab: onSelectTab);
            if (constraints.maxWidth < 760) {
              return Column(
                children: [attention, const SizedBox(height: 12), quickActions],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: attention),
                const SizedBox(width: 12),
                Expanded(flex: 2, child: quickActions),
              ],
            );
          },
        ),
        const SizedBox(height: 28),
      ],
    );
  }
}

class _PaymentMetric extends StatelessWidget {
  const _PaymentMetric({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: PosColors.accent, size: 20),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: AppFonts.system(
                color: PosColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
            Text(
              value,
              style: AppFonts.system(
                color: PosColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _OverviewMetric {
  const _OverviewMetric({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.metrics});

  final List<_OverviewMetric> metrics;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 620 ? 2 : 4;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: metrics.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            mainAxisExtent: 90,
          ),
          itemBuilder: (context, index) {
            final metric = metrics[index];
            return Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: PosColors.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: PosColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    metric.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.system(
                      color: PosColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    metric.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.system(
                      color: metric.color,
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _AttentionPanel extends StatelessWidget {
  const _AttentionPanel({
    required this.openOrders,
    required this.cancelledOrders,
    required this.lowStockCount,
    required this.onSelectTab,
  });

  final int openOrders;
  final int cancelledOrders;
  final int lowStockCount;
  final ValueChanged<int> onSelectTab;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final hasAttention =
        openOrders > 0 || cancelledOrders > 0 || lowStockCount > 0;
    return _OverviewPanel(
      title: l10n.adminOverviewAttention,
      child: hasAttention
          ? Column(
              children: [
                if (openOrders > 0)
                  _AttentionRow(
                    icon: Icons.room_service_outlined,
                    label: l10n.adminOverviewOpenOrders,
                    value: '$openOrders',
                    color: PosColors.warning,
                    onTap: () => onSelectTab(1),
                  ),
                if (cancelledOrders > 0)
                  _AttentionRow(
                    icon: Icons.cancel_outlined,
                    label: l10n.adminOverviewCancelledOrders,
                    value: '$cancelledOrders',
                    color: PosColors.danger,
                    onTap: () => onSelectTab(4),
                  ),
                if (lowStockCount > 0)
                  _AttentionRow(
                    icon: Icons.inventory_2_outlined,
                    label: l10n.reportsLowStock,
                    value: '$lowStockCount',
                    color: PosColors.warning,
                    onTap: () => onSelectTab(6),
                  ),
              ],
            )
          : Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(
                    color: PosColors.successMuted,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check,
                    color: PosColors.success,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.adminOverviewHealthy,
                        style: AppFonts.system(
                          color: PosColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0,
                        ),
                      ),
                      Text(
                        l10n.adminOverviewHealthyBody,
                        style: AppFonts.system(
                          color: PosColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: AppFonts.system(
                  color: PosColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                ),
              ),
            ),
            Container(
              constraints: const BoxConstraints(minWidth: 34),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                value,
                textAlign: TextAlign.center,
                style: AppFonts.system(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              Icons.chevron_right,
              color: PosColors.textMuted,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.onSelectTab});

  final ValueChanged<int> onSelectTab;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _OverviewPanel(
      title: l10n.adminOverviewQuickActions,
      child: Column(
        children: [
          _QuickAction(
            key: const Key('owner_overview_tables'),
            icon: Icons.table_restaurant_outlined,
            label: l10n.tables,
            onTap: () => onSelectTab(1),
          ),
          _QuickAction(
            key: const Key('owner_overview_reports'),
            icon: Icons.bar_chart_outlined,
            label: l10n.reports,
            onTap: () => onSelectTab(4),
          ),
          _QuickAction(
            key: const Key('owner_overview_attendance'),
            icon: Icons.schedule_outlined,
            label: l10n.attendance,
            onTap: () => onSelectTab(5),
          ),
          _QuickAction(
            key: const Key('owner_overview_inventory'),
            icon: Icons.inventory_2_outlined,
            label: l10n.inventory,
            onTap: () => onSelectTab(6),
          ),
        ],
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Icon(icon, color: PosColors.accent, size: 19),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: AppFonts.system(
                  color: PosColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                ),
              ),
            ),
            const Icon(
              Icons.arrow_forward,
              color: PosColors.textMuted,
              size: 17,
            ),
          ],
        ),
      ),
    );
  }
}

class _OverviewPanel extends StatelessWidget {
  const _OverviewPanel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: PosColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: AppFonts.system(
              color: PosColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _OverviewEmptyState extends StatelessWidget {
  const _OverviewEmptyState({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 56),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: PosColors.border),
      ),
      child: Column(
        children: [
          Icon(icon, color: PosColors.textMuted, size: 36),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppFonts.system(
              color: PosColors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            textAlign: TextAlign.center,
            style: AppFonts.system(
              color: PosColors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}
