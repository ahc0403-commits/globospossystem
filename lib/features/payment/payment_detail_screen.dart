import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/hardware/printer_service.dart';
import '../../core/hardware/receipt_builder.dart';
import '../../core/i18n/locale_extensions.dart';
import '../../core/layout/platform_info.dart';
import '../../core/services/payment_service.dart';
import '../../core/ui/app_primitives.dart';
import '../../core/ui/toast/toast.dart';
import '../../core/utils/live_sync_scope.dart';
import '../../main.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/error_toast.dart';
import '../auth/auth_provider.dart';
import '../settings/printer_provider.dart';

class PaymentDetailScreen extends ConsumerStatefulWidget {
  const PaymentDetailScreen({super.key, required this.paymentId});

  final String paymentId;

  @override
  ConsumerState<PaymentDetailScreen> createState() =>
      _PaymentDetailScreenState();
}

class _PaymentDetailScreenState extends ConsumerState<PaymentDetailScreen> {
  late Future<Map<String, dynamic>?> _detailFuture;
  final _currency = NumberFormat('#,###', 'vi_VN');
  static const _autoRefreshInterval = Duration(seconds: 2);
  RealtimeChannel? _detailChannel;
  Timer? _pollTimer;
  Map<String, dynamic>? _lastDetail;
  String? _subscribedSignature;
  bool _realtimeConnected = false;
  bool _refreshInFlight = false;
  bool _adjustmentInFlight = false;

  @override
  void initState() {
    super.initState();
    _detailFuture = _loadDetail();
  }

  Future<void> _reload() async {
    if (_lastDetail != null) {
      await _refreshDetailSilently();
      return;
    }

    final future = _loadDetail();
    setState(() {
      _detailFuture = future;
    });
    await future;
  }

  Future<Map<String, dynamic>?> _loadDetail() async {
    final storeId = ref.read(authProvider).storeId;
    final detail = await paymentService.fetchPaymentDetail(
      widget.paymentId,
      storeId: storeId,
    );
    if (mounted) {
      if (detail != null || _lastDetail == null) {
        _lastDetail = detail;
      }
      await _subscribeDetail(detail, storeId);
      _ensureAutoRefresh(storeId);
    }
    return detail;
  }

  Future<void> _refreshDetailSilently() async {
    if (_refreshInFlight) {
      return;
    }

    _refreshInFlight = true;
    try {
      final detail = await _loadDetail();
      if (!mounted || detail == null) {
        return;
      }
      setState(() {
        _lastDetail = detail;
      });
    } finally {
      _refreshInFlight = false;
    }
  }

  Future<void> _subscribeDetail(
    Map<String, dynamic>? detail,
    String? storeId,
  ) async {
    final payment = _map(detail?['payment']);
    final order = _map(detail?['order']);
    final resolvedStoreId =
        storeId ??
        payment['restaurant_id']?.toString() ??
        order['restaurant_id']?.toString();
    if (resolvedStoreId == null || resolvedStoreId.isEmpty) {
      return;
    }

    final orderId = payment['order_id']?.toString() ?? order['id']?.toString();
    final signature = '$resolvedStoreId:${widget.paymentId}:${orderId ?? ''}';
    if (_detailChannel != null && _subscribedSignature == signature) {
      return;
    }

    if (_detailChannel != null) {
      await _detailChannel!.unsubscribe();
      _detailChannel = null;
    }
    _subscribedSignature = signature;
    _realtimeConnected = false;

    var channel = supabase
        .channel(
          LiveSyncScope.entityChannel(
            'payment_detail',
            resolvedStoreId,
            widget.paymentId,
          ),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'payments',
          filter: LiveSyncScope.entityFilter('id', widget.paymentId),
          callback: (_) => _refreshDetailFromRealtime(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'payment_adjustments',
          filter: LiveSyncScope.entityFilter('payment_id', widget.paymentId),
          callback: (_) => _refreshDetailFromRealtime(),
        );

    if (orderId != null && orderId.isNotEmpty) {
      channel = channel
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'orders',
            filter: LiveSyncScope.entityFilter('id', orderId),
            callback: (_) => _refreshDetailFromRealtime(),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'order_items',
            filter: LiveSyncScope.entityFilter('order_id', orderId),
            callback: (_) => _refreshDetailFromRealtime(),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'order_items',
            filter: LiveSyncScope.entityFilter('order_id', orderId),
            callback: (_) => _refreshDetailFromRealtime(),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.delete,
            schema: 'public',
            table: 'order_items',
            filter: LiveSyncScope.entityFilter('order_id', orderId),
            callback: (_) => _refreshDetailFromRealtime(),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'meinvoice_jobs',
            filter: LiveSyncScope.entityFilter('order_id', orderId),
            callback: (_) => _refreshDetailFromRealtime(),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'meinvoice_jobs',
            filter: LiveSyncScope.entityFilter('order_id', orderId),
            callback: (_) => _refreshDetailFromRealtime(),
          );
    }

    _detailChannel = channel.subscribe((status, [error]) {
      final connected = status == RealtimeSubscribeStatus.subscribed;
      if (connected != _realtimeConnected) {
        _realtimeConnected = connected;
        _ensureAutoRefresh(resolvedStoreId);
      }
    });
  }

  void _refreshDetailFromRealtime() {
    if (!mounted) {
      return;
    }
    unawaited(_refreshDetailSilently());
  }

  void _ensureAutoRefresh(String? storeId) {
    if (storeId == null || storeId.isEmpty) {
      return;
    }

    if (_realtimeConnected) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }

    if (_pollTimer != null) {
      return;
    }

    _pollTimer = Timer.periodic(_autoRefreshInterval, (_) {
      if (mounted) {
        _refreshDetailFromRealtime();
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _detailChannel?.unsubscribe();
    _detailChannel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      key: const Key('payment_detail_root'),
      backgroundColor: AppColors.surface0,
      body: ToastShell(
        topbar: ToastTopbar(
          title: l10n.paymentDetailTitle,
          actions: [
            IconButton(
              key: const Key('payment_detail_close_to_cashier'),
              tooltip: l10n.close,
              onPressed: () => context.go('/cashier'),
              icon: const Icon(Icons.close_rounded),
            ),
            IconButton(
              tooltip: l10n.retry,
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
            ),
          ],
          trailing: const AppNavBar(),
        ),
        child: FutureBuilder<Map<String, dynamic>?>(
          future: _detailFuture,
          builder: (context, snapshot) {
            final currentDetail = snapshot.data ?? _lastDetail;

            if (snapshot.connectionState == ConnectionState.waiting &&
                currentDetail == null) {
              return AppLoadingView(label: l10n.paymentDetailLoading);
            }

            if (snapshot.hasError && currentDetail == null) {
              return AppErrorState(
                title: l10n.paymentDetailLoadErrorTitle,
                message: snapshot.error.toString(),
                onRetry: _reload,
              );
            }

            final detail = currentDetail;
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
            final adjustments = _listOfMaps(detail['adjustments']);
            final refundAmount = _sumAdjustmentAmount(adjustments, 'refund');
            final voidAmount = _sumAdjustmentAmount(adjustments, 'void');
            final adjustedAmount = refundAmount + voidAmount;
            final paymentAmountValue = _numValue(
              payment['amount'] ??
                  payment['paid_amount'] ??
                  payment['settled_amount'],
            ).toDouble();
            final remainingAdjustmentAmount =
                (paymentAmountValue - adjustedAmount).clamp(0, double.infinity);
            final isRevenuePayment = payment['is_revenue'] != false;
            final canAdjust =
                isRevenuePayment &&
                remainingAdjustmentAmount > 0 &&
                !_adjustmentInFlight;
            final canVoid =
                canAdjust && adjustedAmount == 0 && paymentAmountValue > 0;

            return RefreshIndicator(
              onRefresh: _reload,
              child: ToastResponsiveScrollBody(
                maxWidth: 1180,
                children: [
                  ToastWorkSurface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l10n.paymentDetailOperationalSnapshot,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(
                                          color: AppColors.textSecondary,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.2,
                                        ),
                                  ),
                                  const SizedBox(height: AppSpacing.xs),
                                  Text(
                                    l10n.paymentDetailTitle,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.headlineMedium,
                                  ),
                                  const SizedBox(height: AppSpacing.xs),
                                  Text(
                                    l10n.paymentDetailReadOnlySubtitle(
                                      widget.paymentId,
                                    ),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: AppSpacing.md),
                            ToastStatusBadge(
                              label: paymentStatus.toUpperCase(),
                              color: _statusColor(paymentStatus),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        ToastMetricItemStrip(
                          items: [
                            ToastMetricItem(
                              label: l10n.paymentDetailAmount,
                              value: paymentAmount,
                              color: AppColors.amber500,
                            ),
                            ToastMetricItem(
                              label: l10n.paymentDetailMethod,
                              value: paymentMethod,
                            ),
                            ToastMetricItem(
                              label: l10n.paymentDetailMetricTable,
                              value: tableNumber,
                            ),
                            ToastMetricItem(
                              label: l10n.paymentDetailMetricItems,
                              value: itemCount.toString(),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.lg),
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
                            _SignalCard(
                              title: l10n.paymentDetailAdjustmentSignal,
                              value: _adjustmentStatus(
                                context: context,
                                refundAmount: refundAmount,
                                voidAmount: voidAmount,
                                paymentAmount: paymentAmountValue,
                              ),
                              detail: l10n.paymentDetailRemainingAmount(
                                _formatCurrency(remainingAdjustmentAmount),
                              ),
                              color: _statusColor(
                                voidAmount > 0
                                    ? 'void'
                                    : refundAmount > 0
                                    ? 'refund'
                                    : 'open',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Wrap(
                          spacing: AppSpacing.sm,
                          runSpacing: AppSpacing.sm,
                          children: [
                            PosActionButton(
                              key: const Key('payment_detail_finish_payment'),
                              label: l10n.paymentDetailFinishPayment,
                              tone: PosActionTone.primary,
                              icon: Icons.check_circle_outline,
                              onPressed: () => context.go('/cashier'),
                            ),
                            PosActionButton(
                              key: const Key('payment_detail_print_receipt'),
                              label: l10n.cashierReceipt,
                              tone: PosActionTone.secondary,
                              icon: Icons.print_outlined,
                              onPressed: () => _printReceipt(detail),
                            ),
                            PosActionButton(
                              key: const Key('payment_detail_refund_payment'),
                              label: l10n.paymentDetailRefund,
                              tone: PosActionTone.destructive,
                              icon: Icons.keyboard_return_outlined,
                              loading: _adjustmentInFlight,
                              onPressed: canAdjust
                                  ? () => _openAdjustmentDialog(
                                      payment: payment,
                                      adjustmentType: 'refund',
                                      maxAmount: remainingAdjustmentAmount
                                          .toDouble(),
                                    )
                                  : null,
                            ),
                            PosActionButton(
                              key: const Key('payment_detail_void_payment'),
                              label: l10n.paymentDetailVoid,
                              tone: PosActionTone.destructive,
                              icon: Icons.block_outlined,
                              loading: _adjustmentInFlight,
                              onPressed: canVoid
                                  ? () => _openAdjustmentDialog(
                                      payment: payment,
                                      adjustmentType: 'void',
                                      maxAmount: paymentAmountValue,
                                    )
                                  : null,
                            ),
                            ToastStatusBadge(
                              label: l10n.paymentDetailBadgePayment(
                                paymentStatus.toUpperCase(),
                              ),
                              color: _statusColor(paymentStatus),
                              compact: true,
                            ),
                            ToastStatusBadge(
                              label: l10n.paymentDetailBadgeEInvoice(
                                einvoiceStatus.toUpperCase(),
                              ),
                              color: _statusColor(einvoiceStatus),
                              compact: true,
                            ),
                            ToastStatusBadge(
                              label: l10n.paymentDetailBadgeProof(
                                proofStatus.toUpperCase(),
                              ),
                              color: _statusColor(proofStatus),
                              compact: true,
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
                              PosActionButton(
                                label: l10n.paymentDetailOpenPortal,
                                tone: PosActionTone.secondary,
                                icon: Icons.open_in_new,
                                onPressed: () => _openLookupUrl(lookupUrl),
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
                      _SecondaryInfoPanel(
                        title: l10n.paymentDetailAdjustmentSummary,
                        initiallyExpanded: adjustments.isNotEmpty,
                        rows: [
                          _InfoRow(
                            l10n.paymentDetailAdjustmentRefunded,
                            _formatCurrency(refundAmount),
                          ),
                          _InfoRow(
                            l10n.paymentDetailAdjustmentVoided,
                            _formatCurrency(voidAmount),
                          ),
                          _InfoRow(
                            l10n.paymentDetailRemainingAdjustable,
                            _formatCurrency(remainingAdjustmentAmount),
                          ),
                          _InfoRow(
                            l10n.paymentDetailAdjustmentCount,
                            adjustments.length.toString(),
                          ),
                          if (adjustments.isNotEmpty) ...[
                            _InfoRow(
                              l10n.paymentDetailLastAdjustmentType,
                              _stringOrDash(
                                adjustments.first['adjustment_type'],
                              ),
                            ),
                            _InfoRow(
                              l10n.paymentDetailLastAdjustmentReason,
                              _stringOrDash(adjustments.first['reason']),
                            ),
                            _InfoRow(
                              l10n.paymentDetailLastAdjustmentRecorded,
                              _formatDateTime(adjustments.first['created_at']),
                            ),
                          ],
                        ],
                      ),
                      _SecondaryInfoPanel(
                        title: l10n.paymentDetailEInvoiceSummary,
                        initiallyExpanded: false,
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
                      _SecondaryInfoPanel(
                        title: l10n.paymentDetailProofSummary,
                        initiallyExpanded: false,
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

  Future<void> _printReceipt(Map<String, dynamic> detail) async {
    final l10n = context.l10n;
    if (!PlatformInfo.isPrinterSupported) {
      showErrorToast(context, l10n.cashierPrinterAppOnly);
      return;
    }

    final printerState = ref.read(printerProvider);
    if (printerState.printerIp.isEmpty) {
      showErrorToast(context, l10n.settingsEnterIpFirst);
      return;
    }

    final payment = _map(detail['payment']);
    final order = _map(detail['order']);
    final bytes = await ReceiptBuilder.buildPaymentReceipt(
      restaurantName: _receiptRestaurantName(order),
      tableNumber: _extractTableNumber(order),
      items: _receiptItems(order, l10n.cashierItemFallback),
      totalAmount: _numValue(
        payment['amount'] ??
            payment['paid_amount'] ??
            payment['settled_amount'],
      ).toDouble(),
      paymentMethod: _stringOrDash(
        payment['method'] ?? payment['payment_method'],
      ),
      paidAt: _dateValue(payment['created_at']) ?? DateTime.now(),
      isService:
          _stringOrDash(payment['method'] ?? payment['payment_method']) ==
          'service',
    );

    final result = await ref.read(printerProvider.notifier).print(bytes);
    if (!mounted) return;
    if (result == PrintResult.success) {
      showSuccessToast(context, l10n.settingsTestPrintComplete);
    } else {
      showErrorToast(context, l10n.cashierReceiptPrintFailed);
    }
  }

  Future<void> _openAdjustmentDialog({
    required Map<String, dynamic> payment,
    required String adjustmentType,
    required double maxAmount,
  }) async {
    final l10n = context.l10n;
    final isVoid = adjustmentType == 'void';
    final amountController = TextEditingController(
      text: isVoid ? maxAmount.toStringAsFixed(0) : '',
    );
    final reasonController = TextEditingController();

    try {
      final confirmed = await ToastConfirmDialog.withContent(
        context: context,
        title: isVoid
            ? l10n.paymentDetailVoidPayment
            : l10n.paymentDetailRefundPayment,
        confirmLabel: isVoid
            ? l10n.paymentDetailVoid
            : l10n.paymentDetailRefund,
        cancelLabel: l10n.cancel,
        destructive: true,
        icon: isVoid ? Icons.block_outlined : Icons.keyboard_return_outlined,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${l10n.paymentDetailPaymentId}: ${_stringOrDash(payment['id'])}',
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(l10n.paymentDetailAvailableAmount(_formatCurrency(maxAmount))),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const Key('payment_adjustment_amount_input'),
              controller: amountController,
              enabled: !isVoid,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: l10n.paymentDetailAdjustmentAmount,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const Key('payment_adjustment_reason_input'),
              controller: reasonController,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: l10n.paymentDetailAdjustmentReason,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      );

      if (confirmed != true) return;
      if (!mounted) return;

      final reason = reasonController.text.trim();
      final amount = isVoid
          ? maxAmount
          : double.tryParse(amountController.text.replaceAll(',', '').trim());

      if (reason.isEmpty) {
        showErrorToast(context, l10n.paymentDetailReasonRequired);
        return;
      }

      if (amount == null || amount <= 0 || amount > maxAmount) {
        showErrorToast(
          context,
          l10n.paymentDetailAdjustmentAmountLimit(_formatCurrency(maxAmount)),
        );
        return;
      }

      await _submitAdjustment(
        adjustmentType: adjustmentType,
        amount: amount,
        reason: reason,
      );
    } finally {
      amountController.dispose();
      reasonController.dispose();
    }
  }

  Future<void> _submitAdjustment({
    required String adjustmentType,
    required double amount,
    required String reason,
  }) async {
    setState(() {
      _adjustmentInFlight = true;
    });

    try {
      await paymentService.recordPaymentAdjustment(
        paymentId: widget.paymentId,
        adjustmentType: adjustmentType,
        amount: amount,
        reason: reason,
      );
      if (!mounted) return;
      final l10n = context.l10n;
      showSuccessToast(
        context,
        adjustmentType == 'void'
            ? l10n.paymentDetailVoidRecorded
            : l10n.paymentDetailRefundRecorded,
      );
      await _refreshDetailSilently();
    } catch (error) {
      if (!mounted) return;
      showErrorToast(context, _mapAdjustmentError(context, error));
    } finally {
      if (mounted) {
        setState(() {
          _adjustmentInFlight = false;
        });
      }
    }
  }

  Map<String, dynamic> _map(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return const <String, dynamic>{};
  }

  List<Map<String, dynamic>> _listOfMaps(dynamic value) {
    if (value is! List) return const [];
    return value.map((item) => Map<String, dynamic>.from(item as Map)).toList();
  }

  String _extractTableNumber(Map<String, dynamic> order) {
    final tables = order['tables'];
    if (tables is Map) {
      return _stringOrDash(tables['table_number']);
    }
    return '-';
  }

  String _receiptRestaurantName(Map<String, dynamic> order) {
    final name = order['restaurant_name']?.toString().trim();
    return name == null || name.isEmpty ? 'GLOBOS POS' : name;
  }

  List<ReceiptItem> _receiptItems(
    Map<String, dynamic> order,
    String fallbackLabel,
  ) {
    final items = order['order_items'];
    if (items is! List) return const [];

    return items
        .map((item) => Map<String, dynamic>.from(item))
        .where((item) => item['status']?.toString() != 'cancelled')
        .map((item) {
          final menuItem = item['menu_items'];
          final menuName = menuItem is Map
              ? menuItem['name']?.toString().trim()
              : null;
          final label = item['label']?.toString().trim();
          return ReceiptItem(
            name: (label != null && label.isNotEmpty)
                ? label
                : (menuName != null && menuName.isNotEmpty)
                ? menuName
                : fallbackLabel,
            quantity: _intValue(item['quantity']),
            unitPrice: _numValue(item['unit_price']).toDouble(),
          );
        })
        .toList();
  }

  num _numValue(dynamic value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value) ?? 0;
    return 0;
  }

  int _intValue(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  DateTime? _dateValue(dynamic value) {
    final text = value?.toString();
    if (text == null || text.isEmpty) return null;
    return DateTime.tryParse(text);
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

  double _sumAdjustmentAmount(
    List<Map<String, dynamic>> adjustments,
    String adjustmentType,
  ) {
    return adjustments
        .where((row) => row['adjustment_type']?.toString() == adjustmentType)
        .fold<double>(
          0,
          (sum, row) => sum + _numValue(row['amount']).toDouble(),
        );
  }

  String _adjustmentStatus({
    required BuildContext context,
    required double refundAmount,
    required double voidAmount,
    required double paymentAmount,
  }) {
    final l10n = context.l10n;
    if (voidAmount > 0) return l10n.paymentDetailAdjustmentStatusVoided;
    if (refundAmount <= 0) return l10n.paymentDetailAdjustmentStatusOpen;
    if (refundAmount >= paymentAmount) {
      return l10n.paymentDetailAdjustmentStatusRefunded;
    }
    return l10n.paymentDetailAdjustmentStatusPartialRefund;
  }

  String _mapAdjustmentError(BuildContext context, Object error) {
    final l10n = context.l10n;
    final message = error.toString();
    if (message.contains('PAYMENT_REFUND_EXCEEDS_REMAINING_AMOUNT')) {
      return l10n.paymentDetailRefundExceedsRemaining;
    }
    if (message.contains('PAYMENT_VOID_AMOUNT_MUST_MATCH_PAYMENT')) {
      return l10n.paymentDetailVoidMustMatchPayment;
    }
    if (message.contains('PAYMENT_VOID_AFTER_REFUND_NOT_ALLOWED')) {
      return l10n.paymentDetailRefundAfterPartial;
    }
    if (message.contains('PAYMENT_ADJUSTMENT_SERVICE_NOT_ALLOWED')) {
      return l10n.paymentDetailServiceAdjustmentNotAllowed;
    }
    if (message.contains('PAYMENT_ADJUSTMENT_REASON_REQUIRED')) {
      return l10n.paymentDetailReasonRequired;
    }
    if (message.contains('PAYMENT_ADJUSTMENT_FORBIDDEN')) {
      return l10n.paymentDetailAdjustmentForbidden;
    }
    return l10n.paymentDetailAdjustmentFailed(message);
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
        normalized.contains('refund') ||
        normalized.contains('void') ||
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
    return ToastWorkSurface(
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

class _SecondaryInfoPanel extends StatelessWidget {
  const _SecondaryInfoPanel({
    required this.title,
    required this.rows,
    this.initiallyExpanded = false,
  });

  final String title;
  final List<_InfoRow> rows;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return ToastWorkSurface(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: Key('payment_detail_secondary_${title.hashCode}'),
          initiallyExpanded: initiallyExpanded,
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(top: AppSpacing.md),
          title: Text(title, style: Theme.of(context).textTheme.titleLarge),
          subtitle: Text(
            context.l10n.paymentDetailOperationalSnapshot,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
          children: [
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
        color: AppColors.surface2,
        borderRadius: AppRadius.md,
        border: Border.all(color: AppColors.surface3),
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
              color: color,
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
    return ToastWorkSurface(
      backgroundColor: AppColors.surface2,
      borderColor: AppColors.surface3,
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
