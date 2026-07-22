import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../core/services/qr_order_service.dart';
import '../../core/ui/app_fonts.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';

class QrOrderScreen extends StatefulWidget {
  const QrOrderScreen({super.key, required this.token, this.service});

  final String token;

  /// Optional only so the customer-state contract can be exercised without a
  /// live Supabase project. Routed production callers keep the existing
  /// [qrOrderService] boundary.
  final QrOrderService? service;

  @override
  State<QrOrderScreen> createState() => _QrOrderScreenState();
}

class _QrOrderScreenState extends State<QrOrderScreen> {
  final _uuid = const Uuid();
  final _currency = NumberFormat('#,###', 'vi_VN');
  QrOrderMenu? _menu;
  QrOrderResult? _result;
  String? _selectedCategoryId;
  QrOrderFailurePresentation? _failure;
  String? _clientOrderId;
  bool _isLoading = true;
  bool _isSubmitting = false;
  final Map<String, int> _cart = <String, int>{};

  QrOrderService get _service => widget.service ?? qrOrderService;

  @override
  void initState() {
    super.initState();
    _loadMenu();
  }

  Future<void> _loadMenu() async {
    setState(() {
      _isLoading = true;
      _failure = null;
    });
    try {
      final menu = await _service.fetchMenu(widget.token);
      if (!mounted) return;
      setState(() {
        _menu = menu;
        _selectedCategoryId = menu.categories.isEmpty
            ? null
            : menu.categories.first.id;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _failure = _copy.failureFor(error);
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
    if (menu == null) return const <QrMenuItem>[];
    final categoryId = _selectedCategoryId;
    if (categoryId == null) return menu.items;
    return menu.items.where((item) => item.categoryId == categoryId).toList();
  }

  List<({QrMenuItem item, int quantity})> get _cartItems {
    final menu = _menu;
    if (menu == null) return const [];
    return [
      for (final item in menu.items)
        if ((_cart[item.id] ?? 0) > 0) (item: item, quantity: _cart[item.id]!),
    ];
  }

  double get _cartTotal {
    var total = 0.0;
    for (final line in _cartItems) {
      total += line.item.price * line.quantity;
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
      _failure = null;
    });
  }

  Future<void> _submitOrder() async {
    if (_cart.isEmpty || _isSubmitting) return;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _QrReviewDialog(
        copy: _copy,
        lines: _cartItems,
        totalLabel: '${_currency.format(_cartTotal)} VND',
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _isSubmitting = true;
      _failure = null;
      _clientOrderId ??= _uuid.v4();
    });

    try {
      final result = await _service.placeOrder(
        token: widget.token,
        clientOrderId: _clientOrderId!,
        items: _cart.entries
            .map(
              (entry) =>
                  QrOrderLine(menuItemId: entry.key, quantity: entry.value),
            )
            .toList(),
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _cart.clear();
        _clientOrderId = null;
        _isSubmitting = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _failure = _copy.failureFor(error);
        _isSubmitting = false;
      });
    }
  }

  void _startAnotherOrder() {
    setState(() {
      _result = null;
      _failure = null;
      _clientOrderId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final menu = _menu;
    final result = _result;

    if (_isLoading) {
      return Scaffold(
        key: const Key('qr_state_loading'),
        backgroundColor: ToastColorTokens.canvas,
        body: SafeArea(
          child: ToastOperationalLoadingState(label: _copy.loadingMenu),
        ),
      );
    }

    if (_failure != null && menu == null) {
      return Scaffold(
        key: _failure!.stateKey,
        backgroundColor: ToastColorTokens.canvas,
        body: SafeArea(
          child: _QrCenteredState(
            icon: _failure!.icon,
            title: _failure!.title,
            body: _failure!.body,
            actionLabel: _copy.retry,
            onAction: _loadMenu,
          ),
        ),
      );
    }

    if (menu == null) {
      return const SizedBox.shrink();
    }

    if (result != null) {
      return Scaffold(
        key: const Key('qr_state_success'),
        backgroundColor: ToastColorTokens.canvas,
        body: SafeArea(
          child: _QrSuccessView(
            copy: _copy,
            result: result,
            onAnotherOrder: _startAnotherOrder,
          ),
        ),
      );
    }

    return FocusTraversalGroup(
      key: const Key('qr_focus_traversal'),
      policy: ReadingOrderTraversalPolicy(),
      child: Scaffold(
        key: const Key('qr_order_screen'),
        backgroundColor: ToastColorTokens.canvas,
        bottomNavigationBar: _QrCartBar(
          copy: _copy,
          count: _cartCount,
          totalLabel: '${_currency.format(_cartTotal)} VND',
          isSubmitting: _isSubmitting,
          onSubmit: _cart.isEmpty ? null : _submitOrder,
        ),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: CustomScrollView(
                key: const Key('qr_menu_scroll'),
                slivers: [
                  SliverToBoxAdapter(child: _buildHeader(menu)),
                  if (_failure != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: _QrErrorBanner(
                          failure: _failure!,
                          retryLabel: _copy.retry,
                          onRetry: _submitOrder,
                        ),
                      ),
                    ),
                  if (menu.categories.isNotEmpty)
                    SliverToBoxAdapter(child: _buildCategories(menu)),
                  if (_visibleItems.isEmpty)
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: 320,
                        child: ToastOperationalEmptyState(
                          key: const Key('qr_state_empty'),
                          headline: menu.items.isEmpty
                              ? _copy.emptyMenuTitle
                              : _copy.emptyCategoryTitle,
                          helper: menu.items.isEmpty
                              ? _copy.emptyMenuBody
                              : _copy.emptyCategoryBody,
                          icon: Icons.restaurant_menu_rounded,
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                      sliver: SliverList.separated(
                        itemCount: _visibleItems.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: ToastSpacingTokens.sm),
                        itemBuilder: (context, index) {
                          final item = _visibleItems[index];
                          return _QrMenuItemTile(
                            item: item,
                            quantity: _cart[item.id] ?? 0,
                            priceLabel: '${_currency.format(item.price)} VND',
                            copy: _copy,
                            onChanged: (quantity) =>
                                _setQuantity(item.id, quantity),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
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
              color: ToastColorTokens.textSecondary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: ToastSpacingTokens.sm),
          ToastWorkSurface(
            padding: const EdgeInsets.all(ToastSpacingTokens.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    _copy.tableLabel(menu.tableNumber, menu.floorLabel),
                    style: AppFonts.system(
                      color: ToastColorTokens.textPrimary,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                    ),
                  ),
                ),
                const SizedBox(height: ToastSpacingTokens.sm),
                Text(
                  _copy.headerHint,
                  style: AppFonts.system(
                    color: ToastColorTokens.textSecondary,
                    fontSize: 14,
                    height: 1.45,
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
      height: 56,
      child: ListView.separated(
        key: const Key('qr_category_queue'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        scrollDirection: Axis.horizontal,
        itemCount: menu.categories.length,
        separatorBuilder: (_, __) =>
            const SizedBox(width: ToastSpacingTokens.sm),
        itemBuilder: (context, index) {
          final category = menu.categories[index];
          final selected = category.id == _selectedCategoryId;
          return Semantics(
            selected: selected,
            button: true,
            label: category.name,
            child: ChoiceChip(
              key: Key('qr_category_${category.id}'),
              label: Text(category.name),
              selected: selected,
              onSelected: (_) {
                setState(() {
                  _selectedCategoryId = category.id;
                });
              },
            ),
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
    required this.copy,
    required this.onChanged,
  });

  final QrMenuItem item;
  final int quantity;
  final String priceLabel;
  final QrOrderCopy copy;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: Key('qr_menu_item_${item.id}'),
      container: true,
      label: '${item.name}, $priceLabel, ${copy.quantityLabel(quantity)}',
      child: ToastWorkSurface(
        padding: const EdgeInsets.all(ToastSpacingTokens.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if ((item.imageUrl ?? '').trim().isNotEmpty) ...[
              ClipRRect(
                borderRadius: ToastRadiusTokens.md,
                child: SizedBox(
                  width: 96,
                  height: 96,
                  child: Image.network(
                    item.imageUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => ColoredBox(
                      color: ToastColorTokens.mutedSurface,
                      child: const Icon(Icons.broken_image_outlined),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: ToastSpacingTokens.md),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: AppFonts.system(
                      color: ToastColorTokens.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                    ),
                  ),
                  if ((item.description ?? '').isNotEmpty) ...[
                    const SizedBox(height: ToastSpacingTokens.xs),
                    Text(
                      item.description!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.system(
                        color: ToastColorTokens.textSecondary,
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: ToastSpacingTokens.sm),
                  Text(
                    priceLabel,
                    style: AppFonts.system(
                      color: ToastColorTokens.accentStrong,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: ToastSpacingTokens.sm),
            _QrStepper(
              itemId: item.id,
              itemName: item.name,
              quantity: quantity,
              copy: copy,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _QrStepper extends StatelessWidget {
  const _QrStepper({
    required this.itemId,
    required this.itemName,
    required this.quantity,
    required this.copy,
    required this.onChanged,
  });

  final String itemId;
  final String itemName;
  final int quantity;
  final QrOrderCopy copy;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          enabled: quantity > 0,
          label: copy.decreaseLabel(itemName),
          child: IconButton.filledTonal(
            key: Key('qr_decrease_$itemId'),
            tooltip: copy.decreaseLabel(itemName),
            onPressed: quantity <= 0 ? null : () => onChanged(quantity - 1),
            icon: const Icon(Icons.remove),
          ),
        ),
        SizedBox(
          width: 40,
          child: Semantics(
            liveRegion: true,
            label: copy.quantityLabel(quantity),
            child: Text(
              '$quantity',
              textAlign: TextAlign.center,
              style: AppFonts.system(
                color: ToastColorTokens.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        Semantics(
          button: true,
          enabled: quantity < 20,
          label: copy.increaseLabel(itemName),
          child: IconButton.filled(
            key: Key('qr_add_$itemId'),
            tooltip: copy.increaseLabel(itemName),
            onPressed: quantity >= 20 ? null : () => onChanged(quantity + 1),
            icon: const Icon(Icons.add),
          ),
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
    return Material(
      color: ToastColorTokens.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Align(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final textScale = MediaQuery.textScalerOf(context).scale(1);
                  final stacked = constraints.maxWidth < 560 || textScale > 1.4;
                  final summary = Semantics(
                    liveRegion: true,
                    label: copy.cartSummary(count, totalLabel),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          copy.cartSummary(count, totalLabel),
                          style: AppFonts.system(
                            color: ToastColorTokens.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: ToastSpacingTokens.xs),
                        Text(
                          count == 0
                              ? copy.cartDisabledReason
                              : copy.totalCaption,
                          style: AppFonts.system(
                            color: ToastColorTokens.textSecondary,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  );
                  final action = Semantics(
                    button: true,
                    enabled: onSubmit != null && !isSubmitting,
                    label: isSubmitting ? copy.processing : copy.submit,
                    child: FilledButton.icon(
                      key: const Key('qr_open_review'),
                      onPressed: isSubmitting ? null : onSubmit,
                      icon: isSubmitting
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.receipt_long_rounded),
                      label: Text(isSubmitting ? copy.processing : copy.review),
                    ),
                  );

                  if (stacked) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        summary,
                        const SizedBox(height: ToastSpacingTokens.sm),
                        action,
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: summary),
                      const SizedBox(width: ToastSpacingTokens.lg),
                      action,
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QrReviewDialog extends StatelessWidget {
  const _QrReviewDialog({
    required this.copy,
    required this.lines,
    required this.totalLabel,
  });

  final QrOrderCopy copy;
  final List<({QrMenuItem item, int quantity})> lines;
  final String totalLabel;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.88;
    return Dialog(
      key: const Key('qr_confirm_dialog'),
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.all(ToastSpacingTokens.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  copy.confirmTitle,
                  style: AppFonts.system(
                    color: ToastColorTokens.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
                ),
              ),
              const SizedBox(height: ToastSpacingTokens.sm),
              Text(
                copy.confirmBody,
                style: AppFonts.system(
                  color: ToastColorTokens.textSecondary,
                  fontSize: 14,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: ToastSpacingTokens.lg),
              Flexible(
                child: ListView.separated(
                  key: const Key('qr_review_items'),
                  shrinkWrap: true,
                  itemCount: lines.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: ToastSpacingTokens.lg),
                  itemBuilder: (context, index) {
                    final line = lines[index];
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            line.item.name,
                            style: AppFonts.system(
                              color: ToastColorTokens.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              height: 1.4,
                            ),
                          ),
                        ),
                        const SizedBox(width: ToastSpacingTokens.sm),
                        Text(
                          '×${line.quantity}',
                          style: AppFonts.system(
                            color: ToastColorTokens.textPrimary,
                            fontWeight: FontWeight.w800,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const Divider(height: ToastSpacingTokens.xxl),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      copy.reviewTotal,
                      style: AppFonts.system(
                        color: ToastColorTokens.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    totalLabel,
                    style: AppFonts.system(
                      color: ToastColorTokens.accentStrong,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: ToastSpacingTokens.lg),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: ToastSpacingTokens.sm,
                runSpacing: ToastSpacingTokens.sm,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(copy.cancel),
                  ),
                  FilledButton(
                    key: const Key('qr_confirm_submit'),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(copy.submit),
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
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ToastWorkSurface(
              padding: const EdgeInsets.all(ToastSpacingTokens.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    label: copy.successTitle,
                    liveRegion: true,
                    child: const Icon(
                      Icons.check_circle_rounded,
                      color: ToastColorTokens.success,
                      size: 36,
                    ),
                  ),
                  const SizedBox(height: ToastSpacingTokens.md),
                  Semantics(
                    header: true,
                    child: Text(
                      copy.successTitle,
                      style: AppFonts.system(
                        color: ToastColorTokens.textPrimary,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        height: 1.25,
                      ),
                    ),
                  ),
                  const SizedBox(height: ToastSpacingTokens.sm),
                  Text(
                    copy.successBody,
                    style: AppFonts.system(
                      color: ToastColorTokens.textSecondary,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: ToastSpacingTokens.xl),
                  Text(
                    copy.tableLabel(result.tableNumber, result.floorLabel),
                    style: AppFonts.system(
                      color: ToastColorTokens.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: ToastSpacingTokens.sm),
                  Text(
                    copy.orderReference(result.orderCode, result.batchNo),
                    style: AppFonts.system(
                      color: ToastColorTokens.accentStrong,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Divider(height: ToastSpacingTokens.xxl),
                  ...result.items.map(
                    (item) => Padding(
                      padding: const EdgeInsets.only(
                        bottom: ToastSpacingTokens.sm,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              item.name,
                              style: AppFonts.system(
                                color: ToastColorTokens.textPrimary,
                                fontSize: 15,
                                height: 1.4,
                              ),
                            ),
                          ),
                          Text(
                            '×${item.quantity}',
                            style: AppFonts.system(
                              color: ToastColorTokens.textPrimary,
                              fontWeight: FontWeight.w800,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: ToastSpacingTokens.md),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const Key('qr_add_more'),
                      onPressed: onAnotherOrder,
                      icon: const Icon(Icons.add),
                      label: Text(copy.addMore),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QrErrorBanner extends StatelessWidget {
  const _QrErrorBanner({
    required this.failure,
    required this.retryLabel,
    required this.onRetry,
  });

  final QrOrderFailurePresentation failure;
  final String retryLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: failure.stateKey,
      liveRegion: true,
      container: true,
      child: Container(
        padding: const EdgeInsets.all(ToastSpacingTokens.md),
        decoration: BoxDecoration(
          color: failure.kind == QrOrderFailureKind.rateLimit
              ? ToastColorTokens.warningMuted
              : ToastColorTokens.dangerMuted,
          borderRadius: ToastRadiusTokens.sm,
          border: Border.all(
            color: failure.kind == QrOrderFailureKind.rateLimit
                ? ToastColorTokens.warning
                : ToastColorTokens.danger,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              failure.icon,
              color: failure.kind == QrOrderFailureKind.rateLimit
                  ? ToastColorTokens.warning
                  : ToastColorTokens.danger,
            ),
            const SizedBox(width: ToastSpacingTokens.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    failure.title,
                    style: AppFonts.system(
                      color: ToastColorTokens.textPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: ToastSpacingTokens.xs),
                  Text(
                    failure.body,
                    style: AppFonts.system(
                      color: ToastColorTokens.textSecondary,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: ToastSpacingTokens.sm),
            TextButton(
              key: const Key('qr_submit_retry'),
              onPressed: onRetry,
              child: Text(retryLabel),
            ),
          ],
        ),
      ),
    );
  }
}

class _QrCenteredState extends StatelessWidget {
  const _QrCenteredState({
    required this.icon,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ToastWorkSurface(
            padding: const EdgeInsets.all(ToastSpacingTokens.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 36, color: ToastColorTokens.textSecondary),
                const SizedBox(height: ToastSpacingTokens.md),
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: AppFonts.system(
                      color: ToastColorTokens.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      height: 1.3,
                    ),
                  ),
                ),
                const SizedBox(height: ToastSpacingTokens.sm),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: AppFonts.system(
                    color: ToastColorTokens.textSecondary,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: ToastSpacingTokens.lg),
                FilledButton.icon(
                  key: const Key('qr_retry'),
                  onPressed: onAction,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(actionLabel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum QrOrderFailureKind {
  invalidExpiredOrUnavailable,
  paymentInProgress,
  rateLimit,
  itemUnavailable,
  invalidItems,
  offline,
  unavailable,
}

class QrOrderFailurePresentation {
  const QrOrderFailurePresentation({
    required this.kind,
    required this.title,
    required this.body,
  });

  final QrOrderFailureKind kind;
  final String title;
  final String body;

  Key get stateKey => Key(switch (kind) {
    QrOrderFailureKind.invalidExpiredOrUnavailable =>
      'qr_state_invalid_expired_unavailable',
    QrOrderFailureKind.paymentInProgress => 'qr_state_payment_processing',
    QrOrderFailureKind.rateLimit => 'qr_state_rate_limit',
    QrOrderFailureKind.itemUnavailable => 'qr_state_item_unavailable',
    QrOrderFailureKind.invalidItems => 'qr_state_invalid_items',
    QrOrderFailureKind.offline => 'qr_state_offline_retry',
    QrOrderFailureKind.unavailable => 'qr_state_unavailable',
  });

  IconData get icon => switch (kind) {
    QrOrderFailureKind.invalidExpiredOrUnavailable => Icons.qr_code_2_rounded,
    QrOrderFailureKind.paymentInProgress => Icons.point_of_sale_rounded,
    QrOrderFailureKind.rateLimit => Icons.schedule_rounded,
    QrOrderFailureKind.itemUnavailable => Icons.no_food_rounded,
    QrOrderFailureKind.invalidItems => Icons.edit_note_rounded,
    QrOrderFailureKind.offline => Icons.wifi_off_rounded,
    QrOrderFailureKind.unavailable => Icons.error_outline_rounded,
  };
}

class QrOrderCopy {
  const QrOrderCopy._(this.code);

  final String code;

  static QrOrderCopy forLanguage(String code) {
    return QrOrderCopy._(switch (code) {
      'ko' => 'ko',
      'vi' => 'vi',
      _ => 'en',
    });
  }

  String get loadingMenu => switch (code) {
    'ko' => '메뉴를 불러오는 중입니다',
    'vi' => 'Đang tải thực đơn',
    _ => 'Loading the menu',
  };

  String get headerHint => switch (code) {
    'ko' => '주문 전 테이블 번호를 확인해 주세요.',
    'vi' => 'Vui lòng kiểm tra đúng số bàn trước khi gọi món.',
    _ => 'Please confirm the table number before ordering.',
  };

  String get confirmTitle => switch (code) {
    'ko' => '주문 확인',
    'vi' => 'Xác nhận gọi món',
    _ => 'Review your order',
  };

  String get confirmBody => switch (code) {
    'ko' => '주문을 완료하면 바로 주방으로 전달됩니다. 결제는 식사 후 캐셔에서 진행합니다.',
    'vi' =>
      'Sau khi xác nhận, món sẽ được gửi thẳng đến bếp. Thanh toán sau bữa ăn tại quầy thu ngân.',
    _ =>
      'When you submit, the order goes directly to the kitchen. Payment is made at the cashier after your meal.',
  };

  String get review => switch (code) {
    'ko' => '주문 검토',
    'vi' => 'Xem lại món',
    _ => 'Review order',
  };

  String get reviewTotal => switch (code) {
    'ko' => '표시 합계',
    'vi' => 'Tổng hiển thị',
    _ => 'Displayed total',
  };

  String get submit => switch (code) {
    'ko' => '주문완료',
    'vi' => 'Gọi món',
    _ => 'Place order',
  };

  String get processing => switch (code) {
    'ko' => '주문 전송 중',
    'vi' => 'Đang gửi món',
    _ => 'Sending order',
  };

  String get cancel => switch (code) {
    'ko' => '취소',
    'vi' => 'Hủy',
    _ => 'Cancel',
  };

  String get totalCaption => switch (code) {
    'ko' => '표시용 합계입니다. 최종 금액은 캐셔 POS 기준입니다.',
    'vi' => 'Tổng này chỉ để tham khảo. Thu ngân sẽ tính trên POS.',
    _ => 'Displayed total only. The cashier will charge from the POS.',
  };

  String get cartDisabledReason => switch (code) {
    'ko' => '메뉴에서 수량을 추가하면 주문을 검토할 수 있습니다.',
    'vi' => 'Thêm số lượng món để xem lại đơn.',
    _ => 'Add an item to review the order.',
  };

  String get successTitle => switch (code) {
    'ko' => '주문이 접수되었습니다',
    'vi' => 'Đã nhận món',
    _ => 'Order received',
  };

  String get successBody => switch (code) {
    'ko' => '직원이 주문확인서를 가져다 드립니다. 결제는 식사 후 캐셔에서 진행해 주세요.',
    'vi' =>
      'Nhân viên sẽ mang phiếu xác nhận đến bàn. Vui lòng thanh toán sau bữa ăn tại quầy thu ngân.',
    _ =>
      'Staff will bring an order confirmation slip to your table. Please pay at the cashier after your meal.',
  };

  String get addMore => switch (code) {
    'ko' => '추가 주문하기',
    'vi' => 'Gọi thêm',
    _ => 'Add more',
  };

  String get retry => switch (code) {
    'ko' => '다시 시도',
    'vi' => 'Thử lại',
    _ => 'Retry',
  };

  String get emptyMenuTitle => switch (code) {
    'ko' => '현재 주문 가능한 메뉴가 없습니다',
    'vi' => 'Hiện chưa có món để gọi',
    _ => 'No items are available right now',
  };

  String get emptyMenuBody => switch (code) {
    'ko' => '메뉴가 준비되면 이 화면에 표시됩니다. 도움이 필요하면 직원을 불러주세요.',
    'vi' =>
      'Món sẽ xuất hiện tại đây khi sẵn sàng. Hãy gọi nhân viên nếu cần trợ giúp.',
    _ => 'Items will appear here when available. Please call staff for help.',
  };

  String get emptyCategoryTitle => switch (code) {
    'ko' => '이 분류에는 주문 가능한 메뉴가 없습니다',
    'vi' => 'Danh mục này chưa có món',
    _ => 'No items in this category',
  };

  String get emptyCategoryBody => switch (code) {
    'ko' => '위의 다른 메뉴 분류를 선택해 주세요.',
    'vi' => 'Vui lòng chọn danh mục khác ở phía trên.',
    _ => 'Choose another menu category above.',
  };

  String tableLabel(String tableNumber, String floorLabel) => switch (code) {
    'ko' => '$floorLabel · $tableNumber번 테이블',
    'vi' => '$floorLabel · Bàn $tableNumber',
    _ => '$floorLabel · Table $tableNumber',
  };

  String cartSummary(int count, String totalLabel) => switch (code) {
    'ko' => '$count개 · $totalLabel',
    'vi' => '$count món · $totalLabel',
    _ => '$count item(s) · $totalLabel',
  };

  String quantityLabel(int quantity) => switch (code) {
    'ko' => '수량 $quantity',
    'vi' => 'Số lượng $quantity',
    _ => 'Quantity $quantity',
  };

  String increaseLabel(String itemName) => switch (code) {
    'ko' => '$itemName 수량 추가',
    'vi' => 'Tăng số lượng $itemName',
    _ => 'Increase $itemName quantity',
  };

  String decreaseLabel(String itemName) => switch (code) {
    'ko' => '$itemName 수량 감소',
    'vi' => 'Giảm số lượng $itemName',
    _ => 'Decrease $itemName quantity',
  };

  String orderReference(String orderCode, int batchNo) => switch (code) {
    'ko' => '주문 $orderCode · 차수 $batchNo',
    'vi' => 'Đơn $orderCode · Lần $batchNo',
    _ => 'Order $orderCode · Batch $batchNo',
  };

  QrOrderFailurePresentation failureFor(Object error) {
    final raw = error.toString();
    if (raw.contains('QR_TOKEN_INVALID')) {
      return QrOrderFailurePresentation(
        kind: QrOrderFailureKind.invalidExpiredOrUnavailable,
        title: switch (code) {
          'ko' => 'QR을 사용할 수 없습니다',
          'vi' => 'Không thể sử dụng mã QR',
          _ => 'This QR cannot be used',
        },
        body: switch (code) {
          'ko' => '유효하지 않거나 만료되었거나 현재 사용할 수 없는 QR입니다. 직원을 불러주세요.',
          'vi' =>
            'Mã QR không hợp lệ, đã hết hạn hoặc hiện không khả dụng. Vui lòng gọi nhân viên.',
          _ =>
            'This QR is invalid, expired, or unavailable. Please call staff.',
        },
      );
    }
    if (raw.contains('QR_ORDER_PAYMENT_IN_PROGRESS')) {
      return QrOrderFailurePresentation(
        kind: QrOrderFailureKind.paymentInProgress,
        title: switch (code) {
          'ko' => '결제가 진행 중입니다',
          'vi' => 'Bàn đang thanh toán',
          _ => 'Payment is in progress',
        },
        body: switch (code) {
          'ko' => '추가 주문을 보낼 수 없습니다. 직원을 불러주세요.',
          'vi' => 'Không thể gửi thêm món. Vui lòng gọi nhân viên.',
          _ => 'Another order cannot be sent. Please call staff.',
        },
      );
    }
    if (raw.contains('QR_TOO_FREQUENT')) {
      return QrOrderFailurePresentation(
        kind: QrOrderFailureKind.rateLimit,
        title: switch (code) {
          'ko' => '잠시 기다려 주세요',
          'vi' => 'Vui lòng chờ một chút',
          _ => 'Please wait a moment',
        },
        body: switch (code) {
          'ko' => '직전 주문을 처리하고 있습니다. 같은 장바구니로 다시 시도해 주세요.',
          'vi' => 'Đơn trước đang được xử lý. Hãy thử lại với cùng giỏ món.',
          _ => 'The previous order is processing. Retry with the same cart.',
        },
      );
    }
    if (raw.contains('QR_MENU_ITEM_UNAVAILABLE')) {
      return QrOrderFailurePresentation(
        kind: QrOrderFailureKind.itemUnavailable,
        title: switch (code) {
          'ko' => '주문할 수 없는 메뉴가 있습니다',
          'vi' => 'Một số món không còn phục vụ',
          _ => 'An item is no longer available',
        },
        body: switch (code) {
          'ko' => '메뉴를 다시 불러온 뒤 장바구니를 확인해 주세요.',
          'vi' => 'Tải lại thực đơn rồi kiểm tra giỏ món.',
          _ => 'Reload the menu, then check the cart.',
        },
      );
    }
    if (raw.contains('QR_ITEMS_INVALID')) {
      return QrOrderFailurePresentation(
        kind: QrOrderFailureKind.invalidItems,
        title: switch (code) {
          'ko' => '주문 수량을 확인해 주세요',
          'vi' => 'Vui lòng kiểm tra số lượng',
          _ => 'Check item quantities',
        },
        body: switch (code) {
          'ko' => '수량을 수정하고 같은 장바구니로 다시 시도해 주세요.',
          'vi' => 'Điều chỉnh số lượng rồi thử lại với cùng giỏ món.',
          _ => 'Adjust quantities and retry with the same cart.',
        },
      );
    }
    final normalized = raw.toLowerCase();
    final looksOffline = const [
      'network',
      'offline',
      'socket',
      'timeout',
      'timed out',
      'failed host',
      'connection',
    ].any(normalized.contains);
    if (looksOffline) {
      return QrOrderFailurePresentation(
        kind: QrOrderFailureKind.offline,
        title: switch (code) {
          'ko' => '연결을 확인해 주세요',
          'vi' => 'Vui lòng kiểm tra kết nối',
          _ => 'Check your connection',
        },
        body: switch (code) {
          'ko' => '네트워크 오류입니다. 같은 장바구니로 다시 시도해 주세요.',
          'vi' => 'Lỗi mạng. Hãy thử lại với cùng giỏ món.',
          _ => 'Network error. Please retry with the same cart.',
        },
      );
    }
    return QrOrderFailurePresentation(
      kind: QrOrderFailureKind.unavailable,
      title: switch (code) {
        'ko' => '지금은 주문을 보낼 수 없습니다',
        'vi' => 'Hiện chưa thể gửi món',
        _ => 'Ordering is temporarily unavailable',
      },
      body: switch (code) {
        'ko' => '잠시 후 다시 시도하거나 직원을 불러주세요.',
        'vi' => 'Thử lại sau hoặc gọi nhân viên.',
        _ => 'Try again shortly or call staff.',
      },
    );
  }

  String errorFor(Object error) => failureFor(error).body;
}
