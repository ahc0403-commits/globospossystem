import 'dart:async';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/services/inventory_service.dart';
import '../../core/utils/permission_utils.dart';
import '../auth/auth_provider.dart';
import 'inventory_purchase_document_service.dart';
import 'supplier_price_excel_import.dart';

enum _WorkflowSection { orders, receiving, prices }

class InventoryOrderWorkflowScreen extends ConsumerStatefulWidget {
  const InventoryOrderWorkflowScreen({super.key, this.initialOrderId});

  final String? initialOrderId;

  @override
  ConsumerState<InventoryOrderWorkflowScreen> createState() =>
      _InventoryOrderWorkflowScreenState();
}

class _InventoryOrderWorkflowScreenState
    extends ConsumerState<InventoryOrderWorkflowScreen> {
  final _receiptControllers = <String, TextEditingController>{};
  final _receiptPriceControllers = <String, TextEditingController>{};
  final _receiptSaveTimers = <String, Timer>{};
  final _receiptSaving = <String>{};
  final _receiptSavedAt = <String, DateTime>{};
  final _receiptErrors = <String, String>{};

  _WorkflowSection _section = _WorkflowSection.orders;
  List<Map<String, dynamic>> _orders = const [];
  List<Map<String, dynamic>> _suppliers = const [];
  List<Map<String, dynamic>> _supplierItems = const [];
  Map<String, dynamic>? _detail;
  String? _selectedOrderId;
  String? _selectedAccountingStoreId;
  String? _loadedStoreId;
  bool _loading = true;
  bool _detailLoading = false;
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _selectedOrderId = widget.initialOrderId;
    if (_role == 'inventory_accounting') {
      _section = _WorkflowSection.receiving;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final timer in _receiptSaveTimers.values) {
      timer.cancel();
    }
    for (final controller in _receiptControllers.values) {
      controller.dispose();
    }
    for (final controller in _receiptPriceControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _text({required String ko, required String en, required String vi}) {
    return switch (Localizations.localeOf(context).languageCode) {
      'en' => en,
      'vi' => vi,
      _ => ko,
    };
  }

  String? get _storeId => ref.read(authProvider).storeId;
  String? get _role => ref.read(authProvider).role;
  bool get _isAccounting => _role == 'inventory_accounting';

  Future<void> _load({bool preserveSelection = true}) async {
    final storeId = _storeId;
    if (storeId == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = StateError('STORE_SCOPE_REQUIRED');
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait([
        if (_isAccounting)
          inventoryService.fetchLegalEntityInventoryPurchaseWorkflowOrders()
        else
          inventoryService.fetchInventoryPurchaseWorkflowOrders(
            storeId: storeId,
          ),
        if (_isAccounting)
          Future.value(<Map<String, dynamic>>[])
        else
          inventoryService.fetchInventorySuppliers(storeId: storeId),
        if (_isAccounting)
          Future.value(<Map<String, dynamic>>[])
        else
          inventoryService.fetchInventorySupplierItems(storeId: storeId),
      ]);
      final orders = results[0];
      final workflowOrders = _isAccounting
          ? orders
                .where(
                  (row) => const {
                    'ordered',
                    'partially_received',
                    'received',
                    'office_approved',
                  }.contains(_string(row['status'])),
                )
                .toList()
          : orders;
      final accountingStoreStillExists = workflowOrders.any(
        (row) => _string(row['restaurant_id']) == _selectedAccountingStoreId,
      );
      final accountingStoreId = accountingStoreStillExists
          ? _selectedAccountingStoreId
          : null;
      final selectableOrders = _isAccounting && accountingStoreId != null
          ? workflowOrders
                .where(
                  (row) => _string(row['restaurant_id']) == accountingStoreId,
                )
                .toList()
          : workflowOrders;
      final selectedExists = selectableOrders.any(
        (row) => _id(row) == _selectedOrderId,
      );
      final selected = preserveSelection && selectedExists
          ? _selectedOrderId
          : (selectableOrders.isEmpty ? null : _id(selectableOrders.first));
      if (!mounted) return;
      setState(() {
        _orders = workflowOrders;
        _suppliers = results[1];
        _supplierItems = results[2];
        _selectedOrderId = selected;
        _selectedAccountingStoreId = accountingStoreId;
        _loadedStoreId = _isAccounting ? '__legal_entity__' : storeId;
        _loading = false;
      });
      if (selected != null) await _loadDetail(selected);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  Future<void> _loadDetail(String orderId) async {
    setState(() {
      _selectedOrderId = orderId;
      _detailLoading = true;
      _error = null;
    });
    try {
      final detail = await inventoryService.fetchInventoryPurchaseOrderDetail(
        purchaseOrderId: orderId,
      );
      if (!mounted || _selectedOrderId != orderId) return;
      setState(() {
        _detail = detail;
        _detailLoading = false;
      });
      _syncReceiptControllers(detail);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _detailLoading = false;
        _error = error;
      });
    }
  }

  void _syncReceiptControllers(Map<String, dynamic>? detail) {
    final draft = _draftReceipt(detail);
    final draftLines = <String, Map<String, dynamic>>{};
    for (final row in _maps(draft?['line_details'])) {
      draftLines[_string(row['purchase_order_line_id'])] = row;
    }
    for (final line in _maps(detail?['lines'])) {
      final lineId = _id(line);
      if (lineId.isEmpty) continue;
      final conversion = _conversion(line);
      final draftLine = draftLines[lineId];
      final acceptedBase = _number(draftLine?['accepted_quantity_base']);
      final receivedBase = _number(draftLine?['received_quantity_base']);
      final displayBase = _isAccounting ? acceptedBase : receivedBase;
      final value = displayBase > 0 ? displayBase / conversion : 0.0;
      final price = _number(
        draftLine?['actual_unit_price'] ?? line['unit_price'],
      );
      _setControllerValue(_receiptControllers, lineId, value);
      _setControllerValue(_receiptPriceControllers, lineId, price);
      if (acceptedBase > 0) _receiptSavedAt[lineId] ??= DateTime.now();
    }
  }

  void _setControllerValue(
    Map<String, TextEditingController> target,
    String key,
    double value,
  ) {
    final text = value == 0 ? '' : _quantity(value);
    final controller = target.putIfAbsent(
      key,
      () => TextEditingController(text: text),
    );
    if (!controller.selection.isValid || !controller.selection.isCollapsed) {
      return;
    }
    if (controller.text != text && !_receiptSaving.contains(key)) {
      controller.text = text;
    }
  }

  Future<void> _selectOrder(String orderId) async {
    if (orderId == _selectedOrderId) return;
    if (GoRouterState.of(context).uri.path != '/inventory-orders') {
      context.go('/inventory-orders');
    }
    await _loadDetail(orderId);
  }

  void _selectAccountingStore(String? storeId) {
    final candidates = storeId == null
        ? _orders
        : _orders
              .where((row) => _string(row['restaurant_id']) == storeId)
              .toList();
    final nextOrderId = candidates.isEmpty ? null : _id(candidates.first);
    setState(() {
      _selectedAccountingStoreId = storeId;
      _selectedOrderId = nextOrderId;
      if (nextOrderId == null) {
        _detail = null;
      }
    });
    if (nextOrderId != null) {
      unawaited(_loadDetail(nextOrderId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    if (!_isAccounting &&
        _loadedStoreId != null &&
        auth.storeId != _loadedStoreId &&
        !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _text(
            ko: '원재료 발주·입고',
            en: 'Ingredient purchasing & receiving',
            vi: 'Đặt và nhập nguyên liệu',
          ),
        ),
        actions: [
          IconButton(
            tooltip: _text(ko: '새로고침', en: 'Refresh', vi: 'Làm mới'),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
          if (!const {
            'inventory_orderer',
            'inventory_accounting',
          }.contains(_role))
            TextButton.icon(
              onPressed: () => context.go('/admin?tab=inventory'),
              icon: const Icon(Icons.dashboard_outlined),
              label: Text(_text(ko: '재고 관리', en: 'Inventory', vi: 'Kho')),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildSectionBar(),
            if (_error != null) _buildErrorBanner(_error!),
            Expanded(
              child: switch (_isAccounting
                  ? _WorkflowSection.receiving
                  : _section) {
                _WorkflowSection.orders => _buildOrdersWorkspace(),
                _WorkflowSection.receiving => _buildReceivingWorkspace(),
                _WorkflowSection.prices => _buildPriceWorkspace(),
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionBar() {
    if (_isAccounting) {
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: ListTile(
          leading: const Icon(Icons.fact_check_outlined),
          title: Text(
            _text(
              ko: '회계팀 최종 입고 확정',
              en: 'Accounting receipt confirmation',
              vi: 'Kế toán xác nhận nhập kho',
            ),
          ),
          subtitle: Text(
            _text(
              ko: '법인 산하 모든 브랜드·매장의 명세서와 실수령 내역을 비교합니다. 확정 후에만 재고가 증가합니다.',
              en: 'Review statements and deliveries across every brand and store in the legal entity. Stock increases only after confirmation.',
              vi: 'Đối chiếu chứng từ và hàng nhận của mọi thương hiệu, cửa hàng thuộc pháp nhân. Tồn kho chỉ tăng sau khi xác nhận.',
            ),
          ),
        ),
      );
    }
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: SegmentedButton<_WorkflowSection>(
          segments: [
            ButtonSegment(
              value: _WorkflowSection.orders,
              icon: const Icon(Icons.shopping_cart_outlined),
              label: Text(
                _text(ko: '발주·승인', en: 'Orders & approvals', vi: 'Đơn & duyệt'),
              ),
            ),
            ButtonSegment(
              value: _WorkflowSection.receiving,
              icon: const Icon(Icons.inventory_outlined),
              label: Text(_text(ko: '입고·검증', en: 'Receiving', vi: 'Nhập kho')),
            ),
            ButtonSegment(
              value: _WorkflowSection.prices,
              icon: const Icon(Icons.price_change_outlined),
              label: Text(
                _text(ko: '거래처 단가', en: 'Supplier prices', vi: 'Giá NCC'),
              ),
            ),
          ],
          selected: {_section},
          onSelectionChanged: (values) => setState(() {
            _section = values.first;
          }),
        ),
      ),
    );
  }

  Widget _buildErrorBanner(Object error) {
    return MaterialBanner(
      content: Text(_friendlyError(error)),
      leading: const Icon(Icons.error_outline),
      actions: [
        TextButton(
          onPressed: () => setState(() => _error = null),
          child: Text(_text(ko: '닫기', en: 'Dismiss', vi: 'Đóng')),
        ),
      ],
    );
  }

  Widget _buildOrdersWorkspace() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 920;
        final list = _buildOrderList();
        final detail = _buildOrderDetail(receivingMode: false);
        if (desktop) {
          return Row(
            children: [
              SizedBox(width: 390, child: list),
              const VerticalDivider(width: 1),
              Expanded(child: detail),
            ],
          );
        }
        return ListView(
          padding: EdgeInsets.zero,
          children: [
            SizedBox(height: 390, child: list),
            const Divider(height: 1),
            SizedBox(height: 760, child: detail),
          ],
        );
      },
    );
  }

  Widget _buildReceivingWorkspace() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 920;
        final list = _buildOrderList(receivableOnly: true);
        final detail = _buildOrderDetail(receivingMode: true);
        if (desktop) {
          return Row(
            children: [
              SizedBox(width: 360, child: list),
              const VerticalDivider(width: 1),
              Expanded(child: detail),
            ],
          );
        }
        return ListView(
          children: [
            SizedBox(height: 330, child: list),
            SizedBox(height: 800, child: detail),
          ],
        );
      },
    );
  }

  Widget _buildOrderList({bool receivableOnly = false}) {
    var visible = receivableOnly
        ? _orders
              .where(
                (row) => const {
                  'ordered',
                  'partially_received',
                  'received',
                  'office_approved',
                }.contains(_string(row['status'])),
              )
              .toList()
        : _orders;
    if (_isAccounting && _selectedAccountingStoreId != null) {
      visible = visible
          .where(
            (row) =>
                _string(row['restaurant_id']) == _selectedAccountingStoreId,
          )
          .toList();
    }
    final accountingStores = <String, String>{};
    if (_isAccounting) {
      for (final order in _orders) {
        final storeId = _string(order['restaurant_id']);
        if (storeId.isNotEmpty) {
          accountingStores[storeId] = _storeName(order);
        }
      }
    }
    final sortedAccountingStores = accountingStores.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  receivableOnly
                      ? _text(
                          ko: '입고 대상',
                          en: 'Receiving queue',
                          vi: 'Chờ nhập kho',
                        )
                      : _text(
                          ko: '발주 목록',
                          en: 'Purchase orders',
                          vi: 'Danh sách đơn',
                        ),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (!receivableOnly &&
                  PermissionUtils.canCreateInventoryPurchaseOrder(_role))
                FilledButton.icon(
                  onPressed: _busy ? null : _createDraft,
                  icon: const Icon(Icons.add),
                  label: Text(_text(ko: '새 발주', en: 'New', vi: 'Tạo đơn')),
                ),
            ],
          ),
        ),
        if (_isAccounting)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 10),
            child: DropdownButtonFormField<String>(
              key: const Key('inventory_accounting_store_filter'),
              initialValue: _selectedAccountingStoreId ?? '',
              decoration: InputDecoration(
                isDense: true,
                labelText: _text(
                  ko: '법인 매장 필터',
                  en: 'Legal entity store filter',
                  vi: 'Lọc cửa hàng pháp nhân',
                ),
              ),
              items: [
                DropdownMenuItem(
                  value: '',
                  child: Text(
                    _text(
                      ko: '전체 브랜드·전체 매장',
                      en: 'All brands and stores',
                      vi: 'Tất cả thương hiệu và cửa hàng',
                    ),
                  ),
                ),
                for (final entry in sortedAccountingStores)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: _loading
                  ? null
                  : (value) => _selectAccountingStore(
                      value == null || value.isEmpty ? null : value,
                    ),
            ),
          ),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (visible.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                _text(
                  ko: '표시할 발주가 없습니다.',
                  en: 'No purchase orders.',
                  vi: 'Không có đơn đặt hàng.',
                ),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
              itemCount: visible.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final order = visible[index];
                final selected = _id(order) == _selectedOrderId;
                return Card(
                  elevation: selected ? 1 : 0,
                  color: selected
                      ? Theme.of(context).colorScheme.primaryContainer
                      : null,
                  child: ListTile(
                    selected: selected,
                    onTap: () => _selectOrder(_id(order)),
                    title: Text(
                      _string(order['purchase_order_no'], fallback: '-'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_isAccounting) ...[
                          Text(
                            _storeName(order),
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          const SizedBox(height: 3),
                        ],
                        Text(_supplierName(order)),
                        const SizedBox(height: 5),
                        Wrap(
                          spacing: 8,
                          runSpacing: 5,
                          children: [
                            _StatusChip(status: _string(order['status'])),
                            Text(_money(order['total_amount'])),
                          ],
                        ),
                      ],
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    isThreeLine: true,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildOrderDetail({required bool receivingMode}) {
    if (_selectedOrderId == null) {
      return Center(
        child: Text(
          _text(
            ko: '발주를 선택하세요.',
            en: 'Select a purchase order.',
            vi: 'Chọn một đơn đặt hàng.',
          ),
        ),
      );
    }
    if (_detailLoading || _detail == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final order = _map(_detail!['order']);
    final lines = _maps(_detail!['lines']);
    return RefreshIndicator(
      onRefresh: () => _loadDetail(_selectedOrderId!),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _buildOrderHeader(order, lines, receivingMode: receivingMode),
          const SizedBox(height: 16),
          if (receivingMode)
            _buildReceivingLines(order, lines)
          else
            _buildPurchaseLines(lines),
          const SizedBox(height: 16),
          if (receivingMode)
            _buildReceiptPanel(order)
          else ...[
            _buildApprovalTimeline(),
            const SizedBox(height: 16),
            _buildDocumentPanel(order, lines),
          ],
          if (receivingMode) ...[
            const SizedBox(height: 16),
            _buildDocumentPanel(order, lines),
          ],
        ],
      ),
    );
  }

  Widget _buildOrderHeader(
    Map<String, dynamic> order,
    List<Map<String, dynamic>> lines, {
    required bool receivingMode,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 10,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _string(order['purchase_order_no'], fallback: '-'),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    Text(
                      '${_isAccounting ? '${_storeName(order)} · ' : ''}${_supplierName(order)} · ${lines.length}${_text(ko: '개 품목', en: ' items', vi: ' mặt hàng')}',
                    ),
                  ],
                ),
                _StatusChip(status: _string(order['status'])),
              ],
            ),
            const Divider(height: 26),
            Wrap(
              spacing: 24,
              runSpacing: 10,
              children: [
                _Metric(
                  label: _text(ko: '납품 요청일', en: 'Delivery', vi: 'Ngày giao'),
                  value: _date(order['requested_delivery_date']),
                ),
                _Metric(
                  label: _text(ko: '공급가', en: 'Subtotal', vi: 'Tiền hàng'),
                  value: _money(order['total_supply_amount']),
                ),
                _Metric(
                  label: _text(ko: '최종 금액', en: 'Total', vi: 'Tổng'),
                  value: _money(order['total_amount']),
                ),
              ],
            ),
            if (!receivingMode) ...[
              const SizedBox(height: 16),
              _buildOrderActions(order, lines),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildOrderActions(
    Map<String, dynamic> order,
    List<Map<String, dynamic>> lines,
  ) {
    final status = _string(order['status']);
    final version = _integer(order['row_version'], fallback: 1);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (status == 'draft' &&
            PermissionUtils.canCreateInventoryPurchaseOrder(_role)) ...[
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _editDraft(order, lines),
            icon: const Icon(Icons.edit_outlined),
            label: Text(_text(ko: '수정', en: 'Edit', vi: 'Sửa')),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _deleteDraft(order, version),
            icon: const Icon(Icons.delete_outline),
            label: Text(_text(ko: '삭제', en: 'Delete', vi: 'Xóa')),
          ),
          FilledButton.icon(
            onPressed: _busy ? null : () => _submitDraft(order, version),
            icon: const Icon(Icons.send_outlined),
            label: Text(_text(ko: '승인 요청', en: 'Submit', vi: 'Gửi duyệt')),
          ),
        ],
        if (status == 'submitted' &&
            const {'admin', 'store_admin', 'super_admin'}.contains(_role)) ...[
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _storeDecision(order, version, approve: false),
            child: Text(_text(ko: '반려', en: 'Return', vi: 'Trả lại')),
          ),
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () => _storeDecision(order, version, approve: true),
            icon: const Icon(Icons.check),
            label: Text(
              _text(ko: '스토어 승인', en: 'Store approve', vi: 'Cửa hàng duyệt'),
            ),
          ),
        ],
        if (status == 'store_approved' &&
            const {'brand_admin', 'super_admin'}.contains(_role)) ...[
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _brandDecision(order, version, approve: false),
            child: Text(_text(ko: '반려', en: 'Return', vi: 'Trả lại')),
          ),
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () => _brandDecision(order, version, approve: true),
            icon: const Icon(Icons.verified_outlined),
            label: Text(
              _text(ko: '브랜드 승인', en: 'Brand approve', vi: 'Thương hiệu duyệt'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildPurchaseLines(List<Map<String, dynamic>> lines) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _text(ko: '발주 품목', en: 'Order lines', vi: 'Mặt hàng'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            for (final line in lines) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_productName(line)),
                subtitle: Text(
                  '${_quantity(_number(line['ordered_quantity_unit']))} ${_string(line['order_unit'])} × ${_money(line['unit_price'])}',
                ),
                trailing: Text(
                  _money(
                    _number(line['supply_amount']) +
                        _number(line['tax_amount']),
                  ),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (line != lines.last) const Divider(height: 1),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildApprovalTimeline() {
    final events = _maps(_detail?['approval_events']);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _text(ko: '승인 이력', en: 'Approval history', vi: 'Lịch sử duyệt'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (events.isEmpty)
              Text(_text(ko: '이력이 없습니다.', en: 'No history.', vi: 'Chưa có.'))
            else
              for (final event in events.take(8))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.radio_button_checked, size: 16),
                  title: Text(_eventLabel(_string(event['action']))),
                  subtitle: Text(
                    [
                      _dateTime(event['created_at']),
                      _string(event['reason']),
                    ].where((value) => value.isNotEmpty).join(' · '),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildDocumentPanel(
    Map<String, dynamic> order,
    List<Map<String, dynamic>> lines,
  ) {
    final status = _string(order['status']);
    final documentStatus = _string(order['document_status'], fallback: 'none');
    final canGenerate = const {'brand_admin', 'super_admin'}.contains(_role);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _text(
                ko: '승인 발주서 PDF',
                en: 'Approved order PDF',
                vi: 'PDF đơn đã duyệt',
              ),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(label: Text('PDF: $documentStatus')),
                if (const {
                      'ordered',
                      'partially_received',
                      'received',
                    }.contains(status) &&
                    documentStatus != 'ready' &&
                    canGenerate)
                  FilledButton.tonalIcon(
                    onPressed: _busy
                        ? null
                        : () => _publishDocument(order, lines),
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    label: Text(
                      _text(
                        ko: 'PDF 다시 생성',
                        en: 'Retry PDF',
                        vi: 'Tạo lại PDF',
                      ),
                    ),
                  ),
                if (documentStatus == 'ready')
                  OutlinedButton.icon(
                    onPressed: () =>
                        inventoryPurchaseDocumentService.layoutPurchaseOrderPdf(
                          order: order,
                          lines: lines,
                          l10n: context.l10n,
                        ),
                    icon: const Icon(Icons.download_outlined),
                    label: Text(
                      _text(
                        ko: 'PDF 열기/다운로드',
                        en: 'Open/download PDF',
                        vi: 'Mở/tải PDF',
                      ),
                    ),
                  ),
              ],
            ),
            if (_string(order['document_last_error']).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _string(order['document_last_error']),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              _text(
                ko: '브랜드 승인과 동시에 발주가 완료되며 승인 PDF가 생성됩니다.',
                en: 'Brand approval completes the order and generates the approved PDF.',
                vi: 'Duyệt thương hiệu hoàn tất đơn và tạo PDF đã duyệt.',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReceivingLines(
    Map<String, dynamic> order,
    List<Map<String, dynamic>> lines,
  ) {
    final receivable = const {
      'ordered',
      'partially_received',
      'office_approved',
    }.contains(_string(order['status']));
    final draft = _draftReceipt(_detail);
    final canCapture =
        receivable && PermissionUtils.canCreateInventoryPurchaseOrder(_role);
    final canFinalize = receivable && _isAccounting && draft != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _text(
                ko: _isAccounting ? '최종 승인 수량과 단가' : '실제 납품 수량과 단가',
                en: _isAccounting
                    ? 'Final approved quantity & price'
                    : 'Actual delivered quantity & price',
                vi: _isAccounting
                    ? 'Số lượng & giá duyệt cuối'
                    : 'Số lượng & giá thực nhận',
              ),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 5),
            Text(
              _text(
                ko: _isAccounting
                    ? '주방의 실수령 내역과 거래명세서를 비교해 최종값을 조정하세요. 아래 확정 전에는 재고가 증가하지 않습니다.'
                    : '수량을 입력하면 입고 초안이 자동 저장됩니다. 이 단계에서는 재고가 증가하지 않습니다.',
                en: _isAccounting
                    ? 'Compare the kitchen receipt with the supplier statement and adjust final values. Stock does not increase before confirmation.'
                    : 'Entering a quantity auto-saves a receipt draft. Stock does not increase yet.',
                vi: _isAccounting
                    ? 'Đối chiếu hàng bếp nhận với phiếu giao và chỉnh giá trị cuối. Tồn kho chưa tăng trước khi xác nhận.'
                    : 'Nhập số lượng sẽ tự lưu phiếu nháp. Tồn kho chưa tăng.',
              ),
            ),
            const SizedBox(height: 14),
            for (final line in lines) ...[
              _buildReceivingLine(
                order,
                line,
                enabled: canCapture || canFinalize,
                finalReview: canFinalize,
              ),
              if (line != lines.last) const Divider(height: 20),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildReceivingLine(
    Map<String, dynamic> order,
    Map<String, dynamic> line, {
    required bool enabled,
    required bool finalReview,
  }) {
    final lineId = _id(line);
    final quantityController = _receiptControllers.putIfAbsent(
      lineId,
      TextEditingController.new,
    );
    final priceController = _receiptPriceControllers.putIfAbsent(
      lineId,
      () => TextEditingController(text: _quantity(_number(line['unit_price']))),
    );
    final saving = _receiptSaving.contains(lineId);
    final error = _receiptErrors[lineId];
    final saved = _receiptSavedAt[lineId];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _productName(line),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        Text(
          '${_text(ko: '발주', en: 'Ordered', vi: 'Đã đặt')}: '
          '${_quantity(_number(line['ordered_quantity_unit']))} '
          '${_string(line['order_unit'])}',
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 180,
              child: TextField(
                controller: quantityController,
                enabled: enabled && !_busy,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: _text(
                    ko: finalReview ? '최종 승인 수량' : '실제 수량',
                    en: finalReview ? 'Final approved qty' : 'Actual qty',
                    vi: finalReview ? 'SL duyệt cuối' : 'SL thực',
                  ),
                  suffixText: _string(line['order_unit']),
                  border: const OutlineInputBorder(),
                ),
                onChanged: finalReview
                    ? null
                    : (_) => _queueReceiptAutosave(order, line),
                onSubmitted: finalReview
                    ? null
                    : (_) => _saveReceiptLine(order, line),
              ),
            ),
            SizedBox(
              width: 200,
              child: TextField(
                controller: priceController,
                enabled: enabled && !_busy,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: _text(
                    ko: finalReview ? '최종 승인 단가' : '실제 단가',
                    en: finalReview ? 'Final approved price' : 'Actual price',
                    vi: finalReview ? 'Giá duyệt cuối' : 'Giá thực',
                  ),
                  suffixText: 'VND',
                  border: const OutlineInputBorder(),
                ),
                onChanged: finalReview
                    ? null
                    : (_) => _queueReceiptAutosave(order, line),
                onSubmitted: finalReview
                    ? null
                    : (_) => _saveReceiptLine(order, line),
              ),
            ),
            if (saving)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (error != null)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              )
            else if (saved != null)
              Text(
                '${_text(ko: '저장됨', en: 'Saved', vi: 'Đã lưu')} ${DateFormat('HH:mm:ss').format(saved)}',
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildReceiptPanel(Map<String, dynamic> order) {
    final draft = _draftReceipt(_detail);
    final receipts = _maps(_detail?['receipts']);
    final canVerify = PermissionUtils.canVerifyInventoryReceipt(
      _role,
      ref.read(authProvider).extraPermissions,
    );
    final canEditStatement =
        PermissionUtils.canCreateInventoryPurchaseOrder(_role) || canVerify;
    final isIndependentVerifier =
        draft != null &&
        _string(draft['received_by']) != ref.read(authProvider).user?.id;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _text(
                ko: '입고 검증',
                en: 'Receipt verification',
                vi: 'Xác minh nhập kho',
              ),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (draft == null)
              Text(
                _text(
                  ko: '실제 수량을 하나 이상 입력하면 입고 초안이 자동 생성됩니다.',
                  en: 'Enter an actual quantity to create the receipt draft automatically.',
                  vi: 'Nhập số lượng thực để tự tạo phiếu nháp.',
                ),
              )
            else ...[
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Chip(
                    avatar: const Icon(Icons.edit_note, size: 18),
                    label: Text(
                      '${_text(ko: '입고 초안', en: 'Receipt draft', vi: 'Phiếu nháp')} #${_integer(draft['delivery_cycle'], fallback: 1)}',
                    ),
                  ),
                  if (canEditStatement)
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _editStatement(draft),
                      icon: const Icon(Icons.description_outlined),
                      label: Text(
                        _string(draft['statement_number']).isEmpty
                            ? _text(
                                ko: '거래명세서 입력',
                                en: 'Enter statement',
                                vi: 'Nhập phiếu giao',
                              )
                            : _string(draft['statement_number']),
                      ),
                    ),
                  if (canVerify && isIndependentVerifier)
                    FilledButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _verifyReceipt(
                              order,
                              draft,
                              _maps(_detail?['lines']),
                            ),
                      icon: const Icon(Icons.verified_user_outlined),
                      label: Text(
                        _text(
                          ko: '최종 검증·입고 확정',
                          en: 'Verify & confirm',
                          vi: 'Xác minh & xác nhận',
                        ),
                      ),
                    ),
                ],
              ),
              if (canVerify && !isIndependentVerifier)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _text(
                      ko: '실수령 입력자와 다른 회계 담당 계정이 최종 확정해야 재고가 증가합니다.',
                      en: 'A separate accounting account must confirm before stock increases.',
                      vi: 'Tài khoản kế toán khác người nhập phải xác nhận trước khi tăng tồn kho.',
                    ),
                  ),
                ),
            ],
            if (receipts.any(
              (receipt) => receipt['status'] == 'confirmed',
            )) ...[
              const Divider(height: 24),
              for (final receipt in receipts.where(
                (receipt) => receipt['status'] == 'confirmed',
              ))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.check_circle_outline),
                  title: Text(
                    '${_string(receipt['statement_number'], fallback: '-')}'
                    ' · ${_money(receipt['total_amount'])}',
                  ),
                  subtitle: Text(
                    '${_dateTime(receipt['verified_at'])} · '
                    '${_text(ko: '재고 반영 완료', en: 'Stock posted', vi: 'Đã cộng kho')}',
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPriceWorkspace() {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final item in _supplierItems.where(
      (row) => row['is_active'] != false,
    )) {
      grouped.putIfAbsent(_supplierName(item), () => []).add(item);
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _text(
                        ko: '거래처 단가 관리',
                        en: 'Supplier price management',
                        vi: 'Quản lý giá nhà cung cấp',
                      ),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      _text(
                        ko: '개별 수정 또는 Excel 미리보기 후 일괄 반영할 수 있습니다.',
                        en: 'Edit individually or preview and apply an Excel batch.',
                        vi: 'Sửa từng dòng hoặc xem trước và áp dụng Excel.',
                      ),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _downloadPriceTemplate,
                icon: const Icon(Icons.download_outlined),
                label: Text(
                  _text(ko: 'Excel 양식', en: 'Excel template', vi: 'Mẫu Excel'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _busy ? null : _importPrices,
                icon: const Icon(Icons.upload_file_outlined),
                label: Text(
                  _text(ko: 'Excel 등록', en: 'Import Excel', vi: 'Nhập Excel'),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final entry in grouped.entries)
                      Card(
                        child: ExpansionTile(
                          initiallyExpanded: grouped.length <= 3,
                          title: Text(entry.key),
                          subtitle: Text('${entry.value.length} items'),
                          children: [
                            for (final item in entry.value)
                              ListTile(
                                title: Text(_productName(item)),
                                subtitle: Text(
                                  '${_string(item['order_unit'])} · VAT ${_quantity(_number(item['tax_rate']))}%',
                                ),
                                trailing: TextButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : () => _quickEditPrice(item),
                                  icon: const Icon(Icons.edit_outlined),
                                  label: Text(_money(item['unit_price'])),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  void _queueReceiptAutosave(
    Map<String, dynamic> order,
    Map<String, dynamic> line,
  ) {
    final lineId = _id(line);
    _receiptSaveTimers.remove(lineId)?.cancel();
    _receiptSaveTimers[lineId] = Timer(
      const Duration(milliseconds: 700),
      () => _saveReceiptLine(order, line),
    );
  }

  Future<void> _saveReceiptLine(
    Map<String, dynamic> order,
    Map<String, dynamic> line,
  ) async {
    final lineId = _id(line);
    _receiptSaveTimers.remove(lineId)?.cancel();
    if (_receiptSaving.contains(lineId)) return;
    final orderUnits = _parseNumber(_receiptControllers[lineId]?.text);
    final price = _parseNumber(_receiptPriceControllers[lineId]?.text);
    final differsFromOrder =
        (orderUnits - _number(line['ordered_quantity_unit'])).abs() > 0.0001 ||
        (price - _number(line['unit_price'])).abs() > 0.01;
    setState(() {
      _receiptSaving.add(lineId);
      _receiptErrors.remove(lineId);
    });
    try {
      await inventoryService.upsertInventoryReceiptDraftLine(
        purchaseOrderId: _id(order),
        purchaseOrderLineId: lineId,
        receivedQuantityBase: orderUnits * _conversion(line),
        actualUnitPrice: price,
        discrepancyReason: differsFromOrder
            ? 'supplier_statement_difference'
            : null,
      );
      if (!mounted) return;
      setState(() => _receiptSavedAt[lineId] = DateTime.now());
      await _loadDetail(_id(order));
    } catch (error) {
      if (!mounted) return;
      setState(() => _receiptErrors[lineId] = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _receiptSaving.remove(lineId));
    }
  }

  Future<void> _createDraft() async {
    final input = await showDialog<_DraftOrderInput>(
      context: context,
      builder: (_) => _DraftOrderDialog(
        key: const Key('inventory_order_create_draft_dialog'),
        suppliers: _suppliers,
        supplierItems: _supplierItems,
      ),
    );
    if (input == null || _storeId == null) return;
    await _runBusy(() async {
      final order = await inventoryService.createManualInventoryPurchaseOrder(
        storeId: _storeId!,
        supplierId: input.supplierId,
        requestedDeliveryDate: input.deliveryDate,
        memo: input.memo,
        lines: input.lines,
      );
      _selectedOrderId = _id(order);
      await _load();
    });
  }

  Future<void> _editDraft(
    Map<String, dynamic> order,
    List<Map<String, dynamic>> lines,
  ) async {
    final input = await showDialog<_DraftOrderInput>(
      context: context,
      builder: (_) => _DraftOrderDialog(
        key: const Key('inventory_order_edit_draft_dialog'),
        suppliers: _suppliers,
        supplierItems: _supplierItems,
        initialOrder: order,
        initialLines: lines,
      ),
    );
    if (input == null) return;
    await _runBusy(() async {
      await inventoryService.saveInventoryPurchaseOrderDraft(
        purchaseOrderId: _id(order),
        expectedVersion: _integer(order['row_version'], fallback: 1),
        requestedDeliveryDate: input.deliveryDate,
        memo: input.memo,
        lines: input.lines,
      );
      await _load();
    });
  }

  Future<void> _deleteDraft(Map<String, dynamic> order, int version) async {
    final confirmed = await _confirm(
      title: _text(ko: '발주 초안 삭제', en: 'Delete draft', vi: 'Xóa bản nháp'),
      message: _text(
        ko: '확정 전 초안을 삭제하시겠습니까?',
        en: 'Delete this draft before submission?',
        vi: 'Xóa bản nháp trước khi gửi?',
      ),
    );
    if (!confirmed) return;
    await _runBusy(() async {
      await inventoryService.deleteInventoryPurchaseOrderDraft(
        purchaseOrderId: _id(order),
        expectedVersion: version,
      );
      _selectedOrderId = null;
      _detail = null;
      await _load(preserveSelection: false);
    });
  }

  Future<void> _submitDraft(Map<String, dynamic> order, int version) async {
    final confirmed = await _confirm(
      title: _text(ko: '승인 요청', en: 'Submit for approval', vi: 'Gửi duyệt'),
      message: _text(
        ko: '제출 후에는 발주 담당자가 수정하거나 삭제할 수 없습니다.',
        en: 'The orderer cannot edit or delete after submission.',
        vi: 'Sau khi gửi, người đặt không thể sửa hoặc xóa.',
      ),
    );
    if (!confirmed) return;
    await _runBusy(() async {
      await inventoryService.submitInventoryPurchaseOrder(
        purchaseOrderId: _id(order),
        expectedVersion: version,
      );
      await _load();
    });
  }

  Future<void> _storeDecision(
    Map<String, dynamic> order,
    int version, {
    required bool approve,
  }) async {
    final reason = approve ? null : await _askReason();
    if (!approve && reason == null) return;
    await _runBusy(() async {
      await inventoryService.storeDecideInventoryPurchaseOrder(
        purchaseOrderId: _id(order),
        expectedVersion: version,
        approve: approve,
        reason: reason,
      );
      await _load();
    });
  }

  Future<void> _brandDecision(
    Map<String, dynamic> order,
    int version, {
    required bool approve,
  }) async {
    final reason = approve ? null : await _askReason();
    if (!approve && reason == null) return;
    await _runBusy(() async {
      await inventoryService.brandDecideInventoryPurchaseOrder(
        purchaseOrderId: _id(order),
        expectedVersion: version,
        approve: approve,
        reason: reason,
      );
      await _load();
      if (approve && _detail != null) {
        await _publishDocument(
          _map(_detail!['order']),
          _maps(_detail!['lines']),
          nested: true,
        );
      }
    });
  }

  Future<void> _publishDocument(
    Map<String, dynamic> order,
    List<Map<String, dynamic>> lines, {
    bool nested = false,
  }) async {
    Future<void> publish() async {
      await inventoryPurchaseDocumentService.publishApprovedPurchaseOrder(
        order: order,
        lines: lines,
        l10n: context.l10n,
      );
      await _load();
    }

    if (nested) {
      await publish();
    } else {
      await _runBusy(publish);
    }
  }

  Future<void> _editStatement(Map<String, dynamic> draft) async {
    final input = await showDialog<_StatementInput>(
      context: context,
      builder: (_) => _StatementDialog(
        key: const Key('inventory_receipt_statement_dialog'),
        initial: draft,
      ),
    );
    if (input == null) return;
    await _runBusy(() async {
      var statementStoragePath = _nullable(draft['statement_storage_path']);
      if (input.attachment != null && _storeId != null) {
        statementStoragePath = await inventoryService
            .uploadInventoryReceiptStatement(
              storeId: _storeId!,
              receiptId: _id(draft),
              fileName: input.attachment!.name,
              bytes: await input.attachment!.readAsBytes(),
              contentType: _statementContentType(input.attachment!.name),
            );
      }
      await inventoryService.updateInventoryReceiptDraftMetadata(
        receiptId: _id(draft),
        expectedVersion: _integer(draft['row_version'], fallback: 1),
        statementNumber: input.number,
        statementDate: input.date,
        statementStoragePath: statementStoragePath,
        memo: input.memo,
      );
      await _loadDetail(_selectedOrderId!);
    });
  }

  Future<void> _verifyReceipt(
    Map<String, dynamic> order,
    Map<String, dynamic> draft,
    List<Map<String, dynamic>> orderLines,
  ) async {
    if (_string(draft['statement_number']).isEmpty ||
        _string(draft['statement_date']).isEmpty) {
      await _editStatement(draft);
      final refreshed = _draftReceipt(_detail);
      if (refreshed == null || _string(refreshed['statement_number']).isEmpty) {
        return;
      }
      draft = refreshed;
    }
    final confirmed = await _confirm(
      title: _text(
        ko: '최종 입고 확정',
        en: 'Confirm receipt',
        vi: 'Xác nhận nhập kho',
      ),
      message: _text(
        ko: '거래명세서의 최종 수량과 금액을 확인했습니다. 확정 즉시 재고가 증가합니다.',
        en: 'I verified final quantities and amounts. Stock increases immediately on confirmation.',
        vi: 'Đã kiểm tra số lượng và tiền. Tồn kho tăng ngay khi xác nhận.',
      ),
    );
    if (!confirmed) return;
    final draftLines = <String, Map<String, dynamic>>{
      for (final row in _maps(draft['line_details']))
        _string(row['purchase_order_line_id']): row,
    };
    final finalLines = <Map<String, dynamic>>[];
    for (final line in orderLines) {
      final lineId = _id(line);
      final draftLine = draftLines[lineId];
      if (lineId.isEmpty || draftLine == null) continue;
      final conversion = _conversion(line);
      final accepted =
          _parseNumber(_receiptControllers[lineId]?.text) * conversion;
      final received = _number(draftLine['received_quantity_base']);
      final currentAccepted = _number(draftLine['accepted_quantity_base']);
      final price = _parseNumber(_receiptPriceControllers[lineId]?.text);
      final currentPrice = _number(
        draftLine['actual_unit_price'] ?? line['unit_price'],
      );
      final changed =
          (accepted - currentAccepted).abs() > 0.0001 ||
          (price - currentPrice).abs() > 0.01 ||
          (price - _number(line['unit_price'])).abs() > 0.01;
      finalLines.add({
        'purchase_order_line_id': lineId,
        'accepted_quantity_base': accepted,
        'rejected_quantity_base': received > accepted ? received - accepted : 0,
        'actual_unit_price': price,
        'discrepancy_reason': changed
            ? 'supplier_statement_double_checked'
            : _nullable(draftLine['discrepancy_reason']),
      });
    }
    await _runBusy(() async {
      await inventoryService.verifyInventoryReceipt(
        receiptId: _id(draft),
        expectedVersion: _integer(draft['row_version'], fallback: 1),
        idempotencyKey: const Uuid().v4(),
        lines: finalLines,
        verificationReason: 'supplier_statement_double_checked',
      );
      await _load();
    });
  }

  Future<void> _quickEditPrice(Map<String, dynamic> item) async {
    final price = await _askText(
      title: _productName(item),
      label: _text(
        ko: '새 단가 (VND)',
        en: 'New price (VND)',
        vi: 'Giá mới (VND)',
      ),
      initialValue: _quantity(_number(item['unit_price'])),
      numeric: true,
    );
    final parsed = double.tryParse(price?.replaceAll(',', '') ?? '');
    if (parsed == null || parsed < 0 || _storeId == null) return;
    await _runBusy(() async {
      await inventoryService.upsertInventorySupplierItem(
        storeId: _storeId!,
        supplierItemId: _id(item),
        supplierId: _string(item['supplier_id']),
        productId: _string(item['product_id']),
        supplierSku: _nullable(item['supplier_sku']),
        orderUnit: _string(item['order_unit']),
        orderUnitQuantityBase: _number(item['order_unit_quantity_base']),
        minOrderQuantity: _number(item['min_order_quantity']),
        unitPrice: parsed,
        taxRate: _number(item['tax_rate']),
        leadTimeDays: _integer(item['lead_time_days']),
        isPreferred: item['is_preferred'] == true,
      );
      await _load();
    });
  }

  Future<void> _downloadPriceTemplate() async {
    await _runBusy(() async {
      final bytes = Uint8List.fromList(
        buildSupplierPriceImportTemplate(_supplierItems),
      );
      await FileSaver.instance.saveFile(
        name: 'supplier_price_${DateFormat('yyyyMMdd').format(DateTime.now())}',
        bytes: bytes,
        ext: 'xlsx',
        mimeType: MimeType.microsoftExcel,
      );
    });
  }

  Future<void> _importPrices() async {
    const group = XTypeGroup(label: 'Excel', extensions: ['xlsx']);
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file == null || _storeId == null) return;
    await _runBusy(() async {
      final parsed = parseSupplierPriceImportWorkbook(await file.readAsBytes());
      final preview = await inventoryService.bulkUpdateInventorySupplierPrices(
        storeId: _storeId!,
        rows: parsed.rows,
        apply: false,
      );
      if (!mounted) return;
      final canApply = preview['can_apply'] == true;
      final confirmed = await _confirm(
        title: _text(
          ko: '단가 변경 미리보기',
          en: 'Price import preview',
          vi: 'Xem trước giá',
        ),
        message:
            '${_text(ko: '변경', en: 'Changed', vi: 'Thay đổi')} '
            '${_integer(preview['changed_count'])} · '
            '${_text(ko: '동일', en: 'Unchanged', vi: 'Không đổi')} '
            '${_integer(preview['unchanged_count'])} · '
            '${_text(ko: '오류', en: 'Errors', vi: 'Lỗi')} '
            '${_integer(preview['error_count'])}',
        confirmEnabled: canApply,
      );
      if (!confirmed) return;
      await inventoryService.bulkUpdateInventorySupplierPrices(
        storeId: _storeId!,
        rows: parsed.rows,
        apply: true,
      );
      await _load();
    });
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    bool confirmEnabled = true,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            key: const Key('inventory_order_confirmation_dialog'),
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(_text(ko: '취소', en: 'Cancel', vi: 'Hủy')),
              ),
              FilledButton(
                onPressed: confirmEnabled
                    ? () => Navigator.pop(dialogContext, true)
                    : null,
                child: Text(_text(ko: '확인', en: 'Confirm', vi: 'Xác nhận')),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<String?> _askReason() => _askText(
    title: _text(ko: '반려 사유', en: 'Return reason', vi: 'Lý do trả lại'),
    label: _text(ko: '사유', en: 'Reason', vi: 'Lý do'),
  );

  Future<String?> _askText({
    required String title,
    required String label,
    String initialValue = '',
    bool numeric = false,
  }) async {
    final controller = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('inventory_order_text_input_dialog'),
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(decimal: true)
              : TextInputType.text,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(_text(ko: '취소', en: 'Cancel', vi: 'Hủy')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(_text(ko: '확인', en: 'Confirm', vi: 'Xác nhận')),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  String _friendlyError(Object error) {
    final raw = error.toString();
    final code = RegExp(r'INVENTORY_[A-Z0-9_]+').firstMatch(raw)?.group(0);
    return switch (code) {
      'INVENTORY_PURCHASE_SELF_APPROVAL_FORBIDDEN' => _text(
        ko: '본인이 작성하거나 앞 단계에서 승인한 발주는 승인할 수 없습니다.',
        en: 'You cannot approve an order you created or approved earlier.',
        vi: 'Không thể duyệt đơn do chính bạn tạo hoặc đã duyệt trước đó.',
      ),
      'INVENTORY_RECEIPT_MAKER_CHECKER_REQUIRED' => _text(
        ko: '입고 입력자와 다른 매니저가 최종 검증해야 합니다.',
        en: 'A different manager must verify this receipt.',
        vi: 'Quản lý khác phải xác minh phiếu nhập.',
      ),
      'INVENTORY_PURCHASE_STALE_VERSION' ||
      'INVENTORY_RECEIPT_STALE_VERSION' => _text(
        ko: '다른 사용자가 먼저 수정했습니다. 새로고침 후 다시 시도하세요.',
        en: 'Another user changed this record. Refresh and retry.',
        vi: 'Dữ liệu đã được người khác sửa. Làm mới và thử lại.',
      ),
      _ => code ?? raw,
    };
  }
}

class _DraftOrderInput {
  const _DraftOrderInput({
    required this.supplierId,
    required this.deliveryDate,
    required this.lines,
    this.memo,
  });

  final String supplierId;
  final DateTime deliveryDate;
  final List<Map<String, dynamic>> lines;
  final String? memo;
}

class _DraftOrderDialog extends StatefulWidget {
  const _DraftOrderDialog({
    super.key,
    required this.suppliers,
    required this.supplierItems,
    this.initialOrder,
    this.initialLines = const [],
  });

  final List<Map<String, dynamic>> suppliers;
  final List<Map<String, dynamic>> supplierItems;
  final Map<String, dynamic>? initialOrder;
  final List<Map<String, dynamic>> initialLines;

  @override
  State<_DraftOrderDialog> createState() => _DraftOrderDialogState();
}

class _DraftOrderDialogState extends State<_DraftOrderDialog> {
  late String? _supplierId;
  late DateTime _deliveryDate;
  late final TextEditingController _memoController;
  late List<_DraftLine> _lines;
  String? _newSupplierItemId;

  @override
  void initState() {
    super.initState();
    _supplierId = _string(widget.initialOrder?['supplier_id']);
    if (_supplierId!.isEmpty) _supplierId = null;
    _deliveryDate =
        DateTime.tryParse(
          _string(widget.initialOrder?['requested_delivery_date']),
        ) ??
        DateTime.now().add(const Duration(days: 1));
    _memoController = TextEditingController(
      text: _string(widget.initialOrder?['memo']),
    );
    _lines = widget.initialLines
        .map(
          (line) => _DraftLine(
            lineId: _id(line),
            supplierItemId: _string(line['supplier_item_id']),
            quantity: _number(line['ordered_quantity_unit']),
            unitPrice: _number(line['unit_price']),
            memo: _string(line['memo']),
          ),
        )
        .toList();
  }

  @override
  void dispose() {
    _memoController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _availableItems => widget.supplierItems
      .where(
        (item) =>
            _string(item['supplier_id']) == _supplierId &&
            item['is_active'] != false,
      )
      .toList();

  @override
  Widget build(BuildContext context) {
    final editing = widget.initialOrder != null;
    return AlertDialog(
      key: widget.key,
      title: Text(editing ? '발주 초안 수정' : '새 발주 초안'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _supplierId,
                decoration: const InputDecoration(
                  labelText: '거래처',
                  border: OutlineInputBorder(),
                ),
                items: widget.suppliers
                    .where(
                      (row) =>
                          row['status'] == null || row['status'] == 'active',
                    )
                    .map(
                      (row) => DropdownMenuItem(
                        value: _id(row),
                        child: Text(_string(row['supplier_name'])),
                      ),
                    )
                    .toList(),
                onChanged: editing
                    ? null
                    : (value) => setState(() {
                        _supplierId = value;
                        _lines = [];
                        _newSupplierItemId = null;
                      }),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('납품 요청일'),
                subtitle: Text(DateFormat('yyyy-MM-dd').format(_deliveryDate)),
                trailing: IconButton(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _deliveryDate,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) setState(() => _deliveryDate = picked);
                  },
                  icon: const Icon(Icons.calendar_month_outlined),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(_newSupplierItemId),
                      initialValue: _newSupplierItemId,
                      decoration: const InputDecoration(
                        labelText: '원재료 추가',
                        border: OutlineInputBorder(),
                      ),
                      items: _availableItems
                          .where(
                            (item) => !_lines.any(
                              (line) => line.supplierItemId == _id(item),
                            ),
                          )
                          .map(
                            (item) => DropdownMenuItem(
                              value: _id(item),
                              child: Text(_productName(item)),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          setState(() => _newSupplierItemId = value),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: _newSupplierItemId == null
                        ? null
                        : () {
                            final item = _availableItems.firstWhere(
                              (row) => _id(row) == _newSupplierItemId,
                            );
                            setState(() {
                              _lines.add(
                                _DraftLine(
                                  supplierItemId: _id(item),
                                  quantity: _number(
                                    item['min_order_quantity'],
                                    fallback: 1,
                                  ),
                                  unitPrice: _number(item['unit_price']),
                                ),
                              );
                              _newSupplierItemId = null;
                            });
                          },
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (var index = 0; index < _lines.length; index++)
                _buildLine(index, _lines[index]),
              TextField(
                controller: _memoController,
                maxLines: 2,
                decoration: const InputDecoration(labelText: '메모'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _supplierId == null || _lines.isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  _DraftOrderInput(
                    supplierId: _supplierId!,
                    deliveryDate: _deliveryDate,
                    memo: _memoController.text.trim(),
                    lines: _lines.map((line) => line.toJson()).toList(),
                  ),
                ),
          child: const Text('저장'),
        ),
      ],
    );
  }

  Widget _buildLine(int index, _DraftLine line) {
    final item = _availableItems.firstWhere(
      (row) => _id(row) == line.supplierItemId,
      orElse: () => const {},
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Expanded(flex: 3, child: Text(_productName(item))),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
                key: ValueKey('draft_qty_${line.supplierItemId}'),
                initialValue: _quantity(line.quantity),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: '수량',
                  suffixText: _string(item['order_unit']),
                ),
                onChanged: (value) => line.quantity = _parseNumber(value),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
                key: ValueKey('draft_price_${line.supplierItemId}'),
                initialValue: _quantity(line.unitPrice),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: '단가',
                  suffixText: 'VND',
                ),
                onChanged: (value) => line.unitPrice = _parseNumber(value),
              ),
            ),
            IconButton(
              onPressed: () => setState(() => _lines.removeAt(index)),
              icon: const Icon(Icons.remove_circle_outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _DraftLine {
  _DraftLine({
    required this.supplierItemId,
    required this.quantity,
    required this.unitPrice,
    this.lineId = '',
    this.memo = '',
  });

  final String lineId;
  final String supplierItemId;
  double quantity;
  double unitPrice;
  final String memo;

  Map<String, dynamic> toJson() => {
    'line_id': lineId.isEmpty ? null : lineId,
    'supplier_item_id': supplierItemId,
    'ordered_quantity_unit': quantity,
    'unit_price': unitPrice,
    'memo': memo,
  };
}

class _StatementInput {
  const _StatementInput({
    required this.number,
    required this.date,
    required this.memo,
    this.attachment,
  });

  final String number;
  final DateTime date;
  final String memo;
  final XFile? attachment;
}

class _StatementDialog extends StatefulWidget {
  const _StatementDialog({super.key, required this.initial});

  final Map<String, dynamic> initial;

  @override
  State<_StatementDialog> createState() => _StatementDialogState();
}

class _StatementDialogState extends State<_StatementDialog> {
  late final TextEditingController _numberController;
  late final TextEditingController _memoController;
  late DateTime _date;
  XFile? _attachment;

  @override
  void initState() {
    super.initState();
    _numberController = TextEditingController(
      text: _string(widget.initial['statement_number']),
    );
    _memoController = TextEditingController(
      text: _string(widget.initial['memo']),
    );
    _date =
        DateTime.tryParse(_string(widget.initial['statement_date'])) ??
        DateTime.now();
  }

  @override
  void dispose() {
    _numberController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: widget.key,
      title: const Text('거래명세서 확인'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _numberController,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: '명세서 번호',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () async {
                  const group = XTypeGroup(
                    label: 'Statement',
                    extensions: ['pdf', 'png', 'jpg', 'jpeg'],
                  );
                  final selected = await openFile(
                    acceptedTypeGroups: const [group],
                  );
                  if (selected != null) {
                    setState(() => _attachment = selected);
                  }
                },
                icon: const Icon(Icons.attach_file),
                label: Text(_attachment?.name ?? '명세서 PDF/사진 첨부'),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('명세서 일자'),
              subtitle: Text(DateFormat('yyyy-MM-dd').format(_date)),
              trailing: IconButton(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime.now().subtract(
                      const Duration(days: 90),
                    ),
                    lastDate: DateTime.now().add(const Duration(days: 7)),
                  );
                  if (picked != null) setState(() => _date = picked);
                },
                icon: const Icon(Icons.calendar_month_outlined),
              ),
            ),
            TextField(
              controller: _memoController,
              maxLines: 2,
              decoration: const InputDecoration(labelText: '검수 메모'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _numberController.text.trim().isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  _StatementInput(
                    number: _numberController.text.trim(),
                    date: _date,
                    memo: _memoController.text.trim(),
                    attachment: _attachment,
                  ),
                ),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (status) {
      'draft' => scheme.outline,
      'submitted' => Colors.orange,
      'store_approved' => Colors.blue,
      'brand_approved' => Colors.indigo,
      'ordered' => Colors.teal,
      'partially_received' => Colors.deepOrange,
      'received' => Colors.green,
      'cancelled' || 'office_rejected' => scheme.error,
      _ => scheme.secondary,
    };
    return Chip(
      visualDensity: VisualDensity.compact,
      side: BorderSide(color: color.withValues(alpha: 0.5)),
      avatar: Icon(Icons.circle, size: 10, color: color),
      label: Text(
        _statusLabel(status, Localizations.localeOf(context).languageCode),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    );
  }
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.whereType<Map>().map(Map<String, dynamic>.from).toList()
    : <Map<String, dynamic>>[];

Map<String, dynamic>? _draftReceipt(Map<String, dynamic>? detail) {
  for (final receipt in _maps(detail?['receipts'])) {
    if (receipt['status'] == 'draft') return receipt;
  }
  return null;
}

String _id(Map<String, dynamic> row) => _string(row['id']);

String _string(Object? value, {String fallback = ''}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

String? _nullable(Object? value) {
  final text = _string(value);
  return text.isEmpty ? null : text;
}

double _number(Object? value, {double fallback = 0}) => switch (value) {
  num number => number.toDouble(),
  _ => double.tryParse(value?.toString() ?? '') ?? fallback,
};

double _parseNumber(String? value) =>
    double.tryParse((value ?? '').replaceAll(',', '').trim()) ?? 0;

int _integer(Object? value, {int fallback = 0}) => switch (value) {
  int number => number,
  num number => number.toInt(),
  _ => int.tryParse(value?.toString() ?? '') ?? fallback,
};

String _supplierName(Map<String, dynamic> row) {
  final supplier = row['supplier'];
  return supplier is Map
      ? _string(supplier['supplier_name'], fallback: '-')
      : '-';
}

String _storeName(Map<String, dynamic> row) {
  final store = row['store'];
  return store is Map ? _string(store['name'], fallback: '-') : '-';
}

String _productName(Map<String, dynamic> row) {
  final product = row['product'];
  return product is Map ? _string(product['name'], fallback: '-') : '-';
}

double _conversion(Map<String, dynamic> line) {
  final supplierItem = line['supplier_item'];
  if (supplierItem is Map) {
    final value = _number(supplierItem['order_unit_quantity_base']);
    if (value > 0) return value;
  }
  final orderedUnits = _number(line['ordered_quantity_unit']);
  final orderedBase = _number(line['ordered_quantity_base']);
  return orderedUnits > 0 && orderedBase > 0 ? orderedBase / orderedUnits : 1;
}

String _quantity(double value) => NumberFormat('#,##0.###').format(value);

String _money(Object? value) =>
    '${NumberFormat('#,##0', 'vi_VN').format(_number(value))} VND';

String _date(Object? value) {
  final raw = _string(value, fallback: '-');
  return raw.length >= 10 ? raw.substring(0, 10) : raw;
}

String _dateTime(Object? value) {
  final raw = _string(value);
  if (raw.isEmpty) return '';
  final parsed = DateTime.tryParse(raw)?.toLocal();
  return parsed == null ? raw : DateFormat('yyyy-MM-dd HH:mm').format(parsed);
}

String _statementContentType(String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.pdf')) return 'application/pdf';
  if (lower.endsWith('.png')) return 'image/png';
  return 'image/jpeg';
}

String _statusLabel(String status, String languageCode) {
  const labels = <String, List<String>>{
    'draft': ['초안', 'Draft', 'Nháp'],
    'submitted': ['스토어 승인 대기', 'Store review', 'Chờ cửa hàng'],
    'store_approved': ['브랜드 승인 대기', 'Brand review', 'Chờ thương hiệu'],
    'brand_approved': ['최종 승인·PDF 완료', 'Approved', 'Đã duyệt'],
    'ordered': ['발주 완료', 'Ordered', 'Đã đặt'],
    'partially_received': ['부분 입고', 'Partially received', 'Nhập một phần'],
    'received': ['입고 완료', 'Received', 'Đã nhập'],
    'cancelled': ['삭제/취소', 'Cancelled', 'Đã hủy'],
    'office_approved': ['기존 승인', 'Legacy approved', 'Đã duyệt cũ'],
    'office_returned': ['반려', 'Returned', 'Trả lại'],
    'office_rejected': ['거절', 'Rejected', 'Từ chối'],
  };
  final values = labels[status];
  if (values == null) return status;
  return switch (languageCode) {
    'en' => values[1],
    'vi' => values[2],
    _ => values[0],
  };
}

String _eventLabel(String action) => switch (action) {
  'draft_created' => '발주 초안 생성',
  'draft_updated' => '발주 초안 수정',
  'draft_deleted' => '발주 초안 삭제',
  'submitted' => '스토어 승인 요청',
  'store_approved' => '스토어 매니저 승인',
  'store_returned' => '스토어 매니저 반려',
  'brand_approved' => '브랜드 매니저 승인',
  'brand_returned' => '브랜드 매니저 반려',
  'document_ready' => '승인 PDF 생성 완료',
  'document_failed' => '승인 PDF 생성 실패',
  _ => action,
};
