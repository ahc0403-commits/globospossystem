import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/services/connectivity_service.dart';
import '../../core/layout/platform_info.dart';
import '../../core/hardware/printer_service.dart';
import '../../core/hardware/receipt_builder.dart';
import '../../core/ui/app_primitives.dart';
import '../../core/ui/toast/toast.dart';
import '../../core/utils/permission_utils.dart';
import '../../main.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/error_toast.dart';
import '../../widgets/offline_banner.dart';
import '../auth/auth_provider.dart';
import '../payment/payment_provider.dart';
import '../payment/einvoice_status_badge.dart';
import '../settings/printer_provider.dart';
import '../../core/services/payment_proof_service.dart';
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
        backgroundColor: AppColors.surface1,
        title: Text(
          l10n.cashierCancelOrderTitle,
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          l10n.cashierCancelOrderMessage(tableNumber),
          style: GoogleFonts.notoSansKr(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.waiterBack),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.statusCancelled,
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

  void _showTodaySummaryDialog(String storeId) {
    showDialog(
      context: context,
      builder: (context) => _CashierTodaySummaryDialog(storeId: storeId),
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
      return;
    }

    final bytes = await ReceiptBuilder.buildPaymentReceipt(
      restaurantName: 'GLOBOS POS',
      tableNumber: order.tableNumber,
      items: order.items
          .map(
            (item) => ReceiptItem(
              name: item.label ?? 'Item',
              quantity: item.quantity,
              unitPrice: item.unitPrice,
            ),
          )
          .toList(),
      totalAmount: order.totalAmount,
      paymentMethod: method,
      paidAt: DateTime.now(),
      isService: false,
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

    return Scaffold(
      key: const Key('cashier_root'),
      backgroundColor: AppColors.surface0,
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: Row(
              children: [
                Container(
                  width: 420,
                  decoration: const BoxDecoration(
                    color: AppColors.surface1,
                    border: Border(
                      right: BorderSide(color: AppColors.surface3),
                    ),
                  ),
                  child: Column(
                    children: [
                      Container(
                        height: 88,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            const AppNavBar(),
                            const SizedBox(width: 10),
                            Text(
                              l10n.cashierTitle,
                              style: AppTextStyles.operationalTitle(size: 28),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                l10n.cashierSubtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.notoSansKr(
                                  color: AppColors.textSecondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.summarize,
                                color: AppColors.textSecondary,
                              ),
                              tooltip: l10n.cashierTodaySettlement,
                              onPressed: storeId == null
                                  ? null
                                  : () => _showTodaySummaryDialog(storeId),
                            ),
                            IconButton(
                              key: const Key('logout_button'),
                              icon: const Icon(
                                Icons.logout,
                                color: AppColors.textSecondary,
                              ),
                              tooltip: l10n.logout,
                              onPressed: () async {
                                await ref.read(authProvider.notifier).logout();
                              },
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: paymentState.orders.isEmpty
                            ? ToastOperationalEmptyState(
                                headline: l10n.cashierNoPayableOrdersTitle,
                                helper: l10n.cashierNoPayableOrdersMessage,
                                icon: Icons.point_of_sale_outlined,
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  12,
                                  12,
                                ),
                                itemCount: paymentState.orders.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, index) {
                                  final order = paymentState.orders[index];
                                  final selected =
                                      paymentState.selectedOrder?.orderId ==
                                      order.orderId;
                                  return KeyedSubtree(
                                    key: Key('cashier_order_${order.orderId}'),
                                    child: InkWell(
                                    key: index == 0
                                        ? const Key('payment_first_candidate')
                                        : null,
                                    onTap: () {
                                      setState(() => _selectedMethod = null);
                                      notifier.selectOrder(order);
                                    },
                                    borderRadius: BorderRadius.circular(14),
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 220,
                                      ),
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        color: selected
                                            ? AppColors.surface0
                                            : AppColors.surface1,
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: selected
                                              ? AppColors.amber500
                                              : AppColors.surface2,
                                          width: selected ? 1.8 : 1,
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Table ${order.tableNumber}',
                                            style: GoogleFonts.bebasNeue(
                                              color: AppColors.textPrimary,
                                              fontSize: 34,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '₫${currency.format(order.totalAmount)}',
                                            style: GoogleFonts.bebasNeue(
                                              color: AppColors.amber500,
                                              fontSize: 24,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            l10n.cashierItemsCount(
                                              order.items.length,
                                            ),
                                            style: GoogleFonts.notoSansKr(
                                              color: AppColors.textSecondary,
                                              fontSize: 12,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          _OrderStatusBadge(
                                            status: order.status,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: paymentState.selectedOrder == null
                            ? ToastOperationalEmptyState(
                                headline: l10n.cashierSelectTableTitle,
                                helper: l10n.cashierSelectTableMessage,
                                icon: Icons.table_bar_outlined,
                              )
                            : _SelectedOrderView(
                                order: paymentState.selectedOrder!,
                                selectedMethod: _selectedMethod,
                                isAdmin: isAdmin,
                                isProcessing: paymentState.isProcessing,
                                isOnline: isOnline,
                                onSelectMethod: (method) {
                                  setState(() => _selectedMethod = method);
                                },
                                onProcess: () async {
                                  final method = _selectedMethod;
                                  final selectedOrder =
                                      paymentState.selectedOrder;
                                  if (storeId == null ||
                                      method == null ||
                                      selectedOrder == null) {
                                    return;
                                  }
                                  if (method == 'service') {
                                    final proceed =
                                        await _showServiceConfirmDialog();
                                    if (!proceed) {
                                      return;
                                    }
                                  }

                                  final payment = await notifier.processPayment(
                                    storeId,
                                    selectedOrder.orderId,
                                    selectedOrder.totalAmount,
                                    method,
                                  );
                                  if (mounted &&
                                      ref
                                          .read(paymentProvider)
                                          .paymentSuccess) {
                                    await _printReceipt(
                                      order: selectedOrder,
                                      method: method,
                                    );
                                    setState(() {
                                      _selectedMethod = null;
                                      _lastCompletedOrderId =
                                          selectedOrder.orderId;
                                    });
                                    final proofRequired =
                                        method == 'card' || method == 'pay';
                                    final paymentId = payment?['id']
                                        ?.toString();

                                    if (proofRequired &&
                                        paymentId != null &&
                                        context.mounted) {
                                      try {
                                        await paymentProofService
                                            .markProofRequired(
                                              paymentId: paymentId,
                                              storeId: storeId,
                                            );
                                        if (!context.mounted) {
                                          return;
                                        }

                                        final proofResult =
                                            await showDialog<
                                              PaymentProofSaveResult?
                                            >(
                                              context: context,
                                              barrierDismissible: false,
                                              builder: (_) => PaymentProofModal(
                                                paymentId: paymentId,
                                                storeId: storeId,
                                                methodLabel: method,
                                              ),
                                            );

                                        if (context.mounted &&
                                            proofResult != null) {
                                          if (proofResult.queued) {
                                            showErrorToast(
                                              context,
                                              'Proof upload queued locally. It will retry automatically.',
                                            );
                                          } else if (proofResult.uploaded) {
                                            showSuccessToast(
                                              context,
                                              'Payment proof saved.',
                                            );
                                          }
                                        }
                                      } catch (e) {
                                        if (context.mounted) {
                                          showErrorToast(
                                            context,
                                            'Proof flow failed: $e',
                                          );
                                        }
                                      }
                                    }

                                    // Stage 2: Red Invoice modal
                                    if (method != 'service') {
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
                                onCancelOrder: () async {
                                  final selectedOrder =
                                      paymentState.selectedOrder;
                                  if (storeId == null ||
                                      selectedOrder == null ||
                                      !isAdmin) {
                                    return;
                                  }
                                  final confirmed =
                                      await _showCancelOrderDialog(
                                        tableNumber: selectedOrder.tableNumber,
                                      );
                                  if (!confirmed) {
                                    return;
                                  }
                                  await notifier.cancelOrder(
                                    selectedOrder.orderId,
                                    storeId,
                                  );
                                  if (context.mounted &&
                                      ref.read(paymentProvider).error == null) {
                                    setState(() => _selectedMethod = null);
                                    showSuccessToast(
                                      context,
                                      l10n.cashierOrderCancelled,
                                    );
                                  }
                                },
                                onReprint: () async {
                                  final selectedOrder =
                                      paymentState.selectedOrder;
                                  if (selectedOrder == null) {
                                    return;
                                  }
                                  final method = _selectedMethod ?? 'cash';
                                  await _printReceipt(
                                    order: selectedOrder,
                                    method: method,
                                  );
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
                                color: AppColors.statusAvailable.withValues(
                                  alpha: 0.2,
                                ),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: AppColors.statusAvailable,
                                  width: 3,
                                ),
                              ),
                              child: const Icon(
                                Icons.check,
                                color: AppColors.statusAvailable,
                                size: 94,
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Stage 2: Einvoice status badge after payment
                      if (_lastCompletedOrderId != null)
                        Positioned(
                          bottom: 24,
                          left: 24,
                          child: EinvoiceStatusBadge(
                            orderId: _lastCompletedOrderId!,
                          ),
                        ),
                    ],
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

class _SelectedOrderView extends StatelessWidget {
  const _SelectedOrderView({
    required this.order,
    required this.selectedMethod,
    required this.isAdmin,
    required this.isProcessing,
    required this.isOnline,
    required this.onSelectMethod,
    required this.onProcess,
    required this.onCancelOrder,
    required this.onReprint,
  });

  final CashierOrder order;
  final String? selectedMethod;
  final bool isAdmin;
  final bool isProcessing;
  final bool isOnline;
  final ValueChanged<String> onSelectMethod;
  final Future<void> Function() onProcess;
  final Future<void> Function() onCancelOrder;
  final Future<void> Function() onReprint;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final currency = NumberFormat('#,###', 'vi_VN');
    final regularMethods = <_PaymentMethod>[
      const _PaymentMethod('cash', 'CASH', Color(0xFF2E7D32)),
      const _PaymentMethod('card', 'CARD', Color(0xFF1565C0)),
      const _PaymentMethod('pay', 'PAY', Color(0xFF8E44AD)),
    ];
    final canCancelOrder = isAdmin && order.status.toLowerCase() != 'completed';
    final isServiceSelected = selectedMethod == 'service';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Table ${order.tableNumber}',
          style: GoogleFonts.bebasNeue(
            color: AppColors.textPrimary,
            fontSize: 48,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: PosActionButton(
            label: PosActionVerbs.reprintReceipt,
            tone: PosActionTone.secondary,
            icon: PosActionIcons.reprintReceipt,
            onPressed: isProcessing ? null : onReprint,
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: AppPanel(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Expanded(
                  child: ListView.separated(
                    itemCount: order.items.length,
                    separatorBuilder: (_, _) =>
                        const Divider(color: AppColors.surface3),
                    itemBuilder: (context, index) {
                      final item = order.items[index];
                      final itemName = item.label ?? 'Item';
                      final lineTotal = item.unitPrice * item.quantity;
                      return Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${item.quantity} x $itemName',
                              style: GoogleFonts.notoSansKr(
                                color: AppColors.textPrimary,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          Text(
                            '₫${currency.format(lineTotal)}',
                            style: GoogleFonts.notoSansKr(
                              color: AppColors.textSecondary,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const Divider(color: AppColors.surface3, height: 26),
                Row(
                  children: [
                    Text(
                      l10n.cashierPaymentDue,
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '₫${currency.format(order.totalAmount)}',
                      style: GoogleFonts.bebasNeue(
                        color: AppColors.amber500,
                        fontSize: 32,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: regularMethods.map((method) {
                    final selected = selectedMethod == method.value;
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: InkWell(
                          onTap: () => onSelectMethod(method.value),
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            height: method.value == 'service' ? 44 : 52,
                            decoration: BoxDecoration(
                              color: method.color.withValues(alpha: 0.22),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: selected
                                    ? AppColors.amber500
                                    : method.color.withValues(alpha: 0.6),
                                width: selected ? 2 : 1,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              method.label,
                              style: GoogleFonts.bebasNeue(
                                color: AppColors.textPrimary,
                                fontSize: method.value == 'service' ? 18 : 22,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                if (isAdmin) ...[
                  const SizedBox(height: 10),
                  InkWell(
                    onTap: () => onSelectMethod('service'),
                    borderRadius: BorderRadius.circular(12),
                    child: _DashedCard(
                      selected: isServiceSelected,
                      child: Container(
                        width: double.infinity,
                        height: 48,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        alignment: Alignment.centerLeft,
                        child: Row(
                          children: [
                            Icon(
                              Icons.volunteer_activism,
                              size: 16,
                              color: isServiceSelected
                                  ? AppColors.textPrimary
                                  : AppColors.textSecondary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              l10n.cashierServiceProvisionTitle,
                              style: GoogleFonts.notoSansKr(
                                color: isServiceSelected
                                    ? AppColors.textPrimary
                                    : AppColors.textSecondary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                if (isServiceSelected) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.statusOccupied.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppColors.statusOccupied.withValues(alpha: 0.8),
                      ),
                    ),
                    child: Text(
                      '⚠️ ${l10n.cashierServiceProvisionRevenueHint}',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 64,
                  child: FilledButton(
                    key: const Key('payment_submit_button'),
                    // RULES.md: 결제는 온라인 필수 — 오프라인 시 버튼 비활성화
                    onPressed:
                        selectedMethod == null || isProcessing || !isOnline
                        ? null
                        : onProcess,
                    child: isProcessing
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: AppColors.surface0,
                            ),
                          )
                        : Text(
                            isServiceSelected
                                ? l10n.cashierServiceNow
                                : l10n.cashierPayNow,
                            style: GoogleFonts.bebasNeue(
                              fontSize: 22,
                              letterSpacing: 1.0,
                            ),
                          ),
                  ),
                ),
                if (canCancelOrder) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: PosActionButton(
                      label: PosActionVerbs.cancelOrder,
                      tone: PosActionTone.destructive,
                      icon: PosActionIcons.cancelOrder,
                      onPressed: isProcessing ? null : onCancelOrder,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _OrderStatusBadge extends StatelessWidget {
  const _OrderStatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final normalized = status.toLowerCase();
    final color = switch (normalized) {
      'pending' => AppColors.statusOccupied,
      'confirmed' => AppColors.amber500,
      'serving' => AppColors.statusAvailable,
      _ => AppColors.surface2,
    };
    return ToastStatusChip(label: normalized, color: color);
  }
}

class _PaymentMethod {
  const _PaymentMethod(this.value, this.label, this.color);

  final String value;
  final String label;
  final Color color;
}

class _DashedCard extends StatelessWidget {
  const _DashedCard({required this.selected, required this.child});

  final bool selected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final borderColor = selected ? AppColors.amber500 : AppColors.textSecondary;
    return CustomPaint(
      painter: _DashedBorderPainter(color: borderColor),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? AppColors.surface2 : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const radius = 12.0;
    const dashWidth = 8.0;
    const dashSpace = 5.0;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(radius),
    );

    final path = Path()..addRRect(rrect);
    final metrics = path.computeMetrics().toList();
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    for (final metric in metrics) {
      double distance = 0;
      while (distance < metric.length) {
        final end = distance + dashWidth;
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += dashWidth + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _CashierTodaySummaryDialog extends ConsumerWidget {
  const _CashierTodaySummaryDialog({required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(cashierTodaySummaryProvider(storeId));
    final currency = NumberFormat('#,###', 'vi_VN');

    return AlertDialog(
      backgroundColor: AppColors.surface1,
      title: Row(
        children: [
          const Icon(Icons.summarize, color: AppColors.amber500, size: 22),
          const SizedBox(width: 8),
          Text(
            "Today's Settlement Status",
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
          const Spacer(),
          InkWell(
            onTap: () => ref.refresh(cashierTodaySummaryProvider(storeId)),
            borderRadius: BorderRadius.circular(4),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(
                Icons.refresh,
                size: 18,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 380,
        child: summaryAsync.when(
          data: (summary) => _buildSummaryContent(summary, currency),
          loading: () => const SizedBox(
            height: 120,
            child: Center(
              child: CircularProgressIndicator(
                color: AppColors.amber500,
                strokeWidth: 2,
              ),
            ),
          ),
          error: (error, _) => Text(
            'Failed to load settlement status.',
            style: GoogleFonts.notoSansKr(
              color: AppColors.statusCancelled,
              fontSize: 14,
            ),
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.amber500,
            foregroundColor: AppColors.surface0,
          ),
          child: const Text('Confirm'),
        ),
      ],
    );
  }

  Widget _buildSummaryContent(
    CashierTodaySummary summary,
    NumberFormat currency,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _summarySection('Revenue Payment', [
          _summaryRow('Payment Count', '${summary.paymentsCount}'),
          _summaryRow(
            'Total',
            '₫${currency.format(summary.paymentsTotal)}',
            valueColor: AppColors.amber500,
            bold: true,
          ),
          _summaryRow('Cash', '₫${currency.format(summary.paymentsCash)}'),
          _summaryRow('Card', '₫${currency.format(summary.paymentsCard)}'),
          _summaryRow(
            'Other (Pay, etc.)',
            '₫${currency.format(summary.paymentsPay)}',
          ),
        ]),
        const SizedBox(height: 16),
        _summarySection('Service (not counted)', [
          _summaryRow('Service Count', '${summary.serviceCount}'),
          _summaryRow(
            'Service Total',
            '₫${currency.format(summary.serviceTotal)}',
          ),
        ]),
        const SizedBox(height: 16),
        _summarySection('Order Status', [
          _summaryRow(
            'Done',
            '${summary.ordersCompleted}',
            valueColor: AppColors.statusAvailable,
          ),
          _summaryRow(
            'In Progress',
            '${summary.ordersActive}',
            valueColor: AppColors.amber500,
          ),
          _summaryRow(
            'Cancel',
            '${summary.ordersCancelled}',
            valueColor: AppColors.statusCancelled,
          ),
        ]),
      ],
    );
  }

  Widget _summarySection(String title, List<Widget> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface0,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.surface2),
          ),
          child: Column(children: rows),
        ),
      ],
    );
  }

  Widget _summaryRow(
    String label,
    String value, {
    Color? valueColor,
    bool bold = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(
            label,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: GoogleFonts.notoSansKr(
              color: valueColor ?? AppColors.textPrimary,
              fontSize: bold ? 15 : 13,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
