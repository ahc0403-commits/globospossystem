import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/services/payment_service.dart';
import '../../core/ui/app_primitives.dart';
import '../../core/ui/app_theme.dart';
import '../../widgets/app_nav_bar.dart';

class PaymentDetailScreen extends StatefulWidget {
  const PaymentDetailScreen({super.key, required this.paymentId});

  final String paymentId;

  @override
  State<PaymentDetailScreen> createState() => _PaymentDetailScreenState();
}

class _PaymentDetailScreenState extends State<PaymentDetailScreen> {
  late Future<Map<String, dynamic>?> _detailFuture;
  final _currency = NumberFormat('#,###', 'vi_VN');

  @override
  void initState() {
    super.initState();
    _detailFuture = paymentService.fetchPaymentDetail(widget.paymentId);
  }

  Future<void> _reload() async {
    final future = paymentService.fetchPaymentDetail(widget.paymentId);
    setState(() {
      _detailFuture = future;
    });
    await future;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: AppShell(
        child: FutureBuilder<Map<String, dynamic>?>(
          future: _detailFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return AppLoadingView(label: l10n.paymentDetailLoading);
            }

            if (snapshot.hasError) {
              return AppErrorState(
                title: l10n.paymentDetailLoadErrorTitle,
                message: snapshot.error.toString(),
                onRetry: _reload,
              );
            }

            final detail = snapshot.data;
            if (detail == null) {
              return AppEmptyState(
                title: l10n.paymentDetailNotFound,
                message: l10n.paymentDetailUnavailableMessage,
                icon: Icons.payments_outlined,
              );
            }

            final payment = _map(detail['payment']);
            final order = _map(detail['order']);
            final einvoiceJob = _map(detail['einvoice_job']);
            final tableNumber = _extractTableNumber(order);
            final lookupUrl = _stringOrDash(einvoiceJob['lookup_url']);
            final itemCount = _extractItemCount(order);
            final paymentStatus = _stringOrDash(
              payment['status'] ?? payment['payment_status'],
            );
            final einvoiceStatus = _stringOrDash(
              einvoiceJob['issuance_status'] ?? einvoiceJob['status'],
            );
            final proofStatus = _proofStatus(payment);
            final showPortalPending = _showPortalPending(
              einvoiceJob: einvoiceJob,
              issuanceStatus: einvoiceStatus,
              lookupUrl: lookupUrl,
            );
            final portalPendingAge = _elapsedLabel(
              context,
              einvoiceJob['created_at'],
            );
            final paymentAmount = _formatCurrency(
              payment['amount'] ??
                  payment['paid_amount'] ??
                  payment['settled_amount'],
            );
            final paymentMethod = _stringOrDash(
              payment['method'] ?? payment['payment_method'],
            );

            return RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  Row(
                    children: [
                      const AppNavBar(),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: AppSectionHeader(
                          title: l10n.paymentDetailTitle.toUpperCase(),
                          subtitle: l10n.paymentDetailReadOnlySubtitle(
                            widget.paymentId,
                          ),
                          trailing: AppStatusBadge(
                            label: paymentStatus.toUpperCase(),
                            color: _statusColor(paymentStatus),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  AppPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.paymentDetailOperationalSnapshot,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Wrap(
                          spacing: AppSpacing.md,
                          runSpacing: AppSpacing.md,
                          children: [
                            _MetricCard(
                              label: l10n.paymentDetailAmount,
                              value: paymentAmount,
                            ),
                            _MetricCard(
                              label: l10n.paymentDetailMethod,
                              value: paymentMethod,
                            ),
                            _MetricCard(
                              label: l10n.paymentDetailMetricTable,
                              value: tableNumber,
                            ),
                            _MetricCard(
                              label: l10n.paymentDetailMetricItems,
                              value: itemCount.toString(),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Wrap(
                          spacing: AppSpacing.md,
                          runSpacing: AppSpacing.md,
                          children: [
                            _SignalCard(
                              title: l10n.paymentDetailSectionPayment,
                              value: paymentStatus.toUpperCase(),
                              detail:
                                  '${l10n.paymentDetailCreated}: ${_formatDateTime(payment['created_at'])}',
                              color: _statusColor(paymentStatus),
                            ),
                            _SignalCard(
                              title: l10n.paymentDetailSectionEInvoice,
                              value: einvoiceStatus.toUpperCase(),
                              detail:
                                  '${l10n.paymentDetailJobStatus}: ${_stringOrDash(einvoiceJob['status'])}',
                              color: _statusColor(einvoiceStatus),
                            ),
                            _SignalCard(
                              title: l10n.paymentDetailSectionProof,
                              value: proofStatus.toUpperCase(),
                              detail: proofStatus == 'captured'
                                  ? '${l10n.paymentDetailProofCaptured}: ${_formatDateTime(payment['proof_photo_taken_at'])}'
                                  : '${l10n.paymentDetailProofRequired}: ${_boolLabel(context, payment['proof_required'])}',
                              color: _statusColor(proofStatus),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Wrap(
                          spacing: AppSpacing.sm,
                          runSpacing: AppSpacing.sm,
                          children: [
                            AppStatusBadge(
                              label: l10n.paymentDetailBadgePayment(
                                paymentStatus.toUpperCase(),
                              ),
                              color: _statusColor(paymentStatus),
                            ),
                            AppStatusBadge(
                              label: l10n.paymentDetailBadgeEInvoice(
                                einvoiceStatus.toUpperCase(),
                              ),
                              color: _statusColor(einvoiceStatus),
                            ),
                            AppStatusBadge(
                              label: l10n.paymentDetailBadgeProof(
                                proofStatus.toUpperCase(),
                              ),
                              color: _statusColor(proofStatus),
                            ),
                          ],
                        ),
                        if (showPortalPending) ...[
                          const SizedBox(height: AppSpacing.lg),
                          _PortalPendingPanel(
                            title: l10n.paymentDetailPortalPendingTitle,
                            body: l10n.paymentDetailPortalPendingBody,
                            footer: portalPendingAge == null
                                ? l10n.paymentDetailPortalPendingFooter
                                : l10n.paymentDetailPortalPendingFooterWithAge(
                                    portalPendingAge,
                                  ),
                          ),
                        ],
                        if (lookupUrl != '-') ...[
                          const SizedBox(height: AppSpacing.lg),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  l10n.paymentDetailPortalHint,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                              const SizedBox(width: AppSpacing.md),
                              OutlinedButton.icon(
                                onPressed: () => _openLookupUrl(lookupUrl),
                                icon: const Icon(Icons.open_in_new),
                                label: Text(l10n.paymentDetailOpenPortal),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _ResponsivePanelGrid(
                    children: [
                      _InfoPanel(
                        title: l10n.paymentDetailPaymentSummary,
                        rows: [
                          _InfoRow(
                            l10n.paymentDetailPaymentId,
                            widget.paymentId,
                          ),
                          _InfoRow(l10n.paymentDetailAmount, paymentAmount),
                          _InfoRow(l10n.paymentDetailMethod, paymentMethod),
                          _InfoRow(
                            l10n.paymentDetailStatus,
                            _stringOrDash(
                              payment['status'] ?? payment['payment_status'],
                            ),
                          ),
                          _InfoRow(
                            l10n.paymentDetailCreated,
                            _formatDateTime(payment['created_at']),
                          ),
                          _InfoRow(
                            l10n.paymentDetailUpdated,
                            _formatDateTime(payment['updated_at']),
                          ),
                        ],
                      ),
                      _InfoPanel(
                        title: l10n.paymentDetailOrderSummary,
                        rows: [
                          _InfoRow(
                            l10n.paymentDetailOrderId,
                            _stringOrDash(order['id']),
                          ),
                          _InfoRow(l10n.paymentDetailMetricTable, tableNumber),
                          _InfoRow(
                            l10n.paymentDetailStatus,
                            _stringOrDash(order['status']),
                          ),
                          _InfoRow(
                            l10n.paymentDetailActiveItems,
                            itemCount.toString(),
                          ),
                          _InfoRow(
                            l10n.paymentDetailOrderTotal,
                            _formatCurrency(order['order_total_amount']),
                          ),
                          _InfoRow(
                            l10n.paymentDetailOrderCreated,
                            _formatDateTime(order['created_at']),
                          ),
                        ],
                      ),
                      _InfoPanel(
                        title: l10n.paymentDetailEInvoiceSummary,
                        rows: [
                          _InfoRow(
                            l10n.paymentDetailJobId,
                            _stringOrDash(einvoiceJob['id']),
                          ),
                          _InfoRow(
                            l10n.paymentDetailJobStatus,
                            _stringOrDash(einvoiceJob['status']),
                          ),
                          _InfoRow(
                            l10n.paymentDetailIssuanceStatus,
                            _stringOrDash(einvoiceJob['issuance_status']),
                          ),
                          _InfoRow(
                            l10n.paymentDetailRefId,
                            _stringOrDash(einvoiceJob['ref_id']),
                          ),
                          _InfoRow(
                            l10n.paymentDetailSid,
                            _stringOrDash(einvoiceJob['sid']),
                          ),
                          _InfoRow(
                            l10n.paymentDetailCqtReportStatus,
                            _stringOrDash(einvoiceJob['cqt_report_status']),
                          ),
                          _InfoRow(
                            l10n.paymentDetailRedInvoiceRequested,
                            _boolLabel(
                              context,
                              einvoiceJob['redinvoice_requested'],
                            ),
                          ),
                          _InfoRow(
                            l10n.paymentDetailLookupUrl,
                            _stringOrDash(einvoiceJob['lookup_url']),
                          ),
                          _InfoRow(
                            l10n.paymentDetailCreated,
                            _formatDateTime(einvoiceJob['created_at']),
                          ),
                          _InfoRow(
                            l10n.paymentDetailUpdated,
                            _formatDateTime(einvoiceJob['updated_at']),
                          ),
                        ],
                      ),
                      _InfoPanel(
                        title: l10n.paymentDetailProofSummary,
                        rows: [
                          _InfoRow(
                            l10n.paymentDetailProofRequired,
                            _boolLabel(context, payment['proof_required']),
                          ),
                          _InfoRow(l10n.paymentDetailStatus, proofStatus),
                          _InfoRow(
                            l10n.paymentDetailProofPhotoUrl,
                            _stringOrDash(payment['proof_photo_url']),
                          ),
                          _InfoRow(
                            l10n.paymentDetailProofCaptured,
                            _formatDateTime(payment['proof_photo_taken_at']),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openLookupUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Map<String, dynamic> _map(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return const <String, dynamic>{};
  }

  String _extractTableNumber(Map<String, dynamic> order) {
    final tables = order['tables'];
    if (tables is Map) {
      return _stringOrDash(tables['table_number']);
    }
    return '-';
  }

  int _extractItemCount(Map<String, dynamic> order) {
    final items = order['order_items'];
    if (items is! List) return 0;

    return items
        .map((item) => Map<String, dynamic>.from(item))
        .where((item) => item['status']?.toString() != 'cancelled')
        .length;
  }

  String _stringOrDash(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return '-';
    return text;
  }

  String _boolLabel(BuildContext context, dynamic value) {
    if (value == true) return context.l10n.yes;
    if (value == false) return context.l10n.no;
    return '-';
  }

  String _proofStatus(Map<String, dynamic> payment) {
    final proofRequired = payment['proof_required'];
    final proofUrl = payment['proof_photo_url']?.toString();
    final proofTakenAt = payment['proof_photo_taken_at']?.toString();

    if (proofRequired != true) return 'not-required';
    if ((proofUrl != null && proofUrl.isNotEmpty) ||
        (proofTakenAt != null && proofTakenAt.isNotEmpty)) {
      return 'captured';
    }
    return 'required';
  }

  bool _showPortalPending({
    required Map<String, dynamic> einvoiceJob,
    required String issuanceStatus,
    required String lookupUrl,
  }) {
    if (lookupUrl == '-') return false;
    if (einvoiceJob['redinvoice_requested'] != true) return false;

    final normalized = issuanceStatus.toLowerCase();
    return normalized.contains('pending') ||
        normalized.contains('queued') ||
        normalized.contains('processing') ||
        normalized == '-';
  }

  String? _elapsedLabel(BuildContext context, dynamic value) {
    final text = value?.toString();
    if (text == null || text.isEmpty) return null;

    final parsed = DateTime.tryParse(text);
    if (parsed == null) return null;

    final diff = DateTime.now().difference(parsed.toLocal());
    if (diff.inSeconds < 60) {
      return context.l10n.paymentDetailElapsedUnderMinute;
    }
    if (diff.inMinutes < 60) {
      return context.l10n.paymentDetailElapsedMinutes(diff.inMinutes);
    }
    if (diff.inHours < 24) {
      final minutes = diff.inMinutes % 60;
      if (minutes == 0) {
        return context.l10n.paymentDetailElapsedHours(diff.inHours);
      }
      return context.l10n.paymentDetailElapsedHoursMinutes(
        diff.inHours,
        minutes,
      );
    }

    final days = diff.inDays;
    final hours = diff.inHours % 24;
    if (hours == 0) {
      return context.l10n.paymentDetailElapsedDays(days);
    }
    return context.l10n.paymentDetailElapsedDaysHours(days, hours);
  }

  String _formatCurrency(dynamic value) {
    if (value is num) {
      return '${_currency.format(value)} VND';
    }
    if (value is String) {
      final parsed = num.tryParse(value);
      if (parsed != null) return '${_currency.format(parsed)} VND';
    }
    return '-';
  }

  String _formatDateTime(dynamic value) {
    final text = value?.toString();
    if (text == null || text.isEmpty) return '-';
    final parsed = DateTime.tryParse(text);
    if (parsed == null) return text;
    return DateFormat('yyyy-MM-dd HH:mm').format(parsed.toLocal());
  }

  Color _statusColor(dynamic status) {
    final normalized = status?.toString().toLowerCase() ?? '';
    if (normalized.contains('success') ||
        normalized.contains('paid') ||
        normalized.contains('done') ||
        normalized.contains('issued')) {
      return AppColors.statusAvailable;
    }
    if (normalized.contains('pending') ||
        normalized.contains('queued') ||
        normalized.contains('processing')) {
      return AppColors.statusReady;
    }
    if (normalized.contains('fail') ||
        normalized.contains('cancel') ||
        normalized.contains('error')) {
      return AppColors.statusCancelled;
    }
    return AppColors.statusInfo;
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({required this.title, required this.rows});

  final String title;
  final List<_InfoRow> rows;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AppSpacing.md),
          for (var i = 0; i < rows.length; i++) ...[
            _InfoRowView(row: rows[i]),
            if (i != rows.length - 1) ...[
              const SizedBox(height: AppSpacing.sm),
              Divider(color: AppColors.surface3, height: 1),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        ],
      ),
    );
  }
}

class _ResponsivePanelGrid extends StatelessWidget {
  const _ResponsivePanelGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final panelWidth = constraints.maxWidth >= 1180
            ? (constraints.maxWidth - AppSpacing.lg) / 2
            : constraints.maxWidth;

        return Wrap(
          spacing: AppSpacing.lg,
          runSpacing: AppSpacing.lg,
          children: [
            for (final child in children)
              SizedBox(width: panelWidth, child: child),
          ],
        );
      },
    );
  }
}

class _InfoRow {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;
}

class _InfoRowView extends StatelessWidget {
  const _InfoRowView({required this.row});

  final _InfoRow row;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Text(
            row.label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          flex: 3,
          child: Text(
            row.value,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 170,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadius.sm,
        border: Border.all(color: AppColors.surface3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _SignalCard extends StatelessWidget {
  const _SignalCard({
    required this.title,
    required this.value,
    required this.detail,
    required this.color,
  });

  final String title;
  final String value;
  final String detail;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: AppRadius.sm,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(detail, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _PortalPendingPanel extends StatelessWidget {
  const _PortalPendingPanel({
    required this.title,
    required this.body,
    required this.footer,
  });

  final String title;
  final String body;
  final String footer;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      backgroundColor: AppColors.statusReady.withValues(alpha: 0.1),
      borderColor: AppColors.statusReady.withValues(alpha: 0.35),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.pending_actions_outlined,
            color: AppColors.statusReady,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: AppSpacing.xs),
                Text(body, style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  footer,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: AppColors.textPrimary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
