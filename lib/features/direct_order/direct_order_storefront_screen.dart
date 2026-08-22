import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/payments/vietqr_payload.dart';
import '../../core/ui/app_theme.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../widgets/language_switcher.dart';
import 'direct_order_copy.dart';
import 'direct_order_localization.dart';
import 'direct_order_browser_location.dart';
import 'direct_order_dialog.dart';
import 'direct_order_map_view.dart';
import 'direct_order_models.dart';
import 'direct_order_service.dart';
import 'google_maps_loader.dart';

enum _CustomerView { menu, address, status }

class DirectOrderStorefrontScreen extends StatefulWidget {
  const DirectOrderStorefrontScreen({
    super.key,
    required this.slug,
    this.service = directOrderService,
    this.locationAdapter,
    this.mapLoader,
    this.mapBuilder,
  });

  final String slug;
  final DirectOrderService service;
  final DirectOrderBrowserLocationAdapter? locationAdapter;
  final Future<bool> Function(String apiKey)? mapLoader;
  final DirectOrderMapBuilder? mapBuilder;

  @override
  State<DirectOrderStorefrontScreen> createState() =>
      _DirectOrderStorefrontScreenState();
}

class _DirectOrderStorefrontScreenState
    extends State<DirectOrderStorefrontScreen> {
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
  DirectOrderPlace? _selectedPlace;
  DirectOrderStatus? _status;
  List<DirectOrderPlaceSuggestion> _suggestions = const [];
  _CustomerView _view = _CustomerView.menu;
  Timer? _searchTimer;
  Timer? _statusTimer;
  DirectOrderMapCamera? _mapCamera;
  DirectOrderLocationFailure? _locationFailure;
  String? _placesSessionToken;
  bool _loading = true;
  bool _submitting = false;
  bool _searching = false;
  bool _mapsReady = false;
  bool _mapLoadAttempted = false;
  bool _locationConfirmed = false;
  bool _rememberAddress = false;
  bool _proofUploading = false;
  bool _sendingMessage = false;
  bool _locating = false;
  bool _resolvingMap = false;
  String? _errorCode;
  String _addressMode = 'search';
  int _loadGeneration = 0;
  int _searchGeneration = 0;
  int _placeDetailsGeneration = 0;
  int _mapResolveGeneration = 0;
  int _locationGeneration = 0;

  String get _languageCode =>
      Localizations.maybeLocaleOf(context)?.languageCode ?? 'vi';
  DirectOrderCopy get _copy => DirectOrderCopy(_languageCode);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _statusTimer?.cancel();
    _mapCamera?.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    _addressController.dispose();
    _detailController.dispose();
    _noteController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _errorCode = null;
    });
    try {
      final storefront = await widget.service.fetchStorefront(widget.slug);
      final session = await widget.service.ensureSession(
        slug: widget.slug,
        locale: _languageCode,
      );
      final saved = await widget.service.loadAddress(widget.slug);
      final activeRequest = await widget.service.loadActiveRequestId(
        widget.slug,
      );
      DirectOrderStatus? status;
      if (activeRequest != null) {
        try {
          status = await widget.service.fetchStatus(
            session: session,
            requestId: activeRequest,
            locale: _languageCode,
          );
        } catch (_) {
          await widget.service.clearActiveRequest(widget.slug);
        }
      }
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _storefront = storefront;
        _session = session;
        _savedAddress = saved;
        _rememberAddress = saved != null;
        _status = status;
        _view = status == null ? _CustomerView.menu : _CustomerView.status;
        _loading = false;
      });
      if (saved != null) _populateAddress(saved);
      await _ensureMapLoaded();
      if (status != null) _startStatusPolling();
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

  Future<void> _ensureMapLoaded() async {
    if (_mapLoadAttempted) return;
    _mapLoadAttempted = true;
    final key = _storefront?.googleMapsBrowserKey ?? '';
    final loader = widget.mapLoader ?? loadDirectOrderGoogleMaps;
    final canAttemptLoad = kIsWeb || widget.mapLoader != null;
    final loaded = canAttemptLoad && key.isNotEmpty ? await loader(key) : false;
    if (mounted) setState(() => _mapsReady = loaded);
  }

  void _populateAddress(DirectOrderAddress address) {
    _nameController.text = address.customerName;
    _phoneController.text = address.customerPhone;
    _addressController.text = address.formattedAddress;
    _detailController.text = address.detailAddress;
    _selectedPlace = DirectOrderPlace(
      formattedAddress: address.formattedAddress,
      latitude: address.latitude,
      longitude: address.longitude,
      placeId: address.googlePlaceId,
      district: address.district,
      ward: address.ward,
    );
    _addressMode = address.addressSource;
    _locationConfirmed = false;
    _rememberAddress = true;
  }

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

  void _onAddressSearchChanged(String value) {
    _searchTimer?.cancel();
    final generation = ++_searchGeneration;
    final query = value.trim();
    if (query.length < 2) {
      _placesSessionToken = null;
      setState(() {
        _suggestions = const [];
        _searching = false;
      });
      return;
    }
    final sessionToken = _placesSessionToken ??= widget.service
        .createPlacesSessionToken();
    _searchTimer = Timer(const Duration(milliseconds: 350), () async {
      if (!mounted || generation != _searchGeneration) return;
      setState(() => _searching = true);
      try {
        final suggestions = await widget.service.autocomplete(
          slug: widget.slug,
          query: query,
          locale: _languageCode,
          sessionToken: sessionToken,
        );
        if (mounted &&
            generation == _searchGeneration &&
            _addressController.text.trim() == query &&
            _placesSessionToken == sessionToken) {
          setState(() => _suggestions = suggestions);
        }
      } catch (_) {
        if (mounted && generation == _searchGeneration) {
          setState(() => _suggestions = const []);
        }
      } finally {
        if (mounted && generation == _searchGeneration) {
          setState(() => _searching = false);
        }
      }
    });
  }

  Future<void> _selectSuggestion(DirectOrderPlaceSuggestion suggestion) async {
    _searchTimer?.cancel();
    ++_searchGeneration;
    ++_locationGeneration;
    ++_mapResolveGeneration;
    final generation = ++_placeDetailsGeneration;
    final sessionToken =
        _placesSessionToken ?? widget.service.createPlacesSessionToken();
    _placesSessionToken = null;
    setState(() {
      _searching = true;
      _suggestions = const [];
      _locationFailure = null;
    });
    try {
      final place = await widget.service.placeDetails(
        placeId: suggestion.placeId,
        locale: _languageCode,
        sessionToken: sessionToken,
      );
      if (!mounted || generation != _placeDetailsGeneration) return;
      setState(() {
        _selectedPlace = place;
        _addressController.text = place.formattedAddress;
        _addressMode = 'search';
        _locationConfirmed = false;
      });
      await _moveMap(LatLng(place.latitude, place.longitude));
    } catch (error) {
      if (generation == _placeDetailsGeneration) _showError(error);
    } finally {
      if (mounted && generation == _placeDetailsGeneration) {
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _selectMapPoint(LatLng point) async {
    ++_locationGeneration;
    await _resolveMapPoint(point, moveCamera: false);
  }

  Future<void> _resolveMapPoint(
    LatLng point, {
    required bool moveCamera,
  }) async {
    final generation = ++_mapResolveGeneration;
    setState(() {
      _resolvingMap = true;
      _locationFailure = null;
    });
    try {
      if (moveCamera) await _moveMap(point);
      final place = await widget.service.reverseGeocode(
        latitude: point.latitude,
        longitude: point.longitude,
        locale: _languageCode,
      );
      if (!mounted || generation != _mapResolveGeneration) return;
      setState(() {
        _selectedPlace = place;
        _addressController.text = place.formattedAddress;
        _addressMode = 'map_pin';
        _locationConfirmed = true;
      });
    } catch (error) {
      if (generation == _mapResolveGeneration) _showError(error);
    } finally {
      if (mounted && generation == _mapResolveGeneration) {
        setState(() => _resolvingMap = false);
      }
    }
  }

  Future<void> _moveMap(LatLng target) async {
    try {
      await _mapCamera?.moveTo(target);
    } catch (_) {
      // A detached browser map must not turn a valid address into an order.
    }
  }

  Future<void> _useCurrentLocation() async {
    if (!_mapsReady || _locating) return;
    _searchTimer?.cancel();
    ++_searchGeneration;
    ++_placeDetailsGeneration;
    _placesSessionToken = null;
    final generation = ++_locationGeneration;
    setState(() {
      _locating = true;
      _locationFailure = null;
      _suggestions = const [];
    });
    final result =
        await (widget.locationAdapter ?? directOrderBrowserLocationAdapter)
            .currentPosition();
    if (!mounted || generation != _locationGeneration) return;
    if (!result.isSuccess) {
      final fallback = LatLng(
        _storefront?.defaultLatitude ?? 10.776,
        _storefront?.defaultLongitude ?? 106.701,
      );
      setState(() {
        _locationFailure =
            result.failure ?? DirectOrderLocationFailure.unavailable;
        _locating = false;
      });
      if (_selectedPlace == null) await _moveMap(fallback);
      return;
    }
    setState(() => _locating = false);
    await _resolveMapPoint(
      LatLng(result.latitude!, result.longitude!),
      moveCamera: true,
    );
  }

  String _locationFailureMessage(DirectOrderLocationFailure failure) =>
      switch (failure) {
        DirectOrderLocationFailure.permissionDenied =>
          _copy.locationPermissionDenied,
        DirectOrderLocationFailure.timeout => _copy.locationTimedOut,
        DirectOrderLocationFailure.unsupported => _copy.locationUnsupported,
        DirectOrderLocationFailure.unavailable => _copy.locationUnavailable,
      };

  DirectOrderAddress? _composeAddress() {
    final place = _selectedPlace;
    if (place == null || place.formattedAddress.trim().isEmpty) return null;
    if (_nameController.text.trim().isEmpty ||
        _phoneController.text.trim().isEmpty ||
        _detailController.text.trim().isEmpty) {
      return null;
    }
    return DirectOrderAddress(
      customerName: _nameController.text.trim(),
      customerPhone: _phoneController.text.trim(),
      formattedAddress: place.formattedAddress.trim(),
      detailAddress: _detailController.text.trim(),
      latitude: place.latitude,
      longitude: place.longitude,
      googlePlaceId: place.placeId,
      district: place.district,
      ward: place.ward,
      addressSource: _addressMode,
      locationVerified: true,
    );
  }

  Future<void> _submit() async {
    if (_cart.isEmpty) {
      _snack(_copy.cartEmpty);
      setState(() => _view = _CustomerView.menu);
      return;
    }
    final address = _composeAddress();
    if (_selectedPlace == null || !_mapsReady || !_locationConfirmed) {
      _snack(_copy.addressRequired);
      return;
    }
    if (address == null) {
      _snack(_copy.requiredFields);
      return;
    }
    final session = _session;
    if (session == null) return;
    setState(() => _submitting = true);
    try {
      final submission = await widget.service.submit(
        slug: widget.slug,
        session: session,
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
        locale: _languageCode,
      );
      if (!mounted) return;
      setState(() {
        _savedAddress = _rememberAddress ? address : null;
        _status = status;
        _view = _CustomerView.status;
      });
      _startStatusPolling();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      _refreshStatus(silent: true);
    });
  }

  Future<void> _refreshStatus({bool silent = false}) async {
    final session = _session;
    final requestId = _status?.requestId;
    if (session == null || requestId == null || requestId.isEmpty) return;
    try {
      final status = await widget.service.fetchStatus(
        session: session,
        requestId: requestId,
        locale: _languageCode,
      );
      if (mounted) setState(() => _status = status);
      if (const {'rejected', 'cancelled', 'expired'}.contains(status.state) ||
          status.fulfillmentStatus == 'completed') {
        _statusTimer?.cancel();
      }
    } catch (error) {
      if (!silent) _showError(error);
    }
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
      final bytes = await image.readAsBytes();
      await widget.service.uploadPaymentProof(
        session: session,
        requestId: status.requestId,
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
      await widget.service.sendMessage(
        session: session,
        requestId: status.requestId,
        message: text,
        locale: _languageCode,
      );
      _messageController.clear();
      await _refreshStatus();
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
    _statusTimer?.cancel();
    await widget.service.clearActiveRequest(widget.slug);
    if (!mounted) return;
    setState(() {
      _status = null;
      _cart.clear();
      _itemNotes.clear();
      _view = _CustomerView.menu;
    });
  }

  Future<void> _clearSavedAddress() async {
    await widget.service.clearAddress(widget.slug);
    if (!mounted) return;
    setState(() {
      _savedAddress = null;
      _selectedPlace = null;
      _locationConfirmed = false;
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
        actions: const [
          Padding(
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
    if (_storefront!.paused) {
      return _CenteredMessage(
        icon: Icons.pause_circle_outline_rounded,
        title: _copy.paused,
        actionLabel: _copy.retry,
        onAction: _load,
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
                copy: _copy,
                canOpenAddress: _cart.isNotEmpty,
                hasStatus: _status != null,
                onSelected: (view) => setState(() => _view = view),
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
              onPressed: () => setState(() => _view = _CustomerView.address),
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
    final initial = LatLng(
      _selectedPlace?.latitude ?? _storefront?.defaultLatitude ?? 10.776,
      _selectedPlace?.longitude ?? _storefront?.defaultLongitude ?? 106.701,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        if (_savedAddress != null)
          Card(
            color: PosColors.infoMuted,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _copy.useSavedAddress,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(_savedAddress!.formattedAddress),
                  Text(
                    _savedAddress!.detailAddress,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _copy.savedOnlyOnDevice,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.tonal(
                        onPressed: () =>
                            setState(() => _populateAddress(_savedAddress!)),
                        child: Text(_copy.useSavedAddress),
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
        SegmentedButton<String>(
          segments: [
            ButtonSegment(
              value: 'search',
              icon: const Icon(Icons.search_rounded),
              label: Text(_copy.searchAddress),
            ),
            ButtonSegment(
              value: 'map_pin',
              icon: const Icon(Icons.location_on_outlined),
              label: Text(_copy.pickOnMap),
            ),
          ],
          selected: {_addressMode},
          onSelectionChanged: (selected) {
            _searchTimer?.cancel();
            ++_searchGeneration;
            ++_placeDetailsGeneration;
            _placesSessionToken = null;
            setState(() {
              _addressMode = selected.first;
              _suggestions = const [];
              _searching = false;
              _locationFailure = null;
            });
          },
        ),
        const SizedBox(height: 14),
        if (_addressMode == 'search') ...[
          TextField(
            key: const Key('direct_address_search'),
            controller: _addressController,
            onChanged: _onAddressSearchChanged,
            decoration: InputDecoration(
              labelText: _copy.searchAddress,
              hintText: _copy.addressSearchHint,
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _searching
                  ? Semantics(
                      liveRegion: true,
                      label: _copy.resolvingMapLocation,
                      child: const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  : null,
            ),
          ),
          if (_suggestions.isNotEmpty)
            Card(
              margin: const EdgeInsets.only(top: 6),
              child: Column(
                children: [
                  for (final suggestion in _suggestions)
                    ListTile(
                      leading: const Icon(Icons.place_outlined),
                      title: Text(suggestion.text),
                      onTap: () => _selectSuggestion(suggestion),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Text(
            _copy.confirmOnMap,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ] else
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _copy.tapMapHint,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 10),
                Semantics(
                  button: true,
                  label: _copy.useCurrentLocation,
                  child: FilledButton.tonalIcon(
                    key: const Key('direct_use_current_location'),
                    onPressed: _mapsReady && !_locating
                        ? _useCurrentLocation
                        : null,
                    icon: _locating
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.my_location_rounded),
                    label: Text(
                      _locating
                          ? _copy.locatingCurrentLocation
                          : _copy.useCurrentLocation,
                    ),
                  ),
                ),
                if (_locationFailure != null) ...[
                  const SizedBox(height: 8),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      '${_locationFailureMessage(_locationFailure!)} '
                      '${_copy.manualPinFallback}',
                      key: const Key('direct_location_fallback'),
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: PosColors.warning),
                    ),
                  ),
                ],
              ],
            ),
          ),
        if (_mapsReady)
          ClipRRect(
            borderRadius: AppRadius.lg,
            child: SizedBox(
              height: 300,
              child: (widget.mapBuilder ?? buildDirectOrderGoogleMap)(
                context,
                DirectOrderMapConfiguration(
                  initialPosition: initial,
                  markerPosition: _selectedPlace == null ? null : initial,
                  semanticLabel: _copy.deliveryMapLabel,
                  onTap: _selectMapPoint,
                  onCameraReady: (camera) {
                    _mapCamera?.dispose();
                    _mapCamera = camera;
                  },
                ),
              ),
            ),
          )
        else
          Semantics(
            liveRegion: true,
            child: Container(
              height: 180,
              decoration: BoxDecoration(
                color: PosColors.panelMuted,
                border: Border.all(color: PosColors.border),
                borderRadius: AppRadius.lg,
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    _copy.mapUnavailable,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        if (_resolvingMap) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Row(
              children: [
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(_copy.resolvingMapLocation)),
              ],
            ),
          ),
        ],
        if (_selectedPlace != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _locationConfirmed
                  ? PosColors.successMuted
                  : PosColors.warningMuted,
              borderRadius: AppRadius.md,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _locationConfirmed
                      ? Icons.check_circle_rounded
                      : Icons.location_searching_rounded,
                  color: _locationConfirmed
                      ? PosColors.success
                      : PosColors.warning,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _locationConfirmed
                            ? _copy.locationConfirmed
                            : _copy.selectedLocation,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      Text(_selectedPlace!.formattedAddress),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (!_locationConfirmed) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                key: const Key('direct_confirm_map_location'),
                onPressed: _mapsReady
                    ? () => setState(() => _locationConfirmed = true)
                    : null,
                icon: const Icon(Icons.check_circle_outline),
                label: Text(_copy.confirmOnMap),
              ),
            ),
          ],
        ],
        const SizedBox(height: 16),
        TextField(
          controller: _detailController,
          decoration: InputDecoration(
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
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: _copy.customerName,
                  prefixIcon: const Icon(Icons.person_outline_rounded),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
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
    final (icon, tone, title) = switch (status.state) {
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
            if ({'rejected', 'cancelled', 'expired'}.contains(status.state) ||
                status.fulfillmentStatus == 'completed') ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _startNewOrder,
                icon: const Icon(Icons.add_shopping_cart_outlined),
                label: Text(_copy.startNewOrder),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _quoteCard(DirectOrderStatus status) {
    final quote = status.quote!;
    final canUpload = status.state == 'quoted' && quote.status == 'active';
    final qrData = VietQrPayload.bankTransfer(
      bankBin: _storefront!.bank.bin,
      accountNumber: _storefront!.bank.accountNumber,
      amount: quote.finalTotal.round(),
      purpose: status.referenceCode,
    );
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
            if (canUpload) ...[
              const SizedBox(height: 16),
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
              _bankLine(_copy.accountHolder, _storefront!.bank.accountHolder),
              _bankLine(_copy.accountNumber, _storefront!.bank.accountNumber),
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const Key('direct_upload_payment_proof'),
                onPressed: _proofUploading ? null : _uploadProof,
                icon: _proofUploading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_photo_alternate_outlined),
                label: Text(
                  _proofUploading ? _copy.proofUploading : _copy.attachProof,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

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
            Text(
              _copy.chatAutoTranslationNotice,
              style: Theme.of(context).textTheme.bodySmall,
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
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
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
            ],
            Flexible(child: Text(body)),
          ],
        ),
      ),
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
