import 'dart:async';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/services/inventory_service.dart';
import '../../core/services/live_refresh_service.dart';
import 'inventory_workflow_state.dart';
import '../../core/utils/permission_utils.dart';
import '../auth/auth_provider.dart';
import 'inventory_purchase_document_service.dart';
import 'supplier_price_excel_import.dart';

enum _WorkflowSection { orders, receiving, prices }

class InventoryOrderWorkflowScreen extends ConsumerStatefulWidget {
  const InventoryOrderWorkflowScreen({
    super.key,
    this.initialOrderId,
    this.service,
  });

  final InventoryService? service;

  final String? initialOrderId;

  @override
  ConsumerState<InventoryOrderWorkflowScreen> createState() =>
      _InventoryOrderWorkflowScreenState();
}

class _InventoryOrderWorkflowScreenState
    extends ConsumerState<InventoryOrderWorkflowScreen>
    with WidgetsBindingObserver {
  InventoryService get _service => widget.service ?? inventoryService;
  final _receiptControllers = <String, TextEditingController>{};
  final _receiptPriceControllers = <String, TextEditingController>{};
  bool _receiptDirty = false;
  String? _formOrderId;
  String? _receiptId;
  _StatementInput? _statementInput;
  String? _uploadedStatementPath;
  Map<String, dynamic>? _pendingReceiptSubmission;
  String? _verificationKey;
  InventoryOrderGroup _orderGroup = InventoryOrderGroup.pending;
  bool _mineOnly = false;
  int _totalOrders = 0;
  Map<String, dynamic> _statusCounts = {};
  List<Map<String, dynamic>> _accessibleStores = [];
  bool _refreshing = false;
  bool _refreshAgain = false;
  String? _loadedScope;
  DateTime? _lastSyncedAt;
  Timer? _syncWatchdog;
  int _detailEpoch = 0;
  final _receiptErrors = <String, String>{};

  _WorkflowSection _section = _WorkflowSection.orders;
  List<Map<String, dynamic>> _orders = const [];
  List<Map<String, dynamic>> _suppliers = const [];
  List<Map<String, dynamic>> _supplierItems = const [];
  Map<String, dynamic>? _detail;
  String? _selectedOrderId;
  String? _selectedAccountingStoreId;
  bool _loading = true;
  bool _detailLoading = false;
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncWatchdog = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshInPlace(),
    );
    _selectedOrderId = widget.initialOrderId;
    if (_role == 'inventory_accounting') {
      _section = _WorkflowSection.receiving;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncWatchdog?.cancel();
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

  bool get _canManagePrices =>
      PermissionUtils.canManageInventorySupplierPrices(_role);
  String get _scopeKey => '${ref.read(authProvider).user?.id}:$_role:$_storeId';
  String get _queryKey =>
      '$_scopeKey:$_section:$_orderGroup:$_mineOnly:$_selectedAccountingStoreId';

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshInPlace();
  }

  void _refreshInPlace() {
    if (!mounted) return;
    if (_busy) {
      _refreshAgain = true;
      return;
    }
    unawaited(_load(background: true));
  }

  Future<void> _load({
    bool preserveSelection = true,
    bool background = false,
    bool append = false,
  }) async {
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    final storeId = _storeId;
    final scope = _scopeKey;
    final query = _queryKey;
    if (storeId == null && !_isAccounting) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = StateError('STORE_SCOPE_REQUIRED');
        });
      }
      return;
    }
    _refreshing = true;
    if (!background && !append && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final receiving = _isAccounting || _section == _WorkflowSection.receiving;
      final targetCount = append
          ? 80
          : (_orders.length > 80 ? _orders.length : 80);
      Map<String, dynamic> page = {};
      final rows = <Map<String, dynamic>>[];
      do {
        final next = await _service.fetchInventoryWorkflowPage(
          storeId: _isAccounting ? _selectedAccountingStoreId : storeId,
          statuses: receiving
              ? InventoryOrderGroup.placed.statuses
              : _orderGroup.statuses,
          mineOnly: !receiving && _mineOnly,
          offset: (append ? _orders.length : 0) + rows.length,
          limit: (targetCount - rows.length).clamp(1, 240),
        );
        if (!mounted || scope != _scopeKey || query != _queryKey) return;
        if (page.isEmpty) page = next;
        final nextRows = _maps(next['orders']);
        rows.addAll(nextRows);
        if (nextRows.isEmpty ||
            (append ? _orders.length : 0) + rows.length >=
                _integer(next['total'])) {
          break;
        }
      } while (rows.length < targetCount);
      Map<String, dynamic>? catalog;
      if (!_isAccounting && (!background || _loadedScope != scope)) {
        catalog = await _service.fetchInventoryOrderCatalog(storeId!);
      }
      if (!mounted || scope != _scopeKey || query != _queryKey) return;
      final orders = append
          ? [
              ..._orders,
              ...rows.where((r) => !_orders.any((o) => _id(o) == _id(r))),
            ]
          : rows;
      final keep =
          preserveSelection &&
          _selectedOrderId != null &&
          (_receiptDirty ||
              _detail == null ||
              orders.any((o) => _id(o) == _selectedOrderId));
      final selected = keep
          ? _selectedOrderId
          : (orders.isEmpty ? null : _id(orders.first));
      setState(() {
        _orders = orders;
        _totalOrders = _integer(page['total']);
        _statusCounts = _map(page['counts']);
        _accessibleStores = _maps(page['stores']);
        if (catalog != null) {
          _suppliers = _maps(catalog['suppliers']);
          _supplierItems = _maps(catalog['items']);
        }
        _selectedOrderId = selected;
        _loadedScope = scope;
        _loading = false;
        _error = null;
        _lastSyncedAt = DateTime.now();
        if (selected == null) _detail = null;
      });
      if (selected != null && !_receiptDirty && !append) {
        await _loadDetail(selected, background: background);
      }
    } catch (error) {
      if (mounted && scope == _scopeKey && query == _queryKey) {
        setState(() {
          _loading = false;
          _error = error;
        });
      }
    } finally {
      _refreshing = false;
      if (_refreshAgain && mounted) {
        _refreshAgain = false;
        _refreshInPlace();
      }
    }
  }

  Future<void> _loadDetail(String orderId, {bool background = false}) async {
    if (_receiptDirty && _formOrderId == orderId) return;
    final scope = _scopeKey;
    final epoch = ++_detailEpoch;
    setState(() {
      _selectedOrderId = orderId;
      _detailLoading = !background;
    });
    try {
      final detail = await _service.fetchInventoryWorkflowDetail(orderId);
      if (!mounted ||
          scope != _scopeKey ||
          epoch != _detailEpoch ||
          _selectedOrderId != orderId ||
          _receiptDirty) {
        return;
      }
      setState(() {
        _detail = detail;
        _detailLoading = false;
      });
      _syncReceiptControllers(detail);
    } catch (error) {
      if (mounted && scope == _scopeKey && epoch == _detailEpoch) {
        setState(() {
          _detailLoading = false;
          _error = error;
        });
      }
    }
  }

  void _clearReceiptForm() {
    for (final c in [
      ..._receiptControllers.values,
      ..._receiptPriceControllers.values,
    ]) {
      c.dispose();
    }
    _receiptControllers.clear();
    _receiptPriceControllers.clear();
    _receiptErrors.clear();
    _receiptDirty = false;
    _formOrderId = null;
    _receiptId = null;
    _statementInput = null;
    _uploadedStatementPath = null;
    _pendingReceiptSubmission = null;
    _verificationKey = null;
  }

  void _syncReceiptControllers(Map<String, dynamic>? detail) {
    if (_receiptDirty) return;
    _clearReceiptForm();
    _formOrderId = _id(_map(detail?['order']));
    final draft = _draftReceipt(detail);
    _receiptId = draft == null ? const Uuid().v4() : _id(draft);
    final drafts = {
      for (final row in _maps(draft?['line_details']))
        _string(row['purchase_order_line_id']): row,
    };
    for (final line in _maps(detail?['lines'])) {
      final id = _id(line);
      final row = drafts[id];
      final value =
          _number(
            row?[_isAccounting
                ? 'accepted_quantity_base'
                : 'received_quantity_base'],
          ) /
          _conversion(line);
      _receiptControllers[id] = TextEditingController(
        text: row == null ? '' : _quantity(value),
      );
      _receiptPriceControllers[id] = TextEditingController(
        text: _quantity(
          _number(row?['actual_unit_price'] ?? line['unit_price']),
        ),
      );
    }
  }

  void _markReceiptDirty(String lineId) {
    setState(() {
      _receiptDirty = true;
      _receiptErrors.remove(lineId);
      _pendingReceiptSubmission = null;
      _verificationKey = null;
    });
  }

  Future<bool> _leaveReceipt() async {
    if (!_receiptDirty) return true;
    final discard = await _confirm(
      title: _text(
        ko: '저장하지 않은 입고 내역',
        en: 'Unsaved receipt',
        vi: 'Phiếu nhập chưa lưu',
      ),
      message: _text(
        ko: '입력 내용을 버리고 이동할까요? 취소하면 입력을 계속할 수 있습니다.',
        en: 'Discard changes and leave? Cancel to continue editing.',
        vi: 'Bỏ thay đổi và chuyển? Hủy để tiếp tục nhập.',
      ),
    );
    if (discard && mounted) setState(_clearReceiptForm);
    return discard;
  }

  Future<void> _selectOrder(String orderId) async {
    if (orderId == _selectedOrderId ||
        _busy ||
        !await _leaveReceipt() ||
        !mounted) {
      return;
    }
    if (GoRouterState.of(context).uri.path != '/inventory-orders') {
      context.go('/inventory-orders');
    }
    await _loadDetail(orderId);
  }

  Future<void> _selectAccountingStore(String? storeId) async {
    if (!await _leaveReceipt() || !mounted) return;
    setState(() {
      _selectedAccountingStoreId = storeId;
      _selectedOrderId = null;
      _detail = null;
      _orders = [];
    });
    await _load(preserveSelection: false);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final scopeChanged = _loadedScope != null && _scopeKey != _loadedScope;
    if (scopeChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _scopeKey == _loadedScope) return;
        setState(() {
          _clearReceiptForm();
          _orders = [];
          _supplierItems = [];
          _suppliers = [];
          _detail = null;
          _selectedOrderId = null;
          _section = _isAccounting
              ? _WorkflowSection.receiving
              : _WorkflowSection.orders;
          _selectedAccountingStoreId = null;
          _statusCounts = {};
          _accessibleStores = [];
          _loadedScope = null;
        });
        unawaited(_load());
      });
    }
    final syncStores = _isAccounting
        ? _accessibleStores.map(_id).toList()
        : [if (auth.storeId != null) auth.storeId!];
    for (final storeId in syncStores) {
      ref.listen<AsyncValue<PosLiveEvent>>(posLiveEventsProvider(storeId), (
        _,
        next,
      ) {
        next.whenData((event) {
          if (event.affects({'inventory'})) _refreshInPlace();
        });
      });
    }
    return PopScope(
      canPop: !_receiptDirty && !_busy,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _busy) return;
        final leave = await _leaveReceipt();
        if (!leave || !context.mounted) return;
        if (context.canPop()) context.pop();
      },
      child: Scaffold(
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
            IconButton(
              key: const Key('inventory_order_workflow_logout_button'),
              tooltip: context.l10n.logout,
              onPressed: _busy
                  ? null
                  : () async {
                      if (!await _leaveReceipt() || !mounted) return;
                      await ref.read(authProvider.notifier).logout();
                    },
              icon: const Icon(Icons.logout_rounded),
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
        body: scopeChanged
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Column(
                  children: [
                    _buildSectionBar(),
                    if (_error != null) _buildErrorBanner(_error!),
                    Expanded(
                      child: switch (_isAccounting
                          ? _WorkflowSection.receiving
                          : _section) {
                        _WorkflowSection.orders => _buildOrdersWorkspace(),
                        _WorkflowSection.receiving =>
                          _buildReceivingWorkspace(),
                        _WorkflowSection.prices => _buildPriceWorkspace(),
                      },
                    ),
                  ],
                ),
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
            if (_canManagePrices)
              ButtonSegment(
                value: _WorkflowSection.prices,
                icon: const Icon(Icons.price_change_outlined),
                label: Text(
                  _text(ko: '거래처 단가', en: 'Supplier prices', vi: 'Giá NCC'),
                ),
              ),
          ],
          selected: {_section},
          onSelectionChanged: (values) async {
            if (_busy || !await _leaveReceipt() || !mounted) return;
            setState(() {
              _section = values.first;
              _orders = [];
              _selectedOrderId = null;
              _detail = null;
            });
            if (_section == _WorkflowSection.prices) {
              final scope = _scopeKey;
              await _runBusy(() async {
                final items = await _service.fetchInventorySupplierItems(
                  storeId: _storeId!,
                );
                if (mounted &&
                    _canManagePrices &&
                    scope == _scopeKey &&
                    _section == _WorkflowSection.prices) {
                  setState(() => _supplierItems = items);
                }
              });
            } else {
              await _load(preserveSelection: false);
            }
          },
        ),
      ),
    );
  }

  Widget _buildErrorBanner(Object error) {
    return MaterialBanner(
      content: Text(_friendlyError(error)),
      leading: const Icon(Icons.error_outline),
      actions: [
        if (error.toString().contains('STALE_VERSION') ||
            error.toString().contains('INVALID_TRANSITION'))
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    if (!await _leaveReceipt() || !mounted) return;
                    await _load();
                  },
            child: Text(
              _text(
                ko: '최신 내용 불러오기',
                en: 'Load latest',
                vi: 'Tải dữ liệu mới nhất',
              ),
            ),
          ),
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

  Widget _buildStatusFilters() {
    final labels = [
      _text(ko: '초안/승인 대기', en: 'Pending', vi: 'Chờ duyệt'),
      _text(ko: '발주 완료', en: 'Placed', vi: 'Đã đặt'),
      _text(ko: '취소', en: 'Cancelled', vi: 'Đã hủy'),
      _text(ko: '기존 거절', en: 'Rejected', vi: 'Từ chối'),
      _text(ko: '검토 필요', en: 'Review', vi: 'Cần kiểm tra'),
    ];
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final group in InventoryOrderGroup.values)
                Padding(
                  padding: const EdgeInsets.all(3),
                  child: ChoiceChip(
                    key: ValueKey('inventory_status_${group.name}'),
                    label: Text(
                      '${labels[group.index]} (${group.count(_statusCounts)})',
                    ),
                    selected: _orderGroup == group,
                    onSelected: _busy
                        ? null
                        : (_) async {
                            if (!await _leaveReceipt() || !mounted) return;
                            setState(() {
                              _orderGroup = group;
                              _orders = [];
                              _selectedOrderId = null;
                              _detail = null;
                            });
                            await _load(preserveSelection: false);
                          },
                  ),
                ),
            ],
          ),
        ),
        if (const {
          'admin',
          'store_admin',
          'brand_admin',
          'super_admin',
        }.contains(_role))
          FilterChip(
            label: Text(
              _text(ko: '내 승인 대기', en: 'My approvals', vi: 'Chờ tôi duyệt'),
            ),
            selected: _mineOnly,
            onSelected: _busy
                ? null
                : (value) {
                    setState(() {
                      _mineOnly = value;
                      _orders = [];
                    });
                    unawaited(_load(preserveSelection: false));
                  },
          ),
      ],
    );
  }

  Widget _buildOrderList({bool receivableOnly = false}) {
    final visible = _orders;
    final sortedAccountingStores = _accessibleStores
        .map((s) => MapEntry(_id(s), _string(s['name'])))
        .toList();
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
        if (!receivableOnly) _buildStatusFilters(),
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
        if (_orders.length < _totalOrders)
          TextButton(
            onPressed: _refreshing || _busy
                ? null
                : () => _load(append: true, background: true),
            child: Text(_text(ko: '더 보기', en: 'Load more', vi: 'Xem thêm')),
          ),
        if (_lastSyncedAt != null)
          Text(
            _text(ko: '최근 갱신 ', en: 'Updated ', vi: 'Cập nhật ') +
                DateFormat('HH:mm:ss').format(_lastSyncedAt!),
            style: Theme.of(context).textTheme.bodySmall,
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
        if (status == 'office_returned' && _canManagePrices)
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _exceptionDecision(order, urgent: false),
            child: Text(
              _text(ko: '초안으로 복구', en: 'Restore draft', vi: 'Khôi phục nháp'),
            ),
          ),
        if (status == 'submitted' && _detail?['can_urgent_approve'] == true)
          OutlinedButton.icon(
            key: const Key('inventory_urgent_approve'),
            onPressed: _busy
                ? null
                : () => _exceptionDecision(order, urgent: true),
            icon: const Icon(Icons.priority_high),
            label: Text(
              _text(
                ko: '긴급 최종 승인',
                en: 'Urgent final approval',
                vi: 'Duyệt khẩn cấp',
              ),
            ),
          ),
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
            _string(order['store_approved_by']) !=
                ref.read(authProvider).user?.id &&
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
                  title: Text(
                    _eventLabel(
                      _string(event['action']),
                      Localizations.localeOf(context).languageCode,
                    ),
                  ),
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
                    : '모든 품목을 입력한 뒤 확인을 눌러 한 번에 제출하세요. 회계 확정 후 재고가 증가합니다.',
                en: _isAccounting
                    ? 'Compare the kitchen receipt with the supplier statement and adjust final values. Stock does not increase before confirmation.'
                    : 'Enter all items, then confirm once to submit. Stock increases after accounting verification.',
                vi: _isAccounting
                    ? 'Đối chiếu hàng bếp nhận với phiếu giao và chỉnh giá trị cuối. Tồn kho chưa tăng trước khi xác nhận.'
                    : 'Nhập tất cả mặt hàng rồi xác nhận một lần. Tồn kho tăng sau khi kế toán xác minh.',
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
    final error = _receiptErrors[lineId];
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
                key: ValueKey('inventory_receipt_quantity_$lineId'),
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
                onChanged: (_) => _markReceiptDirty(lineId),
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
                onChanged: (_) => _markReceiptDirty(lineId),
              ),
            ),
            if (error != null)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildReceiptPanel(Map<String, dynamic> order) {
    final draft = _draftReceipt(_detail);
    final receipts = _maps(_detail?['receipts']);
    final canCapture =
        PermissionUtils.canCreateInventoryPurchaseOrder(_role) &&
        const {
          'ordered',
          'partially_received',
          'office_approved',
        }.contains(_string(order['status']));
    final independent =
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
                ko: '검수 내역',
                en: 'Receipt inspection',
                vi: 'Kiểm nhận hàng',
              ),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            if (_receiptDirty)
              Text(
                _text(
                  ko: '저장하지 않은 변경사항이 있습니다.',
                  en: 'You have unsaved changes.',
                  vi: 'Có thay đổi chưa lưu.',
                ),
              ),
            if (canCapture && _statementInput != null)
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () async {
                        final input = await _statementForm(draft ?? {});
                        if (input != null && mounted) {
                          setState(() {
                            if (input.attachment !=
                                _statementInput?.attachment) {
                              _uploadedStatementPath = null;
                            }
                            _statementInput = input;
                            _receiptDirty = true;
                            _pendingReceiptSubmission = null;
                          });
                        }
                      },
                child: Text(
                  _text(
                    ko: '검수정보 수정',
                    en: 'Edit inspection',
                    vi: 'Sửa kiểm nhận',
                  ),
                ),
              ),
            if (canCapture)
              FilledButton.icon(
                key: const Key('inventory_receipt_submit'),
                onPressed: _busy ? null : () => _submitReceipt(order),
                icon: const Icon(Icons.save_outlined),
                label: Text(
                  _text(
                    ko: '확인 · 입고 내역 제출',
                    en: 'Confirm · submit receipt',
                    vi: 'Xác nhận · gửi phiếu nhập',
                  ),
                ),
              ),
            if (_isAccounting && draft != null) ...[
              Text(_string(draft['inspector_name'], fallback: '-')),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _editStatement(draft),
                icon: const Icon(Icons.description_outlined),
                label: Text(
                  _text(
                    ko: '검수정보·명세서',
                    en: 'Inspection & statement',
                    vi: 'Kiểm nhận & chứng từ',
                  ),
                ),
              ),
              if (independent)
                FilledButton.icon(
                  key: const Key('inventory_receipt_verify'),
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
                )
              else
                Text(
                  _text(
                    ko: '입고 입력자와 다른 회계 계정이 확정해야 합니다.',
                    en: 'A separate accounting account must confirm.',
                    vi: 'Tài khoản kế toán khác người nhập phải xác nhận.',
                  ),
                ),
            ],
            if (draft != null &&
                _string(draft['statement_storage_path']).isNotEmpty)
              OutlinedButton.icon(
                onPressed: () async {
                  final url = await _service.inventoryReceiptStatementUrl(
                    _string(draft['statement_storage_path']),
                  );
                  await launchUrl(
                    Uri.parse(url),
                    mode: LaunchMode.externalApplication,
                  );
                },
                icon: const Icon(Icons.open_in_new),
                label: Text(
                  _text(ko: '첨부 열기', en: 'Open attachment', vi: 'Mở tệp'),
                ),
              ),
            for (final receipt in receipts.where(
              (r) => r['status'] == 'confirmed',
            ))
              ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: Text(
                  '${_string(receipt['inspector_name'], fallback: '-')} · ${_money(receipt['total_amount'])}',
                ),
                subtitle: Text(
                  '${_dateTime(receipt['verified_at'])} · ${_text(ko: '재고 반영 완료', en: 'Stock posted', vi: 'Đã cộng kho')}',
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPriceWorkspace() {
    if (!_canManagePrices) return const SizedBox.shrink();
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final item in _supplierItems.where(
      (row) => row['is_active'] != false,
    )) {
      grouped.putIfAbsent(_supplierName(item), () => []).add(item);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        final heading = Column(
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
        );
        final actions = Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.end,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _downloadPriceTemplate,
              icon: const Icon(Icons.download_outlined),
              label: Text(
                _text(ko: 'Excel 양식', en: 'Excel template', vi: 'Mẫu Excel'),
              ),
            ),
            FilledButton.icon(
              onPressed: _busy ? null : _importPrices,
              icon: const Icon(Icons.upload_file_outlined),
              label: Text(
                _text(ko: 'Excel 등록', en: 'Import Excel', vi: 'Nhập Excel'),
              ),
            ),
          ],
        );
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: compact
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        heading,
                        const SizedBox(height: 12),
                        Align(alignment: Alignment.centerRight, child: actions),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(child: heading),
                        const SizedBox(width: 16),
                        actions,
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
      },
    );
  }

  Future<_StatementInput?> _statementForm(
    Map<String, dynamic> initial, {
    bool requireDiscrepancyReason = false,
  }) async {
    return showDialog<_StatementInput>(
      context: context,
      builder: (_) => _StatementDialog(
        key: const Key('inventory_receipt_statement_dialog'),
        initial: initial,
        input: _statementInput,
        requireDiscrepancyReason: requireDiscrepancyReason,
      ),
    );
  }

  Future<void> _submitReceipt(Map<String, dynamic> order) async {
    if (_busy) return;
    final lines = _maps(_detail?['lines']);
    final draft = _draftReceipt(_detail);
    final payload = <Map<String, dynamic>>[];
    _receiptErrors.clear();
    for (final line in lines) {
      final id = _id(line);
      final qty = parseInventoryQuantity(_receiptControllers[id]?.text ?? '');
      final price = parseInventoryQuantity(
        _receiptPriceControllers[id]?.text ?? '',
      );
      if (qty == null || price == null) {
        _receiptErrors[id] = _text(
          ko: '수량과 단가를 확인하세요. 미수령은 0을 입력하세요.',
          en: 'Enter valid quantity and price; use 0 for undelivered items.',
          vi: 'Nhập số lượng và giá hợp lệ; nhập 0 nếu chưa nhận.',
        );
        continue;
      }
      payload.add({
        'purchase_order_line_id': id,
        'received_quantity_base': qty * _conversion(line),
        'actual_unit_price': price,
        'discrepancy_reason': null,
      });
    }
    if (_receiptErrors.isNotEmpty) {
      setState(() {});
      return;
    }
    final changedLineIds = <String>{
      for (var i = 0; i < lines.length; i++)
        if ((_number(payload[i]['received_quantity_base']) -
                        _number(lines[i]['ordered_quantity_base']))
                    .abs() >
                0.0001 ||
            (_number(payload[i]['actual_unit_price']) -
                        _number(lines[i]['unit_price']))
                    .abs() >
                0.01)
          _id(lines[i]),
    };
    final needsReason = changedLineIds.isNotEmpty;
    if (_statementInput == null ||
        (needsReason && _statementInput!.memo.trim().isEmpty)) {
      final input = await _statementForm(
        draft ?? {},
        requireDiscrepancyReason: needsReason,
      );
      if (input == null || !mounted) return;
      setState(() {
        _statementInput = input;
        _receiptDirty = true;
      });
    }
    await _runBusy(() async {
      final input = _statementInput!;
      for (final row in payload) {
        if (changedLineIds.contains(row['purchase_order_line_id'])) {
          row['discrepancy_reason'] = input.memo.trim();
        }
      }
      _receiptId ??= draft == null ? const Uuid().v4() : _id(draft);
      if (_uploadedStatementPath == null && input.attachment != null) {
        final bytes = await input.attachment!.readAsBytes();
        if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
          throw StateError('INVENTORY_RECEIPT_FILE_SIZE_INVALID');
        }
        _uploadedStatementPath = await _service.uploadInventoryReceiptStatement(
          storeId: _string(order['restaurant_id']),
          receiptId: _receiptId!,
          fileName: input.attachment!.name,
          bytes: bytes,
          contentType: _statementContentType(input.attachment!.name),
        );
      }
      _pendingReceiptSubmission ??= {
        'p_purchase_order_id': _id(order),
        'p_receipt_id': _receiptId,
        'p_expected_order_version': _integer(order['row_version']),
        'p_expected_receipt_version': draft == null
            ? 0
            : _integer(draft['row_version']),
        'p_idempotency_key': const Uuid().v4(),
        'p_lines': payload,
        'p_inspector_name': input.inspectorName,
        'p_statement_storage_path':
            _uploadedStatementPath ?? draft?['statement_storage_path'],
        'p_statement_number': _nullable(input.number),
        'p_statement_date': input.date == null
            ? null
            : DateFormat('yyyy-MM-dd').format(input.date!),
        'p_memo': input.memo,
      };
      await _service.submitInventoryReceiptBatch(_pendingReceiptSubmission!);
      if (!mounted) return;
      setState(() {
        _receiptDirty = false;
        _pendingReceiptSubmission = null;
      });
      await _loadDetail(_id(order), background: true);
    });
  }

  Future<void> _createDraft() async {
    final input = await showDialog<InventoryPurchaseDraftOrderInput>(
      context: context,
      builder: (_) => InventoryPurchaseDraftOrderDialog(
        key: const Key('inventory_order_create_draft_dialog'),
        suppliers: _suppliers,
        supplierItems: _supplierItems,
        canEditPrice: _canManagePrices,
        loadSupplierItems: (supplierId) async {
          final catalog = await _service.fetchInventoryOrderCatalog(_storeId!);
          return _maps(catalog['items'])
              .where((item) => _string(item['supplier_id']) == supplierId)
              .toList();
        },
      ),
    );
    if (input == null || _storeId == null) return;
    await _runBusy(() async {
      final order = await _service.createManualInventoryPurchaseOrder(
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
    final input = await showDialog<InventoryPurchaseDraftOrderInput>(
      context: context,
      builder: (_) => InventoryPurchaseDraftOrderDialog(
        key: const Key('inventory_order_edit_draft_dialog'),
        suppliers: _suppliers,
        supplierItems: _supplierItems,
        canEditPrice: _canManagePrices,
        loadSupplierItems: (supplierId) async {
          final catalog = await _service.fetchInventoryOrderCatalog(_storeId!);
          return _maps(catalog['items'])
              .where((item) => _string(item['supplier_id']) == supplierId)
              .toList();
        },
        initialOrder: order,
        initialLines: lines,
      ),
    );
    if (input == null) return;
    await _runBusy(() async {
      await _service.saveInventoryPurchaseOrderDraft(
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
      await _service.deleteInventoryPurchaseOrderDraft(
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
      await _service.submitInventoryPurchaseOrder(
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
      await _service.storeDecideInventoryPurchaseOrder(
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
      await _service.brandDecideInventoryPurchaseOrder(
        purchaseOrderId: _id(order),
        expectedVersion: version,
        approve: approve,
        reason: reason,
      );
      if (approve) {
        final approved = await _service.fetchInventoryWorkflowDetail(
          _id(order),
        );
        await _publishDocument(
          _map(approved['order']),
          _maps(approved['lines']),
          nested: true,
        );
      } else {
        await _load();
      }
    });
  }

  Future<void> _exceptionDecision(
    Map<String, dynamic> order, {
    required bool urgent,
  }) async {
    final reason = await _askText(
      title: urgent
          ? _text(
              ko: '긴급 승인 사유',
              en: 'Urgent approval reason',
              vi: 'Lý do duyệt khẩn cấp',
            )
          : _text(
              ko: '초안 복구 사유',
              en: 'Restore draft reason',
              vi: 'Lý do khôi phục',
            ),
      label: _text(ko: '사유', en: 'Reason', vi: 'Lý do'),
    );
    if (reason == null || reason.trim().isEmpty || !mounted) return;
    if (!await _confirm(
      title: _string(order['purchase_order_no']),
      message: urgent
          ? _text(
              ko: '매장 승인 단계를 생략하고 최종 승인합니다. 사유와 생략 단계가 기록됩니다.',
              en: 'Skip store approval and approve finally. The reason and skipped step will be recorded.',
              vi: 'Bỏ bước duyệt cửa hàng và duyệt cuối. Lý do và bước bỏ qua sẽ được ghi lại.',
            )
          : _text(
              ko: '기존 반려 주문을 수정 가능한 초안으로 복구합니다.',
              en: 'Restore the returned order to an editable draft.',
              vi: 'Khôi phục đơn trả lại thành nháp có thể sửa.',
            ),
    )) {
      return;
    }
    await _runBusy(() async {
      if (urgent) {
        await _service.urgentApproveInventoryOrder(
          orderId: _id(order),
          version: _integer(order['row_version']),
          reason: reason.trim(),
        );
        final approved = await _service.fetchInventoryWorkflowDetail(
          _id(order),
        );
        await _publishDocument(
          _map(approved['order']),
          _maps(approved['lines']),
          nested: true,
        );
      } else {
        await _service.restoreReturnedInventoryDraft(
          orderId: _id(order),
          version: _integer(order['row_version']),
          reason: reason.trim(),
        );
        await _load();
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
    final input = await _statementForm(draft);
    if (input == null || !mounted) return;
    _statementInput = input;
    await _runBusy(() async {
      var path = _nullable(draft['statement_storage_path']);
      if (input.attachment != null) {
        path = await _service.uploadInventoryReceiptStatement(
          storeId: _string(draft['restaurant_id']),
          receiptId: _id(draft),
          fileName: input.attachment!.name,
          bytes: await input.attachment!.readAsBytes(),
          contentType: _statementContentType(input.attachment!.name),
        );
      }
      final saved = await _service.updateInventoryReceiptMetadataV2({
        'p_receipt_id': _id(draft),
        'p_expected_version': _integer(draft['row_version']),
        'p_inspector_name': input.inspectorName,
        'p_statement_number': _nullable(input.number),
        'p_statement_date': input.date == null
            ? null
            : DateFormat('yyyy-MM-dd').format(input.date!),
        'p_statement_storage_path': path,
        'p_memo': input.memo,
      });
      // Preserve the accountant's unsaved final quantities while refreshing metadata/version.
      if (mounted && _detail != null) {
        setState(() {
          _detail!['receipts'] = _maps(
            _detail!['receipts'],
          ).map((r) => _id(r) == _id(draft) ? {...r, ...saved} : r).toList();
        });
      }
    });
  }

  Future<void> _verifyReceipt(
    Map<String, dynamic> order,
    Map<String, dynamic> draft,
    List<Map<String, dynamic>> orderLines,
  ) async {
    if (_string(draft['inspector_name']).isEmpty ||
        _string(draft['statement_storage_path']).isEmpty) {
      await _editStatement(draft);
      final refreshed = _draftReceipt(_detail);
      if (refreshed == null ||
          _string(refreshed['inspector_name']).isEmpty ||
          _string(refreshed['statement_storage_path']).isEmpty) {
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
    final changedFinalLines = <Map<String, dynamic>>[];
    for (final line in orderLines) {
      final lineId = _id(line);
      final draftLine = draftLines[lineId];
      if (lineId.isEmpty || draftLine == null) continue;
      final conversion = _conversion(line);
      final qty = parseInventoryQuantity(
        _receiptControllers[lineId]?.text ?? '',
      );
      final enteredPrice = parseInventoryQuantity(
        _receiptPriceControllers[lineId]?.text ?? '',
      );
      if (qty == null || enteredPrice == null) {
        setState(
          () => _error = StateError('INVENTORY_RECEIPT_QUANTITY_INVALID'),
        );
        return;
      }
      final accepted = qty * conversion;
      final received = _number(draftLine['received_quantity_base']);
      final currentAccepted = _number(draftLine['accepted_quantity_base']);
      final price = enteredPrice;
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
        'discrepancy_reason': _nullable(draftLine['discrepancy_reason']),
      });
      if (changed) changedFinalLines.add(finalLines.last);
    }
    if (changedFinalLines.isNotEmpty) {
      final reason = await _askText(
        title: _text(
          ko: '수량·단가 차이 사유',
          en: 'Quantity or price difference',
          vi: 'Chênh lệch số lượng hoặc giá',
        ),
        label: _text(
          ko: '조정 사유 *',
          en: 'Adjustment reason *',
          vi: 'Lý do điều chỉnh *',
        ),
      );
      if (reason == null || !mounted) return;
      if (reason.trim().isEmpty) {
        setState(
          () => _error = StateError(
            'INVENTORY_RECEIPT_DISCREPANCY_REASON_REQUIRED',
          ),
        );
        return;
      }
      for (final line in changedFinalLines) {
        line['discrepancy_reason'] = reason.trim();
      }
    }
    await _runBusy(() async {
      await _service.verifyInventoryReceipt(
        receiptId: _id(draft),
        expectedVersion: _integer(draft['row_version'], fallback: 1),
        idempotencyKey: _verificationKey ??= const Uuid().v4(),
        lines: finalLines,
        verificationReason: 'supplier_statement_double_checked',
      );
      if (mounted) {
        setState(() {
          _receiptDirty = false;
          _verificationKey = null;
        });
      }
      await _load();
    });
  }

  Future<void> _quickEditPrice(Map<String, dynamic> item) async {
    if (!_canManagePrices) return;
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
      await _service.upsertInventorySupplierItem(
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
      final preview = await _service.bulkUpdateInventorySupplierPrices(
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
      await _service.bulkUpdateInventorySupplierPrices(
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
      if (mounted) {
        setState(() => _busy = false);
        if (_refreshAgain) {
          _refreshAgain = false;
          _refreshInPlace();
        }
      }
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
      'INVENTORY_RECEIPT_INSPECTOR_REQUIRED' => _text(
        ko: '검수자명을 입력하세요.',
        en: 'Enter the inspector name.',
        vi: 'Nhập tên người kiểm hàng.',
      ),
      'INVENTORY_RECEIPT_ATTACHMENT_REQUIRED' ||
      'INVENTORY_RECEIPT_FILE_SIZE_INVALID' => _text(
        ko: '이 입고 건의 PDF/사진을 첨부하세요. 파일은 10MB 이하여야 합니다.',
        en: 'Attach this receipt’s PDF/photo, up to 10 MB.',
        vi: 'Đính kèm PDF/ảnh của phiếu nhập, tối đa 10 MB.',
      ),
      'INVENTORY_RECEIPT_LINES_REQUIRED' ||
      'INVENTORY_RECEIPT_QUANTITY_INVALID' => _text(
        ko: '전체 품목의 수량을 확인하세요. 미수령은 0이며 최소 한 품목은 수령해야 합니다.',
        en: 'Check all quantities. Use 0 for undelivered items; at least one item must be received.',
        vi: 'Kiểm tra tất cả số lượng. Nhập 0 nếu chưa nhận; phải nhận ít nhất một mặt hàng.',
      ),
      'INVENTORY_RECEIPT_DISCREPANCY_REASON_REQUIRED' => _text(
        ko: '주문과 수량 또는 단가가 다른 이유를 입력하세요.',
        en: 'Enter the reason for the quantity or price difference.',
        vi: 'Nhập lý do chênh lệch số lượng hoặc đơn giá.',
      ),
      'INVENTORY_RECEIPT_SUBMISSION_REQUIRED' => _text(
        ko: '입고 담당자가 전체 검수 내역을 먼저 제출해야 합니다.',
        en: 'The receiver must submit the complete inspection first.',
        vi: 'Người nhận phải gửi đầy đủ thông tin kiểm hàng trước.',
      ),
      'INVENTORY_PURCHASE_INVALID_TRANSITION' => _text(
        ko: '이미 처리되었거나 현재 단계에서 실행할 수 없습니다. 최신 상태를 확인하세요.',
        en: 'Already processed or unavailable at this stage. Check the latest status.',
        vi: 'Đã xử lý hoặc không hợp lệ ở bước này. Kiểm tra trạng thái mới nhất.',
      ),
      'INVENTORY_PURCHASE_FORBIDDEN' ||
      'INVENTORY_RECEIPT_DRAFT_FORBIDDEN' ||
      'INVENTORY_RECEIPT_DRAFT_OWNER_REQUIRED' ||
      'INVENTORY_PURCHASE_URGENT_FORBIDDEN' => _text(
        ko: '이 매장 또는 작업에 대한 권한이 없습니다.',
        en: 'You do not have access to this store or action.',
        vi: 'Bạn không có quyền với cửa hàng hoặc thao tác này.',
      ),
      'INVENTORY_PURCHASE_DISTINCT_APPROVER_REQUIRED' => _text(
        ko: '매장 승인자와 다른 브랜드 승인자가 필요합니다.',
        en: 'Brand approval requires a different approver from the store step.',
        vi: 'Người duyệt thương hiệu phải khác người duyệt cửa hàng.',
      ),
      'INVENTORY_RECEIPT_MAKER_CHECKER_REQUIRED' => _text(
        ko: '입고 입력에 참여하지 않은 회계 담당자가 최종 검증해야 합니다.',
        en: 'An accountant who did not submit this receipt must verify it.',
        vi: 'Kế toán không tham gia gửi phiếu nhập này phải xác minh.',
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

class InventoryPurchaseDraftOrderInput {
  const InventoryPurchaseDraftOrderInput({
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

typedef InventoryPurchaseSupplierItemLoader =
    Future<List<Map<String, dynamic>>> Function(String supplierId);

class InventoryPurchaseDraftOrderDialog extends StatefulWidget {
  const InventoryPurchaseDraftOrderDialog({
    super.key,
    required this.suppliers,
    required this.supplierItems,
    required this.loadSupplierItems,
    this.canEditPrice = true,
    this.initialOrder,
    this.initialLines = const [],
  });

  final List<Map<String, dynamic>> suppliers;
  final List<Map<String, dynamic>> supplierItems;
  final InventoryPurchaseSupplierItemLoader loadSupplierItems;
  final bool canEditPrice;
  final Map<String, dynamic>? initialOrder;
  final List<Map<String, dynamic>> initialLines;

  @override
  State<InventoryPurchaseDraftOrderDialog> createState() =>
      _InventoryPurchaseDraftOrderDialogState();
}

class _InventoryPurchaseDraftOrderDialogState
    extends State<InventoryPurchaseDraftOrderDialog> {
  late String? _supplierId;
  late DateTime _deliveryDate;
  late final TextEditingController _memoController;
  late final TextEditingController _searchController;
  late List<_DraftLine> _lines;
  late List<Map<String, dynamic>> _catalogItems;
  String? _newSupplierItemId;
  Object? _catalogError;
  bool _catalogLoading = false;
  int _catalogRequest = 0;

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
    _searchController = TextEditingController()..addListener(_refreshSearch);
    _catalogItems = List<Map<String, dynamic>>.from(widget.supplierItems);
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
    if (_supplierId != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _loadSupplierItems(_supplierId!),
      );
    }
  }

  @override
  void dispose() {
    _catalogRequest += 1;
    _memoController.dispose();
    _searchController
      ..removeListener(_refreshSearch)
      ..dispose();
    super.dispose();
  }

  void _refreshSearch() {
    if (mounted) setState(() {});
  }

  String _text({required String ko, required String en, required String vi}) {
    return switch (Localizations.localeOf(context).languageCode) {
      'en' => en,
      'vi' => vi,
      _ => ko,
    };
  }

  Future<void> _loadSupplierItems(String supplierId) async {
    final request = ++_catalogRequest;
    setState(() {
      _catalogLoading = true;
      _catalogError = null;
      _newSupplierItemId = null;
    });
    try {
      final loaded = await widget.loadSupplierItems(supplierId);
      if (!mounted || request != _catalogRequest || supplierId != _supplierId) {
        return;
      }
      final retainedIds = _lines.map((line) => line.supplierItemId).toSet();
      final merged = <String, Map<String, dynamic>>{
        for (final item in _catalogItems)
          if (retainedIds.contains(_id(item))) _id(item): item,
        for (final item in loaded) _id(item): item,
      };
      setState(() {
        _catalogItems = merged.values.toList();
        _catalogLoading = false;
      });
    } catch (error) {
      if (!mounted || request != _catalogRequest || supplierId != _supplierId) {
        return;
      }
      setState(() {
        _catalogError = error;
        _catalogLoading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _availableItems => _catalogItems.where((item) {
    final product = item['product'];
    final supplier = item['supplier'];
    return _string(item['supplier_id']) == _supplierId &&
        item['is_active'] != false &&
        product is Map &&
        product['is_active'] != false &&
        product['is_orderable'] != false &&
        supplier is Map &&
        (supplier['status'] == null || supplier['status'] == 'active');
  }).toList();

  List<Map<String, dynamic>> get _selectableItems {
    final query = _searchController.text.trim().toLowerCase();
    return _availableItems.where((item) {
      if (_lines.any((line) => line.supplierItemId == _id(item))) return false;
      return query.isEmpty || _productName(item).toLowerCase().contains(query);
    }).toList();
  }

  Map<String, dynamic> _lineItem(_DraftLine line) => _catalogItems.firstWhere(
    (row) => _id(row) == line.supplierItemId,
    orElse: () => const {},
  );

  String? _lineError(_DraftLine line) {
    final item = _lineItem(line);
    if (item.isEmpty) {
      return _text(
        ko: '원재료 정보를 다시 불러와 주세요.',
        en: 'Reload the ingredient information.',
        vi: 'Vui lòng tải lại thông tin nguyên liệu.',
      );
    }
    final minimum = _number(item['min_order_quantity'], fallback: 1);
    if (!line.quantity.isFinite ||
        line.quantity <= 0 ||
        line.quantity < minimum) {
      return _text(
        ko: '최소 발주량은 ${_quantity(minimum)}입니다.',
        en: 'Minimum order is ${_quantity(minimum)}.',
        vi: 'Số lượng tối thiểu là ${_quantity(minimum)}.',
      );
    }
    if (!line.unitPrice.isFinite || line.unitPrice < 0) {
      return _text(
        ko: '단가는 0 이상이어야 합니다.',
        en: 'Unit price must be zero or greater.',
        vi: 'Đơn giá phải từ 0 trở lên.',
      );
    }
    return null;
  }

  String _catalogStatusText() {
    if (_supplierId == null) {
      return _text(
        ko: '거래처를 먼저 선택해 주세요.',
        en: 'Select a supplier first.',
        vi: 'Vui lòng chọn nhà cung cấp trước.',
      );
    }
    if (_catalogLoading) {
      return _text(
        ko: '발주 가능 원재료를 불러오는 중입니다.',
        en: 'Loading orderable ingredients.',
        vi: 'Đang tải nguyên liệu có thể đặt.',
      );
    }
    if (_catalogError != null) {
      final forbidden = _catalogError.toString().contains(
        'INVENTORY_PURCHASE_CATALOG_FORBIDDEN',
      );
      return forbidden
          ? _text(
              ko: '이 계정의 발주 품목 조회 권한을 확인해 주세요.',
              en: 'Check this account\'s permission to view purchase items.',
              vi: 'Vui lòng kiểm tra quyền xem mặt hàng đặt mua của tài khoản.',
            )
          : _text(
              ko: '원재료를 불러오지 못했습니다.',
              en: 'Could not load ingredients.',
              vi: 'Không thể tải nguyên liệu.',
            );
    }
    if (_availableItems.isEmpty) {
      return _text(
        ko: '이 매장·거래처에 등록된 발주 가능 원재료가 없습니다.',
        en: 'No orderable ingredients are registered for this store and supplier.',
        vi: 'Không có nguyên liệu có thể đặt cho cửa hàng và nhà cung cấp này.',
      );
    }
    if (_selectableItems.isEmpty && _searchController.text.trim().isEmpty) {
      return _text(
        ko: '추가 가능한 품목을 모두 선택했습니다.',
        en: 'All available ingredients have been added.',
        vi: 'Đã thêm tất cả nguyên liệu có thể chọn.',
      );
    }
    if (_selectableItems.isEmpty) {
      return _text(
        ko: '검색 결과가 없습니다.',
        en: 'No ingredients match your search.',
        vi: 'Không có nguyên liệu phù hợp.',
      );
    }
    return _text(
      ko: '원재료를 선택한 뒤 추가 버튼을 누르세요.',
      en: 'Select an ingredient, then tap Add.',
      vi: 'Chọn nguyên liệu rồi nhấn Thêm.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initialOrder != null;
    final canSave =
        _supplierId != null &&
        _lines.isNotEmpty &&
        _lines.every((line) => _lineError(line) == null);
    return AlertDialog(
      key: widget.key,
      title: Text(
        editing
            ? _text(
                ko: '발주 초안 수정',
                en: 'Edit purchase draft',
                vi: 'Sửa bản nháp đặt hàng',
              )
            : _text(
                ko: '새 발주 초안',
                en: 'New purchase draft',
                vi: 'Tạo bản nháp đặt hàng',
              ),
      ),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                key: const Key('inventory_draft_supplier_dropdown'),
                initialValue: _supplierId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: _text(
                    ko: '거래처',
                    en: 'Supplier',
                    vi: 'Nhà cung cấp',
                  ),
                  border: const OutlineInputBorder(),
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
                    : (value) {
                        _catalogRequest += 1;
                        setState(() {
                          _supplierId = value;
                          _lines = [];
                          _newSupplierItemId = null;
                          _catalogError = null;
                          _catalogLoading = false;
                          _searchController.clear();
                        });
                        if (value != null) {
                          unawaited(_loadSupplierItems(value));
                        }
                      },
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  _text(
                    ko: '납품 요청일',
                    en: 'Requested delivery date',
                    vi: 'Ngày yêu cầu giao hàng',
                  ),
                ),
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
              TextField(
                key: const Key('inventory_draft_ingredient_search'),
                controller: _searchController,
                enabled: _supplierId != null && !_catalogLoading,
                decoration: InputDecoration(
                  labelText: _text(
                    ko: '원재료 검색',
                    en: 'Search ingredients',
                    vi: 'Tìm nguyên liệu',
                  ),
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      key: const Key('inventory_draft_supplier_item_dropdown'),
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(
                          'inventory_draft_supplier_item_${_supplierId}_${_newSupplierItemId ?? ''}',
                        ),
                        initialValue: _newSupplierItemId,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: _text(
                            ko: '발주 원재료',
                            en: 'Purchase ingredient',
                            vi: 'Nguyên liệu đặt mua',
                          ),
                          border: const OutlineInputBorder(),
                        ),
                        items: _selectableItems
                            .map(
                              (item) => DropdownMenuItem(
                                value: _id(item),
                                child: Text(
                                  '${_productName(item)} · ${_quantity(_number(item['min_order_quantity'], fallback: 1))} ${_string(item['order_unit'])}'
                                  '${widget.canEditPrice ? ' · ${_money(item['unit_price'])}' : ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged:
                            _supplierId == null ||
                                _catalogLoading ||
                                _catalogError != null ||
                                _selectableItems.isEmpty
                            ? null
                            : (value) =>
                                  setState(() => _newSupplierItemId = value),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    key: const Key('inventory_draft_add_ingredient'),
                    onPressed: _newSupplierItemId == null
                        ? null
                        : () {
                            final item = _selectableItems.firstWhere(
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
                    tooltip: _text(
                      ko: '발주에 추가',
                      en: 'Add to purchase order',
                      vi: 'Thêm vào đơn đặt hàng',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  if (_catalogLoading) ...[
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      _catalogStatusText(),
                      key: const Key('inventory_draft_catalog_status'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _catalogError == null
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                  if (_catalogError != null && _supplierId != null)
                    TextButton.icon(
                      key: const Key('inventory_draft_catalog_retry'),
                      onPressed: _catalogLoading
                          ? null
                          : () => _loadSupplierItems(_supplierId!),
                      icon: const Icon(Icons.refresh),
                      label: Text(
                        _text(ko: '다시 불러오기', en: 'Retry', vi: 'Tải lại'),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              for (var index = 0; index < _lines.length; index++)
                _buildLine(index, _lines[index]),
              TextField(
                controller: _memoController,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: _text(ko: '메모', en: 'Memo', vi: 'Ghi chú'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_text(ko: '취소', en: 'Cancel', vi: 'Hủy')),
        ),
        FilledButton(
          key: const Key('inventory_draft_save'),
          onPressed: !canSave
              ? null
              : () => Navigator.pop(
                  context,
                  InventoryPurchaseDraftOrderInput(
                    supplierId: _supplierId!,
                    deliveryDate: _deliveryDate,
                    memo: _memoController.text.trim(),
                    lines: _lines.map((line) => line.toJson()).toList(),
                  ),
                ),
          child: Text(_text(ko: '저장', en: 'Save', vi: 'Lưu')),
        ),
      ],
    );
  }

  Widget _buildLine(int index, _DraftLine line) {
    final item = _lineItem(line);
    final minimum = _number(item['min_order_quantity'], fallback: 1);
    final quantityError = line.quantity < minimum
        ? _text(
            ko: '최소 ${_quantity(minimum)}',
            en: 'Minimum ${_quantity(minimum)}',
            vi: 'Tối thiểu ${_quantity(minimum)}',
          )
        : null;
    final priceError = line.unitPrice < 0
        ? _text(ko: '0 이상', en: 'Zero or greater', vi: 'Từ 0 trở lên')
        : null;
    final quantityField = TextFormField(
      key: ValueKey('draft_qty_${line.supplierItemId}'),
      initialValue: _quantity(line.quantity),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: _text(ko: '수량', en: 'Quantity', vi: 'Số lượng'),
        suffixText: _string(item['order_unit']),
        errorText: quantityError,
      ),
      onChanged: (value) => setState(() {
        line.quantity = _parseNumber(value);
      }),
    );
    final priceField = TextFormField(
      key: ValueKey('draft_price_${line.supplierItemId}'),
      initialValue: !widget.canEditPrice && line.lineId.isEmpty
          ? ''
          : _quantity(line.unitPrice),
      readOnly: !widget.canEditPrice,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: _text(ko: '단가', en: 'Unit price', vi: 'Đơn giá'),
        hintText: !widget.canEditPrice && line.lineId.isEmpty
            ? _text(ko: '저장 시 확정', en: 'Set on save', vi: 'Xác định khi lưu')
            : null,
        suffixText: 'VND',
        errorText: priceError,
      ),
      onChanged: (value) => setState(() {
        line.unitPrice = _parseNumber(value);
      }),
    );
    final removeButton = IconButton(
      onPressed: () => setState(() => _lines.removeAt(index)),
      tooltip: _text(ko: '삭제', en: 'Remove', vi: 'Xóa'),
      icon: const Icon(Icons.remove_circle_outline),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 620) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(_productName(item))),
                      removeButton,
                    ],
                  ),
                  const SizedBox(height: 8),
                  quantityField,
                  const SizedBox(height: 8),
                  priceField,
                ],
              );
            }
            return Row(
              children: [
                Expanded(flex: 3, child: Text(_productName(item))),
                const SizedBox(width: 8),
                Expanded(child: quantityField),
                const SizedBox(width: 8),
                Expanded(child: priceField),
                removeButton,
              ],
            );
          },
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
    required this.inspectorName,
    required this.number,
    required this.date,
    required this.memo,
    this.attachment,
  });
  final String inspectorName;
  final String number;
  final DateTime? date;
  final String memo;
  final XFile? attachment;
}

class _StatementDialog extends StatefulWidget {
  const _StatementDialog({
    super.key,
    required this.initial,
    this.input,
    this.requireDiscrepancyReason = false,
  });
  final bool requireDiscrepancyReason;
  final Map<String, dynamic> initial;
  final _StatementInput? input;
  @override
  State<_StatementDialog> createState() => _StatementDialogState();
}

class _StatementDialogState extends State<_StatementDialog> {
  late final TextEditingController _inspectorController;
  late final TextEditingController _numberController;
  late final TextEditingController _memoController;
  DateTime? _date;
  XFile? _attachment;
  String _t(String ko, String en, String vi) =>
      switch (Localizations.localeOf(context).languageCode) {
        'en' => en,
        'vi' => vi,
        _ => ko,
      };
  @override
  void initState() {
    super.initState();
    _inspectorController = TextEditingController(
      text:
          widget.input?.inspectorName ??
          _string(widget.initial['inspector_name']),
    );
    _numberController = TextEditingController(
      text: widget.input?.number ?? _string(widget.initial['statement_number']),
    );
    _memoController = TextEditingController(
      text: widget.input?.memo ?? _string(widget.initial['memo']),
    );
    _date =
        widget.input?.date ??
        DateTime.tryParse(_string(widget.initial['statement_date']));
    _attachment = widget.input?.attachment;
  }

  @override
  void dispose() {
    _inspectorController.dispose();
    _numberController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready =
        _inspectorController.text.trim().isNotEmpty &&
        (!widget.requireDiscrepancyReason ||
            _memoController.text.trim().isNotEmpty) &&
        (_attachment != null ||
            _string(widget.initial['statement_storage_path']).isNotEmpty);
    return AlertDialog(
      key: widget.key,
      title: Text(
        _t('검수정보·명세서', 'Inspection & statement', 'Kiểm nhận & chứng từ'),
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('inventory_receipt_inspector'),
                controller: _inspectorController,
                autofocus: true,
                maxLength: 200,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: _t(
                    '검수자명 *',
                    'Inspector name *',
                    'Người kiểm hàng *',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final file = await openFile(
                    acceptedTypeGroups: const [
                      XTypeGroup(
                        label: 'Statement',
                        extensions: ['pdf', 'png', 'jpg', 'jpeg'],
                      ),
                    ],
                  );
                  if (file != null && mounted) {
                    setState(() => _attachment = file);
                  }
                },
                icon: const Icon(Icons.attach_file),
                label: Text(
                  _attachment?.name ??
                      (_string(
                            widget.initial['statement_storage_path'],
                          ).isNotEmpty
                          ? _t(
                              '첨부 파일 변경',
                              'Replace attachment',
                              'Đổi tệp đính kèm',
                            )
                          : _t(
                              '명세서 PDF/사진 첨부 *',
                              'Attach statement PDF/photo *',
                              'Đính kèm PDF/ảnh *',
                            )),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _numberController,
                decoration: InputDecoration(
                  labelText: _t(
                    '명세서 번호 (선택)',
                    'Statement number (optional)',
                    'Số chứng từ (tùy chọn)',
                  ),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  _t(
                    '명세서 날짜 (선택)',
                    'Statement date (optional)',
                    'Ngày chứng từ (tùy chọn)',
                  ),
                ),
                subtitle: Text(
                  _date == null ? '—' : DateFormat('yyyy-MM-dd').format(_date!),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_date != null)
                      IconButton(
                        onPressed: () => setState(() => _date = null),
                        icon: const Icon(Icons.clear),
                      ),
                    IconButton(
                      icon: const Icon(Icons.calendar_month_outlined),
                      onPressed: () async {
                        final now = DateTime.now();
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _date ?? now,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(now.year + 1, 12, 31),
                        );
                        if (picked != null && mounted) {
                          setState(() => _date = picked);
                        }
                      },
                    ),
                  ],
                ),
              ),
              TextField(
                key: const Key('inventory_receipt_inspection_note'),
                controller: _memoController,
                onChanged: (_) => setState(() {}),
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: _t(
                    widget.requireDiscrepancyReason
                        ? '수량·단가 차이 사유 *'
                        : '검수 메모 (선택)',
                    widget.requireDiscrepancyReason
                        ? 'Quantity/price difference reason *'
                        : 'Inspection note (optional)',
                    widget.requireDiscrepancyReason
                        ? 'Lý do chênh lệch số lượng/giá *'
                        : 'Ghi chú (tùy chọn)',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_t('취소', 'Cancel', 'Hủy')),
        ),
        FilledButton(
          key: const Key('inventory_statement_confirm'),
          onPressed: !ready
              ? null
              : () => Navigator.pop(
                  context,
                  _StatementInput(
                    inspectorName: _inspectorController.text.trim(),
                    number: _numberController.text.trim(),
                    date: _date,
                    memo: _memoController.text.trim(),
                    attachment: _attachment,
                  ),
                ),
          child: Text(_t('확인', 'Confirm', 'Xác nhận')),
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

String _eventLabel(String action, String languageCode) {
  const labels = {
    'draft_created': ['발주 초안 생성', 'Draft created', 'Tạo đơn nháp'],
    'draft_updated': ['발주 초안 수정', 'Draft updated', 'Cập nhật đơn nháp'],
    'draft_deleted': ['발주 초안 삭제', 'Draft deleted', 'Xóa đơn nháp'],
    'submitted': [
      '스토어 승인 요청',
      'Store approval requested',
      'Yêu cầu cửa hàng duyệt',
    ],
    'store_approved': ['스토어 매니저 승인', 'Store approved', 'Cửa hàng đã duyệt'],
    'store_returned': ['스토어 매니저 반려', 'Returned by store', 'Cửa hàng trả lại'],
    'brand_approved': ['브랜드 매니저 승인', 'Brand approved', 'Thương hiệu đã duyệt'],
    'brand_returned': [
      '브랜드 매니저 반려',
      'Returned by brand',
      'Thương hiệu trả lại',
    ],
    'store_approval_skipped': [
      '긴급 승인: 스토어 단계 생략',
      'Urgent approval: store step skipped',
      'Duyệt khẩn: bỏ qua bước cửa hàng',
    ],
    'legacy_return_restored': [
      '기존 반려 주문을 초안으로 복원',
      'Returned order restored to draft',
      'Khôi phục đơn trả lại thành bản nháp',
    ],
    'document_ready': [
      '승인 PDF 생성 완료',
      'Approval PDF ready',
      'PDF phê duyệt đã sẵn sàng',
    ],
    'document_failed': [
      '승인 PDF 생성 실패',
      'Approval PDF failed',
      'Tạo PDF phê duyệt thất bại',
    ],
  };
  final values = labels[action];
  if (values == null) return action;
  return switch (languageCode) {
    'en' => values[1],
    'vi' => values[2],
    _ => values[0],
  };
}
