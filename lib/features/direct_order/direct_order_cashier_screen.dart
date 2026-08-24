import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/services/live_refresh_service.dart';
import '../../core/ui/app_theme.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/language_switcher.dart';
import '../auth/auth_provider.dart';
import 'direct_order_copy.dart';
import 'direct_order_dialog.dart';
import 'direct_order_localization.dart';
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
      if (!mounted || revision != _refreshRevision) return;
      setState(() {
        _requests = rows;
        _selectedId = selectedId;
        _detail = detail;
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
      _loading = true;
    });
    try {
      final detail = await directOrderStaffService.requestDetail(
        storeId: storeId,
        requestId: id,
      );
      if (!mounted || revision != _refreshRevision) return;
      setState(() {
        _detail = detail;
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
    final fee = double.tryParse(_feeController.text.replaceAll(',', ''));
    if (fee == null || fee < 0 || _storeId == null || _selectedId == null) {
      return;
    }
    await _act(() async {
      await directOrderStaffService.quote(
        storeId: _storeId!,
        requestId: _selectedId!,
        deliveryFee: fee,
        note: _quoteNoteController.text.trim(),
      );
    }, _copy.quoteSent);
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
    final amount = TextEditingController(text: total.toStringAsFixed(0));
    final reference = TextEditingController();
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
                controller: amount,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: _copy.confirmedAmount,
                  suffixText: 'VND',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: reference,
                decoration: InputDecoration(labelText: _copy.bankReference),
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
    final confirmedAmount = double.tryParse(amount.text.replaceAll(',', ''));
    if (confirmedAmount == null) return;
    await _act(() async {
      await directOrderStaffService.approve(
        storeId: _storeId!,
        requestId: _selectedId!,
        confirmedAmount: confirmedAmount,
        bankReference: reference.text.trim(),
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
    final url = _grabUrlController.text.trim();
    final actual = _actualGrabFeeController.text.trim().isEmpty
        ? null
        : double.tryParse(_actualGrabFeeController.text.replaceAll(',', ''));
    if (!url.startsWith('https://') ||
        _storeId == null ||
        _selectedId == null) {
      return;
    }
    await _act(
      () => directOrderStaffService.setDispatch(
        storeId: _storeId!,
        requestId: _selectedId!,
        grabUrl: url,
        actualGrabFee: actual,
      ),
      _copy.grabLinkSent,
    );
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
              if (address['latitude'] != null &&
                  address['longitude'] != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => launchUrl(
                    Uri.https('www.google.com', '/maps/search/', {
                      'api': '1',
                      'query': '${address['latitude']},${address['longitude']}',
                    }),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.map_outlined),
                  label: Text(_copy.openMap),
                ),
              ],
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
                TextField(
                  controller: _feeController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: _copy.enterGrabFee,
                    suffixText: 'VND',
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
                _AmountRow(
                  label: _copy.enterGrabFee,
                  value: _vnd(quote['delivery_fee_total']),
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
        if (state == 'awaiting_payment_review') ...[
          const SizedBox(height: 12),
          _buildPaymentReview(),
        ],
        if (financial is Map) ...[
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
                TextField(
                  controller: _actualGrabFeeController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: _copy.actualGrabFee,
                    suffixText: 'VND',
                  ),
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
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _storeId == null || _selectedId == null
                ? Future.value(const [])
                : directOrderStaffService.sepayCandidates(
                    storeId: _storeId!,
                    requestId: _selectedId!,
                  ),
            builder: (context, snapshot) {
              final rows = snapshot.data ?? const [];
              if (rows.isEmpty) return Text(_copy.noSepayCandidates);
              return Column(
                children: [
                  for (final row in rows)
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
              );
            },
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _showApproval,
            icon: const Icon(Icons.check_circle_outline),
            label: Text(_copy.approveAndSendKitchen),
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
