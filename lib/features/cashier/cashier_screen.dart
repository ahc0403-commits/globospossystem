import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../main.dart';
import '../../widgets/error_toast.dart';
import '../../widgets/offline_banner.dart';
import '../auth/auth_provider.dart';
import '../payment/payment_provider.dart';

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
          showSuccessToast(context, 'Payment processed successfully');
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

  void _ensureLoaded(String? restaurantId) {
    if (restaurantId == null || restaurantId == _initializedRestaurantId) {
      return;
    }
    _initializedRestaurantId = restaurantId;
    Future.microtask(() {
      ref.read(paymentProvider.notifier).loadOrders(restaurantId);
    });
  }

  @override
  void dispose() {
    _successTimer?.cancel();
    _paymentSub.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final restaurantId = authState.restaurantId;
    final role = authState.role ?? '';
    final isAdmin = role == 'admin' || role == 'super_admin';
    _ensureLoaded(restaurantId);

    final paymentState = ref.watch(paymentProvider);
    final notifier = ref.read(paymentProvider.notifier);
    final currency = NumberFormat('#,###', 'vi_VN');

    return Scaffold(
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
                    border: Border(right: BorderSide(color: AppColors.surface2)),
                  ),
                  child: Column(
                    children: [
                      Container(
                        height: 80,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'CASHIER',
                          style: GoogleFonts.bebasNeue(
                            color: AppColors.amber500,
                            fontSize: 28,
                            letterSpacing: 1.0,
                          ),
                        ),
                      ),
                      Expanded(
                        child: paymentState.orders.isEmpty
                            ? Center(
                                child: Text(
                                  'No payable orders',
                                  style: GoogleFonts.notoSansKr(
                                    color: AppColors.textSecondary,
                                    fontSize: 14,
                                  ),
                                ),
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                                itemCount: paymentState.orders.length,
                                separatorBuilder: (_, _) => const SizedBox(height: 10),
                                itemBuilder: (context, index) {
                                  final order = paymentState.orders[index];
                                  final selected =
                                      paymentState.selectedOrder?.orderId == order.orderId;
                                  return InkWell(
                                    onTap: () {
                                      setState(() => _selectedMethod = null);
                                      notifier.selectOrder(order);
                                    },
                                    borderRadius: BorderRadius.circular(14),
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 220),
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
                                        crossAxisAlignment: CrossAxisAlignment.start,
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
                                            '${order.items.length} items',
                                            style: GoogleFonts.notoSansKr(
                                              color: AppColors.textSecondary,
                                              fontSize: 12,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          _OrderStatusBadge(status: order.status),
                                        ],
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
                            ? Center(
                                child: Text(
                                  'Select a table to process payment',
                                  style: GoogleFonts.notoSansKr(
                                    color: AppColors.textSecondary,
                                    fontSize: 18,
                                  ),
                                ),
                              )
                            : _SelectedOrderView(
                                order: paymentState.selectedOrder!,
                                selectedMethod: _selectedMethod,
                                isAdmin: isAdmin,
                                isProcessing: paymentState.isProcessing,
                                onSelectMethod: (method) {
                                  setState(() => _selectedMethod = method);
                                },
                                onProcess: () async {
                                  final method = _selectedMethod;
                                  final selectedOrder = paymentState.selectedOrder;
                                  if (restaurantId == null ||
                                      method == null ||
                                      selectedOrder == null) {
                                    return;
                                  }
                                  await notifier.processPayment(
                                    restaurantId,
                                    selectedOrder.orderId,
                                    selectedOrder.totalAmount,
                                    method,
                                  );
                                  if (mounted && ref.read(paymentProvider).paymentSuccess) {
                                    setState(() => _selectedMethod = null);
                                  }
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
                              width: 180,
                              height: 180,
                              decoration: BoxDecoration(
                                color: AppColors.statusAvailable.withValues(alpha: 0.2),
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
    required this.onSelectMethod,
    required this.onProcess,
  });

  final CashierOrder order;
  final String? selectedMethod;
  final bool isAdmin;
  final bool isProcessing;
  final ValueChanged<String> onSelectMethod;
  final Future<void> Function() onProcess;

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat('#,###', 'vi_VN');
    final methods = <_PaymentMethod>[
      const _PaymentMethod('cash', 'CASH', Color(0xFF2E7D32)),
      const _PaymentMethod('card', 'CARD', Color(0xFF1565C0)),
      const _PaymentMethod('pay', 'PAY', Color(0xFF8E44AD)),
      if (isAdmin) const _PaymentMethod('service', 'SERVICE', AppColors.surface2),
    ];

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
        const SizedBox(height: 12),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.surface1,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.surface2),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Expanded(
                  child: ListView.separated(
                    itemCount: order.items.length,
                    separatorBuilder: (_, _) => const Divider(color: AppColors.surface2),
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
                const Divider(color: AppColors.surface2, height: 26),
                Row(
                  children: [
                    Text(
                      'TOTAL',
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
                  children: methods.map((method) {
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
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 64,
                  child: FilledButton(
                    onPressed: selectedMethod == null || isProcessing ? null : onProcess,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.amber500,
                      foregroundColor: AppColors.surface0,
                      disabledBackgroundColor: AppColors.amber500.withValues(alpha: 0.4),
                      disabledForegroundColor: AppColors.surface0.withValues(alpha: 0.8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
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
                            'PROCESS PAYMENT',
                            style: GoogleFonts.bebasNeue(
                              fontSize: 22,
                              letterSpacing: 1.0,
                            ),
                          ),
                  ),
                ),
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
    final textColor = normalized == 'confirmed'
        ? AppColors.surface0
        : AppColors.textPrimary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color),
      ),
      child: Text(
        normalized.toUpperCase(),
        style: GoogleFonts.notoSansKr(
          color: textColor,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PaymentMethod {
  const _PaymentMethod(this.value, this.label, this.color);

  final String value;
  final String label;
  final Color color;
}
