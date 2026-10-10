import 'direct_order_translation.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../core/payments/vietqr_payload.dart';
import '../../core/ui/app_theme.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/utils/polling_utils.dart';
import '../../widgets/language_switcher.dart';
import 'direct_order_arrival_alert_sound.dart';
import 'direct_order_copy.dart';
import 'direct_order_stage.dart';
import 'direct_order_details_sheet.dart';
import 'direct_order_customer_push_service.dart';
import 'direct_order_support.dart';
import 'direct_order_localization.dart';
import 'direct_order_dialog.dart';
import 'direct_order_hours.dart';
import 'direct_order_models.dart';
import 'direct_order_service.dart';

enum _CustomerView { menu, address, status }

class DirectOrderStorefrontScreen extends StatefulWidget {
  const DirectOrderStorefrontScreen({
    super.key,
    required this.slug,
    this.requestId,
    this.accessKey,
    this.service = directOrderService,
    this.statusSafetyRefreshInterval = const Duration(seconds: 15),
    this.statusSafetyRefreshJitter = const Duration(seconds: 3),
    this.pollRandom,
    this.now = DateTime.now,
    this.pickProofImage,
    this.pushService,
  });

  final String slug;
  final String? requestId;
  final String? accessKey;
  final DirectOrderService service;
  final Duration statusSafetyRefreshInterval;
  final Duration statusSafetyRefreshJitter;
  final math.Random? pollRandom;
  final DateTime Function() now;
  final Future<XFile?> Function()? pickProofImage;
  final DirectOrderCustomerPushService? pushService;

  @override
  State<DirectOrderStorefrontScreen> createState() =>
      _DirectOrderStorefrontScreenState();
}

class _DirectOrderStorefrontScreenState
    extends State<DirectOrderStorefrontScreen>
    with WidgetsBindingObserver {
  final String _submitDraftId = const Uuid().v4();
  final _cart = <String, int>{};
  final _itemNotes = <String, String>{};
  final _dinerController = TextEditingController();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _addressController = TextEditingController();
  final _detailController = TextEditingController();
  final _noteController = TextEditingController();
  final _messageController = TextEditingController();
  final _menuScroll = ScrollController();
  final _categoryScroll = ScrollController();
  final _categoryKeys = <String, GlobalKey>{};
  String? _selectedCategoryId;
  final _proofAttempts = <String, DirectOrderProofAttempt>{};
  final _proofErrors = <String, String>{};
  final _proofRefreshFailures = <String>{};
  String? _proofBusyRequestId;
  final _money = NumberFormat.currency(
    locale: 'vi_VN',
    symbol: '₫',
    decimalDigits: 0,
  );

  DirectOrderStorefront? _storefront;
  DirectOrderSession? _session;
  DirectOrderAddress? _savedAddress;
  DirectOrderStatus? _status;
  List<DirectOrderSummary> _orders = const [];
  _CustomerView _view = _CustomerView.menu;
  DirectOrderFulfillmentType _fulfillmentType =
      DirectOrderFulfillmentType.delivery;
  bool get _isPickup => _fulfillmentType == DirectOrderFulfillmentType.pickup;
  Timer? _statusTimer;
  Timer? _hoursTimer;
  bool _loading = true;
  bool _submitting = false;
  bool _rememberAddress = false;
  bool _proofUploading = false;
  bool _proofSelecting = false;
  bool _sendingMessage = false;
  bool _refreshingStatus = false;
  bool _pausedByServer = false;
  bool _paymentAlertsEnabled = true;
  String? _errorCode;
  bool _orderClosed = false;
  String? _accessKey;
  int _loadGeneration = 0;
  int _statusMutationRevision = 0;
  bool _isForeground = true;
  late final math.Random _pollRandom;
  late final DirectOrderCustomerPushService _pushService;
  DirectOrderPushReadiness _pushReadiness = DirectOrderPushReadiness.off;
  bool _pushBusy = false;
  String? _pushLocale;

  String get _languageCode =>
      Localizations.maybeLocaleOf(context)?.languageCode ?? 'vi';
  DirectOrderCopy get _copy => DirectOrderCopy(_languageCode);

  @override
  void initState() {
    super.initState();
    _pollRandom = widget.pollRandom ?? math.Random();
    _pushService = widget.pushService ?? DirectOrderCustomerPushService();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant DirectOrderStorefrontScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.slug != widget.slug ||
        oldWidget.requestId != widget.requestId ||
        oldWidget.accessKey != widget.accessKey) {
      _statusMutationRevision++;
      _statusTimer?.cancel();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    _hoursTimer?.cancel();
    _pushService.dispose();
    _dinerController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    _addressController.dispose();
    _detailController.dispose();
    _noteController.dispose();
    _messageController.dispose();
    _menuScroll.dispose();
    _categoryScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _revealSelectedCategory();
    final locale = _languageCode;
    final changed = _pushLocale != null && _pushLocale != locale;
    _pushLocale = locale;
    if (changed && _session != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_setCustomerPush(restore: true));
      });
    }
  }

  List<DirectOrderCategory> get _menuCategories {
    final storefront = _storefront;
    if (storefront == null) return const [];
    final populated = storefront.items.map((item) => item.categoryId).toSet();
    return storefront.categories
        .where((category) => populated.contains(category.id))
        .toList();
  }

  void _reconcileCategories() {
    if (_selectedCategoryId != null &&
        !_menuCategories.any((c) => c.id == _selectedCategoryId)) {
      _selectedCategoryId = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _menuScroll.hasClients) _menuScroll.jumpTo(0);
      });
    }
    _revealSelectedCategory();
  }

  void _revealSelectedCategory() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _view != _CustomerView.menu) return;
      final target =
          _categoryKeys[_selectedCategoryId ?? 'all']?.currentContext;
      if (target != null) Scrollable.ensureVisible(target, alignment: 0.5);
    });
  }

  void _selectCategory(String? id) {
    if (_selectedCategoryId == id) return;
    setState(() => _selectedCategoryId = id);
    if (_menuScroll.hasClients) _menuScroll.jumpTo(0);
    _revealSelectedCategory();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = state == AppLifecycleState.resumed;
    if (_isForeground) {
      unawaited(_refreshStorefrontAvailability());
      if (_session != null) unawaited(_refreshStatusAfterResume());
    } else {
      _statusTimer?.cancel();
      _statusTimer = null;
      _hoursTimer?.cancel();
      _hoursTimer = null;
    }
  }

  void _scheduleHoursRefresh({bool retry = false}) {
    _hoursTimer?.cancel();
    if (!_isForeground) return;
    final now = widget.now();
    _hoursTimer = Timer(
      retry
          ? const Duration(seconds: 30)
          : directOrderNextHoursChange(now).difference(now) +
                const Duration(seconds: 1),
      _refreshStorefrontAvailability,
    );
  }

  Future<void> _refreshStorefrontAvailability() async {
    final generation = _loadGeneration;
    try {
      final storefront = await widget.service.fetchStorefront(widget.slug);
      if (!mounted || generation != _loadGeneration || !_isForeground) return;
      setState(() {
        _storefront = storefront;
        _pausedByServer = false;
      });
      _scheduleHoursRefresh();
    } catch (_) {
      if (mounted && _isForeground) _scheduleHoursRefresh(retry: true);
    }
  }

  Future<void> _refreshStatusAfterResume() async {
    await _refreshStatus(silent: true);
    if (mounted) unawaited(_setCustomerPush(restore: true));
    if (mounted && _hasPendingUpdates) {
      _startStatusPolling();
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _errorCode = null;
      _pausedByServer = false;
      _orderClosed = false;
    });
    try {
      final cached = widget.requestId == null
          ? await widget.service.loadRestorableSession(widget.slug)
          : await widget.service.resumeOrder(
              slug: widget.slug,
              requestId: widget.requestId!,
              accessKey: widget.accessKey ?? '',
            );
      _accessKey = widget.accessKey;
      DirectOrderStorefront storefront;
      try {
        storefront = await widget.service.fetchStorefront(widget.slug);
      } catch (_) {
        if (cached == null) rethrow;
        storefront = await widget.service.resumeStorefront(cached);
      }
      final session =
          cached ??
          await widget.service.ensureSession(
            slug: widget.slug,
            locale: _languageCode,
          );
      final values = await Future.wait<Object?>([
        widget.service.loadAddress(widget.slug),
        widget.service.loadActiveRequestId(widget.slug),
        widget.service.listOrders(session: session),
        widget.service.loadPaymentAlertEnabled(widget.slug),
      ]);
      final saved = values[0] as DirectOrderAddress?;
      final savedRequestId = widget.requestId ?? values[1] as String?;
      final orders = values[2] as List<DirectOrderSummary>;
      final alertsEnabled = values[3] as bool;
      final activeOrders = orders.where((order) => !order.isTerminal).toList();
      final selectedId =
          orders.any((order) => order.requestId == savedRequestId)
          ? savedRequestId
          : activeOrders.isNotEmpty
          ? activeOrders.first.requestId
          : null;
      DirectOrderStatus? status;
      if (selectedId != null) {
        try {
          status = await widget.service.fetchStatus(
            session: session,
            requestId: selectedId,
          );
        } catch (error) {
          if (!_activeRequestIsGone(error)) rethrow;
        }
      }
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _storefront = storefront;
        _reconcileCategories();
        _session = session;
        _savedAddress = saved;
        _rememberAddress = saved != null;
        _orders = orders;
        _paymentAlertsEnabled = alertsEnabled;
        _status = status;
        _view = status == null ? _CustomerView.menu : _CustomerView.status;
        _loading = false;
      });
      if (saved != null) _populateAddress(saved);
      if (status != null) await _publishOrderLink(status);
      if (!mounted || generation != _loadGeneration) return;
      if (status != null && !_orderClosed) unawaited(_notifyForStatus(status));
      if (_hasPendingUpdates) _startStatusPolling();
      _scheduleHoursRefresh();
      unawaited(_setCustomerPush(restore: true));
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      if (error is DirectOrderException &&
          error.code == 'DIRECT_ORDER_ORDER_CLOSED' &&
          widget.requestId != null) {
        await widget.service.clearOrderAccess(widget.slug, widget.requestId!);
        _closeOrderMemory(widget.requestId!);
      }
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _errorCode = error is DirectOrderException
            ? error.code
            : 'DIRECT_ORDER_TEMPORARILY_UNAVAILABLE';
      });
    }
  }

  String _orderPath(String requestId, String accessKey) => Uri(
    path: '/order/${widget.slug}/r/$requestId',
    fragment: 'access=$accessKey',
  ).toString();

  Future<void> _publishOrderLink(
    DirectOrderStatus status, {
    bool force = false,
  }) async {
    if (status.fulfillmentStatus == 'completed' &&
            !_hasCompletionRefund(status) ||
        status.support['chat_open'] == false) {
      await widget.service.clearOrderAccess(widget.slug, status.requestId);
      if (mounted) setState(() => _closeOrderMemory(status.requestId));
      return;
    }
    final session = _session;
    final router = mounted ? GoRouter.maybeOf(context) : null;
    if (session == null || (router == null && !force)) return;
    try {
      final key = await widget.service.ensureOrderAccess(
        slug: widget.slug,
        session: session,
        requestId: status.requestId,
      );
      if (!mounted || _status?.requestId != status.requestId) return;
      _accessKey = key;
      if (widget.requestId != status.requestId || widget.accessKey != key) {
        router?.replace(_orderPath(status.requestId, key));
      }
    } catch (error) {
      // A rolling server upgrade must not hide an otherwise valid order.
      if (force) _showError(error);
    }
  }

  bool _hasCompletionRefund(DirectOrderStatus status) =>
      status.support['refund_evidence_available'] == true ||
      supportNumber(status.support['overpayment_due']) > 0 ||
      supportNumber(status.support['delivery_adjustment_refund_due']) > 0 ||
      supportNumber(status.support['pickup_delivery_refund_due']) > 0 ||
      (status.delivery?.isPickup == true &&
          (status.delivery?.offer?.status == 'accepted' &&
              (status.delivery?.offer?.refundDue ?? 0) > 0 &&
              status.delivery?.offer?.refundRecorded == false));

  void _closeOrderMemory(String requestId) {
    _statusTimer?.cancel();
    _statusTimer = null;
    _accessKey = null;
    _proofAttempts.remove(requestId);
    if (_status?.requestId == requestId) {
      _status = null;
      _messageController.clear();
    }
    _orders = _orders.where((order) => order.requestId != requestId).toList();
    _orderClosed = true;
  }

  Future<void> _copyOrderLink() async {
    final status = _status;
    if (status == null) return;
    await _publishOrderLink(status, force: true);
    final key = _accessKey;
    if (!mounted || key == null) return;
    final path = Uri.parse(_orderPath(status.requestId, key));
    final link = Uri.base.replace(
      path: path.path,
      query: '',
      fragment: path.fragment,
    );
    await Clipboard.setData(ClipboardData(text: link.toString()));
    if (mounted) _snack(_copy.orderLinkCopied);
  }

  void _populateAddress(DirectOrderAddress address) {
    _nameController.text = address.customerName;
    _phoneController.text = address.customerPhone;
    _addressController.text = address.formattedAddress;
    _detailController.text = address.detailAddress;
    _rememberAddress = true;
  }

  Future<void> _selectView(_CustomerView view) async {
    if (view != _CustomerView.status) {
      try {
        final storefront = await widget.service.fetchStorefront(widget.slug);
        if (!mounted) return;
        setState(() {
          _storefront = storefront;
          _reconcileCategories();
          _pausedByServer = false;
        });
      } catch (error) {
        if (!mounted) return;
        if (_status == null) {
          _showError(error);
          return;
        }
        setState(() => _pausedByServer = true);
      }
    }
    if (mounted) setState(() => _view = view);
  }

  bool get _hasPendingUpdates =>
      !_orderClosed &&
      (_orders.any((order) => !order.isTerminal) ||
          (_status?.support['chat_open'] == true &&
              const {
                'cancelled',
                'rejected',
                'expired',
              }.contains(_status?.state)) ||
          (_status?.delivery?.offer?.status == 'accepted' &&
              (_status?.delivery?.offer?.refundDue ?? 0) > 0 &&
              _status?.delivery?.offer?.refundRecorded == false) ||
          (_status != null && _hasCompletionRefund(_status!)));

  void _changeQuantity(String itemId, int delta) {
    setState(() {
      final next = (_cart[itemId] ?? 0) + delta;
      if (next <= 0) {
        _cart.remove(itemId);
        _itemNotes.remove(itemId);
      } else {
        _cart[itemId] = next.clamp(1, 50);
      }
    });
  }

  double get _cartSubtotal {
    final itemById = {
      for (final item in _storefront?.items ?? const <DirectOrderMenuItem>[])
        item.id: item,
    };
    return _cart.entries.fold<double>(0, (sum, entry) {
      return sum + (itemById[entry.key]?.price ?? 0) * entry.value;
    });
  }

  int get _cartCount => _cart.values.fold(0, (sum, value) => sum + value);

  Future<void> _editItemRequest(DirectOrderMenuItem item) async {
    var draft = _itemNotes[item.id] ?? '';
    final note = await showDirectOrderDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item.localizedName(_languageCode)),
        content: TextFormField(
          key: Key('direct_item_request_input_${item.id}'),
          initialValue: draft,
          onChanged: (value) => draft = value,
          autofocus: true,
          maxLength: 300,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(
            labelText: _copy.itemRequest,
            hintText: _copy.itemRequestHint,
            helperText: _copy.itemRequestHelp,
            helperMaxLines: 3,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_copy.close),
          ),
          FilledButton(
            key: const Key('direct_item_request_save'),
            onPressed: () => Navigator.pop(context, draft.trim()),
            child: Text(_copy.save),
          ),
        ],
      ),
    );
    if (mounted && note != null && _cart.containsKey(item.id)) {
      setState(() {
        if (note.isEmpty) {
          _itemNotes.remove(item.id);
        } else {
          _itemNotes[item.id] = note;
        }
      });
    }
  }

  Future<void> _showOrderDetails(DirectOrderStatus status) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        constraints: const BoxConstraints(maxWidth: 920),
        builder: (context) => DirectOrderDetailsSheet(
          status: status,
          languageCode: _languageCode,
        ),
      );

  Future<void> _showCart() async {
    final items = _storefront!.items
        .where((item) => (_cart[item.id] ?? 0) > 0)
        .toList();
    final openAddress = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (context) => StatefulBuilder(
        builder: (context, refreshSheet) => SafeArea(
          child: SizedBox(
            key: const Key('direct_cart_sheet'),
            height: MediaQuery.sizeOf(context).height * 0.78,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.shopping_cart_outlined),
                  title: Text(
                    _copy.cart,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  subtitle: Text(_copy.itemsCount(_cartCount)),
                  trailing: IconButton(
                    key: const Key('direct_cart_close'),
                    tooltip: _copy.close,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 24),
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final quantity = _cart[item.id]!;
                      return Column(
                        key: Key('direct_cart_item_${item.id}'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            item.localizedName(_languageCode),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${_money.format(item.price)} × $quantity',
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                _money.format(item.price * quantity),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ],
                          ),
                          if (_itemNotes[item.id]?.isNotEmpty == true)
                            Text(
                              '${_copy.itemRequest}: ${_itemNotes[item.id]}',
                            ),
                          TextButton.icon(
                            key: Key('direct_cart_request_${item.id}'),
                            onPressed: () async {
                              await _editItemRequest(item);
                              if (context.mounted) refreshSheet(() {});
                            },
                            icon: const Icon(Icons.edit_note),
                            label: Text(_copy.addItemRequest),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(_copy.subtotal)),
                          const SizedBox(width: 12),
                          Text(
                            key: const Key('direct_cart_subtotal'),
                            _money.format(_cartSubtotal),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isPickup ? _copy.vatNotice : _copy.cartQuoteNotice,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        key: const Key('direct_cart_address'),
                        onPressed: () => Navigator.pop(context, true),
                        icon: const Icon(Icons.arrow_forward_rounded),
                        label: Text(_isPickup ? _copy.contact : _copy.address),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (mounted && openAddress == true) {
      await _selectView(_CustomerView.address);
    }
  }

  DirectOrderAddress? _composeAddress() {
    if (_nameController.text.trim().isEmpty ||
        _phoneController.text.trim().isEmpty ||
        (!_isPickup && _addressController.text.trim().length < 3)) {
      return null;
    }
    return DirectOrderAddress(
      customerName: _nameController.text.trim(),
      customerPhone: _phoneController.text.trim(),
      formattedAddress: _addressController.text.trim(),
      detailAddress: _detailController.text.trim(),
    );
  }

  Future<void> _submit() async {
    if (_cart.isEmpty) {
      _snack(_copy.cartEmpty);
      setState(() => _view = _CustomerView.menu);
      return;
    }
    final dinerCount = int.tryParse(_dinerController.text.trim());
    if (dinerCount == null || dinerCount < 1 || dinerCount > 100) {
      _snack(_copy.errorMessage('DIRECT_ORDER_DINER_COUNT_INVALID'));
      return;
    }
    final address = _composeAddress();
    if (address == null) {
      _snack(_isPickup ? _copy.requiredPickupFields : _copy.requiredFields);
      return;
    }
    if (!RegExp(r'^[+]?[0-9][0-9 -]{7,19}$').hasMatch(address.customerPhone)) {
      _snack(_copy.invalidPhone);
      return;
    }
    var session = _session;
    if (session == null) return;
    unawaited(directOrderArrivalAlertSoundService.prepare());
    setState(() => _submitting = true);
    try {
      if (session.orderScoped) {
        session = await widget.service.ensureSession(
          slug: widget.slug,
          locale: _languageCode,
        );
        _session = session;
      }
      final submission = await widget.service.submit(
        slug: widget.slug,
        session: session,
        draftId: _submitDraftId,
        locale: _languageCode,
        cart: _cart,
        itemNotes: _itemNotes,
        address: address,
        rememberAddress: _rememberAddress && !_isPickup,
        fulfillmentType: _fulfillmentType,
        customerNote: _noteController.text.trim(),
        dinerCount: dinerCount,
      );
      final status = await widget.service.fetchStatus(
        session: session,
        requestId: submission.requestId,
      );
      final orders = await widget.service.listOrders(session: session);
      if (!mounted) return;
      setState(() {
        if (!_isPickup) _savedAddress = _rememberAddress ? address : null;
        _status = status;
        _orders = orders;
        _view = _CustomerView.status;
      });
      _startStatusPolling();
      await _publishOrderLink(status);
    } catch (error) {
      if (error is DirectOrderException &&
          (error.code == 'DIRECT_ORDER_STOREFRONT_PAUSED' ||
              error.code == 'DIRECT_ORDER_OUTSIDE_HOURS')) {
        if (mounted) setState(() => _pausedByServer = true);
        _scheduleHoursRefresh();
      } else {
        _showError(error);
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = null;
    if (!_isForeground || !_hasPendingUpdates) return;
    _statusTimer = Timer(
      jitteredPollDelay(
        widget.statusSafetyRefreshInterval,
        maximumJitter: widget.statusSafetyRefreshJitter,
        random: _pollRandom,
      ),
      () async {
        _statusTimer = null;
        await _refreshStatus(silent: true);
        if (mounted && _hasPendingUpdates) {
          _startStatusPolling();
        }
      },
    );
  }

  Future<void> _refreshStatus({bool silent = false}) async {
    final session = _session;
    final requestId = _status?.requestId;
    if (session == null || _refreshingStatus) {
      return;
    }
    _refreshingStatus = true;
    final revision = _statusMutationRevision;
    try {
      final previousOrders = {
        for (final order in _orders) order.requestId: order,
      };
      final orders = await widget.service.listOrders(session: session);
      final status = requestId == null || requestId.isEmpty
          ? null
          : await widget.service.fetchStatus(
              session: session,
              requestId: requestId,
            );
      if (!mounted || revision != _statusMutationRevision) return;
      setState(() {
        _orders = orders;
        if (status != null) _status = status;
      });
      if (status != null) {
        await _publishOrderLink(status);
        if (!_orderClosed) unawaited(_notifyForStatus(status));
      }
      for (final order in orders) {
        if (order.requestId == requestId) continue;
        final previous = previousOrders[order.requestId];
        final becameQuoted =
            order.state == 'quoted' && previous?.state != 'quoted';
        final needsNewProof =
            order.hasOpenProofReview && previous?.hasOpenProofReview != true;
        if (becameQuoted || needsNewProof) {
          final changedStatus = await widget.service.fetchStatus(
            session: session,
            requestId: order.requestId,
          );
          unawaited(_notifyForStatus(changedStatus));
        }
      }
      if (!mounted || revision != _statusMutationRevision) return;
      if (!orders.any((order) => !order.isTerminal) &&
          !_hasPendingUpdates &&
          _status?.support['chat_open'] == false) {
        _statusTimer?.cancel();
        _statusTimer = null;
      }
    } catch (error) {
      if (!mounted || revision != _statusMutationRevision) return;
      if (error is DirectOrderException &&
          error.code == 'DIRECT_ORDER_ORDER_CLOSED' &&
          requestId != null) {
        await widget.service.clearOrderAccess(widget.slug, requestId);
        if (mounted) setState(() => _closeOrderMemory(requestId));
      }
      if (!silent) _showError(error);
    } finally {
      _refreshingStatus = false;
    }
  }

  bool _activeRequestIsGone(Object error) {
    if (error is! DirectOrderException) return false;
    return const {
      'DIRECT_ORDER_REQUEST_NOT_FOUND',
      'DIRECT_ORDER_SESSION_INVALID',
      'DIRECT_ORDER_SESSION_EXPIRED',
    }.contains(error.code);
  }

  Future<void> _notifyForStatus(DirectOrderStatus status) async {
    final quote = status.quote;
    final review = status.proofReview;
    String? eventKey;
    String? message;
    if (status.isPickup && status.fulfillmentStatus == 'ready') {
      eventKey = '${status.requestId}:pickup-ready';
      message = _copy.pickupReadyNotice;
    } else if (status.fulfillmentStatus == 'dispatched' &&
        (status.delivery?.trackingUrl != null ||
            status.delivery?.driverContact != null ||
            status.grabTrackingUrl != null)) {
      eventKey = '${status.requestId}:driver-handoff';
      message = _copy.driverHandoffNotice;
    } else if (review != null) {
      eventKey = '${status.requestId}:proof-review:${review.id}';
      message = '${status.referenceCode} · ${_copy.replaceProof}';
    } else if (quote != null && status.state == 'quoted') {
      eventKey = '${status.requestId}:quote:${quote.id}:${quote.version}';
      message = quote.version > 1 ? _copy.quoteChanged : _copy.quoteArrived;
    }
    if (eventKey == null || message == null) return;
    bool isNew;
    try {
      isNew = await widget.service.markAlertSeen(widget.slug, eventKey);
    } catch (_) {
      return;
    }
    if (!isNew || !mounted) return;
    _snack(
      eventKey.contains(':quote:')
          ? '$message ${_money.format(quote?.finalTotal ?? 0)}'
          : message,
    );
    if (_paymentAlertsEnabled) {
      try {
        await directOrderArrivalAlertSoundService.play();
      } catch (_) {}
      try {
        await HapticFeedback.vibrate();
      } catch (_) {}
    }
  }

  Future<void> _selectOrder(String requestId) async {
    final session = _session;
    if (session == null) return;
    final revision = ++_statusMutationRevision;
    setState(() {
      _loading = true;
      _errorCode = null;
    });
    try {
      final status = await widget.service.fetchStatus(
        session: session,
        requestId: requestId,
      );
      await widget.service.saveSelectedRequest(widget.slug, requestId);
      if (!mounted || revision != _statusMutationRevision) return;
      setState(() {
        _status = status;
        _view = _CustomerView.status;
        _loading = false;
      });
      if (_hasPendingUpdates) _startStatusPolling();
      await _publishOrderLink(status);
    } catch (error) {
      if (!mounted || revision != _statusMutationRevision) return;
      setState(() => _loading = false);
      _showError(error);
    }
  }

  Future<void> _showOrders() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.78,
          ),
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: Text(
                  _copy.myOrders,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const Divider(height: 1),
              if (_orders.isEmpty)
                Expanded(child: Center(child: Text(_copy.noOrderHistory)))
              else
                Expanded(
                  child: ListView.separated(
                    itemCount: _orders.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final order = _orders[index];
                      final stage = directOrderStage(
                        order.state,
                        order.fulfillmentStatus,
                      );
                      return ListTile(
                        key: Key('direct_customer_order_${order.requestId}'),
                        selected: order.requestId == _status?.requestId,
                        onTap: () => Navigator.pop(context, order.requestId),
                        leading: Icon(
                          order.isTerminal
                              ? Icons.check_circle_outline_rounded
                              : Icons.schedule_rounded,
                        ),
                        title: Text('#${order.referenceCode}'),
                        subtitle: Text(
                          '${order.isPickup ? _copy.pickup : _copy.delivery} · ${stage == DirectOrderStage.exception ? _copy.stateLabel(order.fulfillmentStatus == 'cancelled' ? 'cancelled' : order.state) : _copy.stageLabel(stage)} · '
                          '${_copy.itemsCount(order.itemCount)}',
                        ),
                        trailing: Text(
                          order.finalTotal == null
                              ? _copy.amountPending
                              : _money.format(order.finalTotal!),
                        ),
                      );
                    },
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(context, ''),
                    icon: const Icon(Icons.add_shopping_cart_outlined),
                    label: Text(_copy.addOrder),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || selected == null) return;
    if (selected.isEmpty) {
      await _startNewOrder();
    } else {
      await _selectOrder(selected);
    }
  }

  Future<void> _togglePaymentAlerts() async {
    final enabled = !_paymentAlertsEnabled;
    if (enabled) await directOrderArrivalAlertSoundService.prepare();
    await widget.service.setPaymentAlertEnabled(widget.slug, enabled);
    if (!mounted) return;
    setState(() => _paymentAlertsEnabled = enabled);
    _snack(enabled ? _copy.paymentAlertEnabled : _copy.paymentAlertDisabled);
  }

  bool _canSendProof(DirectOrderStatus status) {
    final quote = status.quote;
    if (quote == null) return false;
    if (status.state == 'awaiting_payment_review' &&
        quote.status == 'locked' &&
        status.proofReview?.canResubmit == true) {
      return true;
    }
    return status.state == 'quoted' &&
        quote.status == 'active' &&
        (quote.amountFinalizedAt != null ||
            quote.expiresAt == null ||
            quote.expiresAt!.isAfter(widget.now()));
  }

  DirectOrderProofAttempt? _proofAttemptFor(DirectOrderStatus status) {
    final attempt = _proofAttempts[status.requestId];
    return attempt?.quoteId == status.quote?.id &&
            attempt?.reviewRequestId ==
                (status.proofReview?.canResubmit == true
                    ? status.proofReview?.id
                    : null)
        ? attempt
        : null;
  }

  Future<void> _uploadProof({bool retry = false}) async {
    final session = _session;
    final status = _status;
    if (_proofUploading || session == null || status?.quote == null) return;
    var attempt =
        _proofAttemptFor(status!) ??
        (retry ? _proofAttempts[status.requestId] : null);
    if ((!retry || attempt == null) && !_canSendProof(status)) return;
    setState(() {
      _proofUploading = true;
      _proofSelecting = !retry || attempt == null;
      _proofBusyRequestId = status.requestId;
      if (retry) _proofErrors.remove(status.requestId);
      _statusMutationRevision++;
    });
    try {
      if (!retry || attempt == null) {
        final image =
            await (widget.pickProofImage?.call() ??
                ImagePicker().pickImage(
                  source: ImageSource.gallery,
                  maxWidth: 1800,
                  imageQuality: 88,
                ));
        if (image == null) return;
        final bytes = await image.readAsBytes();
        if (!mounted || _status?.requestId != status.requestId) return;
        final extension = image.name.split('.').last.toLowerCase();
        final mimeType =
            image.mimeType ??
            switch (extension) {
              'png' => 'image/png',
              'webp' => 'image/webp',
              _ => 'image/jpeg',
            };
        if (bytes.isEmpty ||
            bytes.length > 5242880 ||
            !const {
              'image/jpeg',
              'image/png',
              'image/webp',
            }.contains(mimeType)) {
          throw const DirectOrderException('INVALID_PROOF');
        }
        final shouldUpload = await showDirectOrderDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(
              status.proofReview?.canResubmit == true
                  ? _copy.replaceProof
                  : _copy.attachProof,
            ),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '#${status.referenceCode} · ${_money.format(status.quote!.finalTotal)}',
                    ),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: Image.memory(bytes, fit: BoxFit.contain),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                key: const Key('direct_cancel_payment_proof'),
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(
                  MaterialLocalizations.of(context).cancelButtonLabel,
                ),
              ),
              FilledButton(
                key: const Key('direct_confirm_payment_proof'),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(_copy.attachProof),
              ),
            ],
          ),
        );
        if (shouldUpload != true ||
            !mounted ||
            _status?.requestId != status.requestId ||
            _status?.quote?.id != status.quote!.id ||
            _status?.proofReview?.id != status.proofReview?.id ||
            !_canSendProof(_status!)) {
          return;
        }
        attempt = DirectOrderProofAttempt(
          requestId: status.requestId,
          quoteId: status.quote!.id,
          reviewRequestId: status.proofReview?.canResubmit == true
              ? status.proofReview?.id
              : null,
          bytes: bytes,
          mimeType: mimeType,
        );
        _proofAttempts[status.requestId] = attempt;
        _proofErrors.remove(status.requestId);
      }
      if (mounted) setState(() => _proofSelecting = false);
      await widget.service.resumePaymentProof(
        session: session,
        attempt: attempt,
        allowUpload:
            _status?.requestId == status.requestId &&
            _proofAttemptFor(_status!) == attempt &&
            _canSendProof(_status!),
        onChanged: () {
          if (mounted) setState(() {});
        },
      );
      await _refreshProofStatus(session, status.requestId);
    } catch (error) {
      if (mounted) {
        if (attempt == null) _showError(error);
        setState(
          () => _proofErrors[status.requestId] = error is DirectOrderException
              ? error.code
              : 'PROOF_UPLOAD_TEMPORARILY_UNAVAILABLE',
        );
        // Reconcile a changed quote, staff approval or another device's upload.
        await _refreshProofStatus(session, status.requestId);
      }
    } finally {
      if (mounted) {
        setState(() {
          _proofUploading = false;
          _proofSelecting = false;
          _proofBusyRequestId = null;
        });
      }
    }
  }

  Future<void> _refreshProofStatus(
    DirectOrderSession session,
    String requestId,
  ) async {
    final revision = _statusMutationRevision;
    try {
      final latest = await widget.service.fetchStatus(
        session: session,
        requestId: requestId,
      );
      if (!mounted ||
          _status?.requestId != requestId ||
          revision != _statusMutationRevision) {
        return;
      }
      setState(() {
        _statusMutationRevision++;
        _status = latest;
        _proofRefreshFailures.remove(requestId);
      });
    } catch (_) {
      if (mounted) setState(() => _proofRefreshFailures.add(requestId));
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    final session = _session;
    final status = _status;
    if (text.isEmpty || session == null || status == null) return;
    setState(() => _sendingMessage = true);
    try {
      final sent = await widget.service.sendMessage(
        session: session,
        requestId: status.requestId,
        message: text,
      );
      if (!mounted) return;
      final latest = _status ?? status;
      final messages = latest.messages.any((item) => item.id == sent.id)
          ? latest.messages
          : [...latest.messages, sent];
      _statusMutationRevision += 1;
      _messageController.clear();
      setState(() {
        _status = DirectOrderStatus(
          requestId: latest.requestId,
          referenceCode: latest.referenceCode,
          state: latest.state,
          createdAt: latest.createdAt,
          items: latest.items,
          quote: latest.quote,
          messages: messages,
          fulfillmentStatus: latest.fulfillmentStatus,
          grabTrackingUrl: latest.grabTrackingUrl,
          fulfillmentType: latest.fulfillmentType,
          pickupCode: latest.pickupCode,
          fulfillmentVersion: latest.fulfillmentVersion,
          completedAt: latest.completedAt,
          proofReview: latest.proofReview,
          delivery: latest.delivery,
          support: latest.support,
          customer: latest.customer,
        );
      });
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _sendingMessage = false);
    }
  }

  Future<void> _cancelOrder() async {
    final status = _status;
    final session = _session;
    if (status == null || session == null) return;
    final confirmed = await showDirectOrderDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_copy.cancelOrder),
        content: Text(_copy.cancelConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_copy.close),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_copy.cancelOrder),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.service.cancelRequest(
        slug: widget.slug,
        session: session,
        requestId: status.requestId,
      );
      await _refreshStatus();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _startNewOrder() async {
    if (_session?.orderScoped == true) {
      _session = await widget.service.ensureSession(
        slug: widget.slug,
        locale: _languageCode,
      );
      _accessKey = null;
      if (!mounted) return;
      final router = GoRouter.maybeOf(context);
      if (router != null) {
        router.go('/order/${widget.slug}');
        return;
      }
    }
    await _selectView(_CustomerView.menu);
    if (!mounted || (_storefront?.paused ?? true) || _pausedByServer) return;
    await widget.service.clearActiveRequest(widget.slug);
    if (!mounted) return;
    _statusMutationRevision += 1;
    setState(() {
      _status = null;
      _cart.clear();
      _itemNotes.clear();
      _noteController.clear();
      _dinerController.clear();
      _messageController.clear();
      _view = _CustomerView.menu;
      if (_savedAddress != null) _populateAddress(_savedAddress!);
    });
    if (_hasPendingUpdates) _startStatusPolling();
  }

  Future<void> _clearSavedAddress() async {
    await widget.service.clearAddress(widget.slug);
    if (!mounted) return;
    setState(() {
      _savedAddress = null;
      _rememberAddress = false;
      _nameController.clear();
      _phoneController.clear();
      _addressController.clear();
      _detailController.clear();
    });
  }

  void _showError(Object error) {
    if (!mounted) return;
    final code = error is DirectOrderException ? error.code : '';
    _snack(_copy.errorMessage(code));
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PosColors.canvas,
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.delivery_dining_rounded, color: PosColors.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _storefront?.storeName.isNotEmpty == true
                    ? _storefront!.storeName
                    : _copy.directDelivery,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          if (_orders.isNotEmpty)
            IconButton(
              key: const Key('direct_customer_my_orders'),
              tooltip: _copy.myOrders,
              onPressed: _showOrders,
              icon: Badge(
                label: Text('${_orders.length}'),
                child: const Icon(Icons.receipt_long_outlined),
              ),
            ),
          IconButton(
            key: const Key('direct_customer_notifications'),
            tooltip: _copy.customerNotifications,
            onPressed: _showCustomerNotifications,
            icon: Icon(
              _paymentAlertsEnabled
                  ? Icons.notifications_active_outlined
                  : Icons.notifications_off_outlined,
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: LanguageSwitcher(compact: true),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_orderClosed) {
      return _CenteredMessage(
        icon: Icons.check_circle_outline,
        title: _copy.orderClosed,
        actionLabel: _copy.menu,
        onAction: () => GoRouter.maybeOf(context)?.go('/order/${widget.slug}'),
      );
    }
    if (_errorCode != null || _storefront == null) {
      return _CenteredMessage(
        icon: Icons.cloud_off_rounded,
        title: _copy.unavailable,
        actionLabel: _copy.retry,
        onAction: _load,
      );
    }
    if ((_storefront!.paused || _pausedByServer) &&
        _view != _CustomerView.status) {
      return Column(
        children: [
          Expanded(
            child: _DeliveryClosedMessage(copy: _copy, onCheckAgain: _load),
          ),
          if (_status != null)
            SafeArea(
              child: TextButton(
                onPressed: () => _selectView(_CustomerView.status),
                child: Text(_copy.orderStatus),
              ),
            ),
        ],
      );
    }
    final content = switch (_view) {
      _CustomerView.menu => _buildMenu(),
      _CustomerView.address => _buildAddressView(),
      _CustomerView.status => _buildStatus(),
    };
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            children: [
              _ProgressTabs(
                selected: _view,
                isPickup: _isPickup,
                copy: _copy,
                canOpenAddress: _cart.isNotEmpty,
                hasStatus: _status != null,
                onSelected: _selectView,
              ),
              if (_view == _CustomerView.menu) _buildCategoryBar(),
              Expanded(child: content),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryBar() => LayoutBuilder(
    builder: (context, constraints) {
      Widget chip(String? id, String name) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Center(
          key: _categoryKeys.putIfAbsent(id ?? 'all', GlobalKey.new),
          child: Tooltip(
            message: name,
            child: ChoiceChip(
              key: Key('direct_category_${id ?? 'all'}'),
              selected: _selectedCategoryId == id,
              onSelected: (_) => _selectCategory(id),
              materialTapTargetSize: MaterialTapTargetSize.padded,
              label: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
        ),
      );
      void scroll(double direction) {
        if (!_categoryScroll.hasClients) return;
        _categoryScroll.animateTo(
          (_categoryScroll.offset + direction * 280).clamp(
            0,
            _categoryScroll.position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }

      return SizedBox(
        height: 64,
        child: Row(
          children: [
            if (constraints.maxWidth >= 600)
              IconButton(
                tooltip: _copy.previousCategories,
                onPressed: () => scroll(-1),
                icon: const Icon(Icons.chevron_left),
              ),
            Expanded(
              child: ListView(
                key: const Key('direct_category_bar'),
                controller: _categoryScroll,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  chip(null, _copy.allCategories),
                  for (final category in _menuCategories)
                    chip(category.id, category.localizedName(_languageCode)),
                ],
              ),
            ),
            if (constraints.maxWidth >= 600)
              IconButton(
                tooltip: _copy.nextCategories,
                onPressed: () => scroll(1),
                icon: const Icon(Icons.chevron_right),
              ),
          ],
        ),
      );
    },
  );

  Widget _buildMenu() {
    final storefront = _storefront!;
    return Stack(
      children: [
        ListView(
          key: const PageStorageKey('direct_menu_list'),
          controller: _menuScroll,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 156),
          children: [
            SegmentedButton<DirectOrderFulfillmentType>(
              key: const Key('direct_fulfillment_type'),
              segments: [
                ButtonSegment(
                  value: DirectOrderFulfillmentType.delivery,
                  label: Text(_copy.delivery),
                  icon: const Icon(Icons.delivery_dining),
                ),
                ButtonSegment(
                  value: DirectOrderFulfillmentType.pickup,
                  label: Text(_copy.pickup),
                  icon: const Icon(Icons.takeout_dining_outlined),
                ),
              ],
              selected: {_fulfillmentType},
              onSelectionChanged: _submitting
                  ? null
                  : (values) =>
                        setState(() => _fulfillmentType = values.single),
            ),
            if (_isPickup)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '${_storefront!.storeAddress}\n${_copy.pickupHelp}',
                ),
              ),
            if (_menuCategories.isEmpty) ...[
              Text(_copy.emptyMenu),
              TextButton(
                onPressed: () => _selectView(_CustomerView.menu),
                child: Text(_copy.refresh),
              ),
            ],
            for (final category in _menuCategories.where(
              (c) => _selectedCategoryId == null || c.id == _selectedCategoryId,
            )) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
                child: Text(
                  category.localizedName(_languageCode),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              ...storefront.items
                  .where((item) => item.categoryId == category.id)
                  .map((item) => _menuCard(item)),
            ],
          ],
        ),
        if (_cart.isNotEmpty)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: _BottomActionCard(
              leading:
                  '${_isPickup ? _copy.pickup : _copy.delivery} · ${_copy.viewCart} · $_cartCount',
              amount: _money.format(_cartSubtotal),
              label: _isPickup ? _copy.contact : _copy.address,
              onViewCart: _showCart,
              onPressed: () => _selectView(_CustomerView.address),
            ),
          ),
      ],
    );
  }

  Widget _menuCard(DirectOrderMenuItem item) {
    final quantity = _cart[item.id] ?? 0;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: AppRadius.md,
                  child: SizedBox(
                    width: 88,
                    height: 88,
                    child: item.imageUrl?.isNotEmpty == true
                        ? Image.network(
                            item.imageUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _menuPlaceholder(),
                          )
                        : _menuPlaceholder(),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.localizedName(_languageCode),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (item.description?.trim().isNotEmpty == true) ...[
                        const SizedBox(height: 4),
                        Text(
                          item.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        _money.format(item.price),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(color: PosColors.accent),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (quantity == 0)
                  IconButton.filled(
                    key: Key('direct_add_${item.id}'),
                    onPressed: () => _changeQuantity(item.id, 1),
                    icon: const Icon(Icons.add_rounded),
                  )
                else
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton.outlined(
                        onPressed: () => _changeQuantity(item.id, -1),
                        icon: const Icon(Icons.remove_rounded),
                      ),
                      SizedBox(
                        width: 34,
                        child: Text(
                          '$quantity',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton.filled(
                        onPressed: () => _changeQuantity(item.id, 1),
                        icon: const Icon(Icons.add_rounded),
                      ),
                    ],
                  ),
              ],
            ),
            if (quantity > 0) ...[
              const SizedBox(height: 8),
              if (_itemNotes[item.id]?.isNotEmpty == true)
                Text(
                  '${_copy.itemRequest}: ${_itemNotes[item.id]}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: Key('direct_menu_request_${item.id}'),
                  onPressed: () => _editItemRequest(item),
                  icon: const Icon(Icons.edit_note),
                  label: Text(_copy.addItemRequest),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _menuPlaceholder() => const ColoredBox(
    color: PosColors.accentMuted,
    child: Icon(
      Icons.restaurant_menu_rounded,
      color: PosColors.accent,
      size: 34,
    ),
  );

  Widget _buildAddressView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        Text(
          _isPickup ? _copy.pickup : _copy.delivery,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (_isPickup)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('${_storefront!.storeAddress}\n${_copy.pickupHelp}'),
          ),
        if (!_isPickup && _savedAddress != null) ...[
          Card(
            color: PosColors.infoMuted,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_savedAddress!.formattedAddress),
                  Text(_savedAddress!.detailAddress),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        key: const Key('direct_use_saved_address'),
                        onPressed: () =>
                            setState(() => _populateAddress(_savedAddress!)),
                        icon: const Icon(Icons.home_outlined),
                        label: Text(_copy.useSavedAddress),
                      ),
                      TextButton(
                        onPressed: _clearSavedAddress,
                        child: Text(_copy.deleteSavedAddress),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          key: const Key('direct_diner_count_input'),
          controller: _dinerController,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          maxLength: 3,
          decoration: InputDecoration(
            labelText: _copy.dinerQuestion,
            helperText: _copy.dinerHelp,
            helperMaxLines: 3,
            counterText: '',
            prefixIcon: const Icon(Icons.groups_outlined),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: () {
                    final n = int.tryParse(_dinerController.text) ?? 1;
                    _dinerController.text = '${(n - 1).clamp(1, 100)}';
                  },
                  icon: const Icon(Icons.remove),
                ),
                IconButton(
                  onPressed: () {
                    final n = int.tryParse(_dinerController.text) ?? 0;
                    _dinerController.text = '${(n + 1).clamp(1, 100)}';
                  },
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (!_isPickup) ...[
          TextField(
            key: const Key('direct_address_input'),
            controller: _addressController,
            maxLength: 500,
            minLines: 1,
            maxLines: 3,
            keyboardType: TextInputType.streetAddress,
            decoration: InputDecoration(
              labelText: _copy.deliveryAddress,
              hintText: _copy.addressInputHint,
              counterText: '',
              prefixIcon: const Icon(Icons.home_outlined),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('direct_address_detail'),
            controller: _detailController,
            maxLength: 300,
            decoration: InputDecoration(
              counterText: '',
              labelText:
                  '${_copy.detailAddress} (${DirectOrderSupportCopy(Localizations.localeOf(context).languageCode).optional})',
              hintText: _copy.detailAddressHint,
              prefixIcon: const Icon(Icons.apartment_rounded),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('direct_recipient_name'),
                controller: _nameController,
                maxLength: 100,
                decoration: InputDecoration(
                  counterText: '',
                  labelText: _copy.customerName,
                  prefixIcon: const Icon(Icons.person_outline_rounded),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                key: const Key('direct_recipient_phone'),
                controller: _phoneController,
                maxLength: 21,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  counterText: '',
                  labelText: _copy.phone,
                  prefixIcon: const Icon(Icons.phone_outlined),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _noteController,
          maxLength: 500,
          maxLines: 2,
          decoration: InputDecoration(
            labelText: _copy.deliveryNote,
            prefixIcon: const Icon(Icons.notes_rounded),
          ),
        ),
        if (!_isPickup)
          CheckboxListTile(
            value: _rememberAddress,
            contentPadding: EdgeInsets.zero,
            title: Text(_copy.rememberAddress),
            subtitle: Text(_copy.savedOnlyOnDevice),
            onChanged: (value) =>
                setState(() => _rememberAddress = value ?? false),
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('direct_submit_quote_request'),
          onPressed: _submitting ? null : _submit,
          icon: _submitting
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.request_quote_outlined),
          label: Text(_isPickup ? _copy.submitForPickup : _copy.submitForQuote),
        ),
      ],
    );
  }

  Future<void> _setCustomerPush({
    bool restore = false,
    bool disable = false,
  }) async {
    final session = _session;
    if (_pushBusy || session == null || _orderClosed) return;
    setState(() => _pushBusy = true);
    try {
      final readiness = disable
          ? await _pushService.disable(
              slug: session.orderScoped
                  ? "${widget.slug}:${session.id}"
                  : widget.slug,
              session: session,
              service: widget.service,
              locale: _languageCode,
            )
          : await _pushService.enable(
              slug: session.orderScoped
                  ? "${widget.slug}:${session.id}"
                  : widget.slug,
              session: session,
              service: widget.service,
              locale: _languageCode,
              restore: restore,
              onForeground: (requestId, kind) async {
                final eventKey =
                    '$requestId:${kind == 'pickup_ready' ? 'pickup-ready' : 'driver-handoff'}';
                try {
                  if (await widget.service.markAlertSeen(
                        widget.slug,
                        eventKey,
                      ) &&
                      mounted) {
                    _snack(
                      kind == 'pickup_ready'
                          ? _copy.pickupReadyNotice
                          : _copy.driverHandoffNotice,
                    );
                  }
                } catch (_) {
                  // A local alert cache failure must not stop status refresh.
                }
                if (mounted) unawaited(_refreshStatus(silent: true));
              },
            );
      if (mounted && _session?.id == session.id) {
        if (disable && readiness == DirectOrderPushReadiness.error) {
          _snack(_copy.pushFailed);
          return;
        }
        setState(() {
          _pushReadiness = readiness;
        });
      }
    } catch (_) {
      if (mounted && !restore) _snack(_copy.pushFailed);
    } finally {
      if (mounted) setState(() => _pushBusy = false);
    }
  }

  Future<void> _showCustomerNotifications() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) => StatefulBuilder(
      builder: (context, refresh) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _customerNotificationCard(() {
                if (context.mounted) refresh(() {});
              }),
              SwitchListTile(
                value: _paymentAlertsEnabled,
                title: Text(_copy.paymentAlertEnabled),
                onChanged: (_) async {
                  await _togglePaymentAlerts();
                  if (context.mounted) refresh(() {});
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _customerNotificationCard(VoidCallback refresh) {
    final message = switch (_pushReadiness) {
      DirectOrderPushReadiness.ready => _copy.pushReady,
      DirectOrderPushReadiness.denied => _copy.pushDenied,
      DirectOrderPushReadiness.unsupported ||
      DirectOrderPushReadiness.notConfigured => _copy.pushUnavailable,
      DirectOrderPushReadiness.error => _copy.pushFailed,
      DirectOrderPushReadiness.off => _copy.pushDisabled,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _copy.customerNotifications,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(message),
            const SizedBox(height: 8),
            Text(_copy.pushHelp),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('direct_customer_push_toggle'),
              onPressed: _pushBusy
                  ? null
                  : () async {
                      final pending = _setCustomerPush(
                        disable:
                            _pushReadiness == DirectOrderPushReadiness.ready,
                      );
                      refresh();
                      await pending;
                      refresh();
                    },
              icon: Icon(
                _pushReadiness == DirectOrderPushReadiness.ready
                    ? Icons.notifications_off_outlined
                    : Icons.notifications_active_outlined,
              ),
              label: Text(
                _pushReadiness == DirectOrderPushReadiness.ready
                    ? _copy.disableCustomerNotifications
                    : _copy.enableCustomerNotifications,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatus() {
    final status = _status;
    if (status == null) {
      return _CenteredMessage(
        icon: Icons.receipt_long_outlined,
        title: _copy.unavailable,
        actionLabel: _copy.retry,
        onAction: _load,
      );
    }
    return RefreshIndicator(
      onRefresh: _refreshStatus,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          _statusHero(status),
          if ((status.fulfillmentStatus != 'completed' ||
                  _hasCompletionRefund(status)) &&
              status.support['chat_open'] != false)
            TextButton.icon(
              key: const Key('direct_order_copy_link'),
              onPressed: _copyOrderLink,
              icon: const Icon(Icons.link),
              label: Text(_copy.copyOrderLink),
            ),

          if (status.delivery?.offer?.isPending == true) ...[
            const SizedBox(height: 12),
            _pickupOfferCard(status),
          ],
          if (directOrderStage(status.state, status.fulfillmentStatus) !=
              DirectOrderStage.exception) ...[
            const SizedBox(height: 12),
            _orderProgressCard(status),
          ],
          if (status.quote != null) ...[
            const SizedBox(height: 12),
            _quoteCard(status),
          ],
          if (_session != null && _storefront != null)
            DirectOrderCustomerSupportPanel(
              key: ValueKey('customer-support:${status.requestId}'),
              status: status,
              session: _session!,
              bank: _storefront!.bank,
              storeId: _storefront!.storeId,
              service: widget.service,
              onChanged: _refreshStatus,
            ),
          const SizedBox(height: 12),
          _chatCard(status),
          if (const {'awaiting_quote', 'quoted'}.contains(status.state)) ...[
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: _cancelOrder,
              icon: const Icon(Icons.cancel_outlined),
              label: Text(_copy.cancelOrder),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _decidePickup(DirectOrderStatus status, bool accept) async {
    final session = _session;
    final offer = status.delivery?.offer;
    if (session == null || offer == null || _submitting) return;
    var alreadyPaid =
        status.state == 'awaiting_payment_review' || status.state == 'approved';
    if (accept && status.state == 'quoted') {
      final paid = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const Key('direct_pickup_payment_status_dialog'),
          title: Text(_copy.pickup),
          content: Text(_copy.pickupQuestion),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(_copy.notTransferred),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(_copy.alreadyTransferred),
            ),
          ],
        ),
      );
      if (paid == null) return;
      alreadyPaid = paid;
    }
    if (!mounted) return;
    setState(() => _submitting = true);
    try {
      await widget.service.decidePickup(
        session: session,
        requestId: status.requestId,
        offerId: offer.id,
        accept: accept,
        alreadyPaid: alreadyPaid,
      );
      await _refreshStatus();
      if (mounted) _startStatusPolling();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _pickupOfferCard(DirectOrderStatus status) {
    final delivery = status.delivery!;
    return Card(
      key: const Key('direct_pickup_offer'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _copy.pickupQuestion,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(delivery.offer!.reason),
            Text(delivery.storeName),
            Text(delivery.storeAddress),
            if (delivery.offer!.refundDue > 0)
              Text(
                '${_copy.refundPending}: ${_money.format(delivery.offer!.refundDue)}',
              ),
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('direct_accept_pickup'),
              onPressed: _submitting ? null : () => _decidePickup(status, true),
              child: Text(_copy.acceptPickup),
            ),
            TextButton(
              key: const Key('direct_decline_pickup'),
              onPressed: _submitting
                  ? null
                  : () => _decidePickup(status, false),
              child: Text(_copy.keepDelivery),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusHero(DirectOrderStatus status) {
    final stage = directOrderStage(status.state, status.fulfillmentStatus);
    final (icon, tone) = switch (stage) {
      DirectOrderStage.waiting => (Icons.schedule_rounded, PosColors.info),
      DirectOrderStage.paid => (
        Icons.account_balance_wallet_outlined,
        PosColors.accent,
      ),
      DirectOrderStage.completed => (
        Icons.check_circle_outline_rounded,
        PosColors.success,
      ),
      DirectOrderStage.exception => (Icons.cancel_outlined, PosColors.danger),
    };
    final title = stage == DirectOrderStage.exception
        ? _copy.stateLabel(
            status.fulfillmentStatus == 'cancelled'
                ? 'cancelled'
                : status.state,
          )
        : _copy.stageLabel(stage);
    final fulfillment = switch (status.fulfillmentStatus) {
      'preparing' => _copy.preparing,
      'ready' => status.isPickup ? _copy.pickupReady : _copy.ready,
      'dispatched' => _copy.dispatched,
      'completed' => _copy.completed,
      _ =>
        stage == DirectOrderStage.waiting
            ? _copy.stateLabel(status.state)
            : null,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Icon(icon, color: tone, size: 48),
            const SizedBox(height: 10),
            Text(
              title,
              key: const Key('direct_order_status_title'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 5),
            Text(status.isPickup ? _copy.pickup : _copy.delivery),
            TextButton(
              key: const Key('direct_open_order_details'),
              onPressed: () => _showOrderDetails(status),
              child: Wrap(
                spacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  Text(
                    status.referenceCode,
                    style: Theme.of(
                      context,
                    ).textTheme.labelLarge?.copyWith(color: tone),
                  ),
                  Text(_copy.orderDetails),
                  const Icon(Icons.chevron_right, size: 18),
                ],
              ),
            ),
            if (status.delivery != null) ...[
              const SizedBox(height: 8),
              Text(_copy.packingCount(status.delivery!.dinerCount)),
              if (status.delivery!.isPickup) ...[
                Text(_copy.pickup),
                Text(status.delivery!.storeName),
                Text(status.delivery!.storeAddress),
              ],
              if (status.delivery!.provider != null)
                Text(
                  status.delivery!.providerName ??
                      status.delivery!.provider!.toUpperCase(),
                ),
              if (status.delivery!.driverContact != null)
                Text(status.delivery!.driverContact!),
              if (status.delivery!.offer?.status == 'accepted' &&
                  (status.delivery!.offer?.refundDue ?? 0) > 0)
                Text(
                  '${status.delivery!.offer!.refundRecorded ? _copy.refundRecorded : _copy.refundPending}: ${_money.format(status.delivery!.offer!.refundDue)}',
                ),
              if (status.delivery!.paidTotal != null)
                Text(
                  '${_copy.netReceived}: ${_money.format(status.delivery!.paidTotal! - status.delivery!.refundedTotal)}',
                ),
            ],
            if (fulfillment != null) ...[
              const SizedBox(height: 10),
              Chip(
                avatar: const Icon(Icons.delivery_dining_rounded, size: 18),
                label: Text(fulfillment),
              ),
            ],
            if (status.completedAt != null) ...[
              const SizedBox(height: 6),
              Text(
                DateFormat(
                  'yyyy-MM-dd HH:mm',
                ).format(status.completedAt!.toLocal()),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if ((status.delivery?.trackingUrl ?? status.grabTrackingUrl) !=
                null) ...[
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: () async {
                  final uri = Uri.tryParse(
                    status.delivery?.trackingUrl ?? status.grabTrackingUrl!,
                  );
                  if (uri != null) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                icon: const Icon(Icons.open_in_new_rounded),
                label: Text(_copy.openGrab),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _startNewOrder,
                  icon: const Icon(Icons.add_shopping_cart_outlined),
                  label: Text(_copy.addOrder),
                ),
                OutlinedButton.icon(
                  onPressed: _showOrders,
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: Text(_copy.myOrders),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _orderProgressCard(DirectOrderStatus status) {
    final stage = directOrderStage(status.state, status.fulfillmentStatus);
    final currentStep = switch (stage) {
      DirectOrderStage.completed => 2,
      DirectOrderStage.paid => 1,
      _ => 0,
    };
    final steps = <(IconData, String)>[
      (Icons.schedule_outlined, _copy.waitingConfirmation),
      (Icons.account_balance_wallet_outlined, _copy.paymentCompleted),
      (Icons.check_circle_outline_rounded, _copy.fulfillmentCompleted),
    ];
    return Card(
      key: const Key('direct_order_customer_progress'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (status.isPickup && status.pickupCode != null)
              Text('${_copy.pickupCode}: ${status.pickupCode}'),
            Text(
              _copy.orderProgress,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            for (var index = 0; index < steps.length; index++)
              _CustomerProgressRow(
                key: Key('direct_order_progress_step_$index'),
                icon: steps[index].$1,
                label: steps[index].$2,
                isCompleted: index < currentStep,
                isCurrent: index == currentStep,
                showConnector: index < steps.length - 1,
              ),
          ],
        ),
      ),
    );
  }

  Widget _quoteCard(DirectOrderStatus status) {
    final quote = status.quote!;
    final canPay =
        status.state == 'quoted' &&
        _canSendProof(status) &&
        _proofAttemptFor(status)?.complete != true;
    final canResubmit = status.proofReview?.canResubmit == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              status.state == 'approved'
                  ? _copy.paymentCompleted
                  : _copy.quoteReady,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            _amountRow(_copy.menuTotal, quote.menuTotal),
            _amountRow(_copy.serviceCharge, quote.serviceChargeTotal),
            Text(
              status.isPickup
                  ? _copy.pickup
                  : (quote.deliveryPaymentMode == 'store_prepaid'
                        ? _copy.storePrepaysDriver
                        : _copy.customerPaysDriver),
            ),
            if (quote.deliveryPaymentMode == 'customer_direct' &&
                !status.isPickup)
              Text(
                DirectOrderSupportCopy(
                  _copy.languageCode,
                ).text('driver_fee_pending'),
              )
            else if (status.support['delivery_fee_deferred'] == true &&
                status.support['delivery_fee_finalized'] == false)
              Text(
                DirectOrderSupportCopy(_copy.languageCode).text('fee_pending'),
              )
            else if (status.support['delivery_fee_deferred'] == true &&
                supportRows(
                  status.support['charges'],
                ).any((c) => c['kind'] == 'delivery' && c['status'] != 'void'))
              Text(
                DirectOrderSupportCopy(
                  _copy.languageCode,
                ).text('delivery_separate_payments'),
              )
            else
              _amountRow(_copy.deliveryFee, quote.deliveryFeeTotal),
            Text(
              quote.deliveryPaymentMode == 'customer_direct' && !status.isPickup
                  ? _copy.deliveryFeeSeparate
                  : _copy.deliveryFeeIncluded,
            ),
            const Divider(height: 24),
            _amountRow(_copy.finalTotal, quote.finalTotal, strong: true),
            _amountRow(_copy.includedVat, quote.vatTotal),
            if (canResubmit) ...[
              const SizedBox(height: 16),
              Card(
                color: PosColors.warningMuted,
                child: ListTile(
                  leading: const Icon(Icons.refresh_rounded),
                  title: Text(_copy.replaceProof),
                  subtitle: Text(
                    '${_copy.proofReviewReason(status.proofReview!.reasonCode)}'
                    '${status.proofReview!.reasonNote?.isNotEmpty == true ? '\n${status.proofReview!.reasonNote}' : ''}\n'
                    '${_copy.doNotPayAgain}',
                  ),
                ),
              ),
            ],
            if (canPay) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                key: const Key('direct_open_payment_details'),
                onPressed: () => _showPaymentDetails(status),
                icon: const Icon(Icons.account_balance_wallet_outlined),
                label: Text(_copy.paymentDetails),
              ),
            ],
            _buildProofControls(status),
          ],
        ),
      ),
    );
  }

  Widget _buildProofControls(DirectOrderStatus status) {
    final saved = _proofAttempts[status.requestId];
    final attempt =
        _proofAttemptFor(status) ??
        (saved?.outcomeUncertain == true ? saved : null);
    final busy = _proofUploading && _proofBusyRequestId == status.requestId;
    final canSend =
        _canSendProof(status) &&
        (attempt == null || _proofAttemptFor(status) == attempt);
    if (!const {'quoted', 'awaiting_payment_review'}.contains(status.state)) {
      return const SizedBox.shrink();
    }
    final sent =
        (attempt?.complete == true &&
            const {
              'quoted',
              'awaiting_payment_review',
            }.contains(status.state)) ||
        (status.state == 'awaiting_payment_review' &&
            status.proofReview?.canResubmit != true);
    if (!canSend && !sent && attempt?.outcomeUncertain != true) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        if (sent) ...[
          Text(_copy.proofSent, key: const Key('direct_proof_sent')),
          if (_proofRefreshFailures.contains(status.requestId)) ...[
            Text(_copy.proofStatusUnavailable),
            TextButton(
              key: const Key('direct_refresh_proof_status'),
              onPressed: () => _refreshProofStatus(_session!, status.requestId),
              child: Text(_copy.refreshProofStatus),
            ),
          ],
        ] else ...[
          if (attempt != null && !busy) ...[
            SizedBox(
              height: 110,
              child: Image.memory(attempt.bytes, fit: BoxFit.contain),
            ),
            if (_proofErrors[status.requestId] != null)
              Text(
                _copy.errorMessage(_proofErrors[status.requestId]!),
                key: const Key('direct_proof_error'),
              ),
            if (attempt.outcomeUncertain) Text(_copy.checkingProof),
          ],
          FilledButton.icon(
            key: Key(
              attempt == null
                  ? 'direct_upload_payment_proof'
                  : 'direct_retry_payment_proof',
            ),
            onPressed: _proofUploading
                ? null
                : () => _uploadProof(retry: attempt != null),
            icon: busy && !_proofSelecting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_photo_alternate_outlined),
            label: Text(
              busy
                  ? (_proofSelecting
                        ? _copy.selectingProof
                        : attempt?.stage == DirectOrderProofStage.confirming
                        ? _copy.checkingProof
                        : _copy.proofUploading)
                  : attempt != null
                  ? _copy.retryProof
                  : status.proofReview?.canResubmit == true
                  ? _copy.replaceProof
                  : _copy.attachProof,
            ),
          ),
          if (attempt != null && !attempt.outcomeUncertain && canSend)
            TextButton(
              key: const Key('direct_change_payment_proof'),
              onPressed: _proofUploading ? null : () => _uploadProof(),
              child: Text(_copy.changeProof),
            ),
          if (status.proofReview?.canResubmit != true)
            Text(_copy.proofOnlyHelp),
        ],
      ],
    );
  }

  Future<void> _showPaymentDetails(DirectOrderStatus status) async {
    final storefront = _storefront;
    final quote = status.quote;
    if (storefront == null || quote == null) return;
    final isResubmission = status.proofReview?.canResubmit == true;
    final qrData = VietQrPayload.bankTransfer(
      bankBin: storefront.bank.bin,
      accountNumber: storefront.bank.accountNumber,
      amount: quote.finalTotal.round(),
      purpose: status.referenceCode,
    );
    await showDirectOrderDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_copy.paymentDetails),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '#${status.referenceCode}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  status.isPickup
                      ? _copy.pickup
                      : (quote.deliveryPaymentMode == 'store_prepaid'
                            ? _copy.prepaidHelp
                            : _copy.customerPaysDriverHelp),
                ),
                _amountRow(_copy.finalTotal, quote.finalTotal, strong: true),
                _amountRow(_copy.includedVat, quote.vatTotal),
                if (isResubmission) ...[
                  const SizedBox(height: 8),
                  Text(
                    _copy.doNotPayAgain,
                    style: const TextStyle(color: PosColors.danger),
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  Text(_copy.transferInstruction, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      color: Colors.white,
                      child: QrImageView(data: qrData, size: 210),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _copyBankLine(_copy.bankName, storefront.bank.label),
                  _copyBankLine(
                    _copy.accountNumber,
                    storefront.bank.accountNumber,
                  ),
                  _bankLine(_copy.accountHolder, storefront.bank.accountHolder),
                  _copyBankLine(_copy.transferReference, status.referenceCode),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(_copy.close),
          ),
        ],
      ),
    );
  }

  Widget _copyBankLine(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(child: Text('$label\n$value')),
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: value));
            if (mounted) _snack(_copy.copied);
          },
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: Text(_copy.copy),
        ),
      ],
    ),
  );

  Widget _amountRow(String label, double amount, {bool strong = false}) {
    final style = strong
        ? Theme.of(
            context,
          ).textTheme.headlineMedium?.copyWith(color: PosColors.accent)
        : Theme.of(context).textTheme.bodyLarge;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(_money.format(amount), style: style),
        ],
      ),
    );
  }

  Widget _bankLine(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        SelectableText(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    ),
  );

  Widget _chatCard(DirectOrderStatus status) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.chat_bubble_outline_rounded,
                  color: PosColors.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _copy.chat,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: _copy.refresh,
                  onPressed: _refreshStatus,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const Divider(),
            if (status.messages.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_copy.systemUpdate, textAlign: TextAlign.center),
              )
            else
              for (final message in status.messages) _messageBubble(message),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    enabled: status.support['chat_open'] != false,
                    minLines: 1,
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: _copy.messageHint,
                      counterText: '',
                    ),
                    maxLength: 2000,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: _copy.send,
                  onPressed:
                      _sendingMessage || status.support['chat_open'] == false
                      ? null
                      : _sendMessage,
                  icon: _sendingMessage
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _messageBubble(DirectOrderMessage message) {
    final mine = message.senderType == 'customer';
    final body = message.hasAttachment
        ? (message.messageType == 'attachment'
              ? message.body ?? _copy.paymentProof
              : _copy.paymentProof)
        : localizedDirectOrderMessage(
            copy: _copy,
            messageType: message.messageType,
            body: message.body,
          );
    final grabUri = message.messageType == 'grab_link'
        ? Uri.tryParse(message.body ?? '')
        : null;
    final quote = _status?.quote;
    final quoteNote = message.messageType == 'quote'
        ? quote?.cashierNote
        : null;
    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 560),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: mine ? PosColors.accentMuted : PosColors.panelMuted,
        borderRadius: AppRadius.md,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (message.hasAttachment) ...[
            const Icon(Icons.image_outlined, size: 18),
            const SizedBox(width: 6),
          ] else if (grabUri != null) ...[
            const Icon(Icons.delivery_dining_outlined, size: 18),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                DirectOrderTranslatedText(
                  original: body,
                  translations: supportMap(message.metadata['translations']),
                  status: message.metadata['translation_status']?.toString(),
                ),
                if (quoteNote != null && quoteNote.isNotEmpty)
                  DirectOrderTranslatedText(
                    original: quoteNote,
                    translations: quote!.noteTranslations,
                    status: quote.translationStatus,
                  ),
              ],
            ),
          ),
          if (grabUri != null) ...[
            const SizedBox(width: 6),
            const Icon(Icons.open_in_new_rounded, size: 16),
          ],
        ],
      ),
    );
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: message.hasAttachment && _session != null
          ? InkWell(
              onTap: () => openDirectOrderAttachment(
                context,
                () => widget.service.supportRequest(
                  session: _session!,
                  requestId: _status!.requestId,
                  action: 'customer_attachment_url',
                  payload: {'message_id': message.id},
                ),
              ),
              child: bubble,
            )
          : grabUri == null
          ? bubble
          : InkWell(
              onTap: () =>
                  launchUrl(grabUri, mode: LaunchMode.externalApplication),
              child: bubble,
            ),
    );
  }
}

class _CustomerProgressRow extends StatelessWidget {
  const _CustomerProgressRow({
    super.key,
    required this.icon,
    required this.label,
    required this.isCompleted,
    required this.isCurrent,
    required this.showConnector,
  });

  final IconData icon;
  final String label;
  final bool isCompleted;
  final bool isCurrent;
  final bool showConnector;

  @override
  Widget build(BuildContext context) {
    final active = isCompleted || isCurrent;
    final color = isCompleted
        ? PosColors.success
        : isCurrent
        ? PosColors.accent
        : PosColors.textSecondary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 34,
          child: Column(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active ? color : PosColors.panelMuted,
                ),
                child: Icon(
                  isCompleted ? Icons.check_rounded : icon,
                  size: 17,
                  color: active ? Colors.white : color,
                ),
              ),
              if (showConnector)
                Container(
                  width: 2,
                  height: 20,
                  color: isCompleted ? PosColors.success : PosColors.border,
                ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: active ? PosColors.textPrimary : PosColors.textSecondary,
                fontWeight: active ? FontWeight.w800 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ProgressTabs extends StatelessWidget {
  const _ProgressTabs({
    required this.selected,
    required this.isPickup,
    required this.copy,
    required this.canOpenAddress,
    required this.hasStatus,
    required this.onSelected,
  });

  final _CustomerView selected;
  final bool isPickup;
  final DirectOrderCopy copy;
  final bool canOpenAddress;
  final bool hasStatus;
  final ValueChanged<_CustomerView> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: PosColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          _tab(
            context,
            _CustomerView.menu,
            Icons.restaurant_menu_rounded,
            copy.menu,
            true,
          ),
          _tab(
            context,
            _CustomerView.address,
            Icons.location_on_outlined,
            isPickup ? copy.contact : copy.address,
            canOpenAddress,
          ),
          _tab(
            context,
            _CustomerView.status,
            Icons.receipt_long_outlined,
            copy.orderStatus,
            hasStatus,
          ),
        ],
      ),
    );
  }

  Widget _tab(
    BuildContext context,
    _CustomerView view,
    IconData icon,
    String label,
    bool enabled,
  ) {
    final active = selected == view;
    return Expanded(
      child: InkWell(
        onTap: enabled ? () => onSelected(view) : null,
        borderRadius: AppRadius.md,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: active ? PosColors.accent : PosColors.textMuted,
                size: 21,
              ),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: active ? PosColors.accent : PosColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomActionCard extends StatelessWidget {
  const _BottomActionCard({
    required this.leading,
    required this.amount,
    required this.label,
    required this.onViewCart,
    required this.onPressed,
  });

  final String leading;
  final String amount;
  final String label;
  final VoidCallback onViewCart;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: PosTerminalColors.darkShell,
      elevation: 8,
      borderRadius: AppRadius.lg,
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: InkWell(
              key: const Key('direct_view_cart'),
              onTap: onViewCart,
              borderRadius: AppRadius.lg,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      leading,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PosTerminalColors.darkTextMuted,
                      ),
                    ),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        amount,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: PosTerminalColors.darkText,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: InkWell(
              key: const Key('direct_cart_continue'),
              onTap: onPressed,
              borderRadius: AppRadius.lg,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 15,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.arrow_forward_rounded,
                      color: Colors.white,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeliveryClosedMessage extends StatelessWidget {
  const _DeliveryClosedMessage({
    required this.copy,
    required this.onCheckAgain,
  });

  final DirectOrderCopy copy;
  final VoidCallback onCheckAgain;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Container(
              key: const Key('direct_order_closed_state'),
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
              decoration: BoxDecoration(
                color: PosColors.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: PosColors.border),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x0F0F172A),
                    blurRadius: 24,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    label: copy.apologyEmojiLabel,
                    excludeSemantics: true,
                    child: const Text(
                      '🙏',
                      key: Key('direct_order_closed_emoji'),
                      style: TextStyle(fontSize: 72, height: 1),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    copy.pausedTitle,
                    key: const Key('direct_order_closed_title'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: PosColors.textPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    copy.pausedMessage,
                    key: const Key('direct_order_closed_message'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: PosColors.textSecondary,
                      height: 1.55,
                    ),
                  ),
                  const SizedBox(height: 26),
                  FilledButton.icon(
                    key: const Key('direct_order_closed_retry'),
                    onPressed: onCheckAgain,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(copy.checkAgain),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    required this.icon,
    required this.title,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 54, color: PosColors.textMuted),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 14),
            FilledButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}
