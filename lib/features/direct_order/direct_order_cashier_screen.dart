import 'direct_order_translation.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/services/live_refresh_service.dart';
import '../../core/ui/app_theme.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/utils/polling_utils.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/language_switcher.dart';
import '../auth/auth_provider.dart';
import 'direct_order_copy.dart';
import 'direct_order_customer_details.dart';
import 'direct_order_models.dart';
import 'direct_order_support.dart';
import 'direct_order_stage.dart';
import 'direct_order_chat_templates.dart';
import 'package:flutter/services.dart';
import 'direct_order_dialog.dart';
import 'direct_order_localization.dart';
import 'direct_order_money.dart';
import 'direct_order_staff_service.dart';
import 'direct_order_requirements.dart';
import 'direct_order_tracking_link.dart';

class DirectOrderCashierScreen extends ConsumerStatefulWidget {
  const DirectOrderCashierScreen({
    super.key,
    this.service = directOrderStaffService,
  });

  final DirectOrderStaffService service;

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
  final _providerNameController = TextEditingController();
  final _driverContactController = TextEditingController();
  final _bookingReferenceController = TextEditingController();
  final _bookingOperationIds = <String, String>{};
  String _deliveryProvider = 'grab';
  Timer? _timer;
  Timer? _chatRefreshTimer;
  List<Map<String, dynamic>> _requests = const [];
  Map<String, dynamic>? _detail;
  DirectOrderDriverReceiptStatus _driverReceiptStatus =
      const DirectOrderDriverReceiptStatus.empty();
  DirectOrderDriverReceiptStatus _customerReceiptStatus =
      const DirectOrderDriverReceiptStatus.empty();
  DirectOrderDeliveryPaymentMode _deliveryPaymentMode =
      DirectOrderDeliveryPaymentMode.customerDirect;
  String? _selectedId;
  String? _error;
  String? _stateFilter;
  String? _fulfillmentFilter;
  bool _loading = true;
  bool _busy = false;
  final _requirementDrafts = <String, DirectOrderRequirementReply>{};
  final _requirementMutationIds = <String, String>{};
  final _requirementDraftSources = <String, String>{};
  int _refreshRevision = 0;

  DirectOrderCopy get _copy =>
      DirectOrderCopy(Localizations.localeOf(context).languageCode);
  String? get _storeId => ref.read(authProvider).storeId;
  DirectOrderStaffService get directOrderStaffService => widget.service;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    _scheduleSafetyRefresh();
  }

  void _scheduleSafetyRefresh() {
    _timer?.cancel();
    _timer = Timer(jitteredPollDelay(const Duration(seconds: 30)), () async {
      _timer = null;
      await _refresh(silent: true);
      if (mounted) _scheduleSafetyRefresh();
    });
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
    _providerNameController.dispose();
    _driverContactController.dispose();
    _bookingReferenceController.dispose();
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
        fulfillmentType: _fulfillmentFilter,
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
          selectedId != null &&
              detail?['financial'] is Map &&
              _map(detail?['request'])['fulfillment_type'] != 'pickup'
          ? await _loadDriverReceiptStatus(storeId, selectedId)
          : const DirectOrderDriverReceiptStatus.empty();
      final customerReceiptStatus =
          selectedId != null && detail?['financial'] is Map
          ? await _loadCustomerReceiptStatus(storeId, selectedId)
          : const DirectOrderDriverReceiptStatus.empty();
      if (!mounted || revision != _refreshRevision) return;
      if (selectedId != requestedSelection) {
        _chatController.clear();
        if (detail != null) _seedOrderInputs(detail);
      }
      if (detail != null) {
        _seedPickupQuoteInput(detail);
        _seedVerifiedDeliveryCost(detail);
      }
      setState(() {
        _requests = rows;
        _selectedId = selectedId;
        _detail = detail;
        _driverReceiptStatus = driverReceiptStatus;
        _customerReceiptStatus = customerReceiptStatus;
        _error = null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || revision != _refreshRevision) return;
      setState(() {
        _error = _copy.loadFailed;
        _detail = null;
        _loading = false;
      });
    }
  }

  Future<void> _select(String id) async {
    if (_busy) return;
    _chatController.clear();
    final storeId = _storeId;
    if (storeId == null) return;
    final revision = ++_refreshRevision;
    setState(() {
      _selectedId = id;
      _detail = null;
      _driverReceiptStatus = const DirectOrderDriverReceiptStatus.empty();
      _customerReceiptStatus = const DirectOrderDriverReceiptStatus.empty();
      _loading = true;
    });
    try {
      final detail = await directOrderStaffService.requestDetail(
        storeId: storeId,
        requestId: id,
      );
      final driverReceiptStatus =
          detail['financial'] is Map &&
              _map(detail['request'])['fulfillment_type'] != 'pickup'
          ? await _loadDriverReceiptStatus(storeId, id)
          : const DirectOrderDriverReceiptStatus.empty();
      final customerReceiptStatus = detail['financial'] is Map
          ? await _loadCustomerReceiptStatus(storeId, id)
          : const DirectOrderDriverReceiptStatus.empty();
      if (!mounted || revision != _refreshRevision) return;
      _seedOrderInputs(detail);
      setState(() {
        _detail = detail;
        _driverReceiptStatus = driverReceiptStatus;
        _customerReceiptStatus = customerReceiptStatus;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted || revision != _refreshRevision) return;
      setState(() {
        _error = _copy.loadFailed;
        _detail = null;
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
      await _refresh(silent: true, allowWhileBusy: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> get _delivery => _map(_detail?['delivery']);
  bool get _isPickup =>
      _delivery['method'] == 'pickup' ||
      _map(_detail?['request'])['fulfillment_type'] == 'pickup';
  bool get _recipientPolicy {
    final policy = _map(_detail?['request'])['delivery_policy_version'];
    return policy == 2 ||
        (policy == null &&
            _activeQuote == null &&
            _map(_detail?['financial']).isEmpty);
  }

  bool get _pickupOriginalPaymentPending =>
      _isPickup &&
      _map(_detail?['request'])['state'] == 'quoted' &&
      _number(_activeQuote?['delivery_fee_total']) > 0;

  void _seedPickupQuoteInput(Map<String, dynamic> detail) {
    if (_map(detail['delivery'])['method'] == 'pickup' &&
        _map(detail['request'])['state'] == 'awaiting_quote') {
      _deliveryPaymentMode = DirectOrderDeliveryPaymentMode.storePrepaid;
      _feeController.text = '0';
    }
  }

  Future<String?> _inputDialog(
    String title, {
    String? help,
    String initial = '',
    bool number = false,
  }) => showDirectOrderDialog<String>(
    context: context,
    builder: (context) => _FulfillmentInputDialog(
      copy: _copy,
      title: title,
      help: help,
      initial: initial,
      number: number,
    ),
  );

  Future<void> _editDinerCount() async {
    final input = await _inputDialog(
      _copy.editDinerCount,
      initial: _delivery['diner_count']?.toString() ?? '',
      number: true,
    );
    if (input == null || !mounted || _storeId == null || _selectedId == null) {
      return;
    }
    final count = int.tryParse(input);
    if (count == null || count < 1 || count > 100) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_copy.errorMessage('DIRECT_ORDER_DINER_COUNT_INVALID')),
        ),
      );
      return;
    }
    await _act(
      () => directOrderStaffService.setDinerCount(
        storeId: _storeId!,
        requestId: _selectedId!,
        expectedVersion: (_delivery['version'] as num?)?.toInt() ?? 1,
        dinerCount: count,
      ),
      _copy.packingCount(
        count,
        utensilsRequested: _delivery['utensils_requested'] != false,
      ),
    );
  }

  Future<void> _offerPickup() async {
    final reason = await _inputDialog(
      _copy.pickupReason,
      initial: _copy.offerPickup,
    );
    if (reason == null || !mounted || _storeId == null || _selectedId == null) {
      return;
    }
    await _act(
      () => directOrderStaffService.offerPickup(
        storeId: _storeId!,
        requestId: _selectedId!,
        expectedVersion: (_delivery['version'] as num?)?.toInt() ?? 1,
        reason: reason,
      ),
      _copy.pickupOffered,
    );
  }

  Future<void> _recordPickupRefund() async {
    if (_storeId == null || _selectedId == null) return;
    final due = supportNumber(_map(_delivery['pickup_offer'])['refund_due']);
    final payload = await _moneyEvidence(_copy.refundReference, due);
    if (payload == null || !mounted) return;
    await _act(
      () => directOrderStaffService.supportAction(
        storeId: _storeId!,
        requestId: _selectedId!,
        expectedVersion:
            (supportMap(_detail?['support'])['version'] as num?)?.toInt() ?? 1,
        action: 'refund_original_pickup',
        payload: {
          ...payload,
          'offer_id': _map(_delivery['pickup_offer'])['id'],
        },
      ),
      _copy.refundRecorded,
    );
  }

  Future<Map<String, dynamic>?> _moneyEvidence(
    String title,
    num amount, {
    bool cashOnly = false,
  }) => showDirectOrderMoneyEvidence(
    context,
    title: title,
    amount: amount,
    cashOnly: cashOnly,
    storeId: _storeId!,
    requestId: _selectedId!,
    messages: () => _maps(_detail?['messages']),
    upload: (path, name, mime, bytes) =>
        directOrderStaffService.uploadChatAttachment(
          storeId: _storeId!,
          requestId: _selectedId!,
          path: path,
          filename: name,
          mimeType: mime,
          bytes: bytes,
        ),
    onChanged: () => _refresh(silent: true),
  );

  Future<void> _sendQuote() async {
    if (_hasPendingRequirements) return;
    final fee =
        (_recipientPolicy ||
            _isPickup ||
            _deliveryPaymentMode ==
                DirectOrderDeliveryPaymentMode.customerDirect)
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
        deliveryPaymentMode: _isPickup
            ? (_map(_detail?['request'])['fulfillment_type'] == 'pickup'
                  ? DirectOrderDeliveryPaymentMode.notApplicable
                  : DirectOrderDeliveryPaymentMode.customerDirect)
            : _recipientPolicy
            ? DirectOrderDeliveryPaymentMode.customerDirect
            : supportMap(_detail?['support'])['delivery_fee_deferred'] == true
            ? DirectOrderDeliveryPaymentMode.storePrepaid
            : _deliveryPaymentMode,
        note: _quoteNoteController.text.trim(),
      );
    }, _copy.quoteSent);
  }

  List<DirectOrderRequirement> get _requirements =>
      DirectOrderRequirement.fromRows(_detail?['requirements']);
  bool get _hasPendingRequirements => _requirements.any((q) => !q.isConfirmed);

  Future<void> _replyRequirement(DirectOrderRequirement requirement) async {
    final requestId = _selectedId;
    final storeId = _storeId;
    if (_busy || requestId == null || storeId == null) return;
    final draftKey = '$requestId/${requirement.id}';
    final draftSource =
        '${requirement.version}/${requirement.requestText}/${requirement.followupText ?? ''}';
    if (_requirementDraftSources[draftKey] != draftSource) {
      _requirementDrafts.remove(draftKey);
      _requirementMutationIds.remove(draftKey);
    }
    final previousDraft = _requirementDrafts[draftKey];
    final reply = await showDirectOrderDialog<DirectOrderRequirementReply>(
      context: context,
      builder: (_) => DirectOrderRequirementReplyDialog(
        requirement: requirement,
        draft: _requirementDrafts[draftKey],
      ),
    );
    if (reply == null || !mounted || _selectedId != requestId) return;
    if (previousDraft?.body != reply.body ||
        previousDraft?.printRequestVi != reply.printRequestVi ||
        previousDraft?.printReplyVi != reply.printReplyVi ||
        previousDraft?.needsConfirmation != reply.needsConfirmation ||
        previousDraft?.printScope != reply.printScope) {
      _requirementMutationIds[draftKey] = directOrderStaffService
          .newRequirementMutationId();
    }
    _requirementDraftSources[draftKey] = draftSource;
    _requirementDrafts[draftKey] = reply;
    setState(() => _busy = true);
    try {
      final detail = await directOrderStaffService.replyRequirement(
        storeId: storeId,
        requestId: requestId,
        requirement: requirement,
        reply: reply,
        locale: Localizations.localeOf(context).languageCode,
        mutationId: _requirementMutationIds[draftKey]!,
      );
      if (!mounted || _selectedId != requestId) return;
      _refreshRevision += 1;
      _requirementDrafts.remove(draftKey);
      _requirementMutationIds.remove(draftKey);
      _requirementDraftSources.remove(draftKey);
      final requirements = DirectOrderRequirement.fromRows(
        detail['requirements'],
      );
      setState(() {
        _detail = detail;
        _requests = [
          for (final row in _requests)
            if (row['id'] == requestId)
              {
                ...row,
                'request_reply_due': requirements
                    .where((q) => q.status == 'awaiting_reply')
                    .length,
                'request_confirmation_due': requirements
                    .where((q) => q.awaitingCustomer)
                    .length,
              }
            else
              row,
        ];
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_copy.errorMessage(directOrderStaffErrorCode(error))),
          ),
        );
        await _refresh(silent: true, allowWhileBusy: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  Future<void> _sendMessage() async {
    final body = _chatController.text.trim();
    final selectedId = _selectedId;
    final storeId = _storeId;
    if (body.isEmpty || _storeId == null || _selectedId == null) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final sent = await directOrderStaffService.sendMessage(
        storeId: storeId!,
        requestId: selectedId!,
        message: body,
      );
      if (!mounted || _selectedId != selectedId || _storeId != storeId) return;
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
        requestId: message['request_id']?.toString() ?? _selectedId!,
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
                Flexible(
                  child: InteractiveViewer(
                    child: Image.network(
                      url,
                      errorBuilder: (context, error, stackTrace) => Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(_copy.loadFailed),
                      ),
                    ),
                  ),
                ),
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
    if (_busy || _photoApprovalBlockedReason != null) return;
    final storeId = _storeId, requestId = _selectedId;
    final quote = _activeQuote, proof = _currentPaymentProof;
    if (storeId == null ||
        requestId == null ||
        quote == null ||
        proof == null) {
      return;
    }
    final support = supportMap(_detail?['support']);
    final due = support.isEmpty
        ? _number(quote['final_total'])
        : supportNumber(support['food_due']);
    final reviewed = await showDirectOrderReceiptReview(
      context,
      due,
      viewProof: () => _showProof(proof),
    );
    if (!mounted || reviewed == null) return;
    if (_storeId != storeId ||
        _selectedId != requestId ||
        _activeQuote?['id'] != quote['id'] ||
        _currentPaymentProof?['id'] != proof['id']) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _copy.errorMessage('DIRECT_ORDER_PAYMENT_REVIEW_CHANGED'),
          ),
        ),
      );
      return;
    }
    await _act(
      () async {
        await directOrderStaffService.recordReceipt(
          storeId: storeId,
          requestId: requestId,
          quoteId: quote['id'].toString(),
          proofMessageId: proof['id'].toString(),
          amount: reviewed.amount,
          bankReference: reviewed.reference,
        );
      },
      reviewed.amount < due
          ? DirectOrderSupportCopy(_copy.languageCode).text('partial')
          : _copy.approvalSuccess,
    );
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
    final url = normalizeDeliveryTrackingUrl(_grabUrlController.text);
    final mode = DirectOrderDeliveryPaymentMode.fromValue(
      (_detail?['financial'] as Map?)?['delivery_payment_mode'],
    );
    final verifiedFee = supportMap(
      supportMap(_detail?['support'])['delivery_cost'],
    )['actual_fee'];
    final actual = mode == DirectOrderDeliveryPaymentMode.customerDirect
        ? null
        : verifiedFee is num
        ? verifiedFee.toInt()
        : parseDirectOrderVnd(_actualGrabFeeController.text);
    if ((_grabUrlController.text.trim().isNotEmpty && url == null) ||
        (url == null && _driverContactController.text.trim().isEmpty) ||
        (_deliveryProvider == 'other' &&
            _providerNameController.text.trim().isEmpty) ||
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
    Map<String, dynamic>? cash;
    if (actual != null && actual > 0) {
      cash = await _moneyEvidence(
        DirectOrderSupportCopy(
          Localizations.localeOf(context).languageCode,
        ).text('driver_paid'),
        actual,
        cashOnly: true,
      );
      if (cash == null || !mounted) return;
    }
    await _act(
      () => directOrderStaffService.setDispatch(
        storeId: _storeId!,
        requestId: _selectedId!,
        grabUrl: url ?? '',
        provider: _deliveryProvider,
        providerName: _providerNameController.text.trim().isEmpty
            ? null
            : _providerNameController.text.trim(),
        driverContact: _driverContactController.text.trim().isEmpty
            ? null
            : _driverContactController.text.trim(),
        expectedVersion: (_map(_detail?['fulfillment'])['version'] as num?)
            ?.toInt(),
        actualGrabFee: actual?.toDouble(),
        cashConfirmed: cash != null,
        evidenceMessageId: cash?['evidence_message_id'] as String?,
        operationId: cash?['operation_id'] as String?,
        cashReference: cash?['reference'] as String?,
      ),
      _copy.grabLinkSent,
    );
  }

  Future<void> _bookingAction(String action) async {
    final storeId = _storeId, requestId = _selectedId;
    if (_busy || storeId == null || requestId == null) return;
    final url = normalizeDeliveryTrackingUrl(_grabUrlController.text);
    final feeText = _actualGrabFeeController.text.trim();
    final fee = feeText.isEmpty ? null : parseDirectOrderVnd(feeText);
    Map<String, dynamic> payload;
    if (action == 'book') {
      if ((_grabUrlController.text.trim().isNotEmpty && url == null) ||
          (url == null && _driverContactController.text.trim().isEmpty) ||
          (feeText.isNotEmpty && fee == null) ||
          (_deliveryProvider == 'other' &&
              _providerNameController.text.trim().isEmpty)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_copy.bookingInputRequired)));
        return;
      }
      payload = {
        'provider': _deliveryProvider,
        'provider_name': _providerNameController.text.trim(),
        'reference': _bookingReferenceController.text.trim(),
        'driver_contact': _driverContactController.text.trim(),
        'tracking_url': url,
        'recipient_fee': fee,
      };
    } else {
      final reason = await _inputDialog(_copy.bookingFailureReason);
      if (reason == null ||
          reason.trim().isEmpty ||
          !mounted ||
          _selectedId != requestId) {
        return;
      }
      payload = {'reason': reason.trim()};
    }
    // Keep retries within the same booking attempt, but give a new booking
    // after cancellation/failure its own operation even if the details match.
    final bookingContext = _map(_detail?['booking'])['id'] ?? 'initial';
    final operationKey =
        '$requestId/$bookingContext/$action/${jsonEncode(payload)}';
    final operationId = _bookingOperationIds.putIfAbsent(
      operationKey,
      directOrderStaffService.newDeliveryOperationId,
    );
    await _act(() async {
      await directOrderStaffService.bookDriver(
        storeId: storeId,
        requestId: requestId,
        expectedVersion:
            (_map(_detail?['fulfillment'])['version'] as num?)?.toInt() ?? 0,
        operationId: operationId,
        action: action,
        payload: payload,
      );
    }, action == 'book' ? _copy.driverBooked : _copy.bookingRetry);
  }

  Future<void> _handoffBooking() async {
    final storeId = _storeId, requestId = _selectedId;
    final bookingId = _map(_detail?['booking'])['id']?.toString();
    if (storeId == null || requestId == null || bookingId == null) return;
    await _act(
      () => directOrderStaffService.handoffBooking(
        storeId: storeId,
        requestId: requestId,
        expectedVersion:
            (_map(_detail?['fulfillment'])['version'] as num?)?.toInt() ?? 0,
        bookingId: bookingId,
      ),
      _copy.driverHandoffNotice,
    );
  }

  String _workLabel(Map<String, dynamic> row) {
    if (row['state'] == 'awaiting_quote') return _copy.quoteNeeded;
    if (row['state'] != 'approved') {
      return _copy.stateLabel(row['state']?.toString() ?? '');
    }
    final status = row['fulfillment_status']?.toString();
    if (status == 'completed') {
      return _copy.customerProgressLabel('customer_completed');
    }
    if (status == 'cancelled') return _copy.stateLabel('cancelled');
    if (status == 'dispatched') return _copy.driverHandoffNotice;
    if (status == 'ready') {
      return _copy.customerProgressLabel(
        row['fulfillment_method'] == 'pickup'
            ? 'customer_pickup_ready'
            : 'customer_packed',
      );
    }
    if (row['booking_status'] == 'booked') return _copy.driverBooked;
    if (row['cooking_complete'] == true &&
        row['fulfillment_method'] != 'pickup') {
      return _copy.callDriver;
    }
    return _copy.customerProgressLabel('customer_preparing');
  }

  Widget _buildRecipientBooking() {
    final booking = _map(_detail?['booking']);
    final cooked = _delivery['cooking_complete'] == true;
    final booked = booking['status'] == 'booked';
    final ready = _map(_detail?['fulfillment'])['status'] == 'ready';
    final pickupPending =
        _map(_delivery['pickup_offer'])['status'] == 'proposed';
    return _Section(
      title: _copy.driverBooking,
      icon: Icons.delivery_dining,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_copy.customerPaysDriverHelp),
          const SizedBox(height: 8),
          Text(
            booked
                ? _copy.driverBooked
                : cooked
                ? _copy.callDriver
                : _copy.customerProgressLabel('customer_preparing'),
          ),
          if (booking['reason'] != null) Text(booking['reason'].toString()),
          if (booked) ...[
            Text(
              '${booking['provider_name'] ?? booking['provider'] ?? ''} · ${booking['reference'] ?? ''}',
            ),
            if (booking['driver_contact'] != null)
              Text(booking['driver_contact'].toString()),
            if (booking['tracking_url'] != null)
              DirectOrderTrackingLink(url: booking['tracking_url'].toString()),
            if (booking['recipient_fee'] != null)
              Text(
                '${_copy.recipientFeeReference}: ${_vnd(booking['recipient_fee'])}',
              ),
            FilledButton.icon(
              key: const Key('direct_order_handoff_booking'),
              onPressed: _busy || !ready || pickupPending
                  ? null
                  : _handoffBooking,
              icon: const Icon(Icons.local_shipping_outlined),
              label: Text(_copy.handoffDriver),
            ),
            OutlinedButton(
              onPressed: _busy || pickupPending
                  ? null
                  : () => _bookingAction('cancel'),
              child: Text(_copy.cancelBooking),
            ),
          ] else ...[
            DropdownButtonFormField<String>(
              key: const Key('direct_booking_provider'),
              initialValue: _deliveryProvider,
              decoration: InputDecoration(labelText: _copy.deliveryProvider),
              items: [
                for (final provider in ['grab', 'be', 'other'])
                  DropdownMenuItem(
                    value: provider,
                    child: Text(
                      provider == 'grab'
                          ? _copy.grabProvider
                          : provider == 'be'
                          ? _copy.beProvider
                          : _copy.otherProvider,
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) =>
                        setState(() => _deliveryProvider = value ?? 'grab'),
            ),
            if (_deliveryProvider == 'other')
              TextField(
                controller: _providerNameController,
                maxLength: 100,
                decoration: InputDecoration(labelText: _copy.providerName),
              ),
            TextField(
              controller: _bookingReferenceController,
              maxLength: 200,
              decoration: InputDecoration(labelText: _copy.bookingReference),
            ),
            TextField(
              controller: _driverContactController,
              maxLength: 200,
              decoration: InputDecoration(labelText: _copy.driverContact),
            ),
            TextField(
              controller: _grabUrlController,
              decoration: InputDecoration(labelText: _copy.grabTrackingUrl),
            ),
            TextField(
              controller: _actualGrabFeeController,
              keyboardType: TextInputType.number,
              inputFormatters: const [DirectOrderVndInputFormatter()],
              decoration: InputDecoration(
                labelText: _copy.recipientFeeReference,
                suffixText: 'VND',
              ),
            ),
            FilledButton.icon(
              key: const Key('direct_order_book_driver'),
              onPressed: _busy || !cooked || pickupPending
                  ? null
                  : () => _bookingAction('book'),
              icon: const Icon(Icons.person_pin_circle_outlined),
              label: Text(_copy.saveBooking),
            ),
            TextButton(
              onPressed: _busy || !cooked || pickupPending
                  ? null
                  : () => _bookingAction('fail'),
              child: Text(_copy.recordBookingFailure),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _requestProofResubmission(String targetMessageId) async {
    var reasonCode = 'blurry';
    final note = TextEditingController();
    final confirmed = await showDirectOrderDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_copy.requestProofAgain),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  key: const Key('direct_order_proof_review_reason'),
                  initialValue: reasonCode,
                  items:
                      const [
                            'blurry',
                            'details_unreadable',
                            'wrong_transaction',
                            'amount_unreadable',
                            'other',
                          ]
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(_copy.proofReviewReason(value)),
                            ),
                          )
                          .toList(growable: false),
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => reasonCode = value);
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: note,
                  maxLength: 500,
                  maxLines: 3,
                  onChanged: (_) => setDialogState(() {}),
                  decoration: InputDecoration(labelText: _copy.proofReasonNote),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(_copy.close),
            ),
            FilledButton(
              key: const Key('direct_order_proof_review_confirm'),
              onPressed: reasonCode == 'other' && note.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text(_copy.requestProofAgain),
            ),
          ],
        ),
      ),
    );
    final reasonNote = note.text.trim();
    note.dispose();
    if (confirmed != true || _storeId == null || _selectedId == null) return;
    await _act(
      () => directOrderStaffService.requestProofResubmission(
        storeId: _storeId!,
        requestId: _selectedId!,
        targetMessageId: targetMessageId,
        reasonCode: reasonCode,
        reasonNote: reasonNote.isEmpty ? null : reasonNote,
      ),
      _copy.proofRequestSent,
    );
  }

  Future<void> _completePickup() async {
    final fulfillment = _map(_detail?['fulfillment']);
    if (_storeId == null ||
        _selectedId == null ||
        fulfillment['status'] != 'ready') {
      return;
    }
    final storeId = _storeId!;
    final requestId = _selectedId!;
    final referenceCode = _map(_detail?['request'])['reference_code'];
    final confirmed = await showDirectOrderDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(_copy.pickupComplete),
        content: Text(
          '$referenceCode · ${fulfillment['pickup_code']}\n${_copy.pickupConfirm}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_copy.close),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_copy.pickupComplete),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _act(
      () => directOrderStaffService.completePickup(
        storeId: storeId,
        requestId: requestId,
        expectedVersion: (fulfillment['version'] as num).toInt(),
      ),
      _copy.pickupComplete,
    );
  }

  Future<void> _completeDelivery() async {
    final fulfillment = _map(_detail?['fulfillment']);
    final request = _map(_detail?['request']);
    if (_storeId == null ||
        _selectedId == null ||
        fulfillment['status'] != 'dispatched') {
      return;
    }
    final confirmed = await showDirectOrderDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(_copy.completeOrderConfirmTitle),
        content: Text(
          '#${request['reference_code'] ?? ''}\n\n'
          '${_copy.completeOrderConfirmMessage}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_copy.close),
          ),
          FilledButton.icon(
            key: const Key('direct_order_complete_confirm'),
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.check_circle_outline_rounded),
            label: Text(_copy.completeOrder),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _act(
      () => directOrderStaffService.completeDelivery(
        storeId: _storeId!,
        requestId: _selectedId!,
        expectedVersion: (fulfillment['version'] as num?)?.toInt() ?? 0,
      ),
      _copy.orderCompletedSuccess,
    );
  }

  void _seedOrderInputs(Map<String, dynamic> detail) {
    _feeController.clear();
    _quoteNoteController.clear();
    _grabUrlController.clear();
    _actualGrabFeeController.clear();
    _providerNameController.clear();
    _driverContactController.clear();
    _bookingReferenceController.clear();
    _deliveryProvider = 'grab';
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

    _seedPickupQuoteInput(detail);
    _seedVerifiedDeliveryCost(detail);

    final dispatch = detail['dispatch'];
    if (dispatch is! Map) return;
    _deliveryProvider = dispatch['delivery_provider']?.toString() ?? 'grab';
    _providerNameController.text = dispatch['provider_name']?.toString() ?? '';
    _driverContactController.text =
        dispatch['driver_contact']?.toString() ?? '';
    final url = dispatch['grab_tracking_url']?.toString();
    final fee = dispatch['actual_grab_fee'];
    if (url != null && url.isNotEmpty) _grabUrlController.text = url;
    if (fee is num) _actualGrabFeeController.text = formatDirectOrderVnd(fee);
  }

  void _seedVerifiedDeliveryCost(Map<String, dynamic> detail) {
    final support = supportMap(detail['support']);
    final fee = supportMap(support['delivery_cost'])['actual_fee'];
    if (fee is num) {
      _actualGrabFeeController.text = formatDirectOrderVnd(fee);
    }
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

  Map<String, dynamic>? get _currentPaymentProof {
    final quote = _activeQuote;
    if (quote == null) return null;
    final proofs = _maps(_detail?['messages']).where((message) {
      final metadata = _map(message['metadata']);
      return message['message_type'] == 'payment_proof' &&
          message['sender_type'] == 'customer' &&
          message['has_attachment'] == true &&
          message['request_id'] == _selectedId &&
          metadata['quote_id'] == quote['id'] &&
          metadata['charge_id'] == null &&
          metadata['quote_version'].toString() == quote['version'].toString();
    }).toList();
    return proofs.isEmpty ? null : proofs.last;
  }

  String? get _photoApprovalBlockedReason {
    if (_map(_detail?['request'])['state'] != 'awaiting_payment_review' ||
        _activeQuote?['status'] != 'locked' ||
        _number(_activeQuote?['final_total']) <= 0) {
      return _copy.photoAwaitingSubmission;
    }
    if (_maps(
      _detail?['proof_reviews'],
    ).any((review) => review['status'] == 'requested')) {
      return _copy.errorMessage('DIRECT_ORDER_PROOF_RESUBMISSION_PENDING');
    }
    if (_currentPaymentProof == null) return _copy.photoAwaitingSubmission;
    if (supportRows(
      supportMap(_detail?['support'])['receipts'],
    ).any((r) => r['proof_message_id'] == _currentPaymentProof?['id'])) {
      return DirectOrderSupportCopy(
        Localizations.localeOf(context).languageCode,
      ).text('pending');
    }
    return null;
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
      body: _error != null
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
      'customer_pending',
      'customer_paid',
      'customer_completed',
    ];
    String filterLabel(String? state) => state == null
        ? _copy.all
        : _copy.stageLabel(
            DirectOrderStage.values.firstWhere(
              (stage) => stage.filter == state,
            ),
          );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Wrap(
            spacing: 6,
            children: [
              for (final type in <String?>[null, 'delivery', 'pickup'])
                ChoiceChip(
                  label: Text(
                    type == null
                        ? _copy.all
                        : type == 'pickup'
                        ? _copy.pickup
                        : _copy.delivery,
                  ),
                  selected: _fulfillmentFilter == type,
                  onSelected: (_) {
                    setState(() => _fulfillmentFilter = type);
                    _refresh();
                  },
                ),
            ],
          ),
        ),
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
                      label: Text(filterLabel(state)),
                      selected: _stateFilter == state,
                      onSelected: _busy
                          ? null
                          : (_) {
                              setState(() => _stateFilter = state);
                              _refresh();
                            },
                    ),
                  ),
              ],
            ),
          ),
        ),
        ExpansionTile(
          key: const Key('direct_staff_advanced_statuses'),
          title: Text(_copy.advancedStatuses),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final state in const [
                    'awaiting_quote',
                    'quoted',
                    'awaiting_payment_review',
                    'approved',
                    'preparing',
                    'ready',
                    'dispatched',
                    'customer_exception',
                  ])
                    ChoiceChip(
                      label: Text(
                        state == 'customer_exception'
                            ? _copy.exceptionOrders
                            : _copy.stateLabel(state),
                      ),
                      selected: _stateFilter == state,
                      onSelected: _busy
                          ? null
                          : (_) {
                              setState(() => _stateFilter = state);
                              _refresh();
                            },
                    ),
                ],
              ),
            ),
          ],
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
                final requestState = row['state']?.toString() ?? '';
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
                    '${row['fulfillment_type'] == 'pickup' ? _copy.pickup : _copy.delivery} · ${_copy.stageLabel(directOrderStage(requestState, row['fulfillment_status']?.toString()))} · ${_workLabel(row)}\n${row['customer_name'] ?? ''} · ${row['district'] ?? ''}${supportNumber(row['request_reply_due']) > 0 ? ' · ${DirectOrderRequirementCopy(Localizations.localeOf(context).languageCode).replyDue} ${row['request_reply_due']}' : ''}${supportNumber(row['request_confirmation_due']) > 0 ? ' · ${DirectOrderRequirementCopy(Localizations.localeOf(context).languageCode).awaiting} ${row['request_confirmation_due']}' : ''}${row['refund_pending'] == true ? ' · ${_copy.refundPending}' : ''}${supportNumber(row['overpayment_due']) > 0 ? ' · ${DirectOrderSupportCopy(Localizations.localeOf(context).languageCode).text('surplus')}: ${_vnd(row['overpayment_due'])}' : ''}',
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
    final customer = request['pii_purged_at'] == null
        ? DirectOrderCustomerDetails.fromJson({
            'customer_name': address['customer_name'],
            'customer_phone': address['customer_phone'],
            'formatted_address': address['formatted_address'],
            'detail_address': address['detail_address'],
            'district': address['district'],
            'ward': address['ward'],
            'customer_note': request['customer_note'],
          })
        : null;
    final items = _maps(_detail?['items']);
    final quote = _activeQuote;
    final financial = _detail?['financial'];
    final isPickup = _isPickup;
    final state = request['state']?.toString() ?? '';
    final fulfillment = _map(_detail?['fulfillment']);
    final fulfillmentStatus = fulfillment['status']?.toString() ?? '';
    final displayState = fulfillmentStatus.isEmpty ? state : fulfillmentStatus;
    return ListView(
      key: const Key('direct_staff_detail_list'),
      padding: const EdgeInsets.all(16),
      children: [
        DirectOrderStaffSupportPanel(
          key: ValueKey('support:${_selectedId ?? ''}'),
          canAdjustDriverCash: const {
            'admin',
            'store_admin',
            'brand_admin',
            'super_admin',
          }.contains(ref.read(authProvider).role),
          storeId: _storeId!,
          requestId: _selectedId!,
          detail: _detail!,
          service: directOrderStaffService,
          onChanged: () => _refresh(silent: true),
        ),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '#${request['reference_code'] ?? ''}',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            Chip(label: Text(isPickup ? _copy.pickup : _copy.delivery)),
            Chip(label: Text(_copy.stateLabel(displayState))),
            Chip(
              label: Text(
                _isPickup && displayState == 'completed'
                    ? _copy.pickupCompleted
                    : _copy.stateLabel(displayState),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _Section(
          title: _isPickup ? _copy.pickup : _copy.directDelivery,
          icon: Icons.inventory_2_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _copy.packingCount(
                  ((_delivery['diner_count'] ?? request['diner_count']) as num?)
                      ?.toInt(),
                  utensilsRequested: _delivery['utensils_requested'] != false,
                ),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (!{
                    'dispatched',
                    'completed',
                    'cancelled',
                  }.contains(fulfillmentStatus) &&
                  !{'rejected', 'cancelled', 'expired'}.contains(state))
                TextButton(
                  key: const Key('direct_edit_diner_count'),
                  onPressed: _busy ? null : _editDinerCount,
                  child: Text(_copy.editDinerCount),
                ),
              if (_map(_delivery['pickup_offer'])['status'] == 'proposed')
                Text(_copy.pickupOffered),
              if (!_isPickup &&
                  !{
                    'dispatched',
                    'completed',
                    'cancelled',
                  }.contains(fulfillmentStatus) &&
                  !{'rejected', 'cancelled', 'expired'}.contains(state))
                OutlinedButton(
                  key: const Key('direct_offer_pickup'),
                  onPressed: _busy ? null : _offerPickup,
                  child: Text(_copy.offerPickup),
                ),
              if (_map(_delivery['pickup_offer'])['status'] == 'accepted' &&
                  _number(_map(_delivery['pickup_offer'])['refund_due']) >
                      0) ...[
                Text(
                  '${_map(_delivery['pickup_offer'])['refund_recorded'] == true ? _copy.refundRecorded : _copy.refundPending}: ${_vnd(_map(_delivery['pickup_offer'])['refund_due'])}',
                ),
                if (financial is Map &&
                    _map(_delivery['pickup_offer'])['refund_recorded'] != true)
                  FilledButton.tonal(
                    key: const Key('direct_record_pickup_refund'),
                    onPressed: _busy ? null : _recordPickupRefund,
                    child: Text(_copy.recordRefund),
                  ),
              ],
              if (_delivery['paid_total'] != null)
                Text(
                  '${_copy.netReceived}: ${_vnd(_number(_delivery['paid_total']) - _number(_delivery['refunded_total']))}',
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _Section(
          title: _copy.customerDetails,
          icon: Icons.location_on_outlined,
          child: DirectOrderCustomerDetailsBody(
            key: const Key('direct_staff_customer_details'),
            customer: customer,
            noteTranslations: supportMap(request['note_translations']),
            noteTranslationStatus: request['translation_status']?.toString(),
            languageCode: Localizations.localeOf(context).languageCode,
            isPickup: isPickup,
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            width: 42,
                            child: Text(
                              '${item['quantity']}x',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
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
                      DirectOrderInstructions(
                        label: _copy.itemRequest,
                        translations: supportMap(item['note_translations']),
                        status: item['translation_status']?.toString(),
                        note:
                            (item['item_note'] ?? item['note'])
                                    ?.toString()
                                    .trim()
                                    .isNotEmpty ==
                                true
                            ? (item['item_note'] ?? item['note']).toString()
                            : _copy.noInstructions,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_pickupOriginalPaymentPending) ...[
          Text(_copy.pickupOriginalPaymentHelp),
          const SizedBox(height: 12),
        ],
        if ((state == 'awaiting_quote' || state == 'quoted') &&
            !_pickupOriginalPaymentPending)
          _Section(
            title: _recipientPolicy
                ? _copy.finalOrderAmount
                : _copy.enterGrabFee,
            icon: Icons.delivery_dining_outlined,
            child: Column(
              children: [
                if (_recipientPolicy && !_isPickup)
                  Text(_copy.customerPaysDriverHelp),
                if (!_recipientPolicy &&
                    supportMap(_detail?['support'])['delivery_fee_deferred'] !=
                        true) ...[
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
                    onChanged: (_busy || _isPickup || state == 'quoted')
                        ? null
                        : (value) {
                            if (value == null) return;
                            setState(() {
                              _deliveryPaymentMode = value;
                              if (value ==
                                  DirectOrderDeliveryPaymentMode
                                      .customerDirect) {
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
                        state == 'awaiting_quote' &&
                        !_isPickup &&
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
                ],
                TextField(
                  controller: _quoteNoteController,
                  decoration: InputDecoration(labelText: _copy.quoteNote),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _busy || _hasPendingRequirements
                        ? null
                        : _sendQuote,
                    icon: const Icon(Icons.send_outlined),
                    label: Text(_copy.sendQuote),
                  ),
                ),
                if (_hasPendingRequirements)
                  Text(
                    DirectOrderRequirementCopy(
                      Localizations.localeOf(context).languageCode,
                    ).pendingGate,
                    key: const Key('requirement_quote_gate'),
                  ),
              ],
            ),
          ),
        if (isPickup && (state == 'awaiting_quote' || state == 'quoted'))
          FilledButton.icon(
            key: const Key('direct_pickup_send_quote'),
            onPressed: _busy || _hasPendingRequirements ? null : _sendQuote,
            icon: const Icon(Icons.send_outlined),
            label: Text(_copy.sendQuote),
          ),
        if (_isPickup && fulfillmentStatus == 'ready') ...[
          Text('${_copy.pickupCode}: ${fulfillment['pickup_code'] ?? ''}'),
          FilledButton.icon(
            key: Key(
              request['fulfillment_type'] == 'pickup'
                  ? 'direct_order_complete_pickup'
                  : 'direct_complete_pickup',
            ),
            onPressed: _busy ? null : _completePickup,
            icon: const Icon(Icons.check_circle_outline),
            label: Text(_copy.pickupComplete),
          ),
        ],
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
                if (!_isPickup &&
                    DirectOrderDeliveryPaymentMode.fromValue(
                          quote['delivery_payment_mode'] ?? 'store_prepaid',
                        ) ==
                        DirectOrderDeliveryPaymentMode.storePrepaid)
                  _AmountRow(
                    label: _copy.storeCollectedDeliveryFee,
                    value: _vnd(quote['delivery_fee_total']),
                  )
                else if (!_isPickup)
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
                _AmountRow(
                  label: _copy.includedVat,
                  value: _vnd(
                    _number(quote['menu_vat']) +
                        _number(quote['service_charge_vat']) +
                        _number(quote['delivery_fee_vat']),
                  ),
                ),
              ],
            ),
          ),
          if (fulfillmentStatus == 'dispatched' ||
              fulfillmentStatus == 'completed') ...[
            const SizedBox(height: 12),
            _Section(
              title: _copy.stateLabel(fulfillmentStatus),
              icon: fulfillmentStatus == 'completed'
                  ? Icons.check_circle_outline_rounded
                  : Icons.local_shipping_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_grabUrlController.text.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: () {
                        final uri = Uri.tryParse(_grabUrlController.text);
                        if (uri != null) {
                          launchUrl(uri, mode: LaunchMode.externalApplication);
                        }
                      },
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: Text(_copy.openGrab),
                    ),
                  if (fulfillmentStatus == 'dispatched') ...[
                    const SizedBox(height: 8),
                    Text(_copy.completeOrderConfirmMessage),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      key: const Key('direct_order_complete_delivery'),
                      onPressed: _busy ? null : _completeDelivery,
                      icon: const Icon(Icons.check_circle_outline_rounded),
                      label: Text(_copy.completeOrder),
                    ),
                  ],
                  if (fulfillmentStatus == 'completed' &&
                      fulfillment['completed_at'] != null)
                    Text(
                      DateFormat('yyyy-MM-dd HH:mm').format(
                        DateTime.parse(
                          fulfillment['completed_at'].toString(),
                        ).toLocal(),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
        if (const {'quoted', 'awaiting_payment_review'}.contains(state)) ...[
          const SizedBox(height: 12),
          _buildPaymentReview(),
        ],
        if (financial is Map) ...[
          const SizedBox(height: 12),
          _buildCustomerReceiptSection(),
          const SizedBox(height: 12),
          if (!isPickup) _buildDriverReceiptSection(),
          const SizedBox(height: 12),
          if (_recipientPolicy &&
              !_isPickup &&
              {'pending', 'preparing', 'ready'}.contains(fulfillmentStatus))
            _buildRecipientBooking(),
          if (!_recipientPolicy &&
              !_isPickup &&
              fulfillmentStatus == 'ready' &&
              _map(_delivery['pickup_offer'])['status'] != 'proposed')
            _Section(
              title: _copy.grabTrackingUrl,
              icon: Icons.delivery_dining,
              child: Column(
                children: [
                  DropdownButtonFormField<String>(
                    key: const Key('direct_delivery_provider'),
                    initialValue: _deliveryProvider,
                    decoration: InputDecoration(
                      labelText: _copy.deliveryProvider,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'grab',
                        child: Text(_copy.grabProvider),
                      ),
                      DropdownMenuItem(
                        value: 'be',
                        child: Text(_copy.beProvider),
                      ),
                      DropdownMenuItem(
                        value: 'other',
                        child: Text(_copy.otherProvider),
                      ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(
                            () => _deliveryProvider = value ?? 'grab',
                          ),
                  ),
                  if (_deliveryProvider == 'other')
                    TextField(
                      key: const Key('direct_provider_name'),
                      controller: _providerNameController,
                      decoration: InputDecoration(
                        labelText: _copy.providerName,
                      ),
                    ),
                  TextField(
                    key: const Key('direct_driver_contact'),
                    controller: _driverContactController,
                    maxLength: 200,
                    decoration: InputDecoration(labelText: _copy.driverContact),
                  ),
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
                      readOnly:
                          supportMap(
                                supportMap(
                                  _detail?['support'],
                                )['delivery_cost'],
                              )['actual_fee']
                              is num,
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
                      label: Text(_copy.handoffDriver),
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
    final proofReviews = _maps(_detail?['proof_reviews']);
    final openReviews = proofReviews
        .where((review) => review['status'] == 'requested')
        .toList();
    final openReview = openReviews.isEmpty ? null : openReviews.first;
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
          if (openReview != null)
            Card(
              color: PosColors.warningMuted,
              child: ListTile(
                leading: const Icon(Icons.hourglass_top_rounded),
                title: Text(_copy.replaceProof),
                subtitle: Text(
                  '${_copy.proofReviewReason(openReview['reason_code']?.toString() ?? 'other')}'
                  '${openReview['reason_note']?.toString().isNotEmpty == true ? '\n${openReview['reason_note']}' : ''}',
                ),
              ),
            ),
          if (proofs.isNotEmpty) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('direct_order_request_proof_resubmission'),
              onPressed: _busy || openReview != null
                  ? null
                  : () => _requestProofResubmission(
                      proofs.last['id']?.toString() ?? '',
                    ),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(_copy.requestProofAgain),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            _copy.supportingEvidence,
            style: const TextStyle(color: PosColors.textSecondary),
          ),
          const SizedBox(height: 10),
          if (_photoApprovalBlockedReason case final reason?)
            Text(reason, key: const Key('direct_order_photo_approval_blocked')),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('direct_order_photo_approval'),
            onPressed: _busy || _photoApprovalBlockedReason != null
                ? null
                : _showApproval,
            icon: const Icon(Icons.check_circle_outline),
            label: Text(_copy.reviewPaymentAmount),
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
      title: _isPickup ? _copy.pickup : _copy.driverReceipt,
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

  Future<void> _chooseChatTemplate() async {
    final selectedId = _selectedId;
    final detail = _detail;
    if (_busy || selectedId == null || detail == null) return;
    final template = await showModalBottomSheet<DirectOrderChatTemplate>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in <(DirectOrderChatTemplate, String)>[
              (DirectOrderChatTemplate.received, _copy.receiptTemplate),
              if (_map(detail['active_quote']).isNotEmpty)
                (DirectOrderChatTemplate.quote, _copy.quoteTemplate),
              if (!_isPickup)
                (DirectOrderChatTemplate.address, _copy.addressTemplate),
              if (!_isPickup)
                (DirectOrderChatTemplate.deliveryFee, _copy.feeTemplate),
            ])
              ListTile(
                key: Key('direct_chat_template_${entry.$1.name}'),
                title: Text(entry.$2),
                onTap: () => Navigator.pop(context, entry.$1),
              ),
          ],
        ),
      ),
    );
    if (!mounted || template == null || _selectedId != selectedId) return;
    final request = _map(detail['request']);
    final delivery = _map(detail['delivery']);
    final address = _map(detail['address']);
    int? fee;
    if (template == DirectOrderChatTemplate.deliveryFee && _recipientPolicy) {
      fee = (_map(detail['booking'])['recipient_fee'] as num?)?.toInt();
    } else if (template == DirectOrderChatTemplate.deliveryFee) {
      // Always ask staff to confirm the current fare rather than assume a quote
      // of zero means free delivery or reuse an old dispatch fare.
      final value = await _inputDialog(_copy.feeTemplate, number: true);
      fee = value == null ? null : parseDirectOrderVnd(value);
      if (!mounted || fee == null || _selectedId != selectedId) return;
    }
    if (_chatController.text.trim().isNotEmpty) {
      final replace = await showDirectOrderDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_copy.messageTemplates),
          content: Text(_copy.replaceDraft),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(_copy.close),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(_copy.confirm),
            ),
          ],
        ),
      );
      if (!mounted || replace != true || _selectedId != selectedId) return;
    }
    final draft = directOrderChatDraft(
      template: template,
      locale: Localizations.localeOf(context).languageCode,
      storeName: delivery['store_name']?.toString() ?? _copy.shop,
      referenceCode: request['reference_code']?.toString() ?? '',
      customerName: address['customer_name']?.toString() ?? '',
      phone: address['customer_phone']?.toString() ?? '',
      address: [
        address['formatted_address'],
        address['detail_address'],
      ].where((part) => part != null && part.toString().isNotEmpty).join(' '),
      pickup: delivery['method'] == 'pickup',
      recipientDeliveryPolicy: _recipientPolicy,
      customerPaysDriver:
          DirectOrderDeliveryPaymentMode.fromValue(
            _map(detail['active_quote'])['delivery_payment_mode']?.toString() ??
                _deliveryPaymentMode.value,
          ) ==
          DirectOrderDeliveryPaymentMode.customerDirect,
      deliveryFee: fee,
    );
    _chatController.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: draft.length),
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
          if (_requirements.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final requirement in _requirements)
                      DirectOrderRequirementCard(
                        requirement: requirement,
                        cashier: true,
                        busy: _busy,
                        onReply: () => _replyRequirement(requirement),
                      ),
                  ],
                ),
              ),
            ),
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
                    child: type == 'attachment'
                        ? InkWell(
                            onTap: () => openDirectOrderAttachment(
                              context,
                              () => directOrderStaffService.attachmentRequest(
                                storeId: _storeId!,
                                requestId: _selectedId!,
                                action: 'staff_attachment_url',
                                payload: {'message_id': message['id']},
                              ),
                            ),
                            child: Text(
                              message['body']?.toString() ??
                                  DirectOrderSupportCopy(
                                    Localizations.localeOf(
                                      context,
                                    ).languageCode,
                                  ).text('attach'),
                            ),
                          )
                        : type == 'payment_proof'
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
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (supportMap(
                                    message['metadata'],
                                  )['request_text']
                                  is String)
                                Text(
                                  '↳ ${supportMap(message['metadata'])['request_text']}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              DirectOrderTranslatedText(
                                translations: supportMap(
                                  supportMap(
                                    message['metadata'],
                                  )['translations'],
                                ),
                                status: supportMap(
                                  message['metadata'],
                                )['translation_status']?.toString(),
                                original: localizedDirectOrderMessage(
                                  copy: _copy,
                                  messageType: type,
                                  body: message['body']?.toString(),
                                ),
                              ),
                            ],
                          ),
                  ),
                );
              },
            ),
          ),
          if (_maps(_detail?['messages']).any(
                (m) =>
                    supportMap(m['metadata'])['translation_status'] == 'failed',
              ) ||
              supportMap(_detail?['request'])['translation_status'] ==
                  'failed' ||
              [
                ..._maps(_detail?['items']),
                ..._maps(_detail?['quotes']),
              ].any((n) => n['translation_status'] == 'failed'))
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _act(
                      () => directOrderStaffService.retryTranslation(
                        storeId: _storeId!,
                        requestId: _selectedId!,
                      ),
                      _copy.systemUpdate,
                    ),
              child: Text(
                DirectOrderSupportCopy(
                  Localizations.localeOf(context).languageCode,
                ).text('retry_translation'),
              ),
            ),
          if (_storeId != null &&
              _selectedId != null &&
              supportMap(_detail?['support'])['chat_open'] != false)
            DirectOrderAttachmentButton(
              key: ValueKey('staff_attachment:${_selectedId!}'),
              storeId: _storeId!,
              requestId: _selectedId!,
              upload: (path, name, mime, bytes) =>
                  directOrderStaffService.uploadChatAttachment(
                    storeId: _storeId!,
                    requestId: _selectedId!,
                    path: path,
                    filename: name,
                    mimeType: mime,
                    bytes: bytes,
                  ),
              onSent: () => _refresh(silent: true),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    key: const Key('direct_chat_templates'),
                    onPressed: _busy ? null : _chooseChatTemplate,
                    icon: const Icon(Icons.quickreply_outlined),
                    label: Text(_copy.messageTemplates),
                  ),
                ),
                IconButton(
                  tooltip: _copy.copyDraft,
                  onPressed: () async {
                    if (_chatController.text.trim().isEmpty) return;
                    await Clipboard.setData(
                      ClipboardData(text: _chatController.text),
                    );
                    if (mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(_copy.copied)));
                    }
                  },
                  icon: const Icon(Icons.copy),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              _copy.templateHelp,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _chatController,
                    enabled:
                        supportMap(_detail?['support'])['chat_open'] != false,
                    key: const Key('direct_staff_chat_input'),
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 2000,
                    decoration: InputDecoration(
                      hintText: _copy.messageHint,
                      counterText: '',
                    ),
                    textInputAction: TextInputAction.newline,
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filled(
                  key: const Key('direct_staff_chat_send'),
                  onPressed:
                      _busy ||
                          supportMap(_detail?['support'])['chat_open'] == false
                      ? null
                      : _sendMessage,
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

class _FulfillmentInputDialog extends StatefulWidget {
  const _FulfillmentInputDialog({
    required this.copy,
    required this.title,
    required this.initial,
    required this.number,
    this.help,
  });
  final DirectOrderCopy copy;
  final String title;
  final String initial;
  final bool number;
  final String? help;
  @override
  State<_FulfillmentInputDialog> createState() =>
      _FulfillmentInputDialogState();
}

class _FulfillmentInputDialogState extends State<_FulfillmentInputDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.help != null) Text(widget.help!),
          TextField(
            key: const Key('direct_fulfillment_dialog_input'),
            controller: _controller,
            maxLength: widget.number ? 3 : 500,
            keyboardType: widget.number
                ? TextInputType.number
                : TextInputType.text,
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(widget.copy.keepCurrentState),
      ),
      FilledButton(
        onPressed: () {
          final value = _controller.text.trim();
          if (value.isNotEmpty) {
            Navigator.pop(context, value);
          }
        },
        child: Text(widget.copy.confirm),
      ),
    ],
  );
}

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
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
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
