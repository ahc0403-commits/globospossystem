import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/hardware/print_job_agent_service.dart';
import '../../core/i18n/locale_extensions.dart';
import '../../core/i18n/restaurant_cutoff_localization.dart';
import '../../core/models/pos_table.dart';
import '../../core/payments/cash_tender.dart';
import '../../core/payments/payment_method_contract.dart';
import '../../core/services/bank_transfer_alert_service.dart';
import '../../core/services/bank_transfer_alert_sound.dart';
import '../../core/services/bank_transfer_alert_coordinator.dart';
import '../../core/services/connectivity_service.dart';
import '../../core/services/live_refresh_service.dart';
import '../../core/services/menu_service.dart';
import '../../core/layout/platform_info.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../core/utils/permission_utils.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/error_toast.dart';
import '../../widgets/offline_banner.dart';
import '../auth/auth_provider.dart';
import '../order/order_model.dart';
import '../payment/payment_provider.dart';
import '../payment/einvoice_status_badge.dart';
import '../payment/einvoice_provider.dart';
import '../table/floor_layout.dart';
import '../table/table_provider.dart';
import '../../core/services/payment_service.dart';
import '../../core/services/payment_proof_service.dart';
import '../../core/services/restaurant_cutoff_service.dart';
import 'discount_modal.dart';
import 'cash_tender_dialog.dart';
import 'cashier_sold_out_dialog.dart';
import 'payment_proof_modal.dart';
import 'payment_completion_dialog.dart';
import 'red_invoice_modal.dart';

const _wetTissueUnitPrice = 2000;

class CashierScreen extends ConsumerStatefulWidget {
  const CashierScreen({
    super.key,
    this.paymentProofServiceOverride,
    this.paymentServiceOverride,
    this.restaurantCutoffServiceOverride,
    this.printJobAgentOverride,
    this.bankTransferAlertServiceOverride,
    this.bankTransferAlertSoundServiceOverride,
    this.menuServiceOverride,
    this.bankTransferAlertPollInterval = const Duration(seconds: 2),
  });

  final PaymentProofService? paymentProofServiceOverride;
  final PaymentService? paymentServiceOverride;
  final RestaurantCutoffService? restaurantCutoffServiceOverride;
  final PrintJobAgentService? printJobAgentOverride;
  final BankTransferAlertService? bankTransferAlertServiceOverride;
  final BankTransferAlertSoundService? bankTransferAlertSoundServiceOverride;
  final MenuService? menuServiceOverride;
  final Duration bankTransferAlertPollInterval;

  @override
  ConsumerState<CashierScreen> createState() => _CashierScreenState();
}

class _CashierScreenState extends ConsumerState<CashierScreen> {
  String? _selectedMethod;
  int _wetTissueDraftQuantity = 0;
  String? _wetTissueConfirmedOrderId;
  String? _initializedRestaurantId;
  String? _printAgentStoreId;
  String? _selectedTableId;
  Timer? _successTimer;
  String? _lastError;
  String? _lastCompletedOrderId; // for einvoice badge
  bool _isFlushingProofQueue = false;
  bool _hasAttemptedProofFlush = false;
  bool _showPaymentQueueOnCompact = true;
  bool _isCombinedPaymentMode = false;
  final Set<String> _combinedOrderIds = <String>{};
  bool _isOrderSearchLoading = false;
  final TextEditingController _orderSearchController = TextEditingController();
  CashierOrderSearchResult? _orderSearchResult;
  String? _orderSearchFeedback;
  late final ProviderSubscription<PaymentState> _paymentSub;
  late final PrintJobAgentService _printJobAgent;

  PaymentProofService get _paymentProofService =>
      widget.paymentProofServiceOverride ?? paymentProofService;
  PaymentService get _paymentService =>
      widget.paymentServiceOverride ?? paymentService;
  RestaurantCutoffService get _restaurantCutoffService =>
      widget.restaurantCutoffServiceOverride ?? restaurantCutoffService;

  Future<void> _showSoldOutMenuDialog(String storeId) async {
    await showDialog<void>(
      context: context,
      builder: (_) => CashierSoldOutDialog(
        storeId: storeId,
        menuServiceOverride: widget.menuServiceOverride,
      ),
    );
  }

  void _prepareWetTissueForOrder(CashierOrder order) {
    _wetTissueDraftQuantity = order.wetTissueQuantity;
    _wetTissueConfirmedOrderId = order.paymentCount > 0 ? order.orderId : null;
  }

  @override
  void initState() {
    super.initState();
    _printJobAgent = widget.printJobAgentOverride ?? PrintJobAgentService();
    _orderSearchController.addListener(() {
      if (!mounted) {
        return;
      }
      setState(() {
        _orderSearchResult = null;
        _orderSearchFeedback = null;
      });
    });
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
          showErrorToast(
            context,
            localizeRestaurantCutoffError(context.l10n, error),
          );
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
      final uploaded = await _paymentProofService.flushPendingUploads();
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
      ref.read(waiterTableProvider.notifier).loadTables(storeId);
    });
    if (PlatformInfo.isWindows && _printAgentStoreId != storeId) {
      _printJobAgent.stop();
      _printJobAgent.startPolling(storeId);
      _printAgentStoreId = storeId;
    }
  }

  void _refreshFromLiveEvent(String storeId, PosLiveEvent event) {
    if (!event.affects({
      'orders',
      'payments',
      'tables',
      'settings',
      'einvoice',
      'print',
    })) {
      return;
    }
    Future.microtask(() {
      ref.read(paymentProvider.notifier).loadOrders(storeId);
      ref
          .read(waiterTableProvider.notifier)
          .loadTables(storeId, showLoading: false);
      ref.invalidate(einvoiceJobStatusProvider);
    });
  }

  @override
  void dispose() {
    _successTimer?.cancel();
    _printJobAgent.stop();
    _orderSearchController.dispose();
    _paymentSub.close();
    super.dispose();
  }

  Future<bool> _showCancelOrderDialog({required String tableNumber}) async {
    final l10n = context.l10n;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('cashier_cancel_order_dialog'),
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
            key: const Key('cashier_cancel_order_confirm_button'),
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

  void _showCancellationUndoSnackBar({
    required String message,
    required String restoredMessage,
    required Future<bool> Function() onUndo,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 6),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: l10n.cancellationUndoAction,
          onPressed: () async {
            final restored = await onUndo();
            if (restored && mounted) {
              showSuccessToast(context, restoredMessage);
            }
          },
        ),
      ),
    );
  }

  Future<Map<String, String>?> _showNonRevenueDialog() async {
    final l10n = context.l10n;
    final reasonController = TextEditingController();
    final staffNameController = TextEditingController();
    final pinController = TextEditingController();
    var type = 'staff_meal';
    String? validationMessage;

    try {
      return await showDialog<Map<String, String>?>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setModalState) {
            final requiresStaffName = type == 'staff_meal';
            return AlertDialog(
              key: const Key('cashier_non_revenue_dialog'),
              title: Text(l10n.cashierServiceProvisionTitle),
              content: SizedBox(
                width: 480,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l10n.cashierServiceProvisionMessage,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: PosColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        key: const Key('cashier_non_revenue_type_input'),
                        initialValue: type,
                        decoration: InputDecoration(
                          labelText: l10n.cashierNonRevenueType,
                        ),
                        items: [
                          DropdownMenuItem(
                            value: 'staff_meal',
                            child: Text(l10n.cashierNonRevenueStaffMeal),
                          ),
                          DropdownMenuItem(
                            value: 'influencer_invite',
                            child: Text(l10n.cashierNonRevenueInfluencer),
                          ),
                          DropdownMenuItem(
                            value: 'customer_recovery',
                            child: Text(l10n.cashierNonRevenueRecovery),
                          ),
                          DropdownMenuItem(
                            value: 'tasting',
                            child: Text(l10n.cashierNonRevenueTasting),
                          ),
                          DropdownMenuItem(
                            value: 'other',
                            child: Text(l10n.cashierNonRevenueOther),
                          ),
                        ],
                        onChanged: (value) => setModalState(() {
                          type = value ?? 'staff_meal';
                          validationMessage = null;
                        }),
                      ),
                      if (requiresStaffName) ...[
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('cashier_non_revenue_staff_input'),
                          controller: staffNameController,
                          decoration: InputDecoration(
                            labelText: l10n.cashierNonRevenueStaffName,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('cashier_non_revenue_reason_input'),
                        controller: reasonController,
                        minLines: 2,
                        maxLines: 3,
                        decoration: InputDecoration(
                          labelText: l10n.cashierNonRevenueReason,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('cashier_non_revenue_pin_input'),
                        controller: pinController,
                        keyboardType: TextInputType.number,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: l10n.cashierDiscountManagerPin,
                        ),
                      ),
                      if (validationMessage != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          validationMessage!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: PosColors.danger,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(l10n.cancel),
                ),
                FilledButton.icon(
                  key: const Key('cashier_non_revenue_submit'),
                  onPressed: () {
                    final reason = reasonController.text.trim();
                    final staffName = staffNameController.text.trim();
                    final managerPin = pinController.text.trim();
                    if (reason.isEmpty ||
                        managerPin.isEmpty ||
                        (requiresStaffName && staffName.isEmpty)) {
                      setModalState(() {
                        validationMessage = l10n.cashierNonRevenueRequired;
                      });
                      return;
                    }
                    Navigator.of(dialogContext).pop({
                      'type': type,
                      'reason': reason,
                      'staffName': staffName,
                      'managerPin': managerPin,
                    });
                  },
                  icon: const Icon(Icons.volunteer_activism_rounded, size: 18),
                  label: Text(l10n.cashierNonRevenueComplete),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      await Future<void>.delayed(kThemeAnimationDuration);
      reasonController.dispose();
      staffNameController.dispose();
      pinController.dispose();
    }
  }

  Future<Map<String, String>?> _showServiceItemDialog({
    required bool isMarked,
  }) async {
    final l10n = context.l10n;
    final reasonController = TextEditingController();
    final pinController = TextEditingController();
    try {
      return await showDialog<Map<String, String>?>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return AlertDialog(
            key: const Key('cashier_service_item_dialog'),
            title: Text(
              isMarked
                  ? l10n.cashierServiceItemUnmarkTitle
                  : l10n.cashierServiceItemMarkTitle,
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const Key('cashier_service_item_reason_input'),
                  controller: reasonController,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: l10n.cashierServiceItemReason,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('cashier_service_item_pin_input'),
                  controller: pinController,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: l10n.cashierDiscountManagerPin,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                key: const Key('cashier_service_item_confirm'),
                onPressed: () {
                  final reason = reasonController.text.trim();
                  final pin = pinController.text.trim();
                  if (reason.isEmpty || pin.isEmpty) return;
                  Navigator.of(
                    context,
                  ).pop({'reason': reason, 'managerPin': pin});
                },
                child: Text(
                  isMarked
                      ? l10n.cashierServiceItemUnmarkAction
                      : l10n.cashierServiceItemMarkAction,
                ),
              ),
            ],
          );
        },
      );
    } finally {
      await Future<void>.delayed(kThemeAnimationDuration);
      reasonController.dispose();
      pinController.dispose();
    }
  }

  Future<List<PaymentSplitInput>?> _showSplitPaymentDialog({
    required double totalAmount,
  }) {
    return showDialog<List<PaymentSplitInput>?>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SplitPaymentDialog(
        key: const Key('cashier_split_payment_dialog'),
        totalAmount: totalAmount,
      ),
    );
  }

  List<_PaymentMethod> _regularPaymentMethods() {
    final l10n = context.l10n;
    return <_PaymentMethod>[
      _PaymentMethod(
        paymentMethodCash,
        l10n.cashierCashMethod,
        const Color(0xFF2E7D32),
        Icons.payments_rounded,
      ),
      _PaymentMethod(
        paymentMethodOther,
        l10n.cashierQrPaymentMethod,
        const Color(0xFF8E44AD),
        Icons.qr_code_2_rounded,
      ),
      _PaymentMethod(
        paymentMethodCreditCard,
        l10n.cashierCardMethod,
        const Color(0xFF1565C0),
        Icons.credit_card_rounded,
      ),
      _PaymentMethod(
        paymentMethodBankTransfer,
        l10n.cashierBankTransferMethod,
        const Color(0xFF0F766E),
        Icons.account_balance_rounded,
      ),
    ];
  }

  Future<void> _processCombinedTablePayment({
    required String storeId,
    required List<CashierOrder> orders,
    required PaymentNotifier notifier,
  }) async {
    final l10n = context.l10n;
    var paymentOrders = orders;
    if (orders.length < 2) {
      showErrorToast(context, l10n.cashierCombinedSelectAtLeastTwo);
      return;
    }
    if (!await _canCompleteRestaurantPayment(storeId)) {
      return;
    }
    if (!mounted) {
      return;
    }

    final wetTissueQuantities = await showDialog<Map<String, int>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CombinedTablePaymentDialog(
        key: const Key('cashier_combined_payment_dialog'),
        orders: orders,
      ),
    );
    if (wetTissueQuantities == null || !mounted) {
      return;
    }

    final prepared = await notifier.prepareCombinedTablePayment(
      storeId: storeId,
      wetTissueQuantities: {
        for (final order in orders)
          if (order.paymentCount == 0)
            order.orderId: wetTissueQuantities[order.orderId] ?? 0,
      },
    );
    if (!prepared || !mounted) {
      return;
    }
    final requestedIds = orders.map((order) => order.orderId).toSet();
    paymentOrders = ref
        .read(paymentProvider)
        .orders
        .where((order) => requestedIds.contains(order.orderId))
        .toList(growable: false);
    if (paymentOrders.length != orders.length) {
      showErrorToast(context, l10n.cashierCombinedOrderChanged);
      return;
    }

    final method = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CashierPaymentMethodDialog(
        key: const Key('cashier_combined_payment_method_dialog'),
        methods: _regularPaymentMethods(),
      ),
    );
    if (method == null || !mounted) {
      return;
    }

    final combinedTotal = paymentOrders.fold<double>(
      0,
      (sum, order) => sum + order.remainingDue,
    );
    CashTender? cashTender;
    if (method == paymentMethodCash) {
      cashTender = await showDialog<CashTender>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CashTenderDialog(
          key: const Key('cashier_combined_cash_tender_dialog'),
          amountDue: combinedTotal,
        ),
      );
      if (cashTender == null || !mounted) {
        return;
      }
    }

    final result = await notifier.processCombinedTablePayment(
      storeId,
      paymentOrders,
      method,
    );
    if (!mounted ||
        !ref.read(paymentProvider).paymentSuccess ||
        result == null) {
      return;
    }

    for (final order in paymentOrders) {
      await _printReceipt(order: order, method: method);
    }

    final rawPayments = result['payments'];
    final payments = rawPayments is List
        ? rawPayments
              .whereType<Map>()
              .map((payment) => Map<String, dynamic>.from(payment))
              .toList(growable: false)
        : const <Map<String, dynamic>>[];
    if (requiresPaymentProof(method) && payments.isNotEmpty && mounted) {
      final paymentId = payments.first['id']?.toString();
      if (paymentId != null) {
        await _paymentProofService.markProofRequired(
          paymentId: paymentId,
          storeId: storeId,
        );
        if (!mounted) return;
        await showDialog<PaymentProofSaveResult?>(
          context: context,
          barrierDismissible: false,
          builder: (_) => PaymentProofModal(
            key: const Key('cashier_combined_payment_proof_dialog'),
            paymentId: paymentId,
            storeId: storeId,
            methodLabel: paymentMethodDisplayLabel(method),
          ),
        );
      }
    }

    for (final order in paymentOrders) {
      if (!mounted) return;
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => RedInvoiceModal(
          key: Key('cashier_combined_red_invoice_${order.orderId}'),
          orderId: order.orderId,
          storeId: storeId,
        ),
      );
    }

    if (!mounted) return;
    setState(() {
      _combinedOrderIds.clear();
      _isCombinedPaymentMode = false;
      _selectedMethod = null;
      _showPaymentQueueOnCompact = true;
    });
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CombinedPaymentCompletionDialog(
        key: const Key('cashier_combined_payment_completion_dialog'),
        orders: paymentOrders,
        totalAmount: combinedTotal,
        paymentMethod: method,
        cashTender: cashTender,
        onReprint: () async {
          for (final order in paymentOrders) {
            await _printReceipt(order: order, method: method, reprint: true);
          }
        },
      ),
    );
    if (mounted) {
      unawaited(
        ref
            .read(waiterTableProvider.notifier)
            .loadTables(storeId, showLoading: false),
      );
    }
  }

  Future<void> _showPaymentCompletion({
    required CashierOrder order,
    required String paymentMethod,
    CashTender? cashTender,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PaymentCompletionDialog(
        order: order,
        paymentMethod: paymentMethod,
        cashTender: cashTender,
        onReprint: () => _printReceipt(
          order: order,
          method: paymentMethod,
          cashTender: cashTender,
          reprint: true,
        ),
      ),
    );
  }

  Future<void> _handleOrderSearch({
    required String? storeId,
    required PaymentNotifier notifier,
  }) async {
    final query = _orderSearchController.text.trim();
    if (query.isEmpty || _isOrderSearchLoading) {
      return;
    }
    if (storeId == null) {
      showErrorToast(context, 'Store context missing.');
      return;
    }

    setState(() {
      _isOrderSearchLoading = true;
      _orderSearchResult = null;
      _orderSearchFeedback = null;
    });

    try {
      final result = await notifier.searchActiveOrderForCashier(
        storeId: storeId,
        query: query,
      );
      if (!mounted) {
        return;
      }

      if (result == null) {
        setState(() {
          _orderSearchFeedback = 'No active order found for "$query".';
          _isOrderSearchLoading = false;
        });
        return;
      }

      if (!result.isPayable) {
        setState(() {
          _orderSearchResult = result;
          _orderSearchFeedback =
              'Kitchen in progress. This order will appear here when every active item is ready.';
          _isOrderSearchLoading = false;
        });
        return;
      }

      var payableOrder = _findCashierOrderById(
        ref.read(paymentProvider).orders,
        result.orderId,
      );
      if (payableOrder == null) {
        await notifier.loadOrders(storeId);
        payableOrder = _findCashierOrderById(
          ref.read(paymentProvider).orders,
          result.orderId,
        );
      }

      if (!mounted) {
        return;
      }

      if (payableOrder == null) {
        setState(() {
          _orderSearchResult = result;
          _orderSearchFeedback =
              'Kitchen in progress. This order is not payable yet.';
          _isOrderSearchLoading = false;
        });
        return;
      }

      setState(() {
        _selectedMethod = null;
        _prepareWetTissueForOrder(payableOrder!);
        _showPaymentQueueOnCompact = false;
        _orderSearchResult = result;
        _orderSearchFeedback = 'Order ready for cashier payment.';
        _isOrderSearchLoading = false;
      });
      notifier.selectOrder(payableOrder);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _orderSearchFeedback = 'Order search failed. Please retry.';
        _isOrderSearchLoading = false;
      });
      showErrorToast(context, 'Order search failed: $error');
    }
  }

  Future<void> _printReceipt({
    required CashierOrder order,
    required String method,
    CashTender? cashTender,
    bool reprint = false,
  }) async {
    final l10n = context.l10n;
    try {
      final job = await _paymentService.enqueueReceiptPrintJob(
        orderId: order.orderId,
        receivedAmount: cashTender?.receivedAmount,
        reprint: reprint,
      );
      if (!mounted) return;
      final status = job['status']?.toString();
      if (status == 'pending' || status == 'printing' || status == 'done') {
        showSuccessToast(context, l10n.cashierReceiptQueued);
      } else {
        showErrorToast(context, l10n.cashierReceiptPrintFailed);
      }
    } catch (_) {
      if (mounted) {
        showErrorToast(context, l10n.cashierReceiptPrintFailed);
      }
    }
  }

  Future<bool> _canCompleteRestaurantPayment(String storeId) async {
    try {
      final cutoff = await _restaurantCutoffService.fetchState(storeId);
      if (cutoff.canCompletePayment) {
        return true;
      }
      if (mounted) {
        showErrorToast(context, context.l10n.restaurantDailySalesClosed);
      }
      return false;
    } catch (_) {
      // Advisory preflight only; the payment RPC remains authoritative.
      return true;
    }
  }

  void _selectCashierTable({
    required PosTable table,
    required PaymentState paymentState,
    required PaymentNotifier notifier,
  }) {
    CashierOrder? payableOrder;
    for (final order in paymentState.orders) {
      if (order.tableId == table.id) {
        payableOrder = order;
        break;
      }
    }

    setState(() {
      _selectedTableId = table.id;
      if (payableOrder != null) {
        _selectedMethod = null;
        _prepareWetTissueForOrder(payableOrder);
        _showPaymentQueueOnCompact = false;
      }
    });
    if (payableOrder != null) notifier.selectOrder(payableOrder);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final authState = ref.watch(authProvider);
    final storeId = authState.storeId;
    if (storeId != null) {
      ref.listen<AsyncValue<PosLiveEvent>>(posLiveEventsProvider(storeId), (
        _,
        next,
      ) {
        next.whenData((event) => _refreshFromLiveEvent(storeId, event));
      });
    }
    final role = authState.role ?? '';
    final isAdmin = PermissionUtils.isAdminLike(role);
    final canCancelOrders = role == 'cashier' || isAdmin;
    final canProcessNonRevenue = role == 'cashier' || isAdmin;
    final canApplyDiscount = PermissionUtils.hasPermission(
      role,
      authState.extraPermissions,
      'discount_apply',
    );
    final canManageServiceItems = isAdmin || canApplyDiscount;
    _ensureLoaded(storeId);
    final cutoffState = storeId == null
        ? const RestaurantCutoffState.unrestricted()
        : ref.watch(restaurantCutoffStateProvider(storeId)).valueOrNull ??
              const RestaurantCutoffState.unrestricted();

    final paymentState = ref.watch(paymentProvider);
    final tableState = ref.watch(waiterTableProvider);
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
    final wetTissueConfirmed =
        selectedOrder == null ||
        selectedOrder.isStaffMeal ||
        selectedOrder.paymentCount > 0 ||
        _wetTissueConfirmedOrderId == selectedOrder.orderId;
    final queueTotalAmount = paymentState.orders.fold<double>(
      0,
      (sum, order) => sum + order.remainingDue,
    );
    final orderSearchQuery = _orderSearchController.text.trim();
    final visiblePaymentOrders = _filterCashierOrders(
      paymentState.orders,
      orderSearchQuery,
    );
    final combinedOrders = paymentState.orders
        .where((order) => _combinedOrderIds.contains(order.orderId))
        .toList(growable: false);
    final combinedTotal = combinedOrders.fold<double>(
      0,
      (sum, order) => sum + order.remainingDue,
    );
    final queuePane = PosDataPanel(
      key: const Key('cashier_pending_payment_list'),
      title: l10n.cashierPendingStatus,
      subtitle: l10n.cashierSelectOrderToPay,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_isCombinedPaymentMode && selectedOrder != null) ...[
            ToastStatusBadge(
              label: l10n.selected,
              color: PosColors.accent,
              compact: true,
            ),
          ],
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton.icon(
            key: const Key('cashier_combined_payment_mode'),
            onPressed: paymentState.isProcessing
                ? null
                : () {
                    setState(() {
                      _isCombinedPaymentMode = !_isCombinedPaymentMode;
                      _combinedOrderIds.clear();
                      if (_isCombinedPaymentMode) {
                        _selectedMethod = null;
                      }
                    });
                  },
            icon: Icon(
              _isCombinedPaymentMode
                  ? Icons.close_rounded
                  : Icons.call_merge_rounded,
              size: 18,
            ),
            label: Text(
              _isCombinedPaymentMode
                  ? l10n.cancel
                  : l10n.cashierCombinedPayment,
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: _isCombinedPaymentMode
                  ? PosColors.danger
                  : PosColors.accent,
              minimumSize: const Size.fromHeight(44),
              textStyle: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(height: 10),
          _CashierOrderSearchToolbar(
            controller: _orderSearchController,
            isSearching: _isOrderSearchLoading,
            onSearch: () =>
                _handleOrderSearch(storeId: storeId, notifier: notifier),
            onClear: () => _orderSearchController.clear(),
          ),
          if (_orderSearchFeedback != null) ...[
            const SizedBox(height: 10),
            _CashierOrderSearchFeedback(
              key: const Key('cashier_order_search_status'),
              result: _orderSearchResult,
              message: _orderSearchFeedback!,
            ),
          ],
          if (_isCombinedPaymentMode) ...[
            const SizedBox(height: 10),
            _CombinedPaymentSelectionBar(
              selectedCount: combinedOrders.length,
              totalAmount: combinedTotal,
              isProcessing: paymentState.isProcessing,
              onPay: storeId == null || combinedOrders.length < 2
                  ? null
                  : () => unawaited(
                      _processCombinedTablePayment(
                        storeId: storeId,
                        orders: combinedOrders,
                        notifier: notifier,
                      ),
                    ),
            ),
          ],
          const SizedBox(height: 12),
          Expanded(
            child: visiblePaymentOrders.isEmpty
                ? SingleChildScrollView(
                    child: _CashierNoPayableOrdersPanel(
                      title: l10n.cashierNoPayableOrdersTitle,
                      subtitle: orderSearchQuery.isEmpty
                          ? l10n.cashierNoPayableOrdersMessage
                          : 'No payable order in the cashier queue for "$orderSearchQuery".',
                      isOnline: isOnline,
                      onRefresh: storeId == null
                          ? null
                          : () => unawaited(notifier.loadOrders(storeId)),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: visiblePaymentOrders.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final order = visiblePaymentOrders[index];
                      final selected =
                          paymentState.selectedOrder?.orderId == order.orderId;
                      final combinedSelected = _combinedOrderIds.contains(
                        order.orderId,
                      );
                      void handleOrderTap() {
                        if (_isCombinedPaymentMode) {
                          if (order.isStaffMeal) {
                            showErrorToast(
                              context,
                              l10n.cashierCombinedCustomerOnly,
                            );
                            return;
                          }
                          setState(() {
                            if (combinedSelected) {
                              _combinedOrderIds.remove(order.orderId);
                            } else {
                              _combinedOrderIds.add(order.orderId);
                            }
                          });
                          return;
                        }
                        setState(() {
                          _selectedMethod = null;
                          _prepareWetTissueForOrder(order);
                          _showPaymentQueueOnCompact = false;
                        });
                        notifier.selectOrder(order);
                      }

                      return KeyedSubtree(
                        key: Key('cashier_order_${order.orderId}'),
                        child: Row(
                          children: [
                            if (_isCombinedPaymentMode) ...[
                              Checkbox(
                                key: Key(
                                  'cashier_combined_order_${order.orderId}',
                                ),
                                value: combinedSelected,
                                onChanged: order.isStaffMeal
                                    ? null
                                    : (_) => handleOrderTap(),
                              ),
                              const SizedBox(width: 4),
                            ],
                            Expanded(
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final rowSelected = _isCombinedPaymentMode
                                      ? combinedSelected
                                      : selected;
                                  final rowKey = index == 0
                                      ? const Key('payment_first_candidate')
                                      : null;
                                  if (constraints.maxWidth < 320) {
                                    return _CashierCompactOrderRow(
                                      key: rowKey,
                                      order: order,
                                      currency: currency,
                                      selected: rowSelected,
                                      onTap: handleOrderTap,
                                    );
                                  }
                                  return PosDataGridRow(
                                    key: rowKey,
                                    selected: rowSelected,
                                    statusColor: rowSelected
                                        ? PosColors.accent
                                        : null,
                                    onTap: handleOrderTap,
                                    cells: [
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            '#${_shortCashierOrderId(order.orderId)}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: PosNumericText.orderId
                                                .copyWith(
                                                  color: PosColors.textPrimary,
                                                ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            _formatCashierOrderAge(
                                              context,
                                              order.createdAt,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  color:
                                                      PosColors.textSecondary,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                        ],
                                      ),
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            l10n.cashierTableLabel(
                                              order.tableNumber,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w800,
                                                ),
                                          ),
                                          const SizedBox(height: 2),
                                          Wrap(
                                            spacing: 6,
                                            runSpacing: 4,
                                            children: [
                                              _OrderStatusBadge(
                                                status: order.status,
                                              ),
                                              if (order.isQrOrder)
                                                ToastStatusBadge(
                                                  key: Key(
                                                    'cashier_qr_order_badge_${order.orderId}',
                                                  ),
                                                  label: 'QR',
                                                  color: PosColors.accent,
                                                  compact: true,
                                                ),
                                            ],
                                          ),
                                        ],
                                      ),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          l10n.cashierItemsCount(
                                            order.items.length,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
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
                                          style: PosNumericText.amountLine
                                              .copyWith(
                                                color: PosColors.accent,
                                              ),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
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
          padding: const EdgeInsets.all(8),
          child: selectedOrder == null
              ? _CashierTableOverview(
                  state: tableState,
                  selectedTableId: _selectedTableId,
                  onRetry: storeId == null
                      ? null
                      : () => ref
                            .read(waiterTableProvider.notifier)
                            .loadTables(storeId),
                  onTapTable: (table) => _selectCashierTable(
                    table: table,
                    paymentState: paymentState,
                    notifier: notifier,
                  ),
                )
              : _SelectedOrderView(
                  order: selectedOrder,
                  selectedMethod: _selectedMethod,
                  canCancelOrders: canCancelOrders,
                  canProcessNonRevenue: canProcessNonRevenue,
                  canApplyDiscount: canApplyDiscount,
                  canManageServiceItems: canManageServiceItems,
                  isProcessing: paymentState.isProcessing,
                  isOnline: isOnline,
                  canCompletePayment: cutoffState.canCompletePayment,
                  wetTissueQuantity: _wetTissueDraftQuantity,
                  wetTissueConfirmed: wetTissueConfirmed,
                  onWetTissueQuantityChanged: (quantity) {
                    setState(() {
                      _wetTissueDraftQuantity = quantity;
                      _wetTissueConfirmedOrderId = null;
                      _selectedMethod = null;
                    });
                  },
                  onConfirmWetTissue: (quantity) async {
                    if (storeId == null) {
                      return false;
                    }
                    final success = await notifier.setWetTissueQuantity(
                      storeId: storeId,
                      orderId: selectedOrder.orderId,
                      quantity: quantity,
                    );
                    if (success && mounted) {
                      setState(() {
                        _wetTissueConfirmedOrderId = selectedOrder.orderId;
                        _selectedMethod = null;
                      });
                    }
                    return success;
                  },
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
                        key: const Key('cashier_discount_dialog'),
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
                  onToggleServiceItem: (item) async {
                    final selectedOrder = paymentState.selectedOrder;
                    if (storeId == null || selectedOrder == null) {
                      return;
                    }
                    if (!isOnline) {
                      showErrorToast(
                        context,
                        context.l10n.cashierInternetRequired,
                      );
                      return;
                    }
                    final input = await _showServiceItemDialog(
                      isMarked: item.isServiceItem,
                    );
                    if (input == null) {
                      return;
                    }
                    final success = item.isServiceItem
                        ? await notifier.unmarkOrderItemService(
                            storeId: storeId,
                            itemId: item.id,
                            reason: input['reason'] ?? '',
                            managerPin: input['managerPin'] ?? '',
                          )
                        : await notifier.markOrderItemService(
                            storeId: storeId,
                            itemId: item.id,
                            reason: input['reason'] ?? '',
                            managerPin: input['managerPin'] ?? '',
                          );
                    if (success && context.mounted) {
                      showSuccessToast(
                        context,
                        item.isServiceItem
                            ? context.l10n.cashierServiceItemUnmarked
                            : context.l10n.cashierServiceItemMarked,
                      );
                    }
                  },
                  onCancelOrderItem: (item) async {
                    if (storeId == null || !canCancelOrders || !isOnline) {
                      return;
                    }
                    final cancelled = await notifier.cancelOrderItem(
                      item.id,
                      storeId,
                    );
                    if (cancelled && context.mounted) {
                      _showCancellationUndoSnackBar(
                        message: l10n.orderWorkspaceCancelItemAction,
                        restoredMessage: l10n.cancelledItemRestored,
                        onUndo: () => notifier.restoreCancelledOrderItem(
                          item.id,
                          storeId,
                        ),
                      );
                    }
                  },
                  onProcess: (method, cashTender) async {
                    final selectedOrder = paymentState.selectedOrder;
                    if (storeId == null || selectedOrder == null) {
                      return;
                    }
                    if (!wetTissueConfirmed) {
                      showErrorToast(
                        context,
                        context.l10n.cashierWetTissueRequired,
                      );
                      return;
                    }
                    if (!await _canCompleteRestaurantPayment(storeId)) {
                      return;
                    }
                    Map<String, String>? nonRevenueInput;
                    if (isServicePaymentMethod(method)) {
                      nonRevenueInput = await _showNonRevenueDialog();
                      if (nonRevenueInput == null) {
                        return;
                      }
                    }

                    final payment = nonRevenueInput == null
                        ? await notifier.processPayment(
                            storeId,
                            selectedOrder.orderId,
                            selectedOrder.remainingDue,
                            method,
                          )
                        : await notifier.processNonRevenuePayment(
                            storeId: storeId,
                            orderId: selectedOrder.orderId,
                            amount: selectedOrder.remainingDue,
                            type: nonRevenueInput['type'] ?? '',
                            reason: nonRevenueInput['reason'] ?? '',
                            staffName: nonRevenueInput['staffName'],
                            managerPin: nonRevenueInput['managerPin'] ?? '',
                          );
                    if (mounted && ref.read(paymentProvider).paymentSuccess) {
                      await _printReceipt(
                        order: selectedOrder,
                        method: method,
                        cashTender: cashTender,
                      );
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
                          await _paymentProofService.markProofRequired(
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
                                  key: const Key(
                                    'cashier_single_payment_proof_dialog',
                                  ),
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
                            key: const Key('cashier_single_red_invoice_dialog'),
                            orderId: selectedOrder.orderId,
                            storeId: storeId,
                          ),
                        );
                      }

                      if (context.mounted) {
                        await _showPaymentCompletion(
                          order: selectedOrder,
                          paymentMethod: method,
                          cashTender: cashTender,
                        );
                        if (context.mounted) {
                          unawaited(
                            ref
                                .read(waiterTableProvider.notifier)
                                .loadTables(storeId, showLoading: false),
                          );
                        }
                      }
                    }
                  },
                  onProcessSplit: () async {
                    final selectedOrder = paymentState.selectedOrder;
                    if (storeId == null || selectedOrder == null) {
                      return;
                    }
                    if (!wetTissueConfirmed) {
                      showErrorToast(
                        context,
                        context.l10n.cashierWetTissueRequired,
                      );
                      return;
                    }
                    if (!await _canCompleteRestaurantPayment(storeId)) {
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
                          await _paymentProofService.markProofRequired(
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
                              key: const Key(
                                'cashier_split_payment_proof_dialog',
                              ),
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
                            key: const Key('cashier_split_red_invoice_dialog'),
                            orderId: selectedOrder.orderId,
                            storeId: storeId,
                          ),
                        );
                      }

                      if (context.mounted) {
                        await _showPaymentCompletion(
                          order: selectedOrder,
                          paymentMethod: 'SPLIT',
                        );
                        if (context.mounted) {
                          unawaited(
                            ref
                                .read(waiterTableProvider.notifier)
                                .loadTables(storeId, showLoading: false),
                          );
                        }
                      }
                    }
                  },
                  onCancelOrder: () async {
                    final selectedOrder = paymentState.selectedOrder;
                    if (storeId == null ||
                        selectedOrder == null ||
                        !canCancelOrders) {
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
                      _showCancellationUndoSnackBar(
                        message: l10n.cashierOrderCancelled,
                        restoredMessage: l10n.cancelledOrderRestored,
                        onUndo: () => notifier.restoreCancelledOrder(
                          selectedOrder.orderId,
                          storeId,
                        ),
                      );
                    }
                  },
                  onReprint: () async {
                    final selectedOrder = paymentState.selectedOrder;
                    if (selectedOrder == null) {
                      return;
                    }
                    final method = _selectedMethod ?? paymentMethodCash;
                    await _printReceipt(
                      order: selectedOrder,
                      method: method,
                      reprint: true,
                    );
                  },
                  onBackToTables: () {
                    setState(() {
                      _selectedMethod = null;
                      _showPaymentQueueOnCompact = true;
                    });
                    notifier.clearSelection();
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

    final cashier = Scaffold(
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
                  ? 760
                  : 720,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final viewport = MediaQuery.sizeOf(context);
                  final forceScrollableCompact =
                      (viewport.width > viewport.height &&
                          viewport.height < 720) ||
                      MediaQuery.textScalerOf(context).scale(1) > 1.5;
                  final useWideLayout =
                      constraints.maxWidth >= 1180 && !forceScrollableCompact;
                  final useTabletSplit =
                      !useWideLayout &&
                      ((constraints.maxWidth >= 900 &&
                              constraints.maxHeight >= 720) ||
                          (constraints.maxWidth >= 760 &&
                              constraints.maxHeight >= 900)) &&
                      MediaQuery.textScalerOf(context).scale(1) <= 1.3;
                  final useCompactChrome = !useWideLayout;
                  final useDenseWideLayout =
                      useWideLayout && viewport.height < 900;
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
                        dense: useDenseWideLayout,
                        onManageSoldOut: storeId == null || !isOnline
                            ? null
                            : () => _showSoldOutMenuDialog(storeId),
                      ),
                      SizedBox(
                        height: useCompactChrome
                            ? 8
                            : useDenseWideLayout
                            ? 6
                            : 12,
                      ),
                      Expanded(
                        child: useWideLayout
                            ? Row(
                                children: [
                                  SizedBox(width: 348, child: queueWithHistory),
                                  const SizedBox(width: 16),
                                  Expanded(child: detailPane),
                                ],
                              )
                            : useTabletSplit
                            ? Row(
                                key: const Key('cashier_tablet_split_view'),
                                children: [
                                  SizedBox(
                                    width: constraints.maxWidth >= 900
                                        ? 300
                                        : 276,
                                    child: queueWithHistory,
                                  ),
                                  const SizedBox(width: 8),
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
    if (widget.bankTransferAlertServiceOverride != null ||
        widget.bankTransferAlertSoundServiceOverride != null) {
      return BankTransferAlertCoordinator(
        storeId: storeId,
        alertService: widget.bankTransferAlertServiceOverride,
        soundService: widget.bankTransferAlertSoundServiceOverride,
        pollInterval: widget.bankTransferAlertPollInterval,
        child: cashier,
      );
    }
    return cashier;
  }

  Widget _buildCashierCommandHeader({
    required int orderCount,
    required double queueTotalAmount,
    required CashierOrder? selectedOrder,
    required NumberFormat currency,
    required bool isOnline,
    required bool compact,
    required bool dense,
    required VoidCallback? onManageSoldOut,
  }) {
    final l10n = context.l10n;
    if (compact) {
      return _CashierCompactCommandBar(
        isOnline: isOnline,
        onManageSoldOut: onManageSoldOut,
      );
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
        Text(
          selectedOrder == null ? l10n.cashierSubtitle : l10n.cashierPaymentDue,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: PosColors.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
    final actions = <Widget>[
      const AppNavBar(showLogout: false),
      OutlinedButton.icon(
        key: const Key('cashier_sold_out_menu_action'),
        onPressed: onManageSoldOut,
        icon: const Icon(Icons.remove_shopping_cart_outlined, size: 20),
        label: Text(l10n.menuSoldOut),
      ),
      if (PlatformInfo.isKioskSupported)
        FilledButton.icon(
          key: const Key('cashier_attendance_kiosk_entry'),
          onPressed: () => context.go('/attendance-kiosk'),
          icon: const Icon(Icons.badge_outlined, size: 22),
          label: Text(l10n.attendance),
          style: FilledButton.styleFrom(
            minimumSize: const Size(112, 48),
            backgroundColor: PosColors.accent,
            foregroundColor: Colors.white,
            textStyle: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
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
      padding: EdgeInsets.fromLTRB(14, dense ? 6 : 10, 14, dense ? 6 : 10),
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
              SizedBox(height: dense ? 4 : 8),
              ToastMetricStrip(
                dense: dense,
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
  const _CashierCompactCommandBar({
    required this.isOnline,
    required this.onManageSoldOut,
  });

  final bool isOnline;
  final VoidCallback? onManageSoldOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;

    return ToastWorkSurface(
      key: const Key('cashier_compact_command_bar'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      backgroundColor: PosColors.surface,
      child: Row(
        children: [
          const AppNavBar(showLogout: false),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Text(
                    l10n.cashierTitle,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: PosColors.textPrimary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ToastStatusBadge(
                    label: isOnline
                        ? l10n.cashierTerminalOnline
                        : l10n.cashierTerminalOffline,
                    color: isOnline ? PosColors.success : PosColors.warning,
                    compact: true,
                  ),
                ],
              ),
            ),
          ),
          if (PlatformInfo.isKioskSupported) ...[
            const SizedBox(width: 6),
            FilledButton.icon(
              key: const Key('cashier_compact_attendance_kiosk_entry'),
              onPressed: () => context.go('/attendance-kiosk'),
              icon: const Icon(Icons.badge_outlined, size: 22),
              label: Text(l10n.attendance),
              style: FilledButton.styleFrom(
                minimumSize: const Size(112, 48),
                backgroundColor: PosColors.accent,
                foregroundColor: Colors.white,
                textStyle: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ],
          IconButton(
            key: const Key('cashier_sold_out_menu_action'),
            onPressed: onManageSoldOut,
            icon: const Icon(Icons.remove_shopping_cart_outlined),
            tooltip: l10n.menuSoldOut,
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

class _CashierCompactOrderRow extends StatelessWidget {
  const _CashierCompactOrderRow({
    super.key,
    required this.order,
    required this.currency,
    required this.selected,
    required this.onTap,
  });

  final CashierOrder order;
  final NumberFormat currency;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? PosColors.accentMuted : PosColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? PosColors.accent : PosColors.border,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.cashierTableLabel(order.tableNumber),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '₫${currency.format(order.remainingDue)}',
                    maxLines: 1,
                    style: PosNumericText.amountLine.copyWith(
                      color: selected
                          ? PosColors.accent
                          : PosColors.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '#${_shortCashierOrderId(order.orderId)} · '
                      '${_formatCashierOrderAge(context, order.createdAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PosColors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.cashierItemsCount(order.items.length),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
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

CashierOrder? _findCashierOrderById(List<CashierOrder> orders, String orderId) {
  for (final order in orders) {
    if (order.orderId == orderId) {
      return order;
    }
  }
  return null;
}

List<CashierOrder> _filterCashierOrders(
  List<CashierOrder> orders,
  String query,
) {
  final normalizedQuery = _normalizeCashierOrderSearch(query);
  if (normalizedQuery.isEmpty) {
    return orders;
  }

  return orders.where((order) {
    final haystack = [
      order.orderId,
      _shortCashierOrderId(order.orderId),
      order.tableNumber,
      if (order.isQrOrder) 'qr',
    ].map(_normalizeCashierOrderSearch).join(' ');
    return haystack.contains(normalizedQuery);
  }).toList();
}

String _normalizeCashierOrderSearch(String raw) {
  return raw.trim().replaceAll('#', '').toLowerCase();
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
    required this.canCancelOrders,
    required this.canProcessNonRevenue,
    required this.canApplyDiscount,
    required this.canManageServiceItems,
    required this.isProcessing,
    required this.isOnline,
    required this.canCompletePayment,
    required this.wetTissueQuantity,
    required this.wetTissueConfirmed,
    required this.onWetTissueQuantityChanged,
    required this.onConfirmWetTissue,
    required this.onSelectMethod,
    required this.onApplyDiscount,
    required this.onToggleServiceItem,
    required this.onCancelOrderItem,
    required this.onProcess,
    required this.onProcessSplit,
    required this.onCancelOrder,
    required this.onReprint,
    required this.onBackToTables,
  });

  final CashierOrder order;
  final String? selectedMethod;
  final bool canCancelOrders;
  final bool canProcessNonRevenue;
  final bool canApplyDiscount;
  final bool canManageServiceItems;
  final bool isProcessing;
  final bool isOnline;
  final bool canCompletePayment;
  final int wetTissueQuantity;
  final bool wetTissueConfirmed;
  final ValueChanged<int> onWetTissueQuantityChanged;
  final Future<bool> Function(int quantity) onConfirmWetTissue;
  final ValueChanged<String> onSelectMethod;
  final Future<void> Function() onApplyDiscount;
  final Future<void> Function(OrderItem item) onToggleServiceItem;
  final Future<void> Function(OrderItem item) onCancelOrderItem;
  final Future<void> Function(String method, CashTender? cashTender) onProcess;
  final Future<void> Function() onProcessSplit;
  final Future<void> Function() onCancelOrder;
  final Future<void> Function() onReprint;
  final VoidCallback onBackToTables;

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
      _PaymentMethod(
        paymentMethodBankTransfer,
        l10n.cashierBankTransferMethod,
        Color(0xFF0F766E),
        Icons.account_balance_rounded,
      ),
    ];
    final canCancelOrder =
        canCancelOrders &&
        order.status.toLowerCase() != 'completed' &&
        order.paymentCount == 0;
    final effectiveSelectedMethod =
        selectedMethod ?? (order.isStaffMeal ? paymentMethodService : null);
    final isServiceSelected = isServicePaymentMethod(
      effectiveSelectedMethod ?? '',
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final dense =
            constraints.maxWidth >= 1080 && constraints.maxHeight < 1100;
        final orderSummary = _CashierOrderSummarySurface(
          order: order,
          dense: dense,
          canManageServiceItems: canManageServiceItems,
          canCancelItems: canCancelOrders,
          isProcessing: isProcessing,
          isOnline: isOnline,
          onToggleServiceItem: onToggleServiceItem,
          onCancelOrderItem: onCancelOrderItem,
        );
        final paymentRail = _CashierPaymentRail(
          order: order,
          selectedMethod: effectiveSelectedMethod,
          regularMethods: regularMethods,
          canProcessNonRevenue: canProcessNonRevenue,
          canApplyDiscount: canApplyDiscount,
          isServiceSelected: isServiceSelected,
          isProcessing: isProcessing,
          isOnline: isOnline,
          canCompletePayment: canCompletePayment,
          canCancelOrder: canCancelOrder,
          wetTissueQuantity: wetTissueQuantity,
          wetTissueConfirmed: wetTissueConfirmed,
          onWetTissueQuantityChanged: onWetTissueQuantityChanged,
          onConfirmWetTissue: onConfirmWetTissue,
          onSelectMethod: onSelectMethod,
          onApplyDiscount: onApplyDiscount,
          onProcess: onProcess,
          onProcessSplit: onProcessSplit,
          onCancelOrder: onCancelOrder,
          onReprint: onReprint,
          dense: dense,
        );

        final content = constraints.maxWidth < 1080
            ? SingleChildScrollView(
                key: const Key('cashier_selected_order_scroll'),
                physics: const AlwaysScrollableScrollPhysics(
                  parent: ClampingScrollPhysics(),
                ),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  children: [
                    _CashierOrderSummarySurface(
                      order: order,
                      compact: true,
                      canManageServiceItems: canManageServiceItems,
                      canCancelItems: canCancelOrders,
                      isProcessing: isProcessing,
                      isOnline: isOnline,
                      onToggleServiceItem: onToggleServiceItem,
                      onCancelOrderItem: onCancelOrderItem,
                    ),
                    const SizedBox(height: 12),
                    _CashierPaymentRail(
                      order: order,
                      selectedMethod: effectiveSelectedMethod,
                      regularMethods: regularMethods,
                      canProcessNonRevenue: canProcessNonRevenue,
                      canApplyDiscount: canApplyDiscount,
                      isServiceSelected: isServiceSelected,
                      isProcessing: isProcessing,
                      isOnline: isOnline,
                      canCompletePayment: canCompletePayment,
                      canCancelOrder: canCancelOrder,
                      wetTissueQuantity: wetTissueQuantity,
                      wetTissueConfirmed: wetTissueConfirmed,
                      onWetTissueQuantityChanged: onWetTissueQuantityChanged,
                      onConfirmWetTissue: onConfirmWetTissue,
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
              )
            : Row(
                children: [
                  Expanded(flex: 6, child: orderSummary),
                  SizedBox(width: dense ? 10 : 16),
                  SizedBox(width: 420, child: paymentRail),
                ],
              );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('cashier_back_to_all_tables'),
                onPressed: isProcessing ? null : onBackToTables,
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
                label: Text(l10n.cashierSelectTableTitle),
                style: dense
                    ? OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      )
                    : null,
              ),
            ),
            SizedBox(height: dense ? 5 : 10),
            Expanded(child: content),
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
    this.dense = false,
    this.canManageServiceItems = false,
    this.canCancelItems = false,
    this.isProcessing = false,
    this.isOnline = true,
    this.onToggleServiceItem,
    this.onCancelOrderItem,
  });

  final CashierOrder order;
  final bool compact;
  final bool dense;
  final bool canManageServiceItems;
  final bool canCancelItems;
  final bool isProcessing;
  final bool isOnline;
  final Future<void> Function(OrderItem item)? onToggleServiceItem;
  final Future<void> Function(OrderItem item)? onCancelOrderItem;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final currency = NumberFormat('#,###', 'vi_VN');
    final itemsPanel = _CashierOrderItemsPanel(
      order: order,
      scrollable: !compact,
      dense: dense,
      canManageServiceItems: canManageServiceItems,
      canCancelItems: canCancelItems,
      isProcessing: isProcessing,
      isOnline: isOnline,
      onToggleServiceItem: onToggleServiceItem,
      onCancelOrderItem: onCancelOrderItem,
    );

    return ToastWorkSurface(
      key: const Key('cashier_payment_surface'),
      padding: EdgeInsets.all(dense ? 10 : 18),
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
          SizedBox(height: dense ? 6 : 12),
          if (compact) itemsPanel else Expanded(child: itemsPanel),
          SizedBox(height: dense ? 6 : 12),
          _AmountLine(
            label: l10n.cashierSubtotal,
            value: '₫${currency.format(order.menuSubtotal)}',
          ),
          if (order.serviceChargeTotal > 0)
            _AmountLine(
              label: l10n.cashierServiceCharge,
              value: '₫${currency.format(order.serviceChargeTotal)}',
            ),
          if (order.fixedChargeTotal > 0)
            _AmountLine(
              label: l10n.cashierWetTissueCharge,
              value: '₫${currency.format(order.fixedChargeTotal)}',
            ),
          if (order.serviceItemTotal > 0)
            _AmountLine(
              label: l10n.cashierServiceItemFooter(order.serviceItemCount),
              value: '₫${currency.format(order.serviceItemTotal)}',
              valueColor: PosColors.warning,
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
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: PosColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                value,
                maxLines: 1,
                style:
                    (prominent
                            ? PosNumericText.amountLarge
                            : PosNumericText.amountLine)
                        .copyWith(color: valueColor ?? PosColors.textPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CashierOrderItemsPanel extends StatelessWidget {
  const _CashierOrderItemsPanel({
    required this.order,
    this.scrollable = true,
    this.dense = false,
    this.canManageServiceItems = false,
    this.canCancelItems = false,
    this.isProcessing = false,
    this.isOnline = true,
    this.onToggleServiceItem,
    this.onCancelOrderItem,
  });

  final CashierOrder order;
  final bool scrollable;
  final bool dense;
  final bool canManageServiceItems;
  final bool canCancelItems;
  final bool isProcessing;
  final bool isOnline;
  final Future<void> Function(OrderItem item)? onToggleServiceItem;
  final Future<void> Function(OrderItem item)? onCancelOrderItem;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final currency = NumberFormat('#,###', 'vi_VN');
    final billableMenuItemCount = order.items
        .where(
          (item) =>
              item.status.toLowerCase() != 'cancelled' &&
              item.itemType.toLowerCase() == 'menu_item' &&
              !item.isServiceItem,
        )
        .length;

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
              padding: EdgeInsets.all(dense ? 8 : 16),
              itemCount: order.items.length,
              separatorBuilder: (_, _) => SizedBox(height: dense ? 6 : 12),
              itemBuilder: (context, index) {
                final item = order.items[index];
                final itemName = item.label ?? l10n.cashierItemFallback;
                final translatedNames = _cashierTranslatedItemNames(
                  item,
                  itemName,
                );
                final lineTotal = item.unitPrice * item.quantity;
                final itemType = item.itemType.toLowerCase();
                final isCancelled = item.status.toLowerCase() == 'cancelled';
                final isMenuItem = itemType == 'menu_item';
                final canCancelItem =
                    canCancelItems &&
                    !isProcessing &&
                    isOnline &&
                    order.paymentCount == 0 &&
                    isMenuItem &&
                    !isCancelled &&
                    const {
                      'pending',
                      'preparing',
                      'ready',
                    }.contains(item.status.toLowerCase()) &&
                    onCancelOrderItem != null;
                final canToggleServiceItem =
                    canManageServiceItems &&
                    !isProcessing &&
                    isOnline &&
                    !order.isStaffMeal &&
                    order.paymentCount == 0 &&
                    isMenuItem &&
                    !isCancelled &&
                    onToggleServiceItem != null &&
                    (item.isServiceItem || billableMenuItemCount > 1);
                return Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: dense ? 6 : 12,
                  ),
                  decoration: BoxDecoration(
                    color: PosColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: PosColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
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
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  itemName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        color: PosColors.textPrimary,
                                      ),
                                ),
                                for (final translatedName
                                    in translatedNames) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    translatedName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: PosColors.textSecondary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ],
                                if (item.isServiceItem) ...[
                                  const SizedBox(height: 6),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: ToastStatusBadge(
                                      key: const Key(
                                        'cashier_service_item_badge',
                                      ),
                                      label: l10n.cashierServiceItemBadge,
                                      color: PosColors.warning,
                                      compact: true,
                                    ),
                                  ),
                                  if ((item.serviceReason ?? '')
                                      .isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      item.serviceReason!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: PosColors.textSecondary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ],
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                item.isServiceItem
                                    ? l10n.cashierServiceItemExcluded
                                    : '₫${currency.format(lineTotal)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: PosNumericText.lineAmount.copyWith(
                                  color: item.isServiceItem
                                      ? PosColors.warning
                                      : PosColors.textPrimary,
                                ),
                              ),
                              if (item.isServiceItem)
                                Text(
                                  '₫${currency.format(lineTotal)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: PosColors.textMuted,
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                            ],
                          ),
                        ],
                      ),
                      if (isMenuItem) ...[
                        const SizedBox(height: 8),
                        const Divider(height: 1),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          alignment: WrapAlignment.end,
                          children: [
                            OutlinedButton.icon(
                              key: ValueKey(
                                'cashier_cancel_order_item_${item.id}',
                              ),
                              onPressed: canCancelItem
                                  ? () => onCancelOrderItem!(item)
                                  : null,
                              icon: const Icon(Icons.cancel_outlined, size: 18),
                              label: Text(l10n.orderWorkspaceCancelItemAction),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: PosColors.danger,
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                            OutlinedButton.icon(
                              key: ValueKey(
                                'cashier_service_item_action_${item.id}',
                              ),
                              onPressed: canToggleServiceItem
                                  ? () => onToggleServiceItem!(item)
                                  : null,
                              icon: Icon(
                                item.isServiceItem
                                    ? Icons.undo_rounded
                                    : Icons.volunteer_activism_rounded,
                                size: 18,
                              ),
                              label: Text(
                                item.isServiceItem
                                    ? l10n.cashierServiceItemUnmarkAction
                                    : l10n.cashierServiceItemMarkAction,
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: item.isServiceItem
                                    ? PosColors.warning
                                    : PosColors.accent,
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
    );
  }
}

List<String> _cashierTranslatedItemNames(OrderItem item, String primaryName) {
  final names = <String>[];
  final normalizedPrimary = primaryName.trim().toLowerCase();
  for (final candidate in [item.nameVi, item.nameEn]) {
    final name = candidate?.trim() ?? '';
    if (name.isEmpty || name.toLowerCase() == normalizedPrimary) continue;
    if (names.any((existing) => existing.toLowerCase() == name.toLowerCase())) {
      continue;
    }
    names.add(name);
  }
  return names;
}

class _CashierPaymentRail extends StatelessWidget {
  const _CashierPaymentRail({
    required this.order,
    required this.selectedMethod,
    required this.regularMethods,
    required this.canProcessNonRevenue,
    required this.canApplyDiscount,
    required this.isServiceSelected,
    required this.isProcessing,
    required this.isOnline,
    required this.canCompletePayment,
    required this.canCancelOrder,
    required this.wetTissueQuantity,
    required this.wetTissueConfirmed,
    required this.onWetTissueQuantityChanged,
    required this.onConfirmWetTissue,
    this.expandMethodSection = true,
    required this.onSelectMethod,
    required this.onApplyDiscount,
    required this.onProcess,
    required this.onProcessSplit,
    required this.onCancelOrder,
    required this.onReprint,
    this.dense = false,
  });

  final CashierOrder order;
  final String? selectedMethod;
  final List<_PaymentMethod> regularMethods;
  final bool canProcessNonRevenue;
  final bool canApplyDiscount;
  final bool isServiceSelected;
  final bool isProcessing;
  final bool isOnline;
  final bool canCompletePayment;
  final bool canCancelOrder;
  final int wetTissueQuantity;
  final bool wetTissueConfirmed;
  final ValueChanged<int> onWetTissueQuantityChanged;
  final Future<bool> Function(int quantity) onConfirmWetTissue;
  final bool expandMethodSection;
  final ValueChanged<String> onSelectMethod;
  final Future<void> Function() onApplyDiscount;
  final Future<void> Function(String method, CashTender? cashTender) onProcess;
  final Future<void> Function() onProcessSplit;
  final Future<void> Function() onCancelOrder;
  final Future<void> Function() onReprint;
  final bool dense;

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
        : [
            ...regularMethods,
            if (canProcessNonRevenue && order.paymentCount == 0) serviceMethod,
          ];
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
      canCompletePayment: canCompletePayment,
      paymentMethodsEnabled: wetTissueConfirmed,
      canCancelOrder: canCancelOrder,
      canApplyDiscount: canApplyDiscount && !order.isStaffMeal,
      canProcessSplit: !order.isStaffMeal && order.remainingDue > 0,
      scrollable: expandMethodSection,
      dense: dense,
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
          builder: (_) => _CashierPaymentMethodDialog(
            key: const Key('cashier_payment_method_dialog'),
            methods: paymentOptions,
          ),
        );
        if (method == null) {
          return;
        }

        onSelectMethod(method);
        return;
      }

      CashTender? cashTender;
      if (selectedMethod == paymentMethodCash) {
        cashTender = await showDialog<CashTender>(
          context: context,
          barrierDismissible: false,
          builder: (_) => CashTenderDialog(amountDue: order.remainingDue),
        );
        if (cashTender == null) return;
      }

      await onProcess(selectedMethod!, cashTender);
    }

    final submitState = isProcessing
        ? PosActionTileState.processing
        : !wetTissueConfirmed
        ? PosActionTileState.disabled
        : !canCompletePayment
        ? PosActionTileState.disabled
        : !isOnline
        ? PosActionTileState.offlineBlocked
        : PosActionTileState.idle;
    final submitLabel = selectedMethod == null
        ? l10n.cashierPaymentMethod
        : isServiceSelected
        ? l10n.cashierServiceNow
        : l10n.cashierCompletedStatus;
    final submitHelper = !canCompletePayment
        ? l10n.restaurantDailySalesClosed
        : !wetTissueConfirmed
        ? l10n.cashierWetTissueRequired
        : !isOnline
        ? PosDisabledCopy.forReason(l10n, PosActionDisabledReason.offline)
        : selectedLabel;

    return ToastWorkSurface(
      padding: EdgeInsets.all(dense ? 8 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: dense ? 8 : 12,
              vertical: dense ? 5 : 10,
            ),
            decoration: BoxDecoration(
              color: PosColors.mutedSurface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: PosColors.border),
            ),
            child: Row(
              children: [
                Container(
                  width: dense ? 28 : 36,
                  height: dense ? 28 : 36,
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
          SizedBox(height: dense ? 6 : 12),
          if (!order.isStaffMeal) ...[
            _WetTissueQuantityControl(
              dense: dense,
              quantity: wetTissueQuantity,
              confirmed: wetTissueConfirmed,
              isProcessing: isProcessing,
              isOnline: isOnline,
              onQuantityChanged: onWetTissueQuantityChanged,
              onConfirm: onConfirmWetTissue,
            ),
            SizedBox(height: dense ? 6 : 12),
          ],
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
                      child: dense
                          ? Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: PosSurfaceRole.selected.fill,
                                borderRadius: ToastRadiusTokens.md,
                                border: Border.all(
                                  color: PosSurfaceRole.selected.stroke,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          l10n.cashierPaymentDue,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: PosSurfaceRole
                                                    .selected
                                                    .helper,
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                        Text(
                                          amountHelper,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: PosSurfaceRole
                                                    .selected
                                                    .helper,
                                                fontSize: 10,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerRight,
                                      child: Text(
                                        amountText,
                                        maxLines: 1,
                                        style: PosNumericText.amountLarge
                                            .copyWith(
                                              color:
                                                  PosSurfaceRole.selected.text,
                                            ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : PosAmountAnchor(
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
          SizedBox(height: dense ? 6 : 14),
          if (selectedMethod == null && !dense) ...[
            Text(
              key: const Key('cashier_payment_method_required_hint'),
              l10n.cashierPaymentMethod,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PosColors.warning,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: dense ? 4 : 8),
          ],
          if (expandMethodSection)
            Expanded(child: methodActions)
          else
            methodActions,
          SizedBox(height: dense ? 6 : 12),
          SizedBox(
            width: double.infinity,
            child: PosActionTile(
              key: const Key('payment_submit_button'),
              label: submitLabel,
              helper: dense ? null : submitHelper,
              icon: PosActionIcons.processPayment,
              state: submitState,
              onTap:
                  isProcessing ||
                      !isOnline ||
                      !canCompletePayment ||
                      !wetTissueConfirmed
                  ? null
                  : () => unawaited(handlePayPressed()),
            ),
          ),
        ],
      ),
    );
  }
}

class _WetTissueQuantityControl extends StatelessWidget {
  const _WetTissueQuantityControl({
    this.dense = false,
    required this.quantity,
    required this.confirmed,
    required this.isProcessing,
    required this.isOnline,
    required this.onQuantityChanged,
    required this.onConfirm,
  });

  final int quantity;
  final bool dense;
  final bool confirmed;
  final bool isProcessing;
  final bool isOnline;
  final ValueChanged<int> onQuantityChanged;
  final Future<bool> Function(int quantity) onConfirm;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final currency = NumberFormat('#,###', 'vi_VN');
    final enabled = !isProcessing && isOnline;
    final total = quantity * _wetTissueUnitPrice;

    return Container(
      key: const Key('cashier_wet_tissue_control'),
      width: double.infinity,
      padding: EdgeInsets.all(dense ? 6 : 12),
      decoration: BoxDecoration(
        color: confirmed ? PosColors.successMuted : PosColors.warningMuted,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: (confirmed ? PosColors.success : PosColors.warning).withValues(
            alpha: 0.38,
          ),
        ),
      ),
      child: dense
          ? Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.cashierWetTissueTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(
                                    color: PosColors.textPrimary,
                                    fontWeight: FontWeight.w900,
                                  ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '₫${currency.format(total)}',
                            key: const Key('cashier_wet_tissue_total'),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: PosColors.textPrimary,
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                        ],
                      ),
                      Text(
                        confirmed
                            ? l10n.cashierWetTissueUnitPrice
                            : l10n.cashierWetTissueRequired,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        key: confirmed
                            ? null
                            : const Key('cashier_wet_tissue_required_hint'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: confirmed
                              ? PosColors.textSecondary
                              : PosColors.warning,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.outlined(
                  key: const Key('cashier_wet_tissue_decrement'),
                  tooltip: '-',
                  onPressed: enabled && quantity > 0
                      ? () => onQuantityChanged(quantity - 1)
                      : null,
                  icon: const Icon(Icons.remove_rounded, size: 18),
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(36),
                    maximumSize: const Size.square(36),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                SizedBox(
                  width: 34,
                  child: Text(
                    '$quantity',
                    key: const Key('cashier_wet_tissue_quantity'),
                    textAlign: TextAlign.center,
                    style: PosNumericText.amountLine.copyWith(
                      color: PosColors.textPrimary,
                    ),
                  ),
                ),
                IconButton.filledTonal(
                  key: const Key('cashier_wet_tissue_increment'),
                  tooltip: '+',
                  onPressed: enabled && quantity < 100
                      ? () => onQuantityChanged(quantity + 1)
                      : null,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(36),
                    maximumSize: const Size.square(36),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 110,
                  child: FilledButton(
                    key: const Key('cashier_wet_tissue_confirm'),
                    onPressed: enabled && !confirmed
                        ? () => unawaited(onConfirm(quantity))
                        : null,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      confirmed
                          ? l10n.cashierWetTissueConfirmed
                          : l10n.cashierWetTissueConfirm,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.cashierWetTissueTitle,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: PosColors.textPrimary,
                                  fontWeight: FontWeight.w900,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            l10n.cashierWetTissueUnitPrice,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: PosColors.textSecondary,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '₫${currency.format(total)}',
                      key: const Key('cashier_wet_tissue_total'),
                      style: PosNumericText.amountLine.copyWith(
                        color: PosColors.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    IconButton.outlined(
                      key: const Key('cashier_wet_tissue_decrement'),
                      tooltip: '-',
                      onPressed: enabled && quantity > 0
                          ? () => onQuantityChanged(quantity - 1)
                          : null,
                      icon: const Icon(Icons.remove_rounded),
                    ),
                    SizedBox(
                      width: 56,
                      child: Text(
                        '$quantity',
                        key: const Key('cashier_wet_tissue_quantity'),
                        textAlign: TextAlign.center,
                        style: PosNumericText.amountLine.copyWith(
                          color: PosColors.textPrimary,
                        ),
                      ),
                    ),
                    IconButton.filledTonal(
                      key: const Key('cashier_wet_tissue_increment'),
                      tooltip: '+',
                      onPressed: enabled && quantity < 100
                          ? () => onQuantityChanged(quantity + 1)
                          : null,
                      icon: const Icon(Icons.add_rounded),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        key: const Key('cashier_wet_tissue_confirm'),
                        onPressed: enabled && !confirmed
                            ? () => unawaited(onConfirm(quantity))
                            : null,
                        icon: Icon(
                          confirmed
                              ? Icons.check_circle_rounded
                              : Icons.done_rounded,
                          size: 18,
                        ),
                        label: Text(
                          confirmed
                              ? l10n.cashierWetTissueConfirmed
                              : l10n.cashierWetTissueConfirm,
                        ),
                      ),
                    ),
                  ],
                ),
                if (!confirmed) ...[
                  const SizedBox(height: 8),
                  Text(
                    l10n.cashierWetTissueRequired,
                    key: const Key('cashier_wet_tissue_required_hint'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.warning,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
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
    required this.canCompletePayment,
    required this.paymentMethodsEnabled,
    required this.canCancelOrder,
    required this.canApplyDiscount,
    required this.canProcessSplit,
    required this.scrollable,
    this.dense = false,
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
  final bool canCompletePayment;
  final bool paymentMethodsEnabled;
  final bool canCancelOrder;
  final bool canApplyDiscount;
  final bool canProcessSplit;
  final bool scrollable;
  final bool dense;
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
        SizedBox(height: dense ? 4 : 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final spacing = dense ? 6.0 : 10.0;
            final tileWidth = dense
                ? (constraints.maxWidth - (spacing * 2)) / 3
                : constraints.maxWidth < 390
                ? constraints.maxWidth
                : (constraints.maxWidth - spacing) / 2;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final method in paymentOptions)
                  SizedBox(
                    width: tileWidth,
                    child: _CashierMethodTile(
                      key: Key('cashier_method_tile_${method.value}'),
                      method: method,
                      selected: selectedMethod == method.value,
                      dense: dense,
                      onTap: paymentMethodsEnabled
                          ? () => onSelectMethod(method.value)
                          : null,
                    ),
                  ),
              ],
            );
          },
        ),
        if (isServiceSelected) ...[
          SizedBox(height: dense ? 6 : 10),
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
        SizedBox(height: dense ? 6 : 10),
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
                minimumSize: Size(0, dense ? 40 : 48),
                tapTargetSize: dense
                    ? MaterialTapTargetSize.shrinkWrap
                    : MaterialTapTargetSize.padded,
              ),
            ),
          ),
          SizedBox(height: dense ? 6 : 10),
        ],
        if (canProcessSplit) ...[
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('cashier_split_payment_button'),
              onPressed:
                  isProcessing ||
                      !isOnline ||
                      !canCompletePayment ||
                      !paymentMethodsEnabled
                  ? null
                  : onProcessSplit,
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
                minimumSize: Size(0, dense ? 40 : 48),
                tapTargetSize: dense
                    ? MaterialTapTargetSize.shrinkWrap
                    : MaterialTapTargetSize.padded,
              ),
            ),
          ),
          SizedBox(height: dense ? 6 : 10),
        ],
        Row(
          children: [
            if (PlatformInfo.isPrinterSupported)
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: isProcessing ? null : onReprint,
                  icon: const Icon(Icons.print_outlined, size: 16),
                  label: Text(l10n.cashierReceipt),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: PosColors.textSecondary,
                    side: const BorderSide(color: PosColors.border),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    textStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    minimumSize: Size(0, dense ? 40 : 48),
                    tapTargetSize: dense
                        ? MaterialTapTargetSize.shrinkWrap
                        : MaterialTapTargetSize.padded,
                  ),
                ),
              ),
            if (canCancelOrder) ...[
              if (PlatformInfo.isPrinterSupported) const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('cashier_cancel_order_action'),
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
                    minimumSize: Size(0, dense ? 40 : 48),
                    tapTargetSize: dense
                        ? MaterialTapTargetSize.shrinkWrap
                        : MaterialTapTargetSize.padded,
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
  const _CashierPaymentMethodDialog({super.key, required this.methods});

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
    this.dense = false,
    this.onTap,
  });

  final _PaymentMethod method;
  final bool selected;
  final bool dense;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: double.infinity,
        constraints: BoxConstraints(minHeight: dense ? 46 : 76),
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 8 : 14,
          vertical: dense ? 5 : 14,
        ),
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
              width: dense ? 30 : 44,
              height: dense ? 30 : 44,
              decoration: BoxDecoration(
                color: selected ? Colors.white : PosColors.mutedSurface,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                method.icon,
                size: dense ? 18 : 22,
                color: selected ? method.color : PosColors.textSecondary,
              ),
            ),
            SizedBox(width: dense ? 6 : 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    method.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: selected
                          ? PosColors.accent
                          : PosColors.textPrimary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  if (!dense) ...[
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

class _CashierOrderSearchToolbar extends StatelessWidget {
  const _CashierOrderSearchToolbar({
    required this.controller,
    required this.isSearching,
    required this.onSearch,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool isSearching;
  final VoidCallback onSearch;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final hasQuery = controller.text.trim().isNotEmpty;
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const Key('cashier_order_search'),
            controller: controller,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => onSearch(),
            decoration: InputDecoration(
              labelText: 'Order or table search',
              hintText: '8-char order code or table number',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: hasQuery
                  ? IconButton(
                      key: const Key('cashier_order_search_clear'),
                      tooltip: 'Clear search',
                      onPressed: onClear,
                      icon: const Icon(Icons.close_rounded),
                    )
                  : null,
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          key: const Key('cashier_order_search_action'),
          tooltip: 'Search order',
          onPressed: isSearching ? null : onSearch,
          icon: isSearching
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.manage_search_rounded),
        ),
      ],
    );
  }
}

class _CashierOrderSearchFeedback extends StatelessWidget {
  const _CashierOrderSearchFeedback({
    super.key,
    required this.result,
    required this.message,
  });

  final CashierOrderSearchResult? result;
  final String message;

  @override
  Widget build(BuildContext context) {
    final result = this.result;
    final color = result == null
        ? PosColors.warning
        : result.isPayable
        ? PosColors.success
        : PosColors.info;

    return PosExceptionAlert(
      label: result == null
          ? 'Order search'
          : '#${result.orderCode} · Table ${result.tableNumber}',
      detail: result == null
          ? message
          : '$message ${result.isQrOrder ? 'QR order.' : 'Staff order.'}',
      color: color,
      icon: result == null
          ? Icons.search_off_rounded
          : result.isPayable
          ? Icons.point_of_sale_rounded
          : Icons.restaurant_menu_rounded,
    );
  }
}

class _CashierTableOverview extends StatelessWidget {
  const _CashierTableOverview({
    required this.state,
    required this.selectedTableId,
    required this.onRetry,
    required this.onTapTable,
  });

  final WaiterTableState state;
  final String? selectedTableId;
  final VoidCallback? onRetry;
  final ValueChanged<PosTable> onTapTable;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (state.isLoading && state.tables.isEmpty) {
      return const ToastWorkSurface(
        key: Key('cashier_all_tables_loading'),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (state.error != null && state.tables.isEmpty) {
      return ToastWorkSurface(
        key: const Key('cashier_all_tables_error'),
        child: Center(
          child: _CashierTableStatusMessage(
            title: l10n.cashierSelectTableTitle,
            helper: state.error!,
            icon: Icons.sync_problem_rounded,
            onRetry: onRetry,
          ),
        ),
      );
    }

    if (state.tables.isEmpty) {
      return ToastWorkSurface(
        key: const Key('cashier_all_tables_empty'),
        child: Center(
          child: _CashierTableStatusMessage(
            title: l10n.waiterNoTablesTitle,
            helper: l10n.waiterNoTablesSubtitle,
            icon: Icons.table_restaurant_outlined,
            onRetry: onRetry,
          ),
        ),
      );
    }

    final occupiedCount = state.tables
        .where((table) => table.isOccupied)
        .length;
    return PosDataPanel(
      key: const Key('cashier_all_tables_overview'),
      title: l10n.cashierSelectTableTitle,
      subtitle: l10n.waiterTapTableToStart,
      trailing: Wrap(
        spacing: 6,
        children: [
          ToastStatusBadge(
            label: '${state.tables.length}',
            color: PosColors.info,
            compact: true,
          ),
          ToastStatusBadge(
            label: '$occupiedCount',
            color: PosColors.warning,
            compact: true,
          ),
        ],
      ),
      child: FloorLayoutView(
        tables: state.tables,
        selectedTableId: selectedTableId,
        orderPreviewByTableId: state.orderPreviewByTableId,
        onTapTable: onTapTable,
        editable: false,
        fitAllTables: true,
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
      ),
    );
  }
}

class _CashierTableStatusMessage extends StatelessWidget {
  const _CashierTableStatusMessage({
    required this.title,
    required this.helper,
    required this.icon,
    required this.onRetry,
  });

  final String title;
  final String helper;
  final IconData icon;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 36, color: PosColors.textMuted),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: PosColors.textPrimary,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          helper,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: PosColors.textSecondary),
        ),
        if (onRetry != null) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(context.l10n.retry),
          ),
        ],
      ],
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

class _CombinedPaymentSelectionBar extends StatelessWidget {
  const _CombinedPaymentSelectionBar({
    required this.selectedCount,
    required this.totalAmount,
    required this.isProcessing,
    required this.onPay,
  });

  final int selectedCount;
  final double totalAmount;
  final bool isProcessing;
  final VoidCallback? onPay;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final currency = NumberFormat('#,###', 'vi_VN');
    return Container(
      key: const Key('cashier_combined_payment_selection_bar'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PosColors.accentMuted,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PosColors.accent.withValues(alpha: 0.35)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final summary = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.cashierCombinedSelectedCount(selectedCount),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: PosColors.textPrimary,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '₫${currency.format(totalAmount)}',
                style: PosNumericText.amountLine.copyWith(
                  color: PosColors.accent,
                ),
              ),
            ],
          );
          final payButton = FilledButton.icon(
            key: const Key('cashier_combined_payment_start'),
            onPressed: isProcessing ? null : onPay,
            icon: isProcessing
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.payments_rounded, size: 18),
            label: Text(l10n.cashierCombinedPayNow),
          );
          if (constraints.maxWidth < 340) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [summary, const SizedBox(height: 8), payButton],
            );
          }
          return Row(
            children: [
              Expanded(child: summary),
              const SizedBox(width: 8),
              payButton,
            ],
          );
        },
      ),
    );
  }
}

class _CombinedTablePaymentDialog extends StatefulWidget {
  const _CombinedTablePaymentDialog({super.key, required this.orders});

  final List<CashierOrder> orders;

  @override
  State<_CombinedTablePaymentDialog> createState() =>
      _CombinedTablePaymentDialogState();
}

class _CombinedTablePaymentDialogState
    extends State<_CombinedTablePaymentDialog> {
  late final Map<String, int> _wetTissueQuantities;

  @override
  void initState() {
    super.initState();
    _wetTissueQuantities = {
      for (final order in widget.orders) order.orderId: order.wetTissueQuantity,
    };
  }

  double get _adjustedTotal => widget.orders.fold<double>(0, (sum, order) {
    final quantity = _wetTissueQuantities[order.orderId] ?? 0;
    final wetTissueDifference = quantity - order.wetTissueQuantity;
    return sum +
        order.remainingDue +
        (wetTissueDifference * _wetTissueUnitPrice);
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final currency = NumberFormat('#,###', 'vi_VN');
    final dialogHeight = (230 + (widget.orders.length * 88))
        .clamp(360, 520)
        .toDouble();
    return AlertDialog(
      title: Text(l10n.cashierCombinedPayment),
      content: SizedBox(
        width: 520,
        height: dialogHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.cashierCombinedWetTissueHelp,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: PosColors.textSecondary),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.separated(
                itemCount: widget.orders.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final order = widget.orders[index];
                  final quantity = _wetTissueQuantities[order.orderId] ?? 0;
                  final canChange = order.paymentCount == 0;
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: PosColors.mutedSurface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: PosColors.border),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.cashierTableLabel(order.tableNumber),
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.w900),
                              ),
                              Text(
                                '₫${currency.format(order.remainingDue)}',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: PosColors.textSecondary,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        IconButton.outlined(
                          key: Key(
                            'cashier_combined_wet_tissue_minus_${order.orderId}',
                          ),
                          onPressed: canChange && quantity > 0
                              ? () => setState(() {
                                  _wetTissueQuantities[order.orderId] =
                                      quantity - 1;
                                })
                              : null,
                          icon: const Icon(Icons.remove_rounded, size: 18),
                        ),
                        SizedBox(
                          width: 44,
                          child: Text(
                            '$quantity',
                            textAlign: TextAlign.center,
                            style: PosNumericText.amountLine,
                          ),
                        ),
                        IconButton.filled(
                          key: Key(
                            'cashier_combined_wet_tissue_plus_${order.orderId}',
                          ),
                          onPressed: canChange
                              ? () => setState(() {
                                  _wetTissueQuantities[order.orderId] =
                                      quantity + 1;
                                })
                              : null,
                          icon: const Icon(Icons.add_rounded, size: 18),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 14),
            PosAmountAnchor(
              label: l10n.cashierCombinedTotal,
              amount: '₫${currency.format(_adjustedTotal)}',
              helper: l10n.cashierCombinedSelectedCount(widget.orders.length),
              role: PosSurfaceRole.selected,
              amountStyle: PosNumericText.amountHero,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton.icon(
          key: const Key('cashier_combined_payment_confirm'),
          onPressed: () => Navigator.of(context).pop(_wetTissueQuantities),
          icon: const Icon(Icons.check_rounded, size: 18),
          label: Text(l10n.cashierCombinedConfirmWetTissue),
        ),
      ],
    );
  }
}

class _CombinedPaymentCompletionDialog extends StatelessWidget {
  const _CombinedPaymentCompletionDialog({
    super.key,
    required this.orders,
    required this.totalAmount,
    required this.paymentMethod,
    required this.cashTender,
    required this.onReprint,
  });

  final List<CashierOrder> orders;
  final double totalAmount;
  final String paymentMethod;
  final CashTender? cashTender;
  final Future<void> Function() onReprint;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final currency = NumberFormat('#,###', 'vi_VN');
    final tableNumbers = orders.map((order) => order.tableNumber).join(', ');
    return AlertDialog(
      title: Text(l10n.cashierCombinedCompleted),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.cashierCombinedTables(tableNumbers),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: PosColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            PosAmountAnchor(
              label: l10n.cashierCombinedTotal,
              amount: '₫${currency.format(totalAmount)}',
              helper: paymentMethodDisplayLabel(paymentMethod),
              role: PosSurfaceRole.selected,
              amountStyle: PosNumericText.amountHero,
            ),
            if (cashTender != null) ...[
              const SizedBox(height: 10),
              Text(
                '${l10n.cashierCashReceived}: ₫${currency.format(cashTender!.receivedAmount)} · ${l10n.cashierCashChange}: ₫${currency.format(cashTender!.changeAmount)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: PosColors.textSecondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          key: const Key('cashier_combined_payment_reprint'),
          onPressed: () => unawaited(onReprint()),
          icon: const Icon(Icons.print_rounded, size: 18),
          label: Text(l10n.cashierReprint),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.confirm),
        ),
      ],
    );
  }
}

class _SplitPaymentDialog extends StatefulWidget {
  const _SplitPaymentDialog({super.key, required this.totalAmount});

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
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: l10n.cashierMethodLabel,
                          ),
                          items: [
                            for (final method in _methods)
                              DropdownMenuItem(
                                value: method,
                                child: Text(
                                  paymentMethodDisplayLabel(method),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
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
