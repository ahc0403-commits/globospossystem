import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

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
    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: AppShell(
        child: FutureBuilder<Map<String, dynamic>?>(
          future: _detailFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const AppLoadingView(label: 'Loading payment detail');
            }

            if (snapshot.hasError) {
              return AppErrorState(
                title: 'Unable to load payment detail',
                message: snapshot.error.toString(),
                onRetry: _reload,
              );
            }

            final detail = snapshot.data;
            if (detail == null) {
              return const AppEmptyState(
                title: 'Payment not found',
                message:
                    'This payment record is unavailable or no longer exists.',
                icon: Icons.payments_outlined,
              );
            }

            final payment = _map(detail['payment']);
            final order = _map(detail['order']);
            final einvoiceJob = _map(detail['einvoice_job']);
            final tableNumber = _extractTableNumber(order);

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
                          title: 'PAYMENT DETAIL',
                          subtitle:
                              'Read-only detail for payment ${widget.paymentId}',
                          trailing: AppStatusBadge(
                            label: _stringOrDash(
                              payment['status'] ?? payment['payment_status'],
                            ).toUpperCase(),
                            color: _statusColor(
                              payment['status'] ?? payment['payment_status'],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  _InfoPanel(
                    title: 'Payment Summary',
                    rows: [
                      _InfoRow('Payment ID', widget.paymentId),
                      _InfoRow(
                        'Amount',
                        _formatCurrency(
                          payment['amount'] ??
                              payment['paid_amount'] ??
                              payment['settled_amount'],
                        ),
                      ),
                      _InfoRow(
                        'Method',
                        _stringOrDash(payment['method'] ?? payment['payment_method']),
                      ),
                      _InfoRow(
                        'Status',
                        _stringOrDash(
                          payment['status'] ?? payment['payment_status'],
                        ),
                      ),
                      _InfoRow(
                        'Created',
                        _formatDateTime(payment['created_at']),
                      ),
                      _InfoRow(
                        'Updated',
                        _formatDateTime(payment['updated_at']),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _InfoPanel(
                    title: 'Order Summary',
                    rows: [
                      _InfoRow('Order ID', _stringOrDash(order['id'])),
                      _InfoRow('Table', tableNumber),
                      _InfoRow('Order Status', _stringOrDash(order['status'])),
                      _InfoRow(
                        'Order Total',
                        _formatCurrency(order['order_total_amount']),
                      ),
                      _InfoRow(
                        'Order Created',
                        _formatDateTime(order['created_at']),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _InfoPanel(
                    title: 'E-Invoice Summary',
                    rows: [
                      _InfoRow('Job ID', _stringOrDash(einvoiceJob['id'])),
                      _InfoRow('Status', _stringOrDash(einvoiceJob['status'])),
                      _InfoRow(
                        'Issuance Status',
                        _stringOrDash(einvoiceJob['issuance_status']),
                      ),
                      _InfoRow(
                        'CQT Report Status',
                        _stringOrDash(einvoiceJob['cqt_report_status']),
                      ),
                      _InfoRow(
                        'Red Invoice Requested',
                        _boolLabel(einvoiceJob['redinvoice_requested']),
                      ),
                      _InfoRow(
                        'Lookup URL',
                        _stringOrDash(einvoiceJob['lookup_url']),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _InfoPanel(
                    title: 'Proof Summary',
                    rows: [
                      _InfoRow(
                        'Proof Required',
                        _boolLabel(payment['proof_required']),
                      ),
                      _InfoRow(
                        'Proof Photo URL',
                        _stringOrDash(payment['proof_photo_url']),
                      ),
                      _InfoRow(
                        'Proof Captured',
                        _formatDateTime(payment['proof_photo_taken_at']),
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

  String _stringOrDash(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return '-';
    return text;
  }

  String _boolLabel(dynamic value) {
    if (value == true) return 'Yes';
    if (value == false) return 'No';
    return '-';
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
