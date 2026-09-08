import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/services/live_refresh_service.dart';
import '../../core/ui/app_theme.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/language_switcher.dart';
import '../auth/auth_provider.dart';
import 'direct_order_copy.dart';
import 'direct_order_dialog.dart';
import 'direct_order_localization.dart';
import 'direct_order_money.dart';
import 'direct_order_staff_service.dart';

class DirectOrderCashierScreen extends ConsumerStatefulWidget {
  const DirectOrderCashierScreen({super.key});

  @override
  ConsumerState<DirectOrderCashierScreen> createState() =>
      _DirectOrderCashierScreenState();
}

class _DirectOrderCashierScreenState
    extends ConsumerState<DirectOrderCashierScreen> {
  final _money = NumberFormat('#,###', 'vi_VN');
  final _chatController = TextEditingController();
  final _feeController = TextEditingController();
  final _quoteNoteController = TextEditingController();
  final _grabUrlController = TextEditingController();
  final _actualGrabFeeController = TextEditingController();
  Timer? _timer;
  Timer? _chatRefreshTimer;
  List<Map<String, dynamic>> _requests = const [];
  Map<String, dynamic>? _detail;
  Map<String, dynamic>? _verifiedPaymentEvidence;
  List<Map<String, dynamic>> _sepayCandidates = const [];
  DirectOrderDriverReceiptStatus _driverReceiptStatus =
      const DirectOrderDriverReceiptStatus.empty();
  DirectOrderDriverReceiptStatus _customerReceiptStatus =
      const DirectOrderDriverReceiptStatus.empty();
  DirectOrderDeliveryPaymentMode _deliveryPaymentMode =
      DirectOrderDeliveryPaymentMode.customerDirect;
  String? _selectedId;
  String? _error;
  String? _stateFilter;
  bool _loading = true;
  bool _busy = false;
  int _refreshRevision = 0;

  DirectOrderCopy get _copy =>
      DirectOrderCopy(Localizations.localeOf(context).languageCode);
  String? get _storeId => ref.read(authProvider).storeId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    _timer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refresh(silent: true),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _chatRefreshTimer?.cancel();
    _chatController.dispose();
    _feeController.dispose();
    _quoteNoteController.dispose();
    _grabUrlController.dispose();
    _actualGrabFeeController.dispose();
    super.dispose();
  }

  Future<void> _refresh({
    bool silent = false,
    bool allowWhileBusy = false,
  }) async {
    final storeId = _storeId;
    if (storeId == null || (_busy && !allowWhileBusy)) return;
    final revision = ++_refreshRevision;
    if (!silent) setState(() => _loading = true);
    try {
      final rows = await directOrderStaffService.listRequests(
        storeId: storeId,
        states: _stateFilter == null ? null : [_stateFilter!],
      );
      Map<String, dynamic>? detail;
      final requestedSelection = _selectedId;
      final selectedId =
          rows.any((row) => row['id']?.toString() == requestedSelection)
          ? requestedSelection
          : (rows.isEmpty ? null : rows.first['id']?.toString());
      if (selectedId != null) {
        detail = await directOrderStaffService.requestDetail(
          storeId: storeId,
          requestId: selectedId,
        );
      }
      final driverReceiptStatus =
          selectedId != null && detail?['financial'] is Map
          ? await _loadDriverReceiptStatus(storeId, selectedId)
          : const DirectOrderDriverReceiptStatus.empty();
      final customerReceiptStatus =
          selectedId != null && detail?['financial'] is Map
          ? await _loadCustomerReceiptStatus(storeId, selectedId)
          : const DirectOrderDriverReceiptStatus.empty();
      final paymentReview = selectedId == null || detail == null
          ? const _PaymentReviewData.empty()
          : await _loadPaymentReview(storeId, selectedId, detail);
      if (!mounted || revision != _refreshRevision) return;
      if (selectedId != requestedSelection && detail != null) {
        _seedOrderInputs(detail);
      }
      setState(() {
        _requests = rows;
        _selectedId = selectedId;
        _detail = detail;
        _driverReceiptStatus = driverReceiptStatus;
        _customerReceiptStatus = customerReceiptStatus;
        _verifiedPaymentEvidence = paymentReview.evidence;
        _sepayCandidates = paymentReview.candidates;
        _error = null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || silent) return;
      setState(() {
        _error = _copy.loadFailed;
        _loading = false;
      });
    }
  }

  Future<void> _select(String id) async {
    final storeId = _storeId;
    if (storeId == null) return;
    final revision = ++_refreshRevision;
    setState(() {
      _selectedId = id;
      _detail = null;
      _driverReceiptStatus = const DirectOrderDriverReceiptStatus.empty();
      _customerReceiptStatus = const DirectOrderDriverReceiptStatus.empty();
      _verifiedPaymentEvidence = null;
      _sepayCandidates = const [];
      _loading = true;
    });
    try {
      final detail = await directOrderStaffService.requestDetail(
        storeId: storeId,
        requestId: id,
      );
      final driverReceiptStatus = detail['financial'] is Map
          ? await _loadDriverReceiptStatus(storeId, id)
          : const DirectOrderDriverReceiptStatus.empty();
      final customerReceiptStatus = detail['financial'] is Map
          ? await _loadCustomerReceiptStatus(storeId, id)
          : const DirectOrderDriverReceiptStatus.empty();
      final paymentReview = await _loadPaymentReview(storeId, id, detail);
      if (!mounted || revision != _refreshRevision) return;
      _seedOrderInputs(detail);
      setState(() {
        _detail = detail;
        _driverReceiptStatus = driverReceiptStatus;
        _customerReceiptStatus = customerReceiptStatus;
        _verifiedPaymentEvidence = paymentReview.evidence;
        _sepayCandidates = paymentReview.candidates;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = _copy.loadFailed;
        _loading = false;
      });
    }
  }

  Future<void> _act(Future<void> Function() action, String success) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(success)));
      await _refresh(silent: true, allowWhileBusy: true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_copy.errorMessage(directOrderStaffErrorCode(error))),
            backgroundColor: PosColors.danger,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendQuote() async {
    final fee =
        _deliveryPaymentMode == DirectOrderDeliveryPaymentMode.customerDirect
        ? 0
        : parseDirectOrderVnd(_feeController.text);
    if (fee == null || _storeId == null || _selectedId == null) {
      return;
    }
    await _act(() async {
      await directOrderStaffService.quote(
        storeId: _storeId!,
        requestId: _selectedId!,
        deliveryFee: fee.toDouble(),
        deliveryPaymentMode: _deliveryPaymentMode,
        note: _quoteNoteController.text.trim(),
      );
    }, _copy.quoteSent);
  }

  Future<DirectOrderDriverReceiptStatus> _loadDriverReceiptStatus(
    String storeId,
    String requestId,
  ) async {
    try {
      return await directOrderStaffService.driverReceiptStatus(
        storeId: storeId,
        requestId: requestId,
      );
    } catch (_) {
      // Keep the pre-existing direct-order detail usable while the additive
      // migration is rolling out or the print-status endpoint is unavailable.
      return const DirectOrderDriverReceiptStatus.empty();
    }
  }

  Future<DirectOrderDriverReceiptStatus> _loadCustomerReceiptStatus(
    String storeId,
    String requestId,
  ) async {
    try {
      return await directOrderStaffService.customerReceiptStatus(
        storeId: storeId,
        requestId: requestId,
      );
    } catch (_) {
      return const DirectOrderDriverReceiptStatus.empty();
    }
  }

  Future<_PaymentReviewData> _loadPaymentReview(
    String storeId,
    String requestId,
    Map<String, dynamic> detail,
  ) async {
    final state = _map(detail['request'])['state']?.toString();
    if (!const {'quoted', 'awaiting_payment_review'}.contains(state)) {
      return const _PaymentReviewData.empty();
    }
    try {
      final results = await Future.wait<Object?>([
        directOrderStaffService.verifiedPaymentEvidence(
          storeId: storeId,
          requestId: requestId,
        ),
        directOrderStaffService.sepayCandidates(
          storeId: storeId,
          requestId: requestId,
        ),
      ]);
      return _PaymentReviewData(
        evidence: results[0] as Map<String, dynamic>?,
        candidates: results[1] as List<Map<String, dynamic>>,
      );
    } catch (_) {
      return const _PaymentReviewData.empty();
    }
  }

  Future<void> _sendMessage() async {
    final body = _chatController.text.trim();
    if (body.isEmpty || _storeId == null || _selectedId == null) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final sent = await directOrderStaffService.sendMessage(
        storeId: _storeId!,
        requestId: _selectedId!,
        message: body,
      );
      if (!mounted) return;
      _refreshRevision += 1;
      final currentDetail = _detail;
      _chatController.clear();
      setState(() {
        if (currentDetail != null) {
          _detail = {
            ...currentDetail,
            'messages': [
              ..._maps(currentDetail['messages']),
              {
                'id': sent['message_id'],
                'sender_type': 'cashier',
                'message_type': 'text',
                'body': body,
                'has_attachment': false,
                'created_at': sent['created_at'],
              },
            ],
          };
        }
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_copy.errorMessage(directOrderStaffErrorCode(error))),
            backgroundColor: PosColors.danger,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _handleLiveEvent(PosLiveEvent event) {
    if (!event.affects({'direct_order_chat'})) return;
    _chatRefreshTimer?.cancel();
    _chatRefreshTimer = Timer(const Duration(milliseconds: 100), () {
      if (mounted) _refresh(silent: true);
    });
  }

  Future<void> _showProof(Map<String, dynamic> message) async {
    if (_storeId == null || _selectedId == null) return;
    try {
      final url = await directOrderStaffService.proofSignedUrl(
        storeId: _storeId!,
        requestId: _selectedId!,
        messageId: message['id']?.toString() ?? '',
      );
      if (!mounted) return;
      await showDirectOrderDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _copy.proof,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Flexible(child: InteractiveViewer(child: Image.network(url))),
              ],
            ),
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_copy.loadFailed)));
      }
    }
  }

  Future<void> _showApproval() async {
    final quote = _activeQuote;
    final total = _number(quote?['final_total']);
    if (_verifiedPaymentEvidence == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_copy.verifiedPaymentRequired),
          backgroundColor: PosColors.danger,
        ),
      );
      return;
    }
    final confirmed = await showDirectOrderDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(_copy.approveConfirmTitle),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: formatDirectOrderVnd(total),
                readOnly: true,
                decoration: InputDecoration(
                  labelText: _copy.confirmedAmount,
                  suffixText: 'VND',
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _copy.verifiedPaymentSummary(
                  _vnd(_verifiedPaymentEvidence!['amount']),
                  _verifiedPaymentEvidence!['reference_code']?.toString(),
                ),
              ),
              const SizedBox(height: 14),
              Text(_copy.manualApprovalCheck),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(_copy.close),
          ),
          FilledButton(
            key: const Key('direct_order_approval_confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(_copy.approveAndSendKitchen),
          ),
        ],
      ),
    );
    if (confirmed != true || _storeId == null || _selectedId == null) return;
    await _act(() async {
      await directOrderStaffService.approve(
        storeId: _storeId!,
        requestId: _selectedId!,
      );
    }, _copy.approvalSuccess);
  }

  Future<void> _reject() async {
    final controller = TextEditingController();
    final ok = await showDirectOrderDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(_copy.rejectOrder),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(labelText: _copy.rejectionReasonOptional),
          maxLines: 3,
          maxLength: 500,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_copy.close),
          ),
          FilledButton(
            key: const Key('direct_order_reject_confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(_copy.rejectOrder),
          ),
        ],
      ),
    );
    final reason = controller.text.trim().isEmpty
        ? 'DIRECT_ORDER_REJECTED_BY_STORE'
        : controller.text.trim();
    controller.dispose();
    if (ok != true || _storeId == null || _selectedId == null) {
      return;
    }
    await _act(
      () => directOrderStaffService.reject(
        storeId: _storeId!,
        requestId: _selectedId!,
        reason: reason,
      ),
      _copy.rejected,
    );
  }

  Future<void> _sendGrab() async {
    final url = normalizeGrabTrackingUrl(_grabUrlController.text);
    final mode = DirectOrderDeliveryPaymentMode.fromValue(
      (_detail?['financial'] as Map?)?['delivery_payment_mode'],
    );
    final actual = parseDirectOrderVnd(_actualGrabFeeController.text);
    if (url == null ||
        (mode == DirectOrderDeliveryPaymentMode.storePrepaid &&
            actual == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_copy.deliveryCashPayoutRequired),
          backgroundColor: PosColors.danger,
        ),
      );
      return;
    }
    if (_storeId == null || _selectedId == null) {
      return;
    }
    await _act(
      () => directOrderStaffService.setDispatch(
        storeId: _storeId!,
        requestId: _selectedId!,
        grabUrl: url,
        actualGrabFee: actual?.toDouble(),
      ),
      _copy.grabLinkSent,
    );
  }

  void _seedOrderInputs(Map<String, dynamic> detail) {
    _feeController.clear();
    _quoteNoteController.clear();
    _grabUrlController.clear();
    _actualGrabFeeController.clear();
    _deliveryPaymentMode = DirectOrderDeliveryPaymentMode.customerDirect;

    final quotes = _maps(detail['quotes']);
    final activeQuote = quotes.cast<Map<String, dynamic>?>().firstWhere(
      (quote) => quote?['status'] == 'active' || quote?['status'] == 'locked',
      orElse: () => quotes.isEmpty ? null : quotes.first,
    );
    if (activeQuote != null) {
      _deliveryPaymentMode = DirectOrderDeliveryPaymentMode.fromValue(
        activeQuote['delivery_payment_mode'] ?? 'store_prepaid',
      );
      final fee = activeQuote['delivery_fee_total'];
      if (fee is num && fee > 0) {
        _feeController.text = formatDirectOrderVnd(fee);
      }
      _quoteNoteController.text = activeQuote['cashier_note']?.toString() ?? '';
    }

    final dispatch = detail['dispatch'];
    if (dispatch is! Map) return;
    final url = dispatch['grab_tracking_url']?.toString();
    final fee = dispatch['actual_grab_fee'];
    if (url != null && url.isNotEmpty) _grabUrlController.text = url;
    if (fee is num) _actualGrabFeeController.text = formatDirectOrderVnd(fee);
  }

  Future<void> _printDriverReceipt({required bool reprint}) async {
    if (_storeId == null || _selectedId == null) return;
    await _act(() async {
      await directOrderStaffService.enqueueDriverReceipt(
        storeId: _storeId!,
        requestId: _selectedId!,
        reprint: reprint,
      );
    }, reprint ? _copy.driverReceiptReprintQueued : _copy.driverReceiptQueued);
  }

  Future<void> _printCustomerReceipt({required bool reprint}) async {
    if (_storeId == null || _selectedId == null) return;
    await _act(() async {
      await directOrderStaffService.enqueueCustomerReceipt(
        storeId: _storeId!,
        requestId: _selectedId!,
        reprint: reprint,
      );
    }, reprint ? _copy.customerBillReprintQueued : _copy.customerBillQueued);
  }

  Map<String, dynamic>? get _activeQuote {
    final quotes = _maps(_detail?['quotes']);
    for (final quote in quotes) {
      if (quote['status'] == 'active' || quote['status'] == 'locked') {
        return quote;
      }
    }
    return quotes.isEmpty ? null : quotes.first;
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final storeId = auth.storeId;
    if (storeId != null) {
      ref.listen<AsyncValue<PosLiveEvent>>(posLiveEventsProvider(storeId), (
        _,
        next,
      ) {
        next.whenData(_handleLiveEvent);
      });
    }
    final width = MediaQuery.sizeOf(context).width;
    final isCompact = width < 900;
    return Scaffold(
      backgroundColor: PosColors.canvas,
      appBar: AppBar(
        title: Text(_copy.directOrderDesk),
        actions: [
          if ({
            'admin',
            'store_admin',
            'brand_admin',
            'super_admin',
          }.contains(auth.role)) ...[
            IconButton(
              tooltip: _copy.analytics,
              onPressed: () => context.go('/direct-delivery/analytics'),
              icon: const Icon(Icons.query_stats_rounded),
            ),
            IconButton(
              tooltip: _copy.settings,
              onPressed: () => context.go('/direct-delivery/settings'),
              icon: const Icon(Icons.tune_rounded),
            ),
          ],
          IconButton(
            tooltip: _copy.refresh,
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const LanguageSwitcher(compact: true),
          const SizedBox(width: 6),
          const Padding(
            padding: EdgeInsets.only(right: 10),
            child: AppNavBar(
              showLogout: false,
              showLanguage: false,
              forceHomeEnabled: true,
            ),
          ),
        ],
      ),
      body: _error != null && _requests.isEmpty
          ? _ErrorState(message: _error!, retry: _refresh, copy: _copy)
          : isCompact
          ? (_selectedId == null ? _buildQueue() : _buildCompactDetail())
          : Row(
              children: [
                SizedBox(width: 310, child: _buildQueue()),
                const VerticalDivider(width: 1),
                Expanded(child: _buildDetail(includeChat: width < 1240)),
                if (width >= 1240) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(width: 360, child: _buildChat()),
                ],
              ],
            ),
    );
  }

  Widget _buildCompactDetail() => Column(
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => setState(() => _selectedId = null),
          icon: const Icon(Icons.arrow_back),
          label: Text(_copy.backToQueue),
        ),
      ),
      Expanded(child: _buildDetail(includeChat: true)),
    ],
  );

  Widget _buildQueue() {
    const filters = <String?>[
      null,
      'awaiting_quote',
      'quoted',
      'awaiting_payment_review',
      'approved',
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final state in filters)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(
                        state == null ? _copy.all : _copy.stateLabel(state),
                      ),
                      selected: _stateFilter == state,
                      onSelected: (_) {
                        setState(() => _stateFilter = state);
                        _refresh();
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (_loading && _requests.isEmpty)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_requests.isEmpty)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_copy.noOrders, textAlign: TextAlign.center),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              itemCount: _requests.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final row = _requests[index];
                final id = row['id']?.toString() ?? '';
                final state = row['state']?.toString() ?? '';
                return ListTile(
                  selected: id == _selectedId,
                  selectedTileColor: PosColors.selectedRow,
                  onTap: () => _select(id),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '#${row['reference_code'] ?? ''}',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      if (row['has_payment_proof'] == true)
                        const Icon(
                          Icons.image_outlined,
                          color: PosColors.warning,
                          size: 19,
                        ),
                    ],
                  ),
                  subtitle: Text(
                    '${_copy.stateLabel(state)}\n${row['customer_name'] ?? ''} · ${row['district'] ?? ''}',
                  ),
                  trailing: row['final_total'] == null
                      ? null
                      : Text(
                          _vnd(row['final_total']),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                  isThreeLine: true,
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildDetail({bool includeChat = false}) {
    if (_selectedId == null) return Center(child: Text(_copy.noOrders));
    if (_detail == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final request = _map(_detail?['request']);
    final address = _map(_detail?['address']);
    final items = _maps(_detail?['items']);
    final quote = _activeQuote;
    final financial = _detail?['financial'];
    final state = request['state']?.toString() ?? '';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '#${request['reference_code'] ?? ''}',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            Chip(label: Text(_copy.stateLabel(state))),
          ],
        ),
        const SizedBox(height: 12),
        _Section(
          title: _copy.addressAndContact,
          icon: Icons.location_on_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                address['customer_name']?.toString() ?? '',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              Text(address['customer_phone']?.toString() ?? ''),
              const SizedBox(height: 6),
              Text(address['formatted_address']?.toString() ?? ''),
              Text(
                address['detail_address']?.toString() ?? '',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _Section(
          title: _copy.orderItems,
          icon: Icons.receipt_long_outlined,
          child: Column(
            children: [
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 42,
                        child: Text(
                          '${item['quantity']}x',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          localizedDirectOrderSnapshotName(
                            item,
                            Localizations.localeOf(context).languageCode,
                          ),
                        ),
                      ),
                      Text(
                        _vnd(
                          _number(item['unit_price']) *
                              _number(item['quantity']),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (state == 'awaiting_quote' || state == 'quoted')
          _Section(
            title: _copy.enterGrabFee,
            icon: Icons.delivery_dining_outlined,
            child: Column(
              children: [
                DropdownButtonFormField<DirectOrderDeliveryPaymentMode>(
                  key: const Key('direct_order_delivery_payment_mode'),
                  initialValue: _deliveryPaymentMode,
                  decoration: InputDecoration(
                    labelText: _copy.deliveryPaymentMethod,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: DirectOrderDeliveryPaymentMode.customerDirect,
                      child: Text(_copy.customerPaysDriver),
                    ),
                    DropdownMenuItem(
                      value: DirectOrderDeliveryPaymentMode.storePrepaid,
                      child: Text(_copy.storePrepaysDriver),
                    ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() {
                            _deliveryPaymentMode = value;
                            if (value ==
                                DirectOrderDeliveryPaymentMode.customerDirect) {
                              _feeController.clear();
                            }
                          });
                        },
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('direct_order_delivery_fee_input'),
                  controller: _feeController,
                  enabled:
                      _deliveryPaymentMode ==
                      DirectOrderDeliveryPaymentMode.storePrepaid,
                  keyboardType: TextInputType.number,
                  inputFormatters: const [DirectOrderVndInputFormatter()],
                  decoration: InputDecoration(
                    labelText:
                        _deliveryPaymentMode ==
                            DirectOrderDeliveryPaymentMode.customerDirect
                        ? _copy.customerPaysDriver
                        : _copy.storeCollectedDeliveryFee,
                    suffixText: 'VND',
                    helperText:
                        _deliveryPaymentMode ==
                            DirectOrderDeliveryPaymentMode.customerDirect
                        ? _copy.customerPaysDriverHelp
                        : _copy.storePrepaysDriverHelp,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _quoteNoteController,
                  decoration: InputDecoration(labelText: _copy.quoteNote),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _sendQuote,
                    icon: const Icon(Icons.send_outlined),
                    label: Text(_copy.sendQuote),
                  ),
                ),
              ],
            ),
          ),
        if (quote != null) ...[
          const SizedBox(height: 12),
          _Section(
            title: _copy.quoteBreakdown,
            icon: Icons.calculate_outlined,
            child: Column(
              children: [
                _AmountRow(
                  label: _copy.subtotal,
                  value: _vnd(quote['menu_total']),
                ),
                _AmountRow(
                  label: _copy.serviceCharge,
                  value: _vnd(quote['service_charge_total']),
                ),
                if (DirectOrderDeliveryPaymentMode.fromValue(
                      quote['delivery_payment_mode'] ?? 'store_prepaid',
                    ) ==
                    DirectOrderDeliveryPaymentMode.storePrepaid)
                  _AmountRow(
                    label: _copy.storeCollectedDeliveryFee,
                    value: _vnd(quote['delivery_fee_total']),
                  )
                else
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.delivery_dining_outlined),
                    title: Text(_copy.customerPaysDriver),
                    subtitle: Text(_copy.customerPaysDriverHelp),
                  ),
                const Divider(),
                _AmountRow(
                  label: _copy.finalTotal,
                  value: _vnd(quote['final_total']),
                  strong: true,
                ),
              ],
            ),
          ),
        ],
        if (const {'quoted', 'awaiting_payment_review'}.contains(state)) ...[
          const SizedBox(height: 12),
          _buildPaymentReview(),
        ],
        if (financial is Map) ...[
          const SizedBox(height: 12),
          _buildCustomerReceiptSection(),
          const SizedBox(height: 12),
          _buildDriverReceiptSection(),
          const SizedBox(height: 12),
          _Section(
            title: _copy.grabTrackingUrl,
            icon: Icons.delivery_dining,
            child: Column(
              children: [
                TextField(
                  controller: _grabUrlController,
                  decoration: InputDecoration(
                    labelText: _copy.grabTrackingUrl,
                    hintText: 'https://...',
                  ),
                ),
                const SizedBox(height: 8),
                if (DirectOrderDeliveryPaymentMode.fromValue(
                      financial['delivery_payment_mode'],
                    ) ==
                    DirectOrderDeliveryPaymentMode.storePrepaid)
                  TextField(
                    key: const Key('direct_order_actual_grab_fee_input'),
                    controller: _actualGrabFeeController,
                    keyboardType: TextInputType.number,
                    inputFormatters: const [DirectOrderVndInputFormatter()],
                    decoration: InputDecoration(
                      labelText: _copy.actualGrabFeeCashPayout,
                      suffixText: 'VND',
                    ),
                  )
                else
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.person_outline),
                    title: Text(_copy.customerPaysDriver),
                    subtitle: Text(_copy.noStoreCashPayout),
                  ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _sendGrab,
                    icon: const Icon(Icons.send_outlined),
                    label: Text(_copy.sendGrabLink),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (!{'approved', 'rejected', 'cancelled'}.contains(state)) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _reject,
            icon: const Icon(Icons.block_outlined),
            label: Text(_copy.rejectOrder),
            style: OutlinedButton.styleFrom(foregroundColor: PosColors.danger),
          ),
        ],
        if (includeChat) ...[
          const SizedBox(height: 16),
          SizedBox(height: 520, child: _buildChat()),
        ],
      ],
    );
  }

  Widget _buildPaymentReview() {
    final messages = _maps(_detail?['messages']);
    final proofs = messages
        .where((m) => m['message_type'] == 'payment_proof')
        .toList();
    return _Section(
      title: _copy.paymentReview,
      icon: Icons.verified_user_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final proof in proofs)
            OutlinedButton.icon(
              onPressed: () => _showProof(proof),
              icon: const Icon(Icons.image_outlined),
              label: Text(_copy.viewProof),
            ),
          const SizedBox(height: 8),
          Text(
            _copy.supportingEvidence,
            style: const TextStyle(color: PosColors.textSecondary),
          ),
          const SizedBox(height: 10),
          if (_verifiedPaymentEvidence != null)
            Card(
              key: const Key('direct_order_verified_payment'),
              color: PosColors.successMuted,
              child: ListTile(
                leading: const Icon(
                  Icons.verified_rounded,
                  color: PosColors.success,
                ),
                title: Text(
                  _copy.paymentConfirmed(
                    _vnd(_verifiedPaymentEvidence!['amount']),
                  ),
                ),
                subtitle: Text(
                  [
                    _verifiedPaymentEvidence!['reference_code'],
                    _verifiedPaymentEvidence!['transaction_at'] ??
                        _verifiedPaymentEvidence!['received_at'],
                  ].where((value) => value != null).join(' · '),
                ),
              ),
            )
          else if (_sepayCandidates.isEmpty)
            Text(_copy.noSepayCandidates)
          else
            Column(
              children: [
                for (final row in _sepayCandidates)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_vnd(row['amount'])),
                    subtitle: Text(
                      [
                        row['payment_code'],
                        row['reference_code'],
                        row['transaction_at'] ?? row['received_at'],
                      ].where((value) => value != null).join(' · '),
                    ),
                    trailing: TextButton(
                      onPressed: _busy
                          ? null
                          : () => _act(
                              () => directOrderStaffService.linkSepay(
                                storeId: _storeId!,
                                requestId: _selectedId!,
                                transactionId: row['id']?.toString() ?? '',
                              ),
                              _copy.linked,
                            ),
                      child: Text(_copy.link),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('direct_order_verified_approval'),
            onPressed: _busy || _verifiedPaymentEvidence == null
                ? null
                : _showApproval,
            icon: const Icon(Icons.check_circle_outline),
            label: Text(_copy.approveAndSendKitchen),
          ),
        ],
      ),
    );
  }

  Widget _buildCustomerReceiptSection() {
    final status = _customerReceiptStatus;
    final isWaiting = status.status == 'pending' || status.status == 'printing';
    final isFailed = status.status == 'failed';
    final reprint = status.canReprint;
    final enabled = !_busy && !isWaiting;
    final buttonLabel = reprint
        ? _copy.reprintCustomerBill
        : isFailed
        ? _copy.retryCustomerBill
        : _copy.printCustomerBill;

    return _Section(
      title: _copy.customerBill,
      icon: Icons.print_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _copy.customerBillHelp,
            style: const TextStyle(color: PosColors.textSecondary),
          ),
          const SizedBox(height: 10),
          Text(_copy.customerBillStatus(status.status, status.lastErrorCode)),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: Key(
              reprint
                  ? 'direct_order_customer_bill_reprint'
                  : isFailed
                  ? 'direct_order_customer_bill_retry'
                  : 'direct_order_customer_bill_print',
            ),
            onPressed: enabled
                ? () => _printCustomerReceipt(reprint: reprint)
                : null,
            icon: Icon(reprint ? Icons.refresh : Icons.print_outlined),
            label: Text(buttonLabel),
          ),
        ],
      ),
    );
  }

  Widget _buildDriverReceiptSection() {
    final status = _driverReceiptStatus;
    final isWaiting = status.status == 'pending' || status.status == 'printing';
    final isFailed = status.status == 'failed';
    final isExpired = status.status == 'cancelled';
    final reprint = status.canReprint;
    final enabled = !_busy && !isWaiting && !isExpired;
    final buttonLabel = reprint
        ? _copy.reprintDriverReceipt
        : isFailed
        ? _copy.retryDriverReceipt
        : _copy.printDriverReceipt;

    return _Section(
      title: _copy.driverReceipt,
      icon: Icons.receipt_long_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _copy.driverReceiptHelp,
            style: const TextStyle(color: PosColors.textSecondary),
          ),
          if (status.exists) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  status.status == 'done'
                      ? Icons.check_circle_outline
                      : isFailed || isExpired
                      ? Icons.error_outline
                      : Icons.schedule_outlined,
                  size: 18,
                  color: status.status == 'done'
                      ? PosColors.success
                      : isFailed || isExpired
                      ? PosColors.danger
                      : PosColors.warning,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    _copy.driverReceiptStatus(
                      status.status,
                      batchNo: status.batchNo,
                      errorCode: status.lastErrorCode,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            key: Key(
              reprint
                  ? 'direct_order_driver_receipt_reprint'
                  : isFailed
                  ? 'direct_order_driver_receipt_retry'
                  : 'direct_order_driver_receipt_print',
            ),
            onPressed: enabled
                ? () => _printDriverReceipt(reprint: reprint)
                : null,
            icon: Icon(reprint ? Icons.refresh : Icons.print_outlined),
            label: Text(buttonLabel),
          ),
        ],
      ),
    );
  }

  Widget _buildChat() {
    final messages = _maps(_detail?['messages']);
    return Container(
      color: PosColors.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const Icon(Icons.chat_bubble_outline),
                const SizedBox(width: 8),
                Text(
                  _copy.chat,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final message = messages[index];
                final cashier = message['sender_type'] == 'cashier';
                final type = message['message_type']?.toString();
                return Align(
                  alignment: cashier
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 280),
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: cashier
                          ? PosColors.accentMuted
                          : PosColors.panelMuted,
                      borderRadius: AppRadius.sm,
                    ),
                    child: type == 'payment_proof'
                        ? InkWell(
                            onTap: () => _showProof(message),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.image_outlined),
                                const SizedBox(width: 6),
                                Text(_copy.viewProof),
                              ],
                            ),
                          )
                        : Text(
                            localizedDirectOrderMessage(
                              copy: _copy,
                              messageType: type,
                              body: message['body']?.toString(),
                            ),
                          ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _chatController,
                    decoration: InputDecoration(hintText: _copy.messageHint),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filled(
                  onPressed: _busy ? null : _sendMessage,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _vnd(Object? value) => '${_money.format(_number(value))} VND';
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];
double _number(Object? value) => value is num
    ? value.toDouble()
    : double.tryParse(value?.toString() ?? '') ?? 0;

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.child,
  });
  final String title;
  final IconData icon;
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: PosColors.accent),
              const SizedBox(width: 8),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    ),
  );
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({
    required this.label,
    required this.value,
    this.strong = false,
  });
  final String label;
  final String value;
  final bool strong;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(
          value,
          style: TextStyle(
            fontWeight: strong ? FontWeight.w900 : FontWeight.w600,
            fontSize: strong ? 18 : 14,
          ),
        ),
      ],
    ),
  );
}

class _PaymentReviewData {
  const _PaymentReviewData({required this.evidence, required this.candidates});

  const _PaymentReviewData.empty() : evidence = null, candidates = const [];

  final Map<String, dynamic>? evidence;
  final List<Map<String, dynamic>> candidates;
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.message,
    required this.retry,
    required this.copy,
  });
  final String message;
  final VoidCallback retry;
  final DirectOrderCopy copy;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.cloud_off_outlined,
          size: 44,
          color: PosColors.textSecondary,
        ),
        const SizedBox(height: 12),
        Text(message),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: retry,
          icon: const Icon(Icons.refresh),
          label: Text(copy.retry),
        ),
      ],
    ),
  );
}
