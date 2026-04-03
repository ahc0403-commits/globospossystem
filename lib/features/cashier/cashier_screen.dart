import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../core/services/connectivity_service.dart';
import '../../core/layout/platform_info.dart';
import '../../core/hardware/printer_service.dart';
import '../../core/hardware/receipt_builder.dart';
import '../../main.dart';
import '../../widgets/error_toast.dart';
import '../../widgets/offline_banner.dart';
import '../auth/auth_provider.dart';
import '../payment/payment_provider.dart';
import '../settings/printer_provider.dart';

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

  Future<bool> _showCancelOrderDialog({required String tableNumber}) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Text(
          '주문을 취소하시겠습니까?',
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          'T$tableNumber 주문이 취소되고 테이블이 비워집니다.',
          style: GoogleFonts.notoSansKr(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('돌아가기'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.statusCancelled,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.cancel),
            label: const Text('주문 취소'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<bool> _showServiceConfirmDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Text(
          '서비스 제공 처리',
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          '이 주문은 매출에 반영되지 않고 서비스로 처리됩니다.\n직원 식사, 서비스 음료 등에 사용하세요.',
          style: GoogleFonts.notoSansKr(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.amber500,
              foregroundColor: AppColors.surface0,
            ),
            child: const Text('서비스 처리'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _printReceipt({
    required CashierOrder order,
    required String method,
  }) async {
    if (!PlatformInfo.isPrinterSupported) {
      showErrorToast(context, '프린터는 앱에서만 지원됩니다.');
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
      isService: method == 'service',
    );

    final result = await ref.read(printerProvider.notifier).print(bytes);
    if (!mounted) {
      return;
    }
    if (result != PrintResult.success) {
      showErrorToast(context, '결제 완료. 영수증 출력 실패 - 프린터를 확인해주세요.');
    }
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
    // 오프라인 상태 감지 - RULES.md: 결제는 온라인 필수
    final isOnline = ref.watch(connectivityProvider).asData?.value ?? true;

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
                    border: Border(
                      right: BorderSide(color: AppColors.surface2),
                    ),
                  ),
                  child: Column(
                    children: [
                      Container(
                        height: 80,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Text(
                              'CASHIER',
                              style: GoogleFonts.bebasNeue(
                                color: AppColors.amber500,
                                fontSize: 28,
                                letterSpacing: 1.0,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(
                                Icons.logout,
                                color: AppColors.textSecondary,
                              ),
                              tooltip: '로그아웃',
                              onPressed: () async {
                                await ref.read(authProvider.notifier).logout();
                              },
                            ),
                          ],
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
                                  return InkWell(
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
                                            '${order.items.length} items',
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
                                isOnline: isOnline,
                                onSelectMethod: (method) {
                                  setState(() => _selectedMethod = method);
                                },
                                onProcess: () async {
                                  final method = _selectedMethod;
                                  final selectedOrder =
                                      paymentState.selectedOrder;
                                  if (restaurantId == null ||
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

                                  await notifier.processPayment(
                                    restaurantId,
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
                                    setState(() => _selectedMethod = null);
                                  }
                                },
                                onCancelOrder: () async {
                                  final selectedOrder =
                                      paymentState.selectedOrder;
                                  if (restaurantId == null ||
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
                                    restaurantId,
                                  );
                                  if (context.mounted &&
                                      ref.read(paymentProvider).error == null) {
                                    setState(() => _selectedMethod = null);
                                    showSuccessToast(context, '주문이 취소되었습니다');
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
          child: OutlinedButton.icon(
            onPressed: isProcessing ? null : onReprint,
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppColors.surface2),
              foregroundColor: AppColors.textPrimary,
            ),
            icon: const Icon(Icons.print, size: 16),
            label: Text(
              '영수증 재출력',
              style: GoogleFonts.notoSansKr(
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
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
                    separatorBuilder: (_, _) =>
                        const Divider(color: AppColors.surface2),
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
                              '서비스 제공 (매출 미반영)',
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
                      '⚠️ 서비스 처리 시 매출에 반영되지 않습니다',
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
                    // RULES.md: 결제는 온라인 필수 — 오프라인 시 버튼 비활성화
                    onPressed: selectedMethod == null || isProcessing || !isOnline
                        ? null
                        : onProcess,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.amber500,
                      foregroundColor: AppColors.surface0,
                      disabledBackgroundColor: AppColors.amber500.withValues(
                        alpha: 0.4,
                      ),
                      disabledForegroundColor: AppColors.surface0.withValues(
                        alpha: 0.8,
                      ),
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
                            isServiceSelected ? '서비스 처리 완료' : 'PROCESS PAYMENT',
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
                    child: TextButton.icon(
                      onPressed: isProcessing ? null : onCancelOrder,
                      icon: const Icon(
                        Icons.cancel_outlined,
                        color: AppColors.statusCancelled,
                        size: 18,
                      ),
                      label: Text(
                        '주문 취소',
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.statusCancelled,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
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
