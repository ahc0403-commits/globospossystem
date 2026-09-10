import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../core/payments/vietqr_payload.dart';
import '../../core/ui/app_theme.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../widgets/language_switcher.dart';
import 'direct_order_arrival_alert_sound.dart';
import 'direct_order_copy.dart';
import 'direct_order_localization.dart';
import 'direct_order_dialog.dart';
import 'direct_order_models.dart';
import 'direct_order_service.dart';

enum _CustomerView { menu, address, status }

class DirectOrderStorefrontScreen extends StatefulWidget {
  const DirectOrderStorefrontScreen({
    super.key,
    required this.slug,
    this.service = directOrderService,
  });

  final String slug;
  final DirectOrderService service;

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
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _addressController = TextEditingController();
  final _detailController = TextEditingController();
  final _noteController = TextEditingController();
  final _messageController = TextEditingController();
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
  Timer? _statusTimer;
  bool _loading = true;
  bool _submitting = false;
  bool _rememberAddress = false;
  bool _proofUploading = false;
  bool _sendingMessage = false;
  bool _refreshingStatus = false;
  bool _pausedByServer = false;
  bool _paymentAlertsEnabled = true;
  String? _errorCode;
  int _loadGeneration = 0;
  int _statusMutationRevision = 0;

  String get _languageCode =>
      Localizations.maybeLocaleOf(context)?.languageCode ?? 'vi';
  DirectOrderCopy get _copy => DirectOrderCopy(_languageCode);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    _nameController.dispose();
    _phoneController.dispose();
    _addressController.dispose();
    _detailController.dispose();
    _noteController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _session != null) {
      unawaited(_refreshStatus(silent: true));
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _errorCode = null;
      _pausedByServer = false;
    });
    try {
      final storefront = await widget.service.fetchStorefront(widget.slug);
      final session = await widget.service.ensureSession(
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
      final savedRequestId = values[1] as String?;
      final orders = values[2] as List<DirectOrderSummary>;
      final alertsEnabled = values[3] as bool;
      final activeOrders = orders.where((order) => !order.isTerminal).toList();
      final selectedId =
          orders.any((order) => order.requestId == savedRequestId)
          ? savedRequestId
          : activeOrders.isNotEmpty
          ? activeOrders.first.requestId
          : orders.isNotEmpty
          ? orders.first.requestId
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
      if (status != null) unawaited(_notifyForStatus(status));
      if (orders.any((order) => !order.isTerminal)) _startStatusPolling();
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _errorCode = error is DirectOrderException
            ? error.code
            : 'DIRECT_ORDER_TEMPORARILY_UNAVAILABLE';
      });
    }
  }

  void _populateAddress(DirectOrderAddress address) {
    _nameController.text = address.customerName;
    _phoneController.text = address.customerPhone;
    _addressController.text = address.formattedAddress;
    _detailController.text = address.detailAddress;
    _rememberAddress = true;
  }

  void _selectView(_CustomerView view) => setState(() => _view = view);

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

  DirectOrderAddress? _composeAddress() {
    if (_nameController.text.trim().isEmpty ||
        _phoneController.text.trim().isEmpty ||
        _addressController.text.trim().length < 3 ||
        _detailController.text.trim().isEmpty) {
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
    final address = _composeAddress();
    if (address == null) {
      _snack(_copy.requiredFields);
      return;
    }
    if (!RegExp(r'^[+]?[0-9][0-9 -]{7,19}$').hasMatch(address.customerPhone)) {
      _snack(_copy.invalidPhone);
      return;
    }
    final session = _session;
    if (session == null) return;
    unawaited(directOrderArrivalAlertSoundService.prepare());
    setState(() => _submitting = true);
    try {
      final submission = await widget.service.submit(
        slug: widget.slug,
        session: session,
        draftId: _submitDraftId,
        locale: _languageCode,
        cart: _cart,
        itemNotes: _itemNotes,
        address: address,
        rememberAddress: _rememberAddress,
        customerNote: _noteController.text.trim(),
      );
      final status = await widget.service.fetchStatus(
        session: session,
        requestId: submission.requestId,
      );
      final orders = await widget.service.listOrders(session: session);
      if (!mounted) return;
      setState(() {
        _savedAddress = _rememberAddress ? address : null;
        _status = status;
        _orders = orders;
        _view = _CustomerView.status;
      });
      _startStatusPolling();
    } catch (error) {
      if (error is DirectOrderException &&
          error.code == 'DIRECT_ORDER_STOREFRONT_PAUSED') {
        if (mounted) setState(() => _pausedByServer = true);
      } else {
        _showError(error);
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _refreshStatus(silent: true);
    });
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
      if (status != null) {
        await _notifyForStatus(status);
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
          await _notifyForStatus(changedStatus);
        }
      }
      if (!mounted || revision != _statusMutationRevision) return;
      setState(() {
        _orders = orders;
        if (status != null) _status = status;
      });
      if (!orders.any((order) => !order.isTerminal)) {
        _statusTimer?.cancel();
      }
    } catch (error) {
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
    if (review != null) {
      eventKey = '${status.requestId}:proof-review:${review.id}';
      message = '${status.referenceCode} · ${_copy.replaceProof}';
    } else if (quote != null && status.state == 'quoted') {
      eventKey = '${status.requestId}:quote:${quote.id}:${quote.version}';
      message = quote.version > 1 ? _copy.quoteChanged : _copy.quoteArrived;
    }
    if (eventKey == null || message == null) return;
    final isNew = await widget.service.markAlertSeen(widget.slug, eventKey);
    if (!isNew || !mounted) return;
    _snack('$message ${_money.format(quote?.finalTotal ?? 0)}');
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
      if (_orders.any((order) => !order.isTerminal)) _startStatusPolling();
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
                      final status = order.fulfillmentStatus ?? order.state;
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
                          '${_copy.stateLabel(status)} · '
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

  Future<void> _uploadProof() async {
    final session = _session;
    final status = _status;
    if (session == null || status == null) return;
    final image = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1800,
      imageQuality: 88,
    );
    if (image == null) return;
    final bytes = await image.readAsBytes();
    if (!mounted) return;
    final shouldUpload = await showDirectOrderDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          status.proofReview?.canResubmit == true
              ? _copy.replaceProof
              : _copy.attachProof,
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420, maxWidth: 420),
          child: Image.memory(bytes, fit: BoxFit.contain),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              status.proofReview?.canResubmit == true
                  ? _copy.replaceProof
                  : _copy.attachProof,
            ),
          ),
        ],
      ),
    );
    if (shouldUpload != true || !mounted) return;
    final extension = image.name.split('.').last.toLowerCase();
    final mimeType =
        image.mimeType ??
        switch (extension) {
          'png' => 'image/png',
          'webp' => 'image/webp',
          _ => 'image/jpeg',
        };
    setState(() => _proofUploading = true);
    try {
      await widget.service.uploadPaymentProof(
        session: session,
        requestId: status.requestId,
        quoteId: status.quote!.id,
        reviewRequestId: status.proofReview?.id,
        bytes: bytes,
        mimeType: mimeType,
      );
      await _refreshStatus();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _proofUploading = false);
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
          quote: latest.quote,
          messages: messages,
          fulfillmentStatus: latest.fulfillmentStatus,
          grabTrackingUrl: latest.grabTrackingUrl,
          fulfillmentVersion: latest.fulfillmentVersion,
          completedAt: latest.completedAt,
          proofReview: latest.proofReview,
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
    await widget.service.clearActiveRequest(widget.slug);
    if (!mounted) return;
    _statusMutationRevision += 1;
    setState(() {
      _status = null;
      _cart.clear();
      _itemNotes.clear();
      _noteController.clear();
      _messageController.clear();
      _view = _CustomerView.menu;
      if (_savedAddress != null) _populateAddress(_savedAddress!);
    });
    if (_orders.any((order) => !order.isTerminal)) _startStatusPolling();
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
            tooltip: _paymentAlertsEnabled
                ? _copy.paymentAlertEnabled
                : _copy.paymentAlertDisabled,
            onPressed: _togglePaymentAlerts,
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
    if (_errorCode != null || _storefront == null) {
      return _CenteredMessage(
        icon: Icons.cloud_off_rounded,
        title: _copy.unavailable,
        actionLabel: _copy.retry,
        onAction: _load,
      );
    }
    if ((_storefront!.paused || _pausedByServer) && _status == null) {
      return _DeliveryClosedMessage(copy: _copy, onCheckAgain: _load);
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
                copy: _copy,
                canOpenAddress: _cart.isNotEmpty,
                hasStatus: _status != null,
                onSelected: _selectView,
              ),
              Expanded(child: content),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMenu() {
    final storefront = _storefront!;
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 132),
          children: [
            for (final category in storefront.categories) ...[
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
              leading: '$_cartCount ${_copy.cart}',
              amount: _money.format(_cartSubtotal),
              label: _copy.address,
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
        child: Row(
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
                    style: Theme.of(
                      context,
                    ).textTheme.titleMedium?.copyWith(color: PosColors.accent),
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
        if (_savedAddress != null) ...[
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
            labelText: _copy.detailAddress,
            hintText: _copy.detailAddressHint,
            prefixIcon: const Icon(Icons.apartment_rounded),
          ),
        ),
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
          label: Text(_copy.submitForQuote),
        ),
      ],
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
          if (!{'rejected', 'cancelled', 'expired'}.contains(status.state)) ...[
            const SizedBox(height: 12),
            _orderProgressCard(status),
          ],
          if (status.quote != null) ...[
            const SizedBox(height: 12),
            _quoteCard(status),
          ],
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

  Widget _statusHero(DirectOrderStatus status) {
    final (icon, tone, title) = switch (status.fulfillmentStatus) {
      'preparing' => (
        Icons.restaurant_rounded,
        PosColors.warning,
        _copy.preparing,
      ),
      'ready' => (Icons.inventory_2_outlined, PosColors.info, _copy.ready),
      'dispatched' => (
        Icons.delivery_dining_rounded,
        PosColors.success,
        _copy.dispatched,
      ),
      'completed' => (
        Icons.check_circle_outline_rounded,
        PosColors.success,
        _copy.completed,
      ),
      _ => switch (status.state) {
        'awaiting_quote' => (
          Icons.schedule_rounded,
          PosColors.info,
          _copy.awaitingQuote,
        ),
        'quoted' => (
          Icons.request_quote_rounded,
          PosColors.accent,
          _copy.quoteReady,
        ),
        'awaiting_payment_review' => (
          Icons.verified_user_outlined,
          PosColors.warning,
          _copy.awaitingApproval,
        ),
        'approved' => (
          Icons.restaurant_rounded,
          PosColors.success,
          _copy.approved,
        ),
        'rejected' => (
          Icons.error_outline_rounded,
          PosColors.danger,
          _copy.rejected,
        ),
        'cancelled' => (
          Icons.cancel_outlined,
          PosColors.textSecondary,
          _copy.cancelled,
        ),
        _ => (
          Icons.info_outline_rounded,
          PosColors.textSecondary,
          _copy.orderStatus,
        ),
      },
    };
    final fulfillment = switch (status.fulfillmentStatus) {
      'preparing' => _copy.preparing,
      'ready' => _copy.ready,
      'dispatched' => _copy.dispatched,
      'completed' => _copy.completed,
      _ => null,
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
            Text(
              status.referenceCode,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: tone),
            ),
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
            if (status.grabTrackingUrl != null) ...[
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: () async {
                  final uri = Uri.tryParse(status.grabTrackingUrl!);
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
    final currentStep = switch (status.fulfillmentStatus) {
      'completed' => 4,
      'dispatched' => 3,
      'preparing' || 'ready' => 2,
      _ when status.state == 'approved' => 1,
      _ => 0,
    };
    final steps = <(IconData, String)>[
      (Icons.receipt_long_outlined, _copy.progressOrderConfirmed),
      (Icons.account_balance_wallet_outlined, _copy.progressPaymentConfirmed),
      (Icons.restaurant_outlined, _copy.progressPreparing),
      (Icons.delivery_dining_outlined, _copy.progressGrabHandoff),
      (Icons.check_circle_outline_rounded, _copy.progressCompleted),
    ];
    return Card(
      key: const Key('direct_order_customer_progress'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
    final canPay = status.state == 'quoted' && quote.status == 'active';
    final canResubmit = status.proofReview?.canResubmit == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _copy.quoteReady,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            _amountRow(_copy.menuTotal, quote.menuTotal),
            _amountRow(_copy.serviceCharge, quote.serviceChargeTotal),
            _amountRow(_copy.deliveryFee, quote.deliveryFeeTotal),
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
            if (canPay || canResubmit) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const Key('direct_open_payment_details'),
                onPressed: _proofUploading
                    ? null
                    : () => _showPaymentDetails(status),
                icon: Icon(
                  canResubmit
                      ? Icons.refresh_rounded
                      : Icons.account_balance_wallet_outlined,
                ),
                label: Text(canResubmit ? _copy.replaceProof : _copy.payNow),
              ),
            ],
          ],
        ),
      ),
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
          FilledButton.icon(
            key: const Key('direct_upload_payment_proof'),
            onPressed: _proofUploading
                ? null
                : () {
                    Navigator.pop(dialogContext);
                    _uploadProof();
                  },
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(
              isResubmission ? _copy.replaceProof : _copy.attachProof,
            ),
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
                  onPressed: _sendingMessage ? null : _sendMessage,
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
        ? _copy.paymentProof
        : localizedDirectOrderMessage(
            copy: _copy,
            messageType: message.messageType,
            body: message.body,
          );
    final grabUri = message.messageType == 'grab_link'
        ? Uri.tryParse(message.body ?? '')
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
          Flexible(child: Text(body)),
          if (grabUri != null) ...[
            const SizedBox(width: 6),
            const Icon(Icons.open_in_new_rounded, size: 16),
          ],
        ],
      ),
    );
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: grabUri == null
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
    required this.copy,
    required this.canOpenAddress,
    required this.hasStatus,
    required this.onSelected,
  });

  final _CustomerView selected;
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
            copy.address,
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
    required this.onPressed,
  });

  final String leading;
  final String amount;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: PosTerminalColors.darkShell,
      elevation: 8,
      borderRadius: AppRadius.lg,
      child: InkWell(
        onTap: onPressed,
        borderRadius: AppRadius.lg,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      leading,
                      style: const TextStyle(
                        color: PosTerminalColors.darkTextMuted,
                      ),
                    ),
                    Text(
                      amount,
                      style: const TextStyle(
                        color: PosTerminalColors.darkText,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.arrow_forward_rounded, color: Colors.white),
            ],
          ),
        ),
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
