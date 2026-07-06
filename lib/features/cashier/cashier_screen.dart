import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/payments/payment_method_contract.dart';
import '../../core/services/connectivity_service.dart';
import '../../core/layout/platform_info.dart';
import '../../core/hardware/printer_service.dart';
import '../../core/hardware/receipt_builder.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../core/utils/permission_utils.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/error_toast.dart';
import '../../widgets/offline_banner.dart';
import '../auth/auth_provider.dart';
import '../payment/payment_provider.dart';
import '../payment/einvoice_status_badge.dart';
import '../settings/printer_provider.dart';
import '../../core/services/payment_service.dart';
import '../../core/services/payment_proof_service.dart';
import 'discount_modal.dart';
import 'payment_proof_modal.dart';
import 'red_invoice_modal.dart';

class CashierScreen extends ConsumerStatefulWidget {
  const CashierScreen({super.key});

  @override
  ConsumerState<CashierScreen> createState() => _CashierScreenState();
}

class _CashierScreenState extends ConsumerState<CashierScreen> {
  String? _selectedMethod;
  String? _initializedRestaurantId;
  Timer? _successTimer;
  String? _lastError;
  String? _lastCompletedOrderId; // for einvoice badge
  bool _isFlushingProofQueue = false;
  bool _hasAttemptedProofFlush = false;
  bool _showPaymentQueueOnCompact = true;
  late final ProviderSubscription<PaymentState> _paymentSub;

  @override
  void initState() {
    super.initState();
    _paymentSub = ref.listenManual<PaymentState>(paymentProvider, (prev, next) {
      if ((prev?.paymentSuccess ?? false) == false && next.paymentSuccess) {
        _successTimer?.cancel();
        _successTimer = Timer(const Duration(milliseconds: 1500), () {
          ref.read(paymentProvider.notifier).resetPaymentSuccess();
        });
        if (mounted) {
          showSuccessToast(context, context.l10n.cashierPaymentProcessed);
        }
      }
      final error = next.error;
      if (error != null && error.isNotEmpty && error != _lastError) {
        _lastError = error;
        if (mounted) {
          showErrorToast(context, error);
        }
      }
    });
  }

  Future<void> _flushProofQueueIfNeeded(bool isOnline) async {
    if (!isOnline || _isFlushingProofQueue) {
      return;
    }

    _isFlushingProofQueue = true;
    try {
      final uploaded = await paymentProofService.flushPendingUploads();
      if (mounted && uploaded > 0) {
        showSuccessToast(
          context,
          context.l10n.cashierQueuedProofUploaded(uploaded),
        );
      }
    } finally {
      _isFlushingProofQueue = false;
    }
  }

  void _ensureLoaded(String? storeId) {
    if (storeId == null || storeId == _initializedRestaurantId) {
      return;
    }
    _initializedRestaurantId = storeId;
    Future.microtask(() {
      ref.read(paymentProvider.notifier).loadOrders(storeId);
    });
  }

  @override
  void dispose() {
    _successTimer?.cancel();
    _paymentSub.close();
    super.dispose();
  }

  Future<bool> _showCancelOrderDialog({required String tableNumber}) async {
    final l10n = context.l10n;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: PosColors.surface,
        title: Text(
          l10n.cashierCancelOrderTitle,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        content: Text(
          l10n.cashierCancelOrderMessage(tableNumber),
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: PosColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.waiterBack),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: PosColors.danger,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.cancel),
            label: Text(l10n.waiterCancelOrderAction),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<bool> _showServiceConfirmDialog() async {
    final l10n = context.l10n;
    final result = await ToastConfirmDialog.show(
      context: context,
      title: l10n.cashierServiceProvisionTitle,
      description: l10n.cashierServiceProvisionMessage,
      confirmLabel: l10n.cashierServiceAction,
    );
    return result ?? false;
  }

  Future<List<PaymentSplitInput>?> _showSplitPaymentDialog({
    required double totalAmount,
  }) {
    return showDialog<List<PaymentSplitInput>?>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SplitPaymentDialog(totalAmount: totalAmount),
    );
  }

  Future<void> _printReceipt({
    required CashierOrder order,
    required String method,
  }) async {
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

    final bytes = await ReceiptBuilder.buildPaymentReceipt(
      restaurantName: 'GLOBOS POS',
      tableNumber: order.tableNumber,
      items: order.items
          .map(
            (item) => ReceiptItem(
              name: item.label ?? l10n.cashierItemFallback,
              quantity: item.quantity,
              unitPrice: item.unitPrice,
            ),
          )
          .toList(),
      totalAmount: order.totalAmount,
      paymentMethod: method,
      paidAt: DateTime.now(),
      isService: isServicePaymentMethod(method),
    );

    final result = await ref.read(printerProvider.notifier).print(bytes);
    if (!mounted) {
      return;
    }
    if (result != PrintResult.success) {
      showErrorToast(context, l10n.cashierReceiptPrintFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final authState = ref.watch(authProvider);
    final storeId = authState.storeId;
    final role = authState.role ?? '';
    final isAdmin = PermissionUtils.isAdminLike(role);
    final canApplyDiscount = PermissionUtils.hasPermission(
      role,
      authState.extraPermissions,
      'discount_apply',
    );
    _ensureLoaded(storeId);

    final paymentState = ref.watch(paymentProvider);
    final notifier = ref.read(paymentProvider.notifier);
    final currency = NumberFormat('#,###', 'vi_VN');
    // 오프라인 상태 감지 - RULES.md: 결제는 온라인 필수
    final isOnline = ref.watch(connectivityProvider).asData?.value ?? true;
    if (!isOnline) {
      _hasAttemptedProofFlush = false;
    } else if (storeId != null && !_hasAttemptedProofFlush) {
      _hasAttemptedProofFlush = true;
      Future.microtask(() => _flushProofQueueIfNeeded(isOnline));
    }
    final selectedOrder = paymentState.selectedOrder;
    final queueTotalAmount = paymentState.orders.fold<double>(
      0,
      (sum, order) => sum + order.remainingDue,
    );
    final queuePane = PosDataPanel(
      key: const Key('cashier_pending_payment_list'),
      title: l10n.cashierPendingStatus,
      subtitle: l10n.cashierSelectOrderToPay,
      trailing: selectedOrder == null
          ? null
          : ToastStatusBadge(
              label: l10n.selected,
              color: PosColors.accent,
              compact: true,
            ),
      child: paymentState.orders.isEmpty
          ? _CashierNoPayableOrdersPanel(
              title: l10n.cashierNoPayableOrdersTitle,
              subtitle: l10n.cashierNoPayableOrdersMessage,
              isOnline: isOnline,
              onRefresh: storeId == null
                  ? null
                  : () => unawaited(notifier.loadOrders(storeId)),
            )
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 12),
              itemCount: paymentState.orders.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final order = paymentState.orders[index];
                final selected =
                    paymentState.selectedOrder?.orderId == order.orderId;
                return KeyedSubtree(
                  key: Key('cashier_order_${order.orderId}'),
                  child: PosDataGridRow(
                    key: index == 0
                        ? const Key('payment_first_candidate')
                        : null,
                    selected: selected,
                    statusColor: selected ? PosColors.accent : null,
                    onTap: () {
                      setState(() {
                        _selectedMethod = null;
                        _showPaymentQueueOnCompact = false;
                      });
                      notifier.selectOrder(order);
                    },
                    cells: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '#${_shortCashierOrderId(order.orderId)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: PosNumericText.orderId.copyWith(
                              color: PosColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _formatCashierOrderAge(context, order.createdAt),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: PosColors.textSecondary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            l10n.cashierTableLabel(order.tableNumber),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 2),
                          _OrderStatusBadge(status: order.status),
                        ],
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          l10n.cashierItemsCount(order.items.length),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: PosColors.textSecondary,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          '₫${currency.format(order.remainingDue)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: PosNumericText.amountLine.copyWith(
                            color: PosColors.accent,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
    final queueWithHistory = _CashierQueueWithHistory(
      queuePane: queuePane,
      completedOrders: paymentState.completedOrders,
      currency: currency,
    );
    final detailPane = Stack(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: selectedOrder == null
              ? const _CashierSelectionPlaceholder()
              : _SelectedOrderView(
                  order: selectedOrder,
                  selectedMethod: _selectedMethod,
                  isAdmin: isAdmin,
                  canApplyDiscount: canApplyDiscount,
                  isProcessing: paymentState.isProcessing,
                  isOnline: isOnline,
                  onSelectMethod: (method) {
                    setState(() => _selectedMethod = method);
                  },
                  onApplyDiscount: () async {
                    final selectedOrder = paymentState.selectedOrder;
                    if (storeId == null || selectedOrder == null) {
                      return;
                    }
                    if (!isOnline) {
                      showErrorToast(
                        context,
                        context.l10n.cashierDiscountOffline,
                      );
                      return;
                    }
                    final result = await showDialog<Map<String, dynamic>?>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => DiscountModal(
                        orderId: selectedOrder.orderId,
                        storeId: storeId,
                        menuSubtotal: selectedOrder.menuSubtotal,
                        serviceChargeTotal: selectedOrder.serviceChargeTotal,
                      ),
                    );
                    if (result != null && context.mounted) {
                      showSuccessToast(
                        context,
                        context.l10n.cashierDiscountApplied,
                      );
                      await notifier.loadOrders(storeId);
                    }
                  },
                  onProcess: (method) async {
                    final selectedOrder = paymentState.selectedOrder;
                    if (storeId == null || selectedOrder == null) {
                      return;
                    }
                    if (isServicePaymentMethod(method)) {
                      final proceed = await _showServiceConfirmDialog();
                      if (!proceed) {
                        return;
                      }
                    }

                    final payment = await notifier.processPayment(
                      storeId,
                      selectedOrder.orderId,
                      selectedOrder.remainingDue,
                      method,
                    );
                    if (mounted && ref.read(paymentProvider).paymentSuccess) {
                      await _printReceipt(order: selectedOrder, method: method);
                      setState(() {
                        _selectedMethod = null;
                        _lastCompletedOrderId = selectedOrder.orderId;
                        _showPaymentQueueOnCompact = true;
                      });
                      final proofRequired = requiresPaymentProof(method);
                      final paymentId = payment?['id']?.toString();

                      if (proofRequired &&
                          paymentId != null &&
                          context.mounted) {
                        try {
                          await paymentProofService.markProofRequired(
                            paymentId: paymentId,
                            storeId: storeId,
                          );
                          if (!context.mounted) {
                            return;
                          }

                          final proofResult =
                              await showDialog<PaymentProofSaveResult?>(
                                context: context,
                                barrierDismissible: false,
                                builder: (_) => PaymentProofModal(
                                  paymentId: paymentId,
                                  storeId: storeId,
                                  methodLabel: paymentMethodDisplayLabel(
                                    method,
                                  ),
                                ),
                              );

                          if (context.mounted && proofResult != null) {
                            if (proofResult.queued) {
                              showErrorToast(
                                context,
                                context.l10n.cashierProofQueuedLocally,
                              );
                            } else if (proofResult.uploaded) {
                              showSuccessToast(
                                context,
                                context.l10n.cashierProofSaved,
                              );
                            }
                          }
                        } catch (e) {
                          if (context.mounted) {
                            showErrorToast(
                              context,
                              context.l10n.cashierProofFlowFailed('$e'),
                            );
                          }
                        }
                      }

                      if (!isServicePaymentMethod(method)) {
                        if (!context.mounted) {
                          return;
                        }
                        await showDialog<bool>(
                          context: context,
                          barrierDismissible: false,
                          builder: (_) => RedInvoiceModal(
                            orderId: selectedOrder.orderId,
                            storeId: storeId,
                          ),
                        );
                      }

                      if (paymentId != null && context.mounted) {
                        context.go('/payments/$paymentId');
                      }
                    }
                  },
                  onProcessSplit: () async {
                    final selectedOrder = paymentState.selectedOrder;
                    if (storeId == null || selectedOrder == null) {
                      return;
                    }
                    if (selectedOrder.isStaffMeal) {
                      return;
                    }
                    final splits = await _showSplitPaymentDialog(
                      totalAmount: selectedOrder.remainingDue,
                    );
                    if (splits == null || splits.isEmpty) {
                      return;
                    }

                    final payments = await notifier.processPaymentSplits(
                      storeId,
                      selectedOrder.orderId,
                      selectedOrder.remainingDue,
                      splits,
                    );
                    if (mounted && ref.read(paymentProvider).paymentSuccess) {
                      await _printReceipt(
                        order: selectedOrder,
                        method: 'SPLIT',
                      );
                      setState(() {
                        _selectedMethod = null;
                        _lastCompletedOrderId = selectedOrder.orderId;
                        _showPaymentQueueOnCompact = true;
                      });

                      if (payments != null) {
                        for (
                          var i = 0;
                          i < payments.length && i < splits.length;
                          i++
                        ) {
                          final method = splits[i].method;
                          if (!requiresPaymentProof(method)) {
                            continue;
                          }
                          final paymentId = payments[i]['id']?.toString();
                          if (paymentId == null || !context.mounted) {
                            continue;
                          }
                          await paymentProofService.markProofRequired(
                            paymentId: paymentId,
                            storeId: storeId,
                          );
                          if (!context.mounted) {
                            return;
                          }
                          await showDialog<PaymentProofSaveResult?>(
                            context: context,
                            barrierDismissible: false,
                            builder: (_) => PaymentProofModal(
                              paymentId: paymentId,
                              storeId: storeId,
                              methodLabel: paymentMethodDisplayLabel(method),
                            ),
                          );
                        }
                      }

                      if (context.mounted) {
                        await showDialog<bool>(
                          context: context,
                          barrierDismissible: false,
                          builder: (_) => RedInvoiceModal(
                            orderId: selectedOrder.orderId,
                            storeId: storeId,
                          ),
                        );
                      }

                      final lastPaymentId = payments?.isNotEmpty == true
                          ? payments!.last['id']?.toString()
                          : null;
                      if (lastPaymentId != null && context.mounted) {
                        context.go('/payments/$lastPaymentId');
                      }
                    }
                  },
                  onCancelOrder: () async {
                    final selectedOrder = paymentState.selectedOrder;
                    if (storeId == null || selectedOrder == null || !isAdmin) {
                      return;
                    }
                    final confirmed = await _showCancelOrderDialog(
                      tableNumber: selectedOrder.tableNumber,
                    );
                    if (!confirmed) {
                      return;
                    }
                    await notifier.cancelOrder(selectedOrder.orderId, storeId);
                    if (context.mounted &&
                        ref.read(paymentProvider).error == null) {
                      setState(() => _selectedMethod = null);
                      showSuccessToast(context, l10n.cashierOrderCancelled);
                    }
                  },
                  onReprint: () async {
                    final selectedOrder = paymentState.selectedOrder;
                    if (selectedOrder == null) {
                      return;
                    }
                    final method = _selectedMethod ?? paymentMethodCash;
                    await _printReceipt(order: selectedOrder, method: method);
                  },
                ),
        ),
        IgnorePointer(
          ignoring: true,
          child: AnimatedOpacity(
            opacity: paymentState.paymentSuccess ? 1 : 0,
            duration: const Duration(milliseconds: 240),
            child: Center(
              child: Container(
                key: const Key('payment_success_banner'),
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  color: PosColors.success.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                  border: Border.all(color: PosColors.success, width: 3),
                ),
                child: const Icon(
                  Icons.check,
                  color: PosColors.success,
                  size: 94,
                ),
              ),
            ),
          ),
        ),
        if (_lastCompletedOrderId != null)
          Positioned(
            bottom: 24,
            left: 24,
            child: EinvoiceStatusBadge(orderId: _lastCompletedOrderId!),
          ),
      ],
    );

    return Scaffold(
      key: const Key('cashier_root'),
      backgroundColor: PosColors.canvas,
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: ToastResponsiveBody(
              maxWidth: 1480,
              fitToViewportWhenNarrow: true,
              minHeight:
                  MediaQuery.sizeOf(context).width >
                      MediaQuery.sizeOf(context).height
                  ? 820
                  : 720,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final viewport = MediaQuery.sizeOf(context);
                  final forceScrollableCompact =
                      viewport.width > viewport.height && viewport.height < 720;
                  final useWideLayout =
                      constraints.maxWidth >= 1180 && !forceScrollableCompact;
                  final useCompactChrome = !useWideLayout;
                  final showCompactQueue =
                      selectedOrder == null || _showPaymentQueueOnCompact;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildCashierCommandHeader(
                        orderCount: paymentState.orders.length,
                        queueTotalAmount: queueTotalAmount,
                        selectedOrder: selectedOrder,
                        currency: currency,
                        isOnline: isOnline,
                        compact: useCompactChrome,
                      ),
                      SizedBox(height: useCompactChrome ? 8 : 12),
                      Expanded(
                        child: useWideLayout
                            ? Row(
                                children: [
                                  SizedBox(width: 348, child: queueWithHistory),
                                  const SizedBox(width: 16),
                                  Expanded(child: detailPane),
                                ],
                              )
                            : Column(
                                children: [
                                  _CashierCompactPaymentSwitch(
                                    showQueue: showCompactQueue,
                                    orderCount: paymentState.orders.length,
                                    selectedOrder: selectedOrder,
                                    currency: currency,
                                    onShowQueue: () => setState(
                                      () => _showPaymentQueueOnCompact = true,
                                    ),
                                    onShowSelected: selectedOrder == null
                                        ? null
                                        : () => setState(
                                            () => _showPaymentQueueOnCompact =
                                                false,
                                          ),
                                  ),
                                  const SizedBox(height: 8),
                                  Expanded(
                                    child: showCompactQueue
                                        ? queueWithHistory
                                        : detailPane,
                                  ),
                                ],
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCashierCommandHeader({
    required int orderCount,
    required double queueTotalAmount,
    required CashierOrder? selectedOrder,
    required NumberFormat currency,
    required bool isOnline,
    required bool compact,
  }) {
    final l10n = context.l10n;
    if (compact) {
      return _CashierCompactCommandBar(isOnline: isOnline);
    }

    final selectedAmount = selectedOrder == null
        ? '—'
        : '₫${currency.format(selectedOrder.remainingDue)}';
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.cashierTitle,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: PosColors.textPrimary,
            fontWeight: FontWeight.w900,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          selectedOrder == null ? l10n.cashierSubtitle : l10n.cashierPaymentDue,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: PosColors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
    final actions = <Widget>[
      const AppNavBar(),
      ToastStatusBadge(
        label: l10n.cashierPendingStatus,
        color: PosColors.accent,
        compact: true,
      ),
      ToastStatusBadge(
        label: isOnline
            ? l10n.cashierTerminalOnline
            : l10n.cashierTerminalOffline,
        color: isOnline ? PosColors.success : PosColors.warning,
        compact: true,
      ),
      IconButton(
        key: const Key('logout_button'),
        icon: const Icon(Icons.logout, color: PosColors.textSecondary),
        tooltip: l10n.logout,
        onPressed: () async {
          await ref.read(authProvider.notifier).logout();
        },
      ),
    ];

    return ToastWorkSurface(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      backgroundColor: PosColors.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compactHeader = constraints.maxWidth < 560;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (compactHeader) ...[
                titleBlock,
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: actions),
                ),
              ] else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: titleBlock),
                    const SizedBox(width: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      alignment: WrapAlignment.end,
                      children: actions,
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              ToastMetricStrip(
                metrics: [
                  ToastMetric(
                    label: l10n.cashierPendingStatus,
                    value: '$orderCount',
                    tone: PosColors.accent,
                  ),
                  ToastMetric(
                    label: l10n.cashierQueuedAmount,
                    value: '₫${currency.format(queueTotalAmount)}',
                  ),
                  ToastMetric(
                    label: l10n.cashierSelectedAmount,
                    value: selectedAmount,
                    tone: selectedOrder == null ? null : PosColors.success,
                  ),
                  ToastMetric(
                    label: l10n.cashierNetwork,
                    value: isOnline
                        ? l10n.cashierTerminalOnline
                        : l10n.cashierTerminalOffline,
                    tone: isOnline ? PosColors.success : PosColors.warning,
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CashierCompactCommandBar extends ConsumerWidget {
  const _CashierCompactCommandBar({required this.isOnline});

  final bool isOnline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;

    return ToastWorkSurface(
      key: const Key('cashier_compact_command_bar'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      backgroundColor: PosColors.surface,
      child: Row(
        children: [
          const AppNavBar(),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ToastStatusBadge(
                label: isOnline
                    ? l10n.cashierTerminalOnline
                    : l10n.cashierTerminalOffline,
                color: isOnline ? PosColors.success : PosColors.warning,
                compact: true,
              ),
            ),
          ),
          IconButton(
            key: const Key('logout_button'),
            icon: const Icon(Icons.logout, color: PosColors.textSecondary),
            tooltip: l10n.logout,
            onPressed: () async {
              await ref.read(authProvider.notifier).logout();
            },
          ),
        ],
      ),
    );
  }
}

class _CashierQueueWithHistory extends StatelessWidget {
  const _CashierQueueWithHistory({
    required this.queuePane,
    required this.completedOrders,
    required this.currency,
  });

  final Widget queuePane;
  final List<CashierOrder> completedOrders;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: queuePane),
        const SizedBox(height: 12),
        SizedBox(
          height: 178,
          child: _CashierCompletedOrderHistory(
            orders: completedOrders,
            currency: currency,
          ),
        ),
      ],
    );
  }
}

class _CashierCompletedOrderHistory extends StatelessWidget {
  const _CashierCompletedOrderHistory({
    required this.orders,
    required this.currency,
  });

  final List<CashierOrder> orders;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return PosDataPanel(
      key: const Key('cashier_completed_order_history'),
      title: l10n.cashierCompletedStatus,
      subtitle: l10n.changeHistory,
      trailing: ToastStatusBadge(
        label: '${orders.length}',
        color: PosColors.success,
        compact: true,
      ),
      child: orders.isEmpty
          ? ToastOperationalEmptyState(
              headline: l10n.cashierCompletedStatus,
              helper: l10n.cashierNoPayableOrdersMessage,
              icon: Icons.receipt_long_outlined,
            )
          : ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: orders.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final order = orders[index];
                final completedAt = order.completedAt ?? order.createdAt;
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: PosSurfaceRole.background.fill,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: PosSurfaceRole.background.stroke),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.check_circle_rounded,
                        color: PosColors.success,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.cashierTableLabel(order.tableNumber),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w900),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _formatCashierOrderAge(context, completedAt),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: PosColors.textSecondary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '₫${currency.format(order.totalAmount)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: PosNumericText.amountCompact.copyWith(
                          color: PosColors.success,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

String _shortCashierOrderId(String orderId) {
  if (orderId.length <= 8) {
    return orderId;
  }
  return orderId.substring(0, 8);
}

String _formatCashierOrderAge(BuildContext context, DateTime createdAt) {
  final l10n = context.l10n;
  final elapsed = DateTime.now().difference(createdAt.toLocal());
  final minutes = elapsed.inMinutes;
  if (minutes < 1) {
    return l10n.paymentDetailElapsedUnderMinute;
  }
  if (minutes < 60) {
    return l10n.paymentDetailElapsedMinutes(minutes);
  }
  final hours = elapsed.inHours;
  if (hours < 24) {
    final remainingMinutes = minutes.remainder(60);
    if (remainingMinutes == 0) {
      return l10n.paymentDetailElapsedHours(hours);
    }
    return l10n.paymentDetailElapsedHoursMinutes(hours, remainingMinutes);
  }
  final days = elapsed.inDays;
  final remainingHours = hours.remainder(24);
  if (remainingHours == 0) {
    return l10n.paymentDetailElapsedDays(days);
  }
  return l10n.paymentDetailElapsedDaysHours(days, remainingHours);
}

class _CashierCompactPaymentSwitch extends StatelessWidget {
  const _CashierCompactPaymentSwitch({
    required this.showQueue,
    required this.orderCount,
    required this.selectedOrder,
    required this.currency,
    required this.onShowQueue,
    required this.onShowSelected,
  });

  final bool showQueue;
  final int orderCount;
  final CashierOrder? selectedOrder;
  final NumberFormat currency;
  final VoidCallback onShowQueue;
  final VoidCallback? onShowSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final selectedSubtitle = selectedOrder == null
        ? l10n.cashierSelectOrderToPay
        : '₫${currency.format(selectedOrder!.totalAmount)}';

    return Row(
      children: [
        Expanded(
          child: _CashierCompactSwitchTile(
            key: const Key('cashier_compact_show_queue'),
            selected: showQueue,
            icon: Icons.pending_actions_rounded,
            title: l10n.cashierPendingStatus,
            subtitle: '$orderCount',
            onTap: onShowQueue,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _CashierCompactSwitchTile(
            key: const Key('cashier_compact_show_selected'),
            selected: !showQueue && selectedOrder != null,
            enabled: selectedOrder != null,
            icon: Icons.receipt_long_rounded,
            title: selectedOrder == null
                ? l10n.cashierSelectedAmount
                : l10n.cashierTableLabel(selectedOrder!.tableNumber),
            subtitle: selectedSubtitle,
            onTap: onShowSelected,
          ),
        ),
      ],
    );
  }
}

class _CashierCompactSwitchTile extends StatelessWidget {
  const _CashierCompactSwitchTile({
    super.key,
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
  });

  final bool selected;
  final bool enabled;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? Colors.white : PosColors.textPrimary;
    final mutedForeground = selected
        ? Colors.white.withValues(alpha: 0.82)
        : PosColors.textSecondary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? PosColors.accent : PosColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? PosColors.accent : PosColors.border,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, color: enabled ? foreground : PosColors.textMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: enabled ? foreground : PosColors.textMuted,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: enabled ? mutedForeground : PosColors.textMuted,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectedOrderView extends StatelessWidget {
  const _SelectedOrderView({
    required this.order,
    required this.selectedMethod,
    required this.isAdmin,
    required this.canApplyDiscount,
    required this.isProcessing,
    required this.isOnline,
    required this.onSelectMethod,
    required this.onApplyDiscount,
    required this.onProcess,
    required this.onProcessSplit,
    required this.onCancelOrder,
    required this.onReprint,
  });

  final CashierOrder order;
  final String? selectedMethod;
  final bool isAdmin;
  final bool canApplyDiscount;
  final bool isProcessing;
  final bool isOnline;
  final ValueChanged<String> onSelectMethod;
  final Future<void> Function() onApplyDiscount;
  final Future<void> Function(String method) onProcess;
  final Future<void> Function() onProcessSplit;
  final Future<void> Function() onCancelOrder;
  final Future<void> Function() onReprint;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final regularMethods = <_PaymentMethod>[
      _PaymentMethod(
        paymentMethodCash,
        l10n.cashierCashMethod,
        Color(0xFF2E7D32),
        Icons.payments_rounded,
      ),
      _PaymentMethod(
        paymentMethodOther,
        l10n.cashierQrPaymentMethod,
        Color(0xFF8E44AD),
        Icons.qr_code_2_rounded,
      ),
      _PaymentMethod(
        paymentMethodCreditCard,
        l10n.cashierCardMethod,
        Color(0xFF1565C0),
        Icons.credit_card_rounded,
      ),
    ];
    final canCancelOrder = isAdmin && order.status.toLowerCase() != 'completed';
    final effectiveSelectedMethod =
        selectedMethod ?? (order.isStaffMeal ? paymentMethodService : null);
    final isServiceSelected = isServicePaymentMethod(
      effectiveSelectedMethod ?? '',
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final orderSummary = _CashierOrderSummarySurface(order: order);
        final paymentRail = _CashierPaymentRail(
          order: order,
          selectedMethod: effectiveSelectedMethod,
          regularMethods: regularMethods,
          isAdmin: isAdmin,
          canApplyDiscount: canApplyDiscount,
          isServiceSelected: isServiceSelected,
          isProcessing: isProcessing,
          isOnline: isOnline,
          canCancelOrder: canCancelOrder,
          onSelectMethod: onSelectMethod,
          onApplyDiscount: onApplyDiscount,
          onProcess: onProcess,
          onProcessSplit: onProcessSplit,
          onCancelOrder: onCancelOrder,
          onReprint: onReprint,
        );

        if (constraints.maxWidth < 1080) {
          return SingleChildScrollView(
            key: const Key('cashier_selected_order_scroll'),
            physics: const AlwaysScrollableScrollPhysics(
              parent: ClampingScrollPhysics(),
            ),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              children: [
                _CashierOrderSummarySurface(order: order, compact: true),
                const SizedBox(height: 12),
                _CashierPaymentRail(
                  order: order,
                  selectedMethod: effectiveSelectedMethod,
                  regularMethods: regularMethods,
                  isAdmin: isAdmin,
                  canApplyDiscount: canApplyDiscount,
                  isServiceSelected: isServiceSelected,
                  isProcessing: isProcessing,
                  isOnline: isOnline,
                  canCancelOrder: canCancelOrder,
                  expandMethodSection: false,
                  onSelectMethod: onSelectMethod,
                  onApplyDiscount: onApplyDiscount,
                  onProcess: onProcess,
                  onProcessSplit: onProcessSplit,
                  onCancelOrder: onCancelOrder,
                  onReprint: onReprint,
                ),
              ],
            ),
          );
        }

        return Row(
          children: [
            Expanded(flex: 6, child: orderSummary),
            const SizedBox(width: 16),
            SizedBox(width: 356, child: paymentRail),
          ],
        );
      },
    );
  }
}

class _CashierOrderSummarySurface extends StatelessWidget {
  const _CashierOrderSummarySurface({
    required this.order,
    this.compact = false,
  });

  final CashierOrder order;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final currency = NumberFormat('#,###', 'vi_VN');

    return ToastWorkSurface(
      key: const Key('cashier_payment_surface'),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                l10n.cashierCheckItems,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (order.isStaffMeal) ...[
                const SizedBox(width: 8),
                ToastStatusBadge(
                  key: const Key('staff_meal_badge'),
                  label: l10n.cashierStaffMealBadge,
                  color: PosColors.warning,
                  compact: true,
                ),
              ],
              const Spacer(),
              Text(
                l10n.cashierItemsCount(order.items.length),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: PosColors.textSecondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (compact)
            _CashierOrderItemsPanel(order: order, scrollable: false)
          else
            Expanded(child: _CashierOrderItemsPanel(order: order)),
          const SizedBox(height: 12),
          _AmountLine(
            label: l10n.cashierSubtotal,
            value: '₫${currency.format(order.menuSubtotal)}',
          ),
          if (order.serviceChargeTotal > 0)
            _AmountLine(
              label: l10n.cashierServiceCharge,
              value: '₫${currency.format(order.serviceChargeTotal)}',
            ),
          if (order.discountTotal > 0)
            _AmountLine(
              label: l10n.cashierDiscountSummary,
              value: '-₫${currency.format(order.discountTotal)}',
              valueColor: PosColors.success,
            ),
          const SizedBox(height: 4),
          _AmountLine(
            label: l10n.cashierPaymentDue,
            value: '₫${currency.format(order.remainingDue)}',
            prominent: true,
          ),
        ],
      ),
    );
  }
}

class _AmountLine extends StatelessWidget {
  const _AmountLine({
    required this.label,
    required this.value,
    this.valueColor,
    this.prominent = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: PosColors.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style:
                (prominent
                        ? PosNumericText.amountLarge
                        : PosNumericText.amountLine)
                    .copyWith(color: valueColor ?? PosColors.textPrimary),
          ),
        ],
      ),
    );
  }
}

class _CashierOrderItemsPanel extends StatelessWidget {
  const _CashierOrderItemsPanel({required this.order, this.scrollable = true});

  final CashierOrder order;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat('#,###', 'vi_VN');

    return Container(
      constraints: scrollable ? null : const BoxConstraints(minHeight: 160),
      decoration: BoxDecoration(
        color: PosSurfaceRole.background.fill,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: PosSurfaceRole.background.stroke),
      ),
      child: order.items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: ToastOperationalEmptyState(
                  headline: context.l10n.cashierCheckItems,
                  helper: context.l10n.cashierNoPayableOrdersMessage,
                  icon: Icons.receipt_long_outlined,
                ),
              ),
            )
          : ListView.separated(
              key: const Key('cashier_selected_order_items_list'),
              shrinkWrap: !scrollable,
              physics: scrollable ? null : const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              itemCount: order.items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final item = order.items[index];
                final itemName = item.label ?? context.l10n.cashierItemFallback;
                final lineTotal = item.unitPrice * item.quantity;
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: PosColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: PosColors.border),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: PosColors.accentMuted,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${item.quantity}',
                          style: PosNumericText.qtyUnit.copyWith(
                            color: PosColors.accent,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          itemName,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: PosColors.textPrimary,
                              ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '₫${currency.format(lineTotal)}',
                        style: PosNumericText.lineAmount.copyWith(
                          color: PosColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class _CashierPaymentRail extends StatelessWidget {
  const _CashierPaymentRail({
    required this.order,
    required this.selectedMethod,
    required this.regularMethods,
    required this.isAdmin,
    required this.canApplyDiscount,
    required this.isServiceSelected,
    required this.isProcessing,
    required this.isOnline,
    required this.canCancelOrder,
    this.expandMethodSection = true,
    required this.onSelectMethod,
    required this.onApplyDiscount,
    required this.onProcess,
    required this.onProcessSplit,
    required this.onCancelOrder,
    required this.onReprint,
  });

  final CashierOrder order;
  final String? selectedMethod;
  final List<_PaymentMethod> regularMethods;
  final bool isAdmin;
  final bool canApplyDiscount;
  final bool isServiceSelected;
  final bool isProcessing;
  final bool isOnline;
  final bool canCancelOrder;
  final bool expandMethodSection;
  final ValueChanged<String> onSelectMethod;
  final Future<void> Function() onApplyDiscount;
  final Future<void> Function(String method) onProcess;
  final Future<void> Function() onProcessSplit;
  final Future<void> Function() onCancelOrder;
  final Future<void> Function() onReprint;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final currency = NumberFormat('#,###', 'vi_VN');
    final serviceMethod = _PaymentMethod(
      paymentMethodService,
      l10n.cashierServiceAction,
      Color(0xFF0F766E),
      Icons.volunteer_activism_rounded,
    );
    final paymentOptions = order.isStaffMeal
        ? [serviceMethod]
        : [...regularMethods, if (isAdmin) serviceMethod];
    final selectedMethodData = selectedMethod == null
        ? null
        : paymentOptions.firstWhere((method) => method.value == selectedMethod);
    final selectedLabel = selectedMethodData?.label;
    final amountText = '₫${currency.format(order.remainingDue)}';
    final subtotalText = '₫${currency.format(order.menuSubtotal)}';
    final amountHelper = order.discountTotal > 0
        ? '${l10n.cashierSubtotal} $subtotalText · ${l10n.cashierDiscountSummary} -₫${currency.format(order.discountTotal)}'
        : '${l10n.cashierSubtotal} $subtotalText';
    final methodActions = _CashierPaymentActions(
      paymentOptions: paymentOptions,
      selectedMethod: selectedMethod,
      isServiceSelected: isServiceSelected,
      isProcessing: isProcessing,
      isOnline: isOnline,
      canCancelOrder: canCancelOrder,
      canApplyDiscount: canApplyDiscount && !order.isStaffMeal,
      canProcessSplit: !order.isStaffMeal && order.remainingDue > 0,
      scrollable: expandMethodSection,
      onSelectMethod: onSelectMethod,
      onApplyDiscount: onApplyDiscount,
      onProcessSplit: onProcessSplit,
      onCancelOrder: onCancelOrder,
      onReprint: onReprint,
    );
    final statusLabel = switch (order.status.toLowerCase()) {
      'pending' => l10n.cashierPendingStatus,
      'serving' => l10n.cashierPendingStatus,
      'completed' => l10n.cashierCompletedStatus,
      _ => l10n.cashierProcessingStatus,
    };

    Future<void> handlePayPressed() async {
      if (selectedMethod == null) {
        final method = await showDialog<String>(
          context: context,
          builder: (_) => _CashierPaymentMethodDialog(methods: paymentOptions),
        );
        if (method == null) {
          return;
        }

        onSelectMethod(method);
        return;
      }

      await onProcess(selectedMethod!);
    }

    final submitState = isProcessing
        ? PosActionTileState.processing
        : !isOnline
        ? PosActionTileState.offlineBlocked
        : PosActionTileState.idle;
    final submitLabel = selectedMethod == null
        ? l10n.cashierPaymentMethod
        : isServiceSelected
        ? l10n.cashierServiceNow
        : l10n.cashierCompletedStatus;
    final submitHelper = !isOnline
        ? PosDisabledCopy.forReason(l10n, PosActionDisabledReason.offline)
        : selectedLabel;

    return ToastWorkSurface(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: PosColors.mutedSurface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: PosColors.border),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: PosColors.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.receipt_long_rounded,
                    size: 18,
                    color: PosColors.accent,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        order.isStaffMeal
                            ? l10n.cashierStaffMealBadge
                            : l10n.cashierTableLabel(order.tableNumber),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: PosColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        order.isStaffMeal
                            ? l10n.cashierStaffMealServiceDefault
                            : l10n.cashierItemsCount(order.items.length),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: PosColors.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                ToastStatusBadge(
                  label: statusLabel,
                  color: order.status.toLowerCase() == 'completed'
                      ? PosColors.success
                      : PosColors.accent,
                  compact: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: const Key('cashier_selected_amount_button'),
              borderRadius: BorderRadius.circular(22),
              onTap: () => _showCashierOrderItemsSheet(context, order),
              child: Ink(
                child: Row(
                  children: [
                    Expanded(
                      child: PosAmountAnchor(
                        label: l10n.cashierPaymentDue,
                        amount: amountText,
                        helper: amountHelper,
                        role: PosSurfaceRole.selected,
                        amountStyle: PosNumericText.amountHero,
                      ),
                    ),
                    if (selectedLabel != null) ...[
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: PosSurfaceRole.selected.fill,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: PosSurfaceRole.selected.stroke,
                          ),
                        ),
                        child: Text(
                          selectedLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: PosSurfaceRole.selected.text,
                                fontWeight: FontWeight.w900,
                              ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (selectedMethod == null) ...[
            Text(
              key: const Key('cashier_payment_method_required_hint'),
              l10n.cashierPaymentMethod,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PosColors.warning,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
          ],
          SizedBox(
            width: double.infinity,
            child: PosActionTile(
              key: const Key('payment_submit_button'),
              label: submitLabel,
              helper: submitHelper,
              icon: PosActionIcons.processPayment,
              state: submitState,
              onTap: isProcessing || !isOnline
                  ? null
                  : () => unawaited(handlePayPressed()),
            ),
          ),
          const SizedBox(height: 12),
          if (expandMethodSection)
            Expanded(child: methodActions)
          else
            methodActions,
        ],
      ),
    );
  }
}

class _CashierPaymentActions extends StatelessWidget {
  const _CashierPaymentActions({
    required this.paymentOptions,
    required this.selectedMethod,
    required this.isServiceSelected,
    required this.isProcessing,
    required this.isOnline,
    required this.canCancelOrder,
    required this.canApplyDiscount,
    required this.canProcessSplit,
    required this.scrollable,
    required this.onSelectMethod,
    required this.onApplyDiscount,
    required this.onProcessSplit,
    required this.onCancelOrder,
    required this.onReprint,
  });

  final List<_PaymentMethod> paymentOptions;
  final String? selectedMethod;
  final bool isServiceSelected;
  final bool isProcessing;
  final bool isOnline;
  final bool canCancelOrder;
  final bool canApplyDiscount;
  final bool canProcessSplit;
  final bool scrollable;
  final ValueChanged<String> onSelectMethod;
  final Future<void> Function() onApplyDiscount;
  final Future<void> Function() onProcessSplit;
  final Future<void> Function() onCancelOrder;
  final Future<void> Function() onReprint;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.cashierPaymentMethod,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final tileWidth = constraints.maxWidth < 390
                ? constraints.maxWidth
                : (constraints.maxWidth - 10) / 2;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final method in paymentOptions)
                  SizedBox(
                    width: tileWidth,
                    child: _CashierMethodTile(
                      key: Key('cashier_method_tile_${method.value}'),
                      method: method,
                      selected: selectedMethod == method.value,
                      onTap: () => onSelectMethod(method.value),
                    ),
                  ),
              ],
            );
          },
        ),
        if (isServiceSelected) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: PosColors.warningMuted,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: PosColors.warning.withValues(alpha: 0.26),
              ),
            ),
            child: Text(
              l10n.cashierServiceProvisionRevenueHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PosColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        if (canApplyDiscount) ...[
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('cashier_discount_button'),
              onPressed: isProcessing || !isOnline ? null : onApplyDiscount,
              icon: const Icon(Icons.local_offer_outlined, size: 16),
              label: Text(l10n.cashierDiscountAction),
              style: OutlinedButton.styleFrom(
                foregroundColor: PosColors.accent,
                side: BorderSide(
                  color: PosColors.accent.withValues(alpha: 0.46),
                ),
                padding: const EdgeInsets.symmetric(vertical: 11),
                textStyle: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
        if (canProcessSplit) ...[
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('cashier_split_payment_button'),
              onPressed: isProcessing || !isOnline ? null : onProcessSplit,
              icon: const Icon(Icons.call_split_rounded, size: 16),
              label: Text(l10n.cashierSplitPaymentTitle),
              style: OutlinedButton.styleFrom(
                foregroundColor: PosColors.accent,
                side: BorderSide(
                  color: PosColors.accent.withValues(alpha: 0.36),
                ),
                padding: const EdgeInsets.symmetric(vertical: 11),
                textStyle: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: isProcessing ? null : onReprint,
                icon: const Icon(Icons.print_outlined, size: 16),
                label: Text(l10n.cashierReceipt),
                style: OutlinedButton.styleFrom(
                  foregroundColor: PosColors.textSecondary,
                  side: const BorderSide(color: PosColors.border),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  textStyle: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            if (canCancelOrder) ...[
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: isProcessing ? null : onCancelOrder,
                  icon: const Icon(Icons.cancel_outlined, size: 16),
                  label: Text(l10n.waiterCancelOrderAction),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: PosColors.danger,
                    side: BorderSide(
                      color: PosColors.danger.withValues(alpha: 0.42),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    textStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        if (!isOnline) ...[
          const SizedBox(height: 8),
          Text(
            context.l10n.cashierInternetRequired,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: PosColors.warning,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );

    if (!scrollable) {
      return content;
    }

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: ClampingScrollPhysics(),
      ),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: content,
    );
  }
}

Future<void> _showCashierOrderItemsSheet(
  BuildContext context,
  CashierOrder order,
) {
  final l10n = context.l10n;
  final currency = NumberFormat('#,###', 'vi_VN');

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: PosColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) {
      return SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.82,
          child: Padding(
            key: const Key('cashier_order_items_sheet'),
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.cashierCheckItems,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w900),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l10n.cashierTableLabel(order.tableNumber),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: PosColors.textSecondary,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(child: _CashierOrderItemsPanel(order: order)),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Text(
                      l10n.cashierSubtotal,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: PosColors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '₫${currency.format(order.totalAmount)}',
                      style: PosNumericText.amountLarge.copyWith(
                        color: PosColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _CashierPaymentMethodDialog extends StatelessWidget {
  const _CashierPaymentMethodDialog({required this.methods});

  final List<_PaymentMethod> methods;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return AlertDialog(
      title: Text(l10n.cashierPaymentMethod),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 360,
          maxHeight: MediaQuery.sizeOf(context).height * 0.62,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final method in methods) ...[
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: Key('cashier_method_dialog_${method.value}'),
                    onPressed: () => Navigator.of(context).pop(method.value),
                    icon: Icon(method.icon, size: 18),
                    label: Text(method.label),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      backgroundColor: method.color,
                      foregroundColor: Colors.white,
                      textStyle: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
                if (method != methods.last) const SizedBox(height: 10),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CashierMethodTile extends StatelessWidget {
  const _CashierMethodTile({
    super.key,
    required this.method,
    required this.selected,
    required this.onTap,
  });

  final _PaymentMethod method;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? PosColors.accentMuted : PosColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? PosColors.accent : PosColors.border,
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: PosColors.accent.withValues(alpha: 0.12),
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  ),
                ]
              : ToastElevationTokens.none,
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: selected ? Colors.white : PosColors.mutedSurface,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                method.icon,
                size: 18,
                color: selected ? method.color : PosColors.textSecondary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    method.label,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: selected
                          ? PosColors.accent
                          : PosColors.textPrimary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    selected
                        ? context.l10n.selected
                        : context.l10n.cashierPaymentMethod,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(
                Icons.check_circle_rounded,
                color: PosColors.accent,
                size: 18,
              ),
          ],
        ),
      ),
    );
  }
}

class _OrderStatusBadge extends StatelessWidget {
  const _OrderStatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final normalized = status.toLowerCase();
    final l10n = context.l10n;
    final color = switch (normalized) {
      'pending' => PosColors.warning,
      'confirmed' => PosColors.accent,
      'serving' => PosColors.accent,
      _ => PosColors.panelMuted,
    };
    final label = switch (normalized) {
      'pending' => l10n.cashierPendingStatus,
      'confirmed' => l10n.confirmed,
      'serving' => l10n.cashierPendingStatus,
      _ => normalized,
    };
    return ToastStatusChip(label: label, color: color);
  }
}

class _CashierSelectionPlaceholder extends StatelessWidget {
  const _CashierSelectionPlaceholder();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ToastWorkSurface(
      child: Center(
        child: ToastOperationalEmptyState(
          headline: l10n.cashierSelectTableTitle,
          helper: l10n.cashierSelectTableMessage,
          icon: Icons.table_bar_outlined,
        ),
      ),
    );
  }
}

class _CashierNoPayableOrdersPanel extends StatelessWidget {
  const _CashierNoPayableOrdersPanel({
    required this.title,
    required this.subtitle,
    required this.isOnline,
    required this.onRefresh,
  });

  final String title;
  final String subtitle;
  final bool isOnline;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return Container(
      key: const Key('cashier_no_payable_orders_operational_empty'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: PosSurfaceRole.background.fill,
        borderRadius: ToastRadiusTokens.md,
        border: Border.all(color: PosSurfaceRole.background.stroke),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.point_of_sale_outlined,
                color: isOnline ? PosColors.accent : PosColors.warning,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: PosSurfaceRole.background.text,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PosSurfaceRole.background.helper,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ToastStatusBadge(
                label: isOnline
                    ? l10n.cashierTerminalOnline
                    : l10n.cashierTerminalOffline,
                color: isOnline ? PosColors.success : PosColors.warning,
                compact: true,
              ),
              PosActionTile(
                label: l10n.refresh,
                helper: l10n.cashierSelectOrderToPay,
                icon: Icons.refresh_rounded,
                state: onRefresh == null
                    ? PosActionTileState.disabled
                    : PosActionTileState.idle,
                onTap: onRefresh,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SplitPaymentDialog extends StatefulWidget {
  const _SplitPaymentDialog({required this.totalAmount});

  final double totalAmount;

  @override
  State<_SplitPaymentDialog> createState() => _SplitPaymentDialogState();
}

class _SplitPaymentDialogState extends State<_SplitPaymentDialog> {
  late final List<_SplitPaymentDraft> _rows;

  static const _methods = <String>[
    paymentMethodCash,
    paymentMethodCreditCard,
    paymentMethodMomo,
    paymentMethodBankTransfer,
    paymentMethodOther,
  ];

  @override
  void initState() {
    super.initState();
    final half = (widget.totalAmount / 2).roundToDouble();
    _rows = [
      _SplitPaymentDraft(paymentMethodCash, half),
      _SplitPaymentDraft(paymentMethodOther, widget.totalAmount - half),
    ];
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  double get _sum => _rows.fold<double>(0, (sum, row) => sum + row.amount);

  void _submit() {
    final splits = _rows
        .where((row) => row.amount > 0)
        .map((row) => PaymentSplitInput(method: row.method, amount: row.amount))
        .toList();
    final error = validatePaymentSplits(splits, widget.totalAmount);
    if (error != null) {
      showErrorToast(context, error);
      return;
    }
    Navigator.of(context).pop(splits);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final currency = NumberFormat('#,###', 'vi_VN');
    final totalText = currency.format(widget.totalAmount);
    final remaining = widget.totalAmount - _sum;

    return AlertDialog(
      backgroundColor: PosColors.surface,
      title: Text(l10n.cashierSplitPaymentTitle),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l10n.cashierTotalLabel(totalText),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: PosColors.textPrimary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _rows.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final row = _rows[index];
                  return Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: row.method,
                          decoration: InputDecoration(
                            labelText: l10n.cashierMethodLabel,
                          ),
                          items: [
                            for (final method in _methods)
                              DropdownMenuItem(
                                value: method,
                                child: Text(paymentMethodDisplayLabel(method)),
                              ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() => row.method = value);
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: row.amountController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: l10n.cashierAmountLabel,
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      IconButton(
                        onPressed: _rows.length <= 2
                            ? null
                            : () {
                                setState(() {
                                  final removed = _rows.removeAt(index);
                                  removed.dispose();
                                });
                              },
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _rows.add(_SplitPaymentDraft(paymentMethodCash, 0));
                    });
                  },
                  icon: const Icon(Icons.add_circle_outline),
                  label: Text(l10n.cashierAddMethod),
                ),
                const Spacer(),
                Text(
                  '₫${currency.format(remaining)}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: remaining.abs() <= 0.01
                        ? PosColors.success
                        : PosColors.warning,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(l10n.cancel),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.call_split_rounded, size: 16),
          label: Text(l10n.cashierProcessSplit),
        ),
      ],
    );
  }
}

class _SplitPaymentDraft {
  _SplitPaymentDraft(this.method, double amount)
    : amountController = TextEditingController(text: amount.toStringAsFixed(0));

  String method;
  final TextEditingController amountController;

  double get amount {
    final normalized = amountController.text.replaceAll(',', '').trim();
    return double.tryParse(normalized) ?? 0;
  }

  void dispose() => amountController.dispose();
}

class _PaymentMethod {
  const _PaymentMethod(this.value, this.label, this.color, this.icon);

  final String value;
  final String label;
  final Color color;
  final IconData icon;
}
