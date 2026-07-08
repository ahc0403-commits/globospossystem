import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../core/services/qr_order_service.dart';
import '../../core/ui/app_theme.dart';
import '../../core/ui/app_fonts.dart';

class QrOrderScreen extends StatefulWidget {
  const QrOrderScreen({super.key, required this.token});

  final String token;

  @override
  State<QrOrderScreen> createState() => _QrOrderScreenState();
}

class _QrOrderScreenState extends State<QrOrderScreen> {
  final _uuid = const Uuid();
  final _currency = NumberFormat('#,###', 'vi_VN');
  QrOrderMenu? _menu;
  QrOrderResult? _result;
  String? _selectedCategoryId;
  String? _error;
  String? _clientOrderId;
  bool _isLoading = true;
  bool _isSubmitting = false;
  final Map<String, int> _cart = <String, int>{};

  @override
  void initState() {
    super.initState();
    _loadMenu();
  }

  Future<void> _loadMenu() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final menu = await qrOrderService.fetchMenu(widget.token);
      setState(() {
        _menu = menu;
        _selectedCategoryId = menu.categories.isEmpty
            ? null
            : menu.categories.first.id;
        _isLoading = false;
      });
    } catch (error) {
      setState(() {
        _error = _copy.errorFor(error);
        _isLoading = false;
      });
    }
  }

  QrOrderCopy get _copy {
    final code = Localizations.localeOf(context).languageCode.toLowerCase();
    return QrOrderCopy.forLanguage(code);
  }

  List<QrMenuItem> get _visibleItems {
    final menu = _menu;
    if (menu == null) {
      return const <QrMenuItem>[];
    }
    final categoryId = _selectedCategoryId;
    if (categoryId == null) {
      return menu.items;
    }
    return menu.items.where((item) => item.categoryId == categoryId).toList();
  }

  double get _cartTotal {
    final menu = _menu;
    if (menu == null) {
      return 0;
    }
    var total = 0.0;
    for (final entry in _cart.entries) {
      final item = menu.items.where((item) => item.id == entry.key).firstOrNull;
      if (item != null) {
        total += item.price * entry.value;
      }
    }
    return total;
  }

  int get _cartCount => _cart.values.fold(0, (sum, qty) => sum + qty);

  void _setQuantity(String itemId, int quantity) {
    setState(() {
      if (quantity <= 0) {
        _cart.remove(itemId);
      } else {
        _cart[itemId] = quantity.clamp(1, 20);
      }
      _clientOrderId = null;
    });
  }

  Future<void> _submitOrder() async {
    if (_cart.isEmpty || _isSubmitting) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('qr_confirm_dialog'),
        title: Text(_copy.confirmTitle),
        content: Text(_copy.confirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_copy.cancel),
          ),
          FilledButton(
            key: const Key('qr_confirm_submit'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_copy.submit),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
      _clientOrderId ??= _uuid.v4();
    });

    try {
      final result = await qrOrderService.placeOrder(
        token: widget.token,
        clientOrderId: _clientOrderId!,
        items: _cart.entries
            .map(
              (entry) =>
                  QrOrderLine(menuItemId: entry.key, quantity: entry.value),
            )
            .toList(),
      );
      setState(() {
        _result = result;
        _cart.clear();
        _clientOrderId = null;
        _isSubmitting = false;
      });
    } catch (error) {
      setState(() {
        _error = _copy.errorFor(error);
        _isSubmitting = false;
      });
    }
  }

  void _startAnotherOrder() {
    setState(() {
      _result = null;
      _error = null;
      _clientOrderId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final menu = _menu;
    final result = _result;

    if (_isLoading) {
      return const Scaffold(
        backgroundColor: AppColors.surface0,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.amber500),
        ),
      );
    }

    if (_error != null && menu == null) {
      return Scaffold(
        backgroundColor: AppColors.surface0,
        body: _QrCenteredState(
          title: _copy.unavailableTitle,
          body: _error!,
          actionLabel: _copy.retry,
          onAction: _loadMenu,
        ),
      );
    }

    if (menu == null) {
      return const SizedBox.shrink();
    }

    if (result != null) {
      return Scaffold(
        backgroundColor: AppColors.surface0,
        body: SafeArea(
          child: _QrSuccessView(
            copy: _copy,
            result: result,
            onAnotherOrder: _startAnotherOrder,
          ),
        ),
      );
    }

    return Scaffold(
      key: const Key('qr_order_screen'),
      backgroundColor: AppColors.surface0,
      body: SafeArea(
        child: Stack(
          children: [
            CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _buildHeader(menu)),
                if (_error != null)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: _QrErrorBanner(message: _error!),
                    ),
                  ),
                SliverToBoxAdapter(child: _buildCategories(menu)),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 112),
                  sliver: SliverList.separated(
                    itemCount: _visibleItems.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final item = _visibleItems[index];
                      return _QrMenuItemTile(
                        item: item,
                        quantity: _cart[item.id] ?? 0,
                        priceLabel: '${_currency.format(item.price)} VND',
                        onChanged: (quantity) =>
                            _setQuantity(item.id, quantity),
                      );
                    },
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: _QrCartBar(
                copy: _copy,
                count: _cartCount,
                totalLabel: '${_currency.format(_cartTotal)} VND',
                isSubmitting: _isSubmitting,
                onSubmit: _cart.isEmpty ? null : _submitOrder,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(QrOrderMenu menu) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            menu.storeName,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColors.surface1,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.surface3),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _copy.tableLabel(menu.tableNumber, menu.floorLabel),
                  style: AppFonts.system(
                    color: AppColors.textPrimary,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _copy.headerHint,
                  style: AppFonts.system(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategories(QrOrderMenu menu) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: menu.categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final category = menu.categories[index];
          final selected = category.id == _selectedCategoryId;
          return ChoiceChip(
            label: Text(category.name),
            selected: selected,
            onSelected: (_) {
              setState(() {
                _selectedCategoryId = category.id;
              });
            },
          );
        },
      ),
    );
  }
}

class _QrMenuItemTile extends StatelessWidget {
  const _QrMenuItemTile({
    required this.item,
    required this.quantity,
    required this.priceLabel,
    required this.onChanged,
  });

  final QrMenuItem item;
  final int quantity;
  final String priceLabel;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.surface3),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: AppFonts.system(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if ((item.description ?? '').isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    item.description!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.system(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  priceLabel,
                  style: AppFonts.system(
                    color: AppColors.amber500,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _QrStepper(quantity: quantity, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _QrStepper extends StatelessWidget {
  const _QrStepper({required this.quantity, required this.onChanged});

  final int quantity;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          onPressed: quantity <= 0 ? null : () => onChanged(quantity - 1),
          icon: const Icon(Icons.remove),
        ),
        SizedBox(
          width: 34,
          child: Text(
            '$quantity',
            textAlign: TextAlign.center,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        IconButton.filled(
          onPressed: quantity >= 20 ? null : () => onChanged(quantity + 1),
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}

class _QrCartBar extends StatelessWidget {
  const _QrCartBar({
    required this.copy,
    required this.count,
    required this.totalLabel,
    required this.isSubmitting,
    required this.onSubmit,
  });

  final QrOrderCopy copy;
  final int count;
  final String totalLabel;
  final bool isSubmitting;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: const BoxDecoration(
        color: AppColors.surface1,
        border: Border(top: BorderSide(color: AppColors.surface3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  copy.cartSummary(count, totalLabel),
                  style: AppFonts.system(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  copy.totalCaption,
                  style: AppFonts.system(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          FilledButton(
            onPressed: isSubmitting ? null : onSubmit,
            child: isSubmitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(copy.submit),
          ),
        ],
      ),
    );
  }
}

class _QrSuccessView extends StatelessWidget {
  const _QrSuccessView({
    required this.copy,
    required this.result,
    required this.onAnotherOrder,
  });

  final QrOrderCopy copy;
  final QrOrderResult result;
  final VoidCallback onAnotherOrder;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surface1,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.surface3),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                copy.successTitle,
                style: AppFonts.system(
                  color: AppColors.textPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                copy.successBody,
                style: AppFonts.system(
                  color: AppColors.textSecondary,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                copy.tableLabel(result.tableNumber, result.floorLabel),
                style: AppFonts.system(
                  color: AppColors.textPrimary,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Order ${result.orderCode} · Batch ${result.batchNo}',
                style: AppFonts.system(
                  color: AppColors.amber500,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 18),
              ...result.items.map(
                (item) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${item.name} x${item.quantity}',
                    style: AppFonts.system(color: AppColors.textPrimary),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onAnotherOrder,
                icon: const Icon(Icons.add),
                label: Text(copy.addMore),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _QrErrorBanner extends StatelessWidget {
  const _QrErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.statusCancelled.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppColors.statusCancelled.withValues(alpha: 0.36),
        ),
      ),
      child: Text(
        message,
        style: AppFonts.system(
          color: AppColors.statusCancelled,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _QrCenteredState extends StatelessWidget {
  const _QrCenteredState({
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onAction,
  });

  final String title;
  final String body;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppFonts.system(
                color: AppColors.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              body,
              textAlign: TextAlign.center,
              style: AppFonts.system(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 18),
            FilledButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}

class QrOrderCopy {
  const QrOrderCopy({
    required this.headerHint,
    required this.confirmTitle,
    required this.confirmBody,
    required this.submit,
    required this.cancel,
    required this.totalCaption,
    required this.successTitle,
    required this.successBody,
    required this.addMore,
    required this.retry,
    required this.unavailableTitle,
  });

  final String headerHint;
  final String confirmTitle;
  final String confirmBody;
  final String submit;
  final String cancel;
  final String totalCaption;
  final String successTitle;
  final String successBody;
  final String addMore;
  final String retry;
  final String unavailableTitle;

  static QrOrderCopy forLanguage(String code) {
    return switch (code) {
      'vi' => const QrOrderCopy(
        headerHint: 'Vui lòng kiểm tra đúng số bàn trước khi gọi món.',
        confirmTitle: 'Xác nhận gọi món',
        confirmBody:
            'Sau khi hoàn tất, món sẽ được gửi thẳng đến bếp. Thanh toán sau bữa ăn tại quầy thu ngân. Bạn có muốn gọi món không?',
        submit: 'Gọi món',
        cancel: 'Hủy',
        totalCaption: 'Tổng này chỉ để tham khảo. Thu ngân sẽ tính trên POS.',
        successTitle: 'Đã nhận món',
        successBody:
            'Nhân viên sẽ mang phiếu xác nhận đến bàn. Vui lòng thanh toán sau bữa ăn tại quầy thu ngân.',
        addMore: 'Gọi thêm',
        retry: 'Thử lại',
        unavailableTitle: 'Không thể mở QR',
      ),
      'ko' => const QrOrderCopy(
        headerHint: '주문 전 테이블 번호를 확인해 주세요.',
        confirmTitle: '주문 확인',
        confirmBody: '주문을 완료하면 바로 주방으로 전달됩니다. 결제는 식사 후 캐셔에서 진행합니다. 주문하시겠습니까?',
        submit: '주문완료',
        cancel: '취소',
        totalCaption: '표시용 합계입니다. 최종 금액은 캐셔 POS 기준입니다.',
        successTitle: '주문이 접수되었습니다',
        successBody: '직원이 주문확인서를 가져다 드립니다. 결제는 식사 후 캐셔에서 진행해 주세요.',
        addMore: '추가 주문하기',
        retry: '다시 시도',
        unavailableTitle: 'QR을 열 수 없습니다',
      ),
      _ => const QrOrderCopy(
        headerHint: 'Please confirm the table number before ordering.',
        confirmTitle: 'Confirm order',
        confirmBody:
            'When you submit, the order goes directly to the kitchen. Payment is made at the cashier after your meal. Place this order?',
        submit: 'Place order',
        cancel: 'Cancel',
        totalCaption:
            'Displayed total only. The cashier will charge from the POS.',
        successTitle: 'Order received',
        successBody:
            'Staff will bring an order confirmation slip to your table. Please pay at the cashier after your meal.',
        addMore: 'Add more',
        retry: 'Retry',
        unavailableTitle: 'QR unavailable',
      ),
    };
  }

  String tableLabel(String tableNumber, String floorLabel) {
    return 'Table $tableNumber / $floorLabel';
  }

  String cartSummary(int count, String totalLabel) {
    return '$count item(s) · $totalLabel';
  }

  String errorFor(Object error) {
    final raw = error.toString();
    if (raw.contains('QR_TOKEN_INVALID')) {
      return 'QR is not valid. Please call staff.';
    }
    if (raw.contains('QR_ORDER_PAYMENT_IN_PROGRESS')) {
      return 'Payment is already in progress. Please call staff.';
    }
    if (raw.contains('QR_TOO_FREQUENT')) {
      return 'Please wait a moment and try again.';
    }
    if (raw.contains('QR_MENU_ITEM_UNAVAILABLE')) {
      return 'One or more menu items are no longer available.';
    }
    if (raw.contains('QR_ITEMS_INVALID')) {
      return 'Please check item quantities and try again.';
    }
    return 'Network error. Please retry with the same cart.';
  }
}
