import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/services/live_refresh_service.dart';
import '../../core/services/qr_order_service.dart';
import '../../core/ui/app_fonts.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../core/utils/floor_label.dart';

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

class _QrOrderScreenState extends State<QrOrderScreen>
    with WidgetsBindingObserver {
  final _uuid = const Uuid();
  final _currency = NumberFormat('#,###', 'vi_VN');
  QrOrderMenu? _menu;
  QrActiveOrder? _activeOrder;
  QrOrderResult? _result;
  String? _selectedCategoryId;
  QrOrderFailurePresentation? _failure;
  String? _clientOrderId;
  bool _isLoading = true;
  bool _isSubmitting = false;
  bool _isRequestingLeftoverPackaging = false;
  bool _submittedOrderObserved = false;
  String _languageCode = 'vi';
  final Map<String, int> _cart = <String, int>{};
  final Map<String, List<String>> _comboDrinkChoices = <String, List<String>>{};
  Timer? _menuRefreshTimer;
  Timer? _liveMenuDebounceTimer;
  RealtimeChannel? _menuChannel;
  String? _subscribedStoreId;

  QrOrderService get _service => widget.service ?? qrOrderService;

  String _lineKey(String itemId, bool isTakeout) =>
      '$itemId|${isTakeout ? 'takeout' : 'dine_in'}';

  String _menuItemIdFromLineKey(String lineKey) => lineKey.split('|').first;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadMenu();
    _menuRefreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_loadMenu(showLoading: false));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_loadMenu(showLoading: false));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _menuRefreshTimer?.cancel();
    _liveMenuDebounceTimer?.cancel();
    _menuChannel?.unsubscribe();
    super.dispose();
  }

  Future<void> _subscribeMenuEvents(String? storeId) async {
    if (widget.service != null ||
        storeId == null ||
        storeId.isEmpty ||
        _subscribedStoreId == storeId) {
      return;
    }

    final previous = _menuChannel;
    _menuChannel = null;
    if (previous != null) await previous.unsubscribe();
    if (!mounted) return;

    _subscribedStoreId = storeId;
    _menuChannel = Supabase.instance.client
        .channel('public:qr_menu_events:$storeId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'pos_live_events',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'restaurant_id',
            value: storeId,
          ),
          callback: (payload) {
            final event = PosLiveEvent.fromRecord(payload.newRecord);
            if (event.affects({'menu', 'tables', 'settings'})) {
              _liveMenuDebounceTimer?.cancel();
              _liveMenuDebounceTimer = Timer(
                const Duration(milliseconds: 350),
                () => unawaited(_loadMenu(showLoading: false)),
              );
            }
          },
        )
        .subscribe();
  }

  Future<void> _loadMenu({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _isLoading = true;
        _failure = null;
      });
    }
    try {
      final responses = await Future.wait<Object>([
        _service.fetchMenu(widget.token),
        _service.fetchActiveOrder(widget.token),
      ]);
      final menu = responses[0] as QrOrderMenu;
      final activeOrder = responses[1] as QrActiveOrder;
      if (!mounted) return;
      unawaited(_subscribeMenuEvents(menu.storeId));
      setState(() {
        _menu = menu;
        _activeOrder = activeOrder;
        if (_result != null &&
            _submittedOrderObserved &&
            !activeOrder.isActive) {
          _result = null;
          _submittedOrderObserved = false;
        }
        final categoryStillExists = menu.categories.any(
          (category) => category.id == _selectedCategoryId,
        );
        if (!categoryStillExists) {
          _selectedCategoryId = menu.categories.isEmpty
              ? null
              : menu.categories.first.id;
        }
        final availableIds = menu.items.map((item) => item.id).toSet();
        _cart.removeWhere(
          (lineKey, _) =>
              !availableIds.contains(_menuItemIdFromLineKey(lineKey)),
        );
        _comboDrinkChoices.removeWhere(
          (lineKey, _) =>
              !availableIds.contains(_menuItemIdFromLineKey(lineKey)),
        );
        for (final item in menu.items) {
          for (final isTakeout in const [false, true]) {
            final lineKey = _lineKey(item.id, isTakeout);
            final quantity = _cart[lineKey] ?? 0;
            if (quantity == 0 || item.comboDrinkChoiceCount == 0) continue;
            final choices = _comboDrinkChoices[lineKey] ?? const <String>[];
            final validOptionIds = item.comboDrinkOptions
                .map((option) => option.id)
                .toSet();
            final choicesStillValid =
                choices.length == quantity * item.comboDrinkChoiceCount &&
                choices.every(validOptionIds.contains);
            if (!choicesStillValid) {
              _cart.remove(lineKey);
              _comboDrinkChoices.remove(lineKey);
            }
          }
        }
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (!showLoading && _menu != null) return;
      setState(() {
        _failure = _copy.failureFor(error);
        _isLoading = false;
      });
    }
  }

  QrOrderCopy get _copy {
    return QrOrderCopy.forLanguage(_languageCode);
  }

  List<QrMenuItem> get _visibleItems {
    final menu = _menu;
    if (menu == null) return const <QrMenuItem>[];
    final categoryId = _selectedCategoryId;
    if (categoryId == null) return menu.items;
    return menu.items.where((item) => item.categoryId == categoryId).toList();
  }

  List<({QrMenuItem item, int quantity, bool isTakeout, String lineKey})>
  get _cartItems {
    final menu = _menu;
    if (menu == null) return const [];
    return [
      for (final item in menu.items)
        for (final isTakeout in const [false, true])
          if ((_cart[_lineKey(item.id, isTakeout)] ?? 0) > 0)
            (
              item: item,
              quantity: _cart[_lineKey(item.id, isTakeout)]!,
              isTakeout: isTakeout,
              lineKey: _lineKey(item.id, isTakeout),
            ),
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

  String _localizedDrinkName(QrMenuItem item, String choiceId) {
    for (final option in item.comboDrinkOptions) {
      if (option.id == choiceId) {
        return option.localizedName(_languageCode);
      }
    }
    return choiceId;
  }

  Future<void> _setQuantity(
    QrMenuItem item,
    int quantity, {
    required bool isTakeout,
  }) async {
    final lineKey = _lineKey(item.id, isTakeout);
    final currentQuantity = _cart[lineKey] ?? 0;
    final choiceCount = item.comboDrinkChoiceCount;
    var choices = List<String>.from(_comboDrinkChoices[lineKey] ?? const []);

    if (quantity > currentQuantity && choiceCount > 0) {
      for (var unit = currentQuantity; unit < quantity; unit++) {
        final selected = await showDialog<List<String>>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _QrComboDrinkDialog(
            copy: _copy,
            languageCode: _languageCode,
            item: item,
          ),
        );
        if (selected == null || !mounted) return;
        choices.addAll(selected);
      }
    } else if (quantity < currentQuantity && choiceCount > 0) {
      final keep = (quantity.clamp(0, 20) * choiceCount).clamp(
        0,
        choices.length,
      );
      choices = choices.take(keep).toList(growable: true);
    }

    if (!mounted) return;
    setState(() {
      if (quantity <= 0) {
        _cart.remove(lineKey);
        _comboDrinkChoices.remove(lineKey);
      } else {
        _cart[lineKey] = quantity.clamp(1, 20);
        if (choiceCount > 0) {
          _comboDrinkChoices[lineKey] = choices;
        }
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
        languageCode: _languageCode,
        lines: _cartItems,
        totalLabel: '${_currency.format(_cartTotal)} VND',
        comboDrinkNames: {
          for (final line in _cartItems)
            line.lineKey: [
              for (final choiceId
                  in _comboDrinkChoices[line.lineKey] ?? const <String>[])
                _localizedDrinkName(line.item, choiceId),
            ],
        },
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _isSubmitting = true;
      _failure = null;
      _clientOrderId ??= _uuid.v4();
    });

    try {
      final submittedItems = _cartItems;
      final result = await _service.placeOrder(
        token: widget.token,
        clientOrderId: _clientOrderId!,
        items: [
          for (final line in submittedItems)
            QrOrderLine(
              menuItemId: line.item.id,
              quantity: line.quantity,
              isTakeout: line.isTakeout,
              comboDrinkChoices:
                  _comboDrinkChoices[line.lineKey] ?? const <String>[],
            ),
        ],
      );
      if (!mounted) return;
      setState(() {
        _result = QrOrderResult(
          orderCode: result.orderCode,
          batchNo: result.batchNo,
          tableNumber: result.tableNumber,
          floorLabel: result.floorLabel,
          items: [
            for (final line in submittedItems)
              QrOrderResultItem(
                name: line.item.localizedName(_languageCode),
                quantity: line.quantity,
                isTakeout: line.isTakeout,
              ),
          ],
        );
        _cart.clear();
        _comboDrinkChoices.clear();
        _clientOrderId = null;
        _isSubmitting = false;
      });
      unawaited(_refreshActiveOrderAfterSubmit());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _failure = _copy.failureFor(error);
        _isSubmitting = false;
      });
    }
  }

  Future<void> _refreshActiveOrderAfterSubmit() async {
    try {
      final activeOrder = await _service.fetchActiveOrder(widget.token);
      if (!mounted || _result == null) return;
      setState(() {
        _activeOrder = activeOrder;
        _submittedOrderObserved = activeOrder.isActive;
      });
    } catch (_) {
      // The success snapshot remains available and the regular refresh loop
      // retries without making a successful order look like a failure.
    }
  }

  Future<void> _requestLeftoverPackaging() async {
    final activeOrder = _activeOrder;
    if (activeOrder == null ||
        !activeOrder.isActive ||
        activeOrder.leftoverPackagingStatus != null ||
        _isRequestingLeftoverPackaging) {
      return;
    }
    final confirmed = await ToastConfirmDialog.show(
      context: context,
      title: _copy.leftoverPackagingConfirmTitle,
      description: _copy.leftoverPackagingConfirmBody,
      cancelLabel: _copy.cancel,
      confirmLabel: _copy.leftoverPackagingRequest,
      icon: Icons.takeout_dining_outlined,
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _isRequestingLeftoverPackaging = true;
      _failure = null;
    });
    try {
      await _service.requestLeftoverPackaging(
        token: widget.token,
        requestId: _uuid.v4(),
      );
      final refreshed = await _service.fetchActiveOrder(widget.token);
      if (!mounted) return;
      setState(() => _activeOrder = refreshed);
    } catch (error) {
      if (!mounted) return;
      setState(() => _failure = _copy.failureFor(error));
    } finally {
      if (mounted) {
        setState(() => _isRequestingLeftoverPackaging = false);
      }
    }
  }

  void _startAnotherOrder() {
    setState(() {
      _result = null;
      _submittedOrderObserved = false;
      _failure = null;
      _clientOrderId = null;
    });
    unawaited(_loadMenu(showLoading: false));
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
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: ToastSpacingTokens.md),
                  Text(
                    _copy.loadingMenu,
                    textAlign: TextAlign.center,
                    style: AppFonts.system(
                      color: ToastColorTokens.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
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
            activeOrder: _activeOrder?.isActive == true ? _activeOrder : null,
            languageCode: _languageCode,
            onAnotherOrder: _startAnotherOrder,
            onRequestLeftoverPackaging: _requestLeftoverPackaging,
            isRequestingLeftoverPackaging: _isRequestingLeftoverPackaging,
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
                  if (_activeOrder?.isActive == true &&
                      _activeOrder!.items.isNotEmpty)
                    SliverToBoxAdapter(
                      child: _QrActiveOrderCard(
                        order: _activeOrder!,
                        languageCode: _languageCode,
                        copy: _copy,
                        onRequestLeftoverPackaging: _requestLeftoverPackaging,
                        isRequestingLeftoverPackaging:
                            _isRequestingLeftoverPackaging,
                        footerLabel: _copy.addItemsTitle,
                      ),
                    ),
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
                            languageCode: _languageCode,
                            dineInQuantity:
                                _cart[_lineKey(item.id, false)] ?? 0,
                            takeoutQuantity:
                                _cart[_lineKey(item.id, true)] ?? 0,
                            priceLabel: '${_currency.format(item.price)} VND',
                            originalPriceLabel:
                                item.discountPercent > 0 &&
                                    item.originalPrice != null
                                ? '${_currency.format(item.originalPrice)} VND'
                                : null,
                            copy: _copy,
                            onDineInChanged: (quantity) => unawaited(
                              _setQuantity(item, quantity, isTakeout: false),
                            ),
                            onTakeoutChanged: (quantity) => unawaited(
                              _setQuantity(item, quantity, isTakeout: true),
                            ),
                          );
                        },
                      ),
                    ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      child: Container(
                        key: const Key('qr_environmental_notice'),
                        padding: const EdgeInsets.all(ToastSpacingTokens.md),
                        decoration: BoxDecoration(
                          color: ToastColorTokens.successMuted,
                          borderRadius: ToastRadiusTokens.sm,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.eco_rounded,
                              size: 20,
                              color: ToastColorTokens.success,
                            ),
                            const SizedBox(width: ToastSpacingTokens.sm),
                            Expanded(
                              child: Text(
                                _copy.environmentalNotice,
                                style: AppFonts.system(
                                  color: ToastColorTokens.textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  menu.storeName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.system(
                    color: ToastColorTokens.textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: ToastSpacingTokens.sm),
              DropdownButton<String>(
                key: const Key('qr_language_selector'),
                value: _languageCode,
                items: const [
                  DropdownMenuItem(value: 'vi', child: Text('Tiếng Việt')),
                  DropdownMenuItem(value: 'ko', child: Text('한국어')),
                  DropdownMenuItem(value: 'en', child: Text('English')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _languageCode = value);
                },
              ),
            ],
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
                Container(
                  key: menu.promotionDiscountPercent > 0
                      ? const Key('qr_active_promotion')
                      : const Key('qr_welcome_message'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: ToastSpacingTokens.sm,
                    vertical: ToastSpacingTokens.xs,
                  ),
                  decoration: BoxDecoration(
                    color: menu.promotionDiscountPercent > 0
                        ? ToastColorTokens.warningMuted
                        : ToastColorTokens.mutedSurface,
                    borderRadius: ToastRadiusTokens.sm,
                  ),
                  child: Text(
                    menu.promotionDiscountPercent > 0
                        ? _copy.promotionLabel(
                            menu.promotionName ?? '',
                            menu.promotionDiscountPercent,
                          )
                        : _copy.welcomeMessage,
                    style: AppFonts.system(
                      color: ToastColorTokens.textPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _copy.vatExclusiveNotice,
                  key: const Key('qr_vat_exclusive_notice'),
                  style: AppFonts.system(
                    color: ToastColorTokens.textSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
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
          final categoryName = category.localizedName(_languageCode);
          final selected = category.id == _selectedCategoryId;
          return Semantics(
            selected: selected,
            button: true,
            label: categoryName,
            child: ChoiceChip(
              key: Key('qr_category_${category.id}'),
              label: Text(categoryName),
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

class _QrActiveOrderCard extends StatelessWidget {
  const _QrActiveOrderCard({
    required this.order,
    required this.languageCode,
    required this.copy,
    this.onRequestLeftoverPackaging,
    this.isRequestingLeftoverPackaging = false,
    this.footerLabel,
  });

  final QrActiveOrder order;
  final String languageCode;
  final QrOrderCopy copy;
  final VoidCallback? onRequestLeftoverPackaging;
  final bool isRequestingLeftoverPackaging;
  final String? footerLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: ToastWorkSurface(
        key: const Key('qr_active_order_summary'),
        padding: const EdgeInsets.all(ToastSpacingTokens.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(ToastSpacingTokens.sm),
                  decoration: BoxDecoration(
                    color: ToastColorTokens.successMuted,
                    borderRadius: ToastRadiusTokens.sm,
                  ),
                  child: const Icon(
                    Icons.receipt_long_rounded,
                    color: ToastColorTokens.success,
                  ),
                ),
                const SizedBox(width: ToastSpacingTokens.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          copy.activeOrderTitle,
                          style: AppFonts.system(
                            color: ToastColorTokens.textPrimary,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(height: ToastSpacingTokens.xs),
                      Text(
                        copy.activeOrderHelper,
                        style: AppFonts.system(
                          color: ToastColorTokens.textSecondary,
                          fontSize: 14,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: ToastSpacingTokens.md),
            const Divider(height: 1),
            for (var index = 0; index < order.items.length; index++) ...[
              Padding(
                key: Key('qr_active_order_item_$index'),
                padding: const EdgeInsets.symmetric(
                  vertical: ToastSpacingTokens.sm,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final item = order.items[index];
                    final name = Text(
                      item.localizedName(languageCode),
                      style: AppFonts.system(
                        color: ToastColorTokens.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                      ),
                    );
                    final details = Wrap(
                      spacing: ToastSpacingTokens.sm,
                      runSpacing: ToastSpacingTokens.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '× ${item.quantity}',
                          style: AppFonts.system(
                            color: ToastColorTokens.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        Container(
                          key: Key('qr_active_order_mode_$index'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: ToastSpacingTokens.sm,
                            vertical: ToastSpacingTokens.xs,
                          ),
                          decoration: BoxDecoration(
                            color: item.isTakeout
                                ? ToastColorTokens.warningMuted
                                : ToastColorTokens.mutedSurface,
                            borderRadius: ToastRadiusTokens.pill,
                          ),
                          child: Text(
                            item.isTakeout ? copy.takeout : copy.dineIn,
                            style: AppFonts.system(
                              color: item.isTakeout
                                  ? ToastColorTokens.warning
                                  : ToastColorTokens.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (order.isPaperless)
                          Container(
                            key: Key('qr_delivery_progress_$index'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: ToastSpacingTokens.sm,
                              vertical: ToastSpacingTokens.xs,
                            ),
                            decoration: BoxDecoration(
                              color: item.remainingQuantity == 0
                                  ? ToastColorTokens.successMuted
                                  : ToastColorTokens.infoMuted,
                              borderRadius: ToastRadiusTokens.pill,
                            ),
                            child: Text(
                              copy.deliveryProgress(
                                item.servedQuantity,
                                item.remainingQuantity,
                              ),
                              style: AppFonts.system(
                                color: item.remainingQuantity == 0
                                    ? ToastColorTokens.success
                                    : ToastColorTokens.info,
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                      ],
                    );
                    final stacked =
                        constraints.maxWidth < 420 ||
                        MediaQuery.textScalerOf(context).scale(1) > 1.4;
                    if (stacked) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          name,
                          const SizedBox(height: ToastSpacingTokens.sm),
                          Align(
                            alignment: Alignment.centerRight,
                            child: details,
                          ),
                          if (order.isPaperless &&
                              item.fulfillmentParts.isNotEmpty)
                            _QrFulfillmentParts(
                              parts: item.fulfillmentParts,
                              languageCode: languageCode,
                              copy: copy,
                            ),
                        ],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(child: name),
                            const SizedBox(width: ToastSpacingTokens.sm),
                            details,
                          ],
                        ),
                        if (order.isPaperless &&
                            item.fulfillmentParts.isNotEmpty)
                          _QrFulfillmentParts(
                            parts: item.fulfillmentParts,
                            languageCode: languageCode,
                            copy: copy,
                          ),
                      ],
                    );
                  },
                ),
              ),
              if (index < order.items.length - 1) const Divider(height: 1),
            ],
            if (onRequestLeftoverPackaging != null) ...[
              const SizedBox(height: ToastSpacingTokens.xs),
              if (order.leftoverPackagingStatus == null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('qr_leftover_packaging_request'),
                    onPressed: isRequestingLeftoverPackaging
                        ? null
                        : onRequestLeftoverPackaging,
                    icon: isRequestingLeftoverPackaging
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.takeout_dining_outlined, size: 18),
                    label: Text(copy.leftoverPackagingRequest),
                  ),
                )
              else
                Container(
                  key: const Key('qr_leftover_packaging_status'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: ToastSpacingTokens.md,
                    vertical: ToastSpacingTokens.sm,
                  ),
                  decoration: BoxDecoration(
                    color: ToastColorTokens.warningMuted,
                    borderRadius: ToastRadiusTokens.sm,
                  ),
                  child: Text(
                    copy.leftoverPackagingStatus(
                      order.leftoverPackagingStatus!,
                    ),
                    style: AppFonts.system(
                      color: ToastColorTokens.textPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
            if (footerLabel != null) ...[
              const Divider(height: ToastSpacingTokens.lg),
              Semantics(
                header: true,
                child: Text(
                  footerLabel!,
                  key: const Key('qr_additional_order_title'),
                  style: AppFonts.system(
                    color: ToastColorTokens.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _QrFulfillmentParts extends StatelessWidget {
  const _QrFulfillmentParts({
    required this.parts,
    required this.languageCode,
    required this.copy,
  });

  final List<QrFulfillmentPart> parts;
  final String languageCode;
  final QrOrderCopy copy;

  @override
  Widget build(BuildContext context) => Padding(
    key: const Key('qr_fulfillment_parts'),
    padding: const EdgeInsets.only(top: ToastSpacingTokens.sm),
    child: Wrap(
      spacing: ToastSpacingTokens.sm,
      runSpacing: ToastSpacingTokens.xs,
      children: [
        for (final part in parts)
          Container(
            key: ValueKey('qr_fulfillment_part_${part.lineKey}'),
            padding: const EdgeInsets.symmetric(
              horizontal: ToastSpacingTokens.sm,
              vertical: ToastSpacingTokens.xs,
            ),
            decoration: BoxDecoration(
              color: part.remainingQuantity == 0
                  ? ToastColorTokens.successMuted
                  : ToastColorTokens.mutedSurface,
              borderRadius: ToastRadiusTokens.pill,
            ),
            child: Text(
              '${part.localizedName(languageCode)} '
              '${copy.deliveryProgress(part.servedQuantity, part.remainingQuantity)}',
              style: AppFonts.system(
                color: part.remainingQuantity == 0
                    ? ToastColorTokens.success
                    : ToastColorTokens.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    ),
  );
}

class _QrMenuItemTile extends StatelessWidget {
  const _QrMenuItemTile({
    required this.item,
    required this.languageCode,
    required this.dineInQuantity,
    required this.takeoutQuantity,
    required this.priceLabel,
    this.originalPriceLabel,
    required this.copy,
    required this.onDineInChanged,
    required this.onTakeoutChanged,
  });

  final QrMenuItem item;
  final String languageCode;
  final int dineInQuantity;
  final int takeoutQuantity;
  final String priceLabel;
  final String? originalPriceLabel;
  final QrOrderCopy copy;
  final ValueChanged<int> onDineInChanged;
  final ValueChanged<int> onTakeoutChanged;

  @override
  Widget build(BuildContext context) {
    final itemName = item.localizedName(languageCode);
    final hasImage = (item.imageUrl ?? '').trim().isNotEmpty;
    final image = hasImage
        ? ClipRRect(
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
          )
        : null;
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          itemName,
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
        if (item.comboDrinkChoiceCount > 0) ...[
          const SizedBox(height: ToastSpacingTokens.xs),
          Text(
            copy.comboDrinkIncluded(item.comboDrinkChoiceCount),
            key: Key('qr_combo_drink_count_${item.id}'),
            style: AppFonts.system(
              color: ToastColorTokens.accentStrong,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        const SizedBox(height: ToastSpacingTokens.sm),
        if (originalPriceLabel != null) ...[
          Text(
            originalPriceLabel!,
            key: Key('qr_original_price_${item.id}'),
            style: AppFonts.system(
              color: ToastColorTokens.textSecondary,
              fontSize: 13,
              decoration: TextDecoration.lineThrough,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: ToastSpacingTokens.xs),
        ],
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
    );
    final controls = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _QrLabeledStepper(
          label: copy.dineIn,
          itemId: item.id,
          itemName: '$itemName ${copy.dineIn}',
          quantity: dineInQuantity,
          copy: copy,
          onChanged: onDineInChanged,
        ),
        const SizedBox(height: ToastSpacingTokens.sm),
        _QrLabeledStepper(
          label: copy.takeout,
          itemId: '${item.id}_takeout',
          itemName: '$itemName ${copy.takeout}',
          quantity: takeoutQuantity,
          copy: copy,
          onChanged: onTakeoutChanged,
        ),
      ],
    );
    return Semantics(
      key: Key('qr_menu_item_${item.id}'),
      container: true,
      label:
          '$itemName, $priceLabel, ${copy.dineIn} ${copy.quantityLabel(dineInQuantity)}, ${copy.takeout} ${copy.quantityLabel(takeoutQuantity)}',
      child: ToastWorkSurface(
        padding: const EdgeInsets.all(ToastSpacingTokens.md),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stacked =
                constraints.maxWidth < 520 ||
                MediaQuery.textScalerOf(context).scale(1) > 1.4;
            if (stacked) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (image != null) ...[
                    Align(alignment: Alignment.centerLeft, child: image),
                    const SizedBox(height: ToastSpacingTokens.md),
                  ],
                  details,
                  const SizedBox(height: ToastSpacingTokens.md),
                  controls,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (image != null) ...[
                  image,
                  const SizedBox(width: ToastSpacingTokens.md),
                ],
                Expanded(child: details),
                const SizedBox(width: ToastSpacingTokens.sm),
                controls,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _QrLabeledStepper extends StatelessWidget {
  const _QrLabeledStepper({
    required this.label,
    required this.itemId,
    required this.itemName,
    required this.quantity,
    required this.copy,
    required this.onChanged,
  });

  final String label;
  final String itemId;
  final String itemName;
  final int quantity;
  final QrOrderCopy copy;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 64,
        child: Text(
          label,
          textAlign: TextAlign.right,
          style: AppFonts.system(
            color: ToastColorTokens.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      const SizedBox(width: ToastSpacingTokens.sm),
      _QrStepper(
        itemId: itemId,
        itemName: itemName,
        quantity: quantity,
        copy: copy,
        onChanged: onChanged,
      ),
    ],
  );
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

class _QrComboDrinkDialog extends StatefulWidget {
  const _QrComboDrinkDialog({
    required this.copy,
    required this.languageCode,
    required this.item,
  });

  final QrOrderCopy copy;
  final String languageCode;
  final QrMenuItem item;

  @override
  State<_QrComboDrinkDialog> createState() => _QrComboDrinkDialogState();
}

class _QrComboDrinkDialogState extends State<_QrComboDrinkDialog> {
  final Map<String, int> _quantities = {};

  int get _selectedCount =>
      _quantities.values.fold(0, (sum, quantity) => sum + quantity);

  @override
  Widget build(BuildContext context) {
    final requiredCount = widget.item.comboDrinkChoiceCount;
    return AlertDialog(
      key: Key('qr_combo_drink_dialog_${widget.item.id}'),
      title: Text(widget.copy.chooseComboDrinksTitle),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.copy.chooseComboDrinksBody(requiredCount),
              style: AppFonts.system(
                color: ToastColorTokens.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: ToastSpacingTokens.md),
            Container(
              padding: const EdgeInsets.all(ToastSpacingTokens.sm),
              decoration: BoxDecoration(
                color: ToastColorTokens.mutedSurface,
                borderRadius: ToastRadiusTokens.sm,
              ),
              child: Text(
                widget.copy.comboDrinkSelectionProgress(
                  _selectedCount,
                  requiredCount,
                ),
                key: const Key('qr_combo_drink_progress'),
                style: AppFonts.system(
                  color: _selectedCount == requiredCount
                      ? ToastColorTokens.success
                      : ToastColorTokens.textPrimary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: ToastSpacingTokens.sm),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: widget.item.comboDrinkOptions.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final option = widget.item.comboDrinkOptions[index];
                  final quantity = _quantities[option.id] ?? 0;
                  return ListTile(
                    key: Key('qr_combo_drink_option_${option.id}'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(option.localizedName(widget.languageCode)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton.outlined(
                          key: Key('qr_combo_drink_minus_${option.id}'),
                          onPressed: quantity == 0
                              ? null
                              : () => setState(() {
                                  if (quantity == 1) {
                                    _quantities.remove(option.id);
                                  } else {
                                    _quantities[option.id] = quantity - 1;
                                  }
                                }),
                          icon: const Icon(Icons.remove, size: 18),
                        ),
                        SizedBox(
                          width: 36,
                          child: Text(
                            '$quantity',
                            textAlign: TextAlign.center,
                            style: AppFonts.system(
                              color: ToastColorTokens.textPrimary,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton.filled(
                          key: Key('qr_combo_drink_plus_${option.id}'),
                          onPressed: _selectedCount >= requiredCount
                              ? null
                              : () => setState(() {
                                  _quantities[option.id] = quantity + 1;
                                }),
                          icon: const Icon(Icons.add, size: 18),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.copy.cancel),
        ),
        FilledButton(
          key: const Key('qr_combo_drink_confirm'),
          onPressed: _selectedCount != requiredCount
              ? null
              : () => Navigator.of(context).pop([
                  for (final option in widget.item.comboDrinkOptions)
                    for (
                      var count = 0;
                      count < (_quantities[option.id] ?? 0);
                      count++
                    )
                      option.id,
                ]),
          child: Text(widget.copy.confirmDrinkChoice),
        ),
      ],
    );
  }
}

class _QrReviewDialog extends StatelessWidget {
  const _QrReviewDialog({
    required this.copy,
    required this.languageCode,
    required this.lines,
    required this.totalLabel,
    required this.comboDrinkNames,
  });

  final QrOrderCopy copy;
  final String languageCode;
  final List<({QrMenuItem item, int quantity, bool isTakeout, String lineKey})>
  lines;
  final String totalLabel;
  final Map<String, List<String>> comboDrinkNames;

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
                    final drinks = comboDrinkNames[line.lineKey] ?? const [];
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                line.item.localizedName(languageCode),
                                style: AppFonts.system(
                                  color: ToastColorTokens.textPrimary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: ToastSpacingTokens.xs),
                              Text(
                                line.isTakeout ? copy.takeout : copy.dineIn,
                                key: Key('qr_review_mode_${line.lineKey}'),
                                style: AppFonts.system(
                                  color: line.isTakeout
                                      ? ToastColorTokens.warning
                                      : ToastColorTokens.textSecondary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              if (drinks.isNotEmpty) ...[
                                const SizedBox(height: ToastSpacingTokens.xs),
                                Text(
                                  drinks.join(', '),
                                  key: Key(
                                    'qr_review_combo_drinks_${line.isTakeout ? '${line.item.id}_takeout' : line.item.id}',
                                  ),
                                  style: AppFonts.system(
                                    color: ToastColorTokens.textSecondary,
                                    fontSize: 13,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ],
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
    required this.activeOrder,
    required this.languageCode,
    required this.onAnotherOrder,
    required this.onRequestLeftoverPackaging,
    required this.isRequestingLeftoverPackaging,
  });

  final QrOrderCopy copy;
  final QrOrderResult result;
  final QrActiveOrder? activeOrder;
  final String languageCode;
  final VoidCallback onAnotherOrder;
  final VoidCallback onRequestLeftoverPackaging;
  final bool isRequestingLeftoverPackaging;

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
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.name,
                                  style: AppFonts.system(
                                    color: ToastColorTokens.textPrimary,
                                    fontSize: 15,
                                    height: 1.4,
                                  ),
                                ),
                                Text(
                                  item.isTakeout ? copy.takeout : copy.dineIn,
                                  style: AppFonts.system(
                                    color: item.isTakeout
                                        ? ToastColorTokens.warning
                                        : ToastColorTokens.textSecondary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
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
            if (activeOrder != null) ...[
              const SizedBox(height: ToastSpacingTokens.md),
              _QrActiveOrderCard(
                order: activeOrder!,
                languageCode: languageCode,
                copy: copy,
                onRequestLeftoverPackaging: onRequestLeftoverPackaging,
                isRequestingLeftoverPackaging: isRequestingLeftoverPackaging,
              ),
            ],
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

  String get environmentalNotice => switch (code) {
    'ko' => '우리 회사는 환경 보호를 실천합니다. 종이 영수증 사용을 줄여 환경 보호에 동참해 주세요.',
    'vi' =>
      'Chúng tôi chung tay bảo vệ môi trường. Hãy hạn chế sử dụng hóa đơn giấy để cùng góp phần bảo vệ môi trường.',
    _ =>
      'We are committed to protecting the environment. Please help by reducing the use of paper receipts.',
  };

  String get activeOrderTitle => switch (code) {
    'ko' => '현재 주문 내역',
    'vi' => 'Các món đã gọi',
    _ => 'Current order',
  };

  String get activeOrderHelper => switch (code) {
    'ko' => '이미 접수된 메뉴입니다. 추가로 주문할 메뉴는 아래에서 선택해 주세요.',
    'vi' =>
      'Các món này đã được gửi. Chọn thêm món bên dưới nếu bạn muốn gọi thêm.',
    _ =>
      'These items have already been sent. Choose more items below to add an order.',
  };

  String get dineIn => switch (code) {
    'ko' => '홀',
    'vi' => 'Tại bàn',
    _ => 'Dine-in',
  };

  String get takeout => switch (code) {
    'ko' => '포장 주문',
    'vi' => 'Mang đi',
    _ => 'Takeout',
  };

  String get leftoverPackagingRequest => switch (code) {
    'ko' => '남은 음식 포장 요청',
    'vi' => 'Yêu cầu gói đồ ăn thừa',
    _ => 'Pack leftover food',
  };

  String get leftoverPackagingConfirmTitle => switch (code) {
    'ko' => '남은 음식을 포장할까요?',
    'vi' => 'Gói đồ ăn thừa mang về?',
    _ => 'Pack the leftover food?',
  };

  String get leftoverPackagingConfirmBody => switch (code) {
    'ko' => '요청하면 담당 층 직원에게 먼저 알림이 전달됩니다.',
    'vi' => 'Yêu cầu sẽ báo cho nhân viên tầng phụ trách trước.',
    _ => 'The request will alert the assigned floor staff first.',
  };

  String leftoverPackagingStatus(String status) => switch (status) {
    'awaiting_floor_pickup' => switch (code) {
      'ko' => '담당 층에서 요청을 확인 중입니다.',
      'vi' => 'Nhân viên tầng đang kiểm tra yêu cầu.',
      _ => 'Floor staff are checking the request.',
    },
    'awaiting_kitchen_packaging' => switch (code) {
      'ko' => '주방에서 포장 중입니다.',
      'vi' => 'Bếp đang đóng gói.',
      _ => 'The kitchen is packing the food.',
    },
    'awaiting_tray_return' || 'awaiting_floor_delivery' => switch (code) {
      'ko' => '포장한 음식을 테이블로 전달 중입니다.',
      'vi' => 'Đồ ăn đã gói đang được chuyển đến bàn.',
      _ => 'The packed food is on its way to the table.',
    },
    'completed' => switch (code) {
      'ko' => '포장 전달이 완료되었습니다.',
      'vi' => 'Đã giao đồ ăn được đóng gói.',
      _ => 'The packed food has been delivered.',
    },
    _ => switch (code) {
      'ko' => '포장 요청을 전달 중입니다.',
      'vi' => 'Yêu cầu đóng gói đang được chuyển.',
      _ => 'The packaging request is being passed along.',
    },
  };

  String deliveryProgress(int served, int remaining) => switch (code) {
    'ko' => '전달 $served · 남음 $remaining',
    'vi' => 'Đã giao $served · Còn $remaining',
    _ => 'Delivered $served · Remaining $remaining',
  };

  String get addItemsTitle => switch (code) {
    'ko' => '추가 주문 메뉴',
    'vi' => 'Chọn món gọi thêm',
    _ => 'Add more items',
  };

  String itemStatus(String status) => switch (status) {
    'preparing' => switch (code) {
      'ko' => '준비 중',
      'vi' => 'Đang chuẩn bị',
      _ => 'Preparing',
    },
    'ready' => switch (code) {
      'ko' => '준비 완료',
      'vi' => 'Đã sẵn sàng',
      _ => 'Ready',
    },
    'served' => switch (code) {
      'ko' => '제공 완료',
      'vi' => 'Đã phục vụ',
      _ => 'Served',
    },
    _ => switch (code) {
      'ko' => '접수 완료',
      'vi' => 'Đã nhận',
      _ => 'Received',
    },
  };

  String promotionLabel(String name, double percent) {
    final percentLabel = percent == percent.roundToDouble()
        ? percent.toInt().toString()
        : percent.toStringAsFixed(1);
    final prefix = name.trim().isEmpty ? '' : '${name.trim()} · ';
    return switch (code) {
      'ko' => '$prefix전 메뉴 $percentLabel% 할인',
      'vi' => '${prefix}Giảm $percentLabel% toàn bộ thực đơn',
      _ => '$prefix$percentLabel% off all menu items',
    };
  }

  String get welcomeMessage => switch (code) {
    'ko' => '정성껏 만들었습니다. 맛있게 드세요.',
    'vi' => 'Món ăn được chuẩn bị tận tâm. Chúc quý khách ngon miệng.',
    _ => 'Made with care. Enjoy your meal.',
  };

  String get vatExclusiveNotice => switch (code) {
    'ko' => '부가세 8% 별도입니다.',
    'vi' => 'Chưa bao gồm 8% VAT.',
    _ => '8% VAT is not included.',
  };

  String get confirmTitle => switch (code) {
    'ko' => '주문 확인',
    'vi' => 'Xác nhận gọi món',
    _ => 'Review your order',
  };

  String get confirmBody => switch (code) {
    'ko' => '주문완료를 누르면 주문확인서가 주방과 해당 층에 출력되고 캐셔로 바로 전달됩니다.',
    'vi' =>
      'Khi hoàn tất, phiếu xác nhận sẽ được in tại bếp và tầng hiện tại, đồng thời đơn sẽ được chuyển đến thu ngân.',
    _ =>
      'When completed, confirmation slips print in the kitchen and on this floor, and the order goes straight to the cashier.',
  };

  String get chooseComboDrinksTitle => switch (code) {
    'ko' => '콤보 음료 선택',
    'vi' => 'Chọn đồ uống cho combo',
    _ => 'Choose combo drinks',
  };

  String chooseComboDrinksBody(int count) => switch (code) {
    'ko' => '이 콤보에 포함된 음료 $count개를 선택해 주세요.',
    'vi' => 'Vui lòng chọn $count đồ uống đi kèm combo này.',
    _ => 'Choose $count drink(s) included with this combo.',
  };

  String comboDrinkSelectionProgress(int selected, int required) =>
      switch (code) {
        'ko' => '$required개 중 $selected개 선택',
        'vi' => 'Đã chọn $selected / $required',
        _ => '$selected of $required selected',
      };

  String comboDrinkIncluded(int count) => switch (code) {
    'ko' => '음료 $count개 선택 포함',
    'vi' => 'Bao gồm lựa chọn $count đồ uống',
    _ => 'Includes $count drink choice(s)',
  };

  String get confirmDrinkChoice => switch (code) {
    'ko' => '음료 선택 완료',
    'vi' => 'Xác nhận đồ uống',
    _ => 'Confirm drinks',
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
    'vi' => 'Hoàn tất đơn hàng',
    _ => 'Complete order',
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
    'ko' => '주문이 완료되었습니다',
    'vi' => 'Đơn hàng đã hoàn tất',
    _ => 'Order completed',
  };

  String get successBody => switch (code) {
    'ko' => '주문확인서가 주방과 해당 층에 출력되었습니다. 결제는 캐셔에서 진행해 주세요.',
    'vi' =>
      'Phiếu xác nhận đã được gửi đến bếp và tầng hiện tại. Vui lòng thanh toán tại quầy thu ngân.',
    _ =>
      'Confirmation slips were sent to the kitchen and this floor. Please pay at the cashier.',
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

  String tableLabel(String tableNumber, String floorLabel) {
    final displayFloor = displayFloorLabel(floorLabel);
    return switch (code) {
      'ko' => '$displayFloor · $tableNumber번 테이블',
      'vi' => '$displayFloor · Bàn $tableNumber',
      _ => '$displayFloor · Table $tableNumber',
    };
  }

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
