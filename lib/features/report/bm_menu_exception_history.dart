import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/permission_utils.dart';
import '../../main.dart';
import '../auth/auth_provider.dart';
import '../auth/auth_state.dart';

enum BmMenuHistoryType {
  all('all'),
  service('service'),
  cancellation('cancellation'),
  staffMeal('staff_meal');

  const BmMenuHistoryType(this.wireValue);
  final String wireValue;
}

final bmMenuHistoryRoleProvider = Provider<String?>((ref) {
  return ref.watch(authProvider).role;
});

class BmMenuExceptionHistoryItem {
  const BmMenuExceptionHistoryItem({
    required this.sourceKind,
    required this.eventType,
    required this.eventId,
    required this.eventAt,
    required this.storeId,
    required this.storeName,
    required this.orderId,
    required this.itemName,
    required this.actorName,
    required this.currentState,
    required this.dataIncomplete,
    this.orderCreatedAt,
    this.tableNumber,
    this.quantity,
    this.unitPrice,
    this.referenceAmount,
    this.cancelledAmount,
    this.isServiceItem = false,
    this.reason,
    this.originalEventId,
  });

  final String sourceKind;
  final String eventType;
  final String eventId;
  final DateTime eventAt;
  final String storeId;
  final String storeName;
  final String orderId;
  final DateTime? orderCreatedAt;
  final String? tableNumber;
  final String itemName;
  final double? quantity;
  final double? unitPrice;
  final double? referenceAmount;
  final double? cancelledAmount;
  final bool isServiceItem;
  final String actorName;
  final String? reason;
  final String currentState;
  final String? originalEventId;
  final bool dataIncomplete;

  factory BmMenuExceptionHistoryItem.fromJson(Map<String, dynamic> json) {
    return BmMenuExceptionHistoryItem(
      sourceKind: json['source_kind']?.toString() ?? '',
      eventType: json['event_type']?.toString() ?? '',
      eventId: json['event_id']?.toString() ?? '',
      eventAt: DateTime.parse(json['event_at'].toString()).toUtc(),
      storeId: json['store_id']?.toString() ?? '',
      storeName: json['store_name']?.toString() ?? 'Unknown store',
      orderId: json['order_id']?.toString() ?? '',
      orderCreatedAt: _dateTimeOrNull(json['order_created_at']),
      tableNumber: _textOrNull(json['table_number']),
      itemName: json['item_name']?.toString() ?? 'Unknown item',
      quantity: _doubleOrNull(json['quantity']),
      unitPrice: _doubleOrNull(json['unit_price']),
      referenceAmount: _doubleOrNull(json['reference_amount']),
      cancelledAmount: _doubleOrNull(json['cancelled_amount']),
      isServiceItem: json['is_service_item'] == true,
      actorName: json['actor_name']?.toString() ?? 'Unknown actor',
      reason: _textOrNull(json['reason']),
      currentState: json['current_state']?.toString() ?? 'unknown',
      originalEventId: _textOrNull(json['original_event_id']),
      dataIncomplete: json['data_incomplete'] == true,
    );
  }
}

class BmMenuExceptionHistorySummary {
  const BmMenuExceptionHistorySummary({
    required this.totalRows,
    required this.serviceEventCount,
    required this.serviceQuantity,
    required this.serviceReferenceAmount,
    required this.cancellationEventCount,
    required this.cancelledQuantity,
    required this.cancelledAmount,
    required this.staffMealEventCount,
    required this.staffMealQuantity,
    required this.staffMealReferenceAmount,
    required this.reversalEventCount,
  });

  final int totalRows;
  final int serviceEventCount;
  final double serviceQuantity;
  final double serviceReferenceAmount;
  final int cancellationEventCount;
  final double cancelledQuantity;
  final double cancelledAmount;
  final int staffMealEventCount;
  final double staffMealQuantity;
  final double staffMealReferenceAmount;
  final int reversalEventCount;

  factory BmMenuExceptionHistorySummary.fromJson(Map<String, dynamic> json) {
    return BmMenuExceptionHistorySummary(
      totalRows: _intValue(json['total_rows']),
      serviceEventCount: _intValue(json['service_event_count']),
      serviceQuantity: _doubleValue(json['service_quantity']),
      serviceReferenceAmount: _doubleValue(json['service_reference_amount']),
      cancellationEventCount: _intValue(json['cancellation_event_count']),
      cancelledQuantity: _doubleValue(json['cancelled_quantity']),
      cancelledAmount: _doubleValue(json['cancelled_amount']),
      staffMealEventCount: _intValue(json['staff_meal_event_count']),
      staffMealQuantity: _doubleValue(json['staff_meal_quantity']),
      staffMealReferenceAmount: _doubleValue(
        json['staff_meal_reference_amount'],
      ),
      reversalEventCount: _intValue(json['reversal_event_count']),
    );
  }
}

class BmMenuExceptionHistoryPage {
  const BmMenuExceptionHistoryPage({
    required this.items,
    required this.summary,
    required this.page,
    required this.pageSize,
    required this.hasMore,
    required this.fetchedAt,
  });

  final List<BmMenuExceptionHistoryItem> items;
  final BmMenuExceptionHistorySummary summary;
  final int page;
  final int pageSize;
  final bool hasMore;
  final DateTime fetchedAt;

  factory BmMenuExceptionHistoryPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return BmMenuExceptionHistoryPage(
      items: rawItems is List
          ? rawItems
                .whereType<Map>()
                .map(
                  (item) => BmMenuExceptionHistoryItem.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList(growable: false)
          : const [],
      summary: BmMenuExceptionHistorySummary.fromJson(
        json['summary'] is Map
            ? Map<String, dynamic>.from(json['summary'] as Map)
            : const {},
      ),
      page: _intValue(json['page']),
      pageSize: _intValue(json['page_size']),
      hasMore: json['has_more'] == true,
      fetchedAt: _dateTimeOrNull(json['fetched_at']) ?? DateTime.now().toUtc(),
    );
  }
}

abstract interface class BmMenuExceptionHistoryLoader {
  Future<BmMenuExceptionHistoryPage> fetch({
    required DateTime startDate,
    required DateTime endDate,
    required BmMenuHistoryType historyType,
    required bool includeReversals,
    required int page,
    String? storeId,
    String? search,
    DateTime? snapshotAt,
  });
}

class BmMenuExceptionHistoryService implements BmMenuExceptionHistoryLoader {
  const BmMenuExceptionHistoryService(this._client);

  final SupabaseClient _client;

  @override
  Future<BmMenuExceptionHistoryPage> fetch({
    required DateTime startDate,
    required DateTime endDate,
    required BmMenuHistoryType historyType,
    required bool includeReversals,
    required int page,
    String? storeId,
    String? search,
    DateTime? snapshotAt,
  }) async {
    final response = await _client.rpc(
      'get_bm_menu_exception_history',
      params: {
        'p_store_id': storeId,
        'p_start_at': _hoChiMinhDayStartUtc(startDate).toIso8601String(),
        'p_end_at': _hoChiMinhDayStartUtc(
          endDate.add(const Duration(days: 1)),
        ).toIso8601String(),
        'p_history_type': historyType.wireValue,
        'p_include_reversals': includeReversals,
        'p_search': _textOrNull(search),
        'p_snapshot_at': snapshotAt?.toUtc().toIso8601String(),
        'p_page': page,
        'p_page_size': 50,
      },
    );
    if (response is! Map) {
      throw const FormatException('BM menu history response is invalid.');
    }
    return BmMenuExceptionHistoryPage.fromJson(
      Map<String, dynamic>.from(response),
    );
  }
}

class BmMenuExceptionHistoryScreen extends ConsumerStatefulWidget {
  const BmMenuExceptionHistoryScreen({
    super.key,
    required this.stores,
    required this.initialStartDate,
    required this.initialEndDate,
    this.initialStoreId,
    this.service,
  });

  final List<AccessibleStore> stores;
  final DateTime initialStartDate;
  final DateTime initialEndDate;
  final String? initialStoreId;
  final BmMenuExceptionHistoryLoader? service;

  @override
  ConsumerState<BmMenuExceptionHistoryScreen> createState() =>
      _BmMenuExceptionHistoryScreenState();
}

class _BmMenuExceptionHistoryScreenState
    extends ConsumerState<BmMenuExceptionHistoryScreen> {
  late DateTime _startDate;
  late DateTime _endDate;
  late String _storeValue;
  final _searchController = TextEditingController();
  BmMenuHistoryType _historyType = BmMenuHistoryType.all;
  bool _includeReversals = true;
  bool _loading = false;
  Object? _error;
  BmMenuExceptionHistoryPage? _result;
  DateTime? _snapshotAt;
  int _page = 0;

  BmMenuExceptionHistoryLoader get _service =>
      widget.service ?? BmMenuExceptionHistoryService(supabase);

  @override
  void initState() {
    super.initState();
    _startDate = DateUtils.dateOnly(widget.initialStartDate);
    _endDate = DateUtils.dateOnly(widget.initialEndDate);
    _storeValue =
        widget.stores.any((store) => store.id == widget.initialStoreId)
        ? widget.initialStoreId!
        : '';
    if (PermissionUtils.canViewServiceCancellationHistory(
      ref.read(bmMenuHistoryRoleProvider),
    )) {
      Future<void>.microtask(_load);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({bool resetPage = false}) async {
    if (resetPage) {
      _page = 0;
      _snapshotAt = null;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _service.fetch(
        startDate: _startDate,
        endDate: _endDate,
        historyType: _historyType,
        includeReversals: _includeReversals,
        page: _page,
        storeId: _storeValue.isEmpty ? null : _storeValue,
        search: _searchController.text,
        snapshotAt: _snapshotAt,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _snapshotAt = result.fetchedAt;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickDate({required bool start}) async {
    final todayInVietnam = _vnTime(DateTime.now().toUtc());
    final picked = await showDatePicker(
      context: context,
      initialDate: start ? _startDate : _endDate,
      firstDate: DateTime(2020),
      lastDate: DateUtils.dateOnly(todayInVietnam),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (start) {
        _startDate = picked;
        if (_endDate.isBefore(picked)) _endDate = picked;
      } else {
        _endDate = picked;
        if (_startDate.isAfter(picked)) _startDate = picked;
      }
    });
  }

  void _applyQuickRange(DateTime start, DateTime end) {
    setState(() {
      _startDate = DateUtils.dateOnly(start);
      _endDate = DateUtils.dateOnly(end);
    });
    _load(resetPage: true);
  }

  void _selectHistoryType(BmMenuHistoryType nextType) {
    if (_loading || nextType == _historyType) return;
    setState(() => _historyType = nextType);
    _load(resetPage: true);
  }

  void _showDetails(BmMenuExceptionHistoryItem item, _BmHistoryCopy copy) {
    final money = NumberFormat('#,###', 'vi_VN');
    final dateTime = DateFormat('dd/MM/yyyy HH:mm');
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.82,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ListView(
            key: const Key('bm_menu_history_detail'),
            children: [
              Text(
                copy.eventLabel(item.eventType),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              _detailRow(
                copy.eventTime,
                dateTime.format(_vnTime(item.eventAt)),
              ),
              _detailRow(copy.store, item.storeName),
              _detailRow(copy.order, _shortId(item.orderId)),
              _detailRow(copy.table, item.tableNumber ?? copy.notRecorded),
              _detailRow(copy.item, item.itemName),
              _detailRow(copy.quantity, _quantity(item.quantity)),
              _detailRow(
                copy.unitPrice,
                _moneyOrMissing(money, item.unitPrice, copy),
              ),
              _detailRow(
                copy.referenceAmount,
                _moneyOrMissing(money, item.referenceAmount, copy),
              ),
              if (item.sourceKind == 'cancellation')
                _detailRow(
                  copy.cancelledAmount,
                  _moneyOrMissing(money, item.cancelledAmount, copy),
                ),
              _detailRow(copy.actor, item.actorName),
              _detailRow(copy.reason, item.reason ?? copy.notRecorded),
              _detailRow(copy.currentState, copy.stateLabel(item.currentState)),
              if (item.dataIncomplete) ...[
                const SizedBox(height: 12),
                Text(
                  copy.incompleteNotice,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(copy.close),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final copy = _BmHistoryCopy(Localizations.localeOf(context).languageCode);
    final role = ref.watch(bmMenuHistoryRoleProvider);
    if (!PermissionUtils.canViewServiceCancellationHistory(role)) {
      return Scaffold(
        appBar: AppBar(title: Text(copy.title)),
        body: Center(child: Text(copy.forbidden)),
      );
    }

    final result = _result;
    final isNarrow = MediaQuery.sizeOf(context).width < 600;
    return Scaffold(
      key: const Key('bm_menu_exception_history_screen'),
      appBar: AppBar(
        title: Text(copy.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: copy.refresh,
            onPressed: _loading ? null : () => _load(resetPage: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (isNarrow)
              Flexible(
                flex: 2,
                fit: FlexFit.loose,
                child: SingleChildScrollView(child: _buildFilters(copy)),
              )
            else
              _buildFilters(copy),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              flex: isNarrow ? 3 : 1,
              child: _error != null
                  ? _buildError(copy)
                  : result == null
                  ? const Center(child: CircularProgressIndicator())
                  : _buildResults(result, copy),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilters(_BmHistoryCopy copy) {
    final date = DateFormat('dd/MM/yyyy');
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    label: Text(copy.today),
                    onPressed: _loading
                        ? null
                        : () {
                            final now = _vnTime(DateTime.now().toUtc());
                            _applyQuickRange(now, now);
                          },
                  ),
                  ActionChip(
                    label: Text(copy.thisWeek),
                    onPressed: _loading
                        ? null
                        : () {
                            final now = _vnTime(DateTime.now().toUtc());
                            _applyQuickRange(
                              now.subtract(Duration(days: now.weekday - 1)),
                              now,
                            );
                          },
                  ),
                  ActionChip(
                    label: Text(copy.thisMonth),
                    onPressed: _loading
                        ? null
                        : () {
                            final now = _vnTime(DateTime.now().toUtc());
                            _applyQuickRange(
                              DateTime(now.year, now.month),
                              now,
                            );
                          },
                  ),
                  ActionChip(
                    label: Text(copy.allPeriod),
                    onPressed: _loading
                        ? null
                        : () => _applyQuickRange(
                            DateTime(2020),
                            _vnTime(DateTime.now().toUtc()),
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 600) {
                  return Wrap(
                    key: const Key('bm_menu_history_type_filter'),
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final type in BmMenuHistoryType.values)
                        ChoiceChip(
                          key: ValueKey(
                            'bm_menu_history_type_${type.wireValue}',
                          ),
                          label: Text(copy.typeLabel(type)),
                          selected: type == _historyType,
                          onSelected: _loading
                              ? null
                              : (selected) {
                                  if (selected) _selectHistoryType(type);
                                },
                        ),
                    ],
                  );
                }
                return SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<BmMenuHistoryType>(
                    key: const Key('bm_menu_history_type_filter'),
                    segments: [
                      for (final type in BmMenuHistoryType.values)
                        ButtonSegment<BmMenuHistoryType>(
                          value: type,
                          label: Text(
                            copy.typeLabel(type),
                            key: ValueKey(
                              'bm_menu_history_type_${type.wireValue}',
                            ),
                          ),
                        ),
                    ],
                    selected: {_historyType},
                    showSelectedIcon: false,
                    onSelectionChanged: _loading
                        ? null
                        : (selection) => _selectHistoryType(selection.single),
                  ),
                );
              },
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<String>(
                    key: const Key('bm_menu_history_store_filter'),
                    initialValue: _storeValue,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: copy.store,
                      isDense: true,
                    ),
                    items: [
                      DropdownMenuItem(value: '', child: Text(copy.allStores)),
                      for (final store in widget.stores)
                        DropdownMenuItem(
                          value: store.id,
                          child: Text(
                            store.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _loading
                        ? null
                        : (value) => setState(() => _storeValue = value ?? ''),
                  ),
                ),
                OutlinedButton.icon(
                  key: const Key('bm_menu_history_start_date'),
                  onPressed: _loading ? null : () => _pickDate(start: true),
                  icon: const Icon(Icons.event_outlined, size: 18),
                  label: Text('${copy.from} ${date.format(_startDate)}'),
                ),
                OutlinedButton.icon(
                  key: const Key('bm_menu_history_end_date'),
                  onPressed: _loading ? null : () => _pickDate(start: false),
                  icon: const Icon(Icons.event_available_outlined, size: 18),
                  label: Text('${copy.to} ${date.format(_endDate)}'),
                ),
                SizedBox(
                  width: 260,
                  child: TextField(
                    key: const Key('bm_menu_history_search'),
                    controller: _searchController,
                    maxLength: 100,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      labelText: copy.search,
                      isDense: true,
                      counterText: '',
                      prefixIcon: const Icon(Icons.search, size: 20),
                    ),
                    onSubmitted: (_) => _load(resetPage: true),
                  ),
                ),
                FilterChip(
                  key: const Key('bm_menu_history_include_reversals'),
                  selected: _includeReversals,
                  label: Text(copy.includeReversals),
                  onSelected: _loading
                      ? null
                      : (value) => setState(() => _includeReversals = value),
                ),
                FilledButton.icon(
                  key: const Key('bm_menu_history_lookup'),
                  onPressed: _loading ? null : () => _load(resetPage: true),
                  icon: const Icon(Icons.search, size: 18),
                  label: Text(copy.lookup),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                copy.scopeNotice,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(_BmHistoryCopy copy) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            Text(copy.errorMessage(_error!), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: Text(copy.retry)),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(BmMenuExceptionHistoryPage result, _BmHistoryCopy copy) {
    final money = NumberFormat('#,###', 'vi_VN');
    final dateTime = DateFormat('dd/MM/yyyy HH:mm');
    final isNarrow = MediaQuery.sizeOf(context).width < 600;
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              _summaryCard(
                copy.serviceEvents,
                '${result.summary.serviceEventCount}',
              ),
              _summaryCard(
                copy.serviceAmount,
                '${money.format(result.summary.serviceReferenceAmount)} VND',
              ),
              _summaryCard(
                copy.cancellationEvents,
                '${result.summary.cancellationEventCount}',
              ),
              _summaryCard(
                copy.cancelledAmount,
                '${money.format(result.summary.cancelledAmount)} VND',
              ),
              _summaryCard(
                copy.staffMealEvents,
                '${result.summary.staffMealEventCount}',
              ),
              _summaryCard(
                copy.staffMealAmount,
                '${money.format(result.summary.staffMealReferenceAmount)} VND',
              ),
              _summaryCard(
                copy.reversalEvents,
                '${result.summary.reversalEventCount}',
              ),
              _summaryCard(copy.totalRows, '${result.summary.totalRows}'),
            ],
          ),
        ),
        Expanded(
          child: result.items.isEmpty
              ? Center(child: Text(copy.empty))
              : ListView.separated(
                  key: const Key('bm_menu_history_list'),
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  itemCount: result.items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final item = result.items[index];
                    final amount = item.sourceKind == 'cancellation'
                        ? item.cancelledAmount
                        : item.referenceAmount;
                    final icon = switch (item.sourceKind) {
                      'service' => Icons.redeem_outlined,
                      'staff_meal' => Icons.restaurant_outlined,
                      _ => Icons.cancel_outlined,
                    };
                    final subtitle =
                        '${copy.eventLabel(item.eventType)} · '
                        '${item.storeName} · '
                        '${dateTime.format(_vnTime(item.eventAt))}\n'
                        '${copy.quantity} ${_quantity(item.quantity)} · '
                        '${copy.actor} ${item.actorName} · '
                        '${copy.currentState} ${copy.stateLabel(item.currentState)}';
                    if (isNarrow) {
                      return Card(
                        margin: EdgeInsets.zero,
                        child: InkWell(
                          onTap: () => _showDetails(item, copy),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Icon(icon),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        item.itemName,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(subtitle),
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    _moneyOrMissing(money, amount, copy),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }
                    return Card(
                      margin: EdgeInsets.zero,
                      child: ListTile(
                        key: ValueKey(
                          'bm_menu_history_${item.eventId}_${item.eventType}_$index',
                        ),
                        leading: CircleAvatar(child: Icon(icon)),
                        title: Text(item.itemName),
                        subtitle: Text(subtitle),
                        isThreeLine: true,
                        trailing: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 150),
                          child: Text(
                            _moneyOrMissing(money, amount, copy),
                            textAlign: TextAlign.end,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        onTap: () => _showDetails(item, copy),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              if (isNarrow)
                IconButton.outlined(
                  key: const Key('bm_menu_history_previous_page'),
                  tooltip: copy.previous,
                  onPressed: _loading || _page == 0
                      ? null
                      : () {
                          setState(() => _page--);
                          _load();
                        },
                  icon: const Icon(Icons.chevron_left),
                )
              else
                OutlinedButton.icon(
                  key: const Key('bm_menu_history_previous_page'),
                  onPressed: _loading || _page == 0
                      ? null
                      : () {
                          setState(() => _page--);
                          _load();
                        },
                  icon: const Icon(Icons.chevron_left),
                  label: Text(copy.previous),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(copy.page(_page + 1)),
              ),
              if (isNarrow)
                IconButton.outlined(
                  key: const Key('bm_menu_history_next_page'),
                  tooltip: copy.next,
                  onPressed: _loading || !result.hasMore
                      ? null
                      : () {
                          setState(() => _page++);
                          _load();
                        },
                  icon: const Icon(Icons.chevron_right),
                )
              else
                OutlinedButton.icon(
                  key: const Key('bm_menu_history_next_page'),
                  onPressed: _loading || !result.hasMore
                      ? null
                      : () {
                          setState(() => _page++);
                          _load();
                        },
                  icon: const Icon(Icons.chevron_right),
                  label: Text(copy.next),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _summaryCard(String label, String value) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 2),
            Text(value, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}

class _BmHistoryCopy {
  const _BmHistoryCopy(this.languageCode);
  final String languageCode;

  String pick(String ko, String vi, String en) => switch (languageCode) {
    'vi' => vi,
    'en' => en,
    _ => ko,
  };

  String get title => pick(
    '서비스·취소·직원식사 메뉴 내역',
    'Lịch sử món phục vụ, hủy và bữa ăn nhân viên',
    'Service, cancelled, and staff-meal menu history',
  );
  String get forbidden => pick(
    'BM 권한만 이 내역을 조회할 수 있습니다.',
    'Chỉ BM mới có thể xem lịch sử này.',
    'Only BM accounts can view this history.',
  );
  String get allStores => pick('전체 매장', 'Tất cả cửa hàng', 'All stores');
  String get today => pick('오늘', 'Hôm nay', 'Today');
  String get thisWeek => pick('이번 주', 'Tuần này', 'This week');
  String get thisMonth => pick('이번 달', 'Tháng này', 'This month');
  String get allPeriod => pick('전체 기간', 'Toàn bộ', 'All time');
  String get store => pick('매장', 'Cửa hàng', 'Store');
  String get from => pick('시작', 'Từ', 'From');
  String get to => pick('종료', 'Đến', 'To');
  String get search => pick(
    '메뉴·주문·처리자 검색',
    'Tìm món, đơn, người xử lý',
    'Search item, order, actor',
  );
  String get includeReversals =>
      pick('해제·복구 포함', 'Gồm bỏ phục vụ và khôi phục', 'Include reversals');
  String get lookup => pick('조회', 'Tra cứu', 'Search');
  String get refresh => pick('새로고침', 'Làm mới', 'Refresh');
  String get retry => pick('다시 시도', 'Thử lại', 'Retry');
  String get close => pick('닫기', 'Đóng', 'Close');
  String get empty => pick(
    '선택한 조건의 내역이 없습니다.',
    'Không có lịch sử phù hợp.',
    'No history matches the selected filters.',
  );
  String get scopeNotice => pick(
    'POS 주문 메뉴 기준입니다. 접수 전 직접배달 요청 취소·거절은 포함하지 않습니다.',
    'Dữ liệu dựa trên món POS; không gồm yêu cầu giao trực tiếp bị hủy hoặc từ chối trước khi nhận.',
    'Based on POS order items; direct-delivery requests cancelled or rejected before acceptance are excluded.',
  );
  String get serviceEvents => pick('서비스 처리', 'Lần phục vụ', 'Service events');
  String get serviceAmount =>
      pick('서비스 기준금액', 'Giá trị món phục vụ', 'Service reference amount');
  String get cancellationEvents =>
      pick('취소 처리', 'Lần hủy', 'Cancellation events');
  String get cancelledAmount => pick('취소금액', 'Số tiền hủy', 'Cancelled amount');
  String get staffMealEvents =>
      pick('직원식사 주문', 'Đơn ăn nhân viên', 'Staff-meal orders');
  String get staffMealAmount => pick(
    '직원식사 기준금액',
    'Giá trị bữa ăn nhân viên',
    'Staff-meal reference amount',
  );
  String get reversalEvents => pick('해제·복구', 'Bỏ/khôi phục', 'Reversals');
  String get totalRows => pick('메뉴 행', 'Dòng món', 'Menu rows');
  String get previous => pick('이전', 'Trước', 'Previous');
  String get next => pick('다음', 'Tiếp', 'Next');
  String page(int page) => pick('$page 페이지', 'Trang $page', 'Page $page');
  String get eventTime => pick('처리 시각', 'Thời gian xử lý', 'Event time');
  String get order => pick('주문', 'Đơn hàng', 'Order');
  String get table => pick('테이블', 'Bàn', 'Table');
  String get item => pick('메뉴', 'Món', 'Item');
  String get quantity => pick('수량', 'Số lượng', 'Quantity');
  String get unitPrice => pick('단가', 'Đơn giá', 'Unit price');
  String get referenceAmount =>
      pick('기준금액', 'Giá trị tham chiếu', 'Reference amount');
  String get actor => pick('처리자', 'Người xử lý', 'Actor');
  String get reason => pick('사유', 'Lý do', 'Reason');
  String get currentState =>
      pick('현재 상태', 'Trạng thái hiện tại', 'Current state');
  String get notRecorded => pick('기록 없음', 'Không có dữ liệu', 'Not recorded');
  String get incompleteNotice => pick(
    '과거 기록의 일부 상세 정보가 저장되어 있지 않습니다.',
    'Một số chi tiết không được lưu trong dữ liệu cũ.',
    'Some details were not stored in the historical record.',
  );

  String typeLabel(BmMenuHistoryType type) => switch (type) {
    BmMenuHistoryType.all => pick('전체', 'Tất cả', 'All'),
    BmMenuHistoryType.service => pick('서비스', 'Phục vụ', 'Service'),
    BmMenuHistoryType.cancellation => pick('취소', 'Hủy', 'Cancellation'),
    BmMenuHistoryType.staffMeal => pick(
      '직원식사',
      'Bữa ăn nhân viên',
      'Staff meal',
    ),
  };

  String eventLabel(String type) => switch (type) {
    'service_marked' => pick('서비스 처리', 'Đánh dấu phục vụ', 'Marked as service'),
    'service_unmarked' => pick('서비스 해제', 'Bỏ phục vụ', 'Service removed'),
    'order_cancelled' => pick('주문 전체 취소', 'Hủy toàn bộ đơn', 'Order cancelled'),
    'item_cancelled' => pick('메뉴 취소', 'Hủy món', 'Item cancelled'),
    'order_restored' => pick('주문 복구', 'Khôi phục đơn', 'Order restored'),
    'item_restored' => pick('메뉴 복구', 'Khôi phục món', 'Item restored'),
    'staff_meal_created' => pick(
      '직원식사 생성',
      'Tạo bữa ăn nhân viên',
      'Staff meal created',
    ),
    _ => type,
  };

  String stateLabel(String state) => switch (state) {
    'service' => pick('서비스 유지', 'Đang phục vụ', 'Service active'),
    'charged' => pick('서비스 해제됨', 'Đã bỏ phục vụ', 'Service removed'),
    'cancelled' => pick('취소 유지', 'Vẫn bị hủy', 'Still cancelled'),
    'restored' => pick('복구됨', 'Đã khôi phục', 'Restored'),
    'cancelled_again' => pick('다시 취소됨', 'Đã hủy lại', 'Cancelled again'),
    'changed' => pick('이후 변경됨', 'Đã thay đổi sau đó', 'Changed later'),
    'staff_meal_pending' => pick('접수 대기', 'Đang chờ', 'Pending'),
    'staff_meal_confirmed' => pick('접수됨', 'Đã xác nhận', 'Confirmed'),
    'staff_meal_serving' => pick('제공 중', 'Đang phục vụ', 'Serving'),
    'staff_meal_completed' => pick('완료', 'Hoàn tất', 'Completed'),
    'staff_meal_cancelled' => pick('취소됨', 'Đã hủy', 'Cancelled'),
    'staff_meal_item_cancelled' => pick(
      '메뉴 취소됨',
      'Món đã hủy',
      'Item cancelled',
    ),
    _ => pick('확인 불가', 'Không xác định', 'Unknown'),
  };

  String errorMessage(Object error) {
    final text = error is PostgrestException ? error.message : error.toString();
    if (text.contains('BM_MENU_HISTORY_FORBIDDEN')) return forbidden;
    if (text.contains('BM_MENU_HISTORY_RANGE_INVALID')) {
      return pick(
        '조회 기간을 확인하세요.',
        'Kiểm tra khoảng ngày.',
        'Check the date range.',
      );
    }
    return pick(
      '내역을 불러오지 못했습니다.',
      'Không thể tải lịch sử.',
      'Failed to load history.',
    );
  }
}

Widget _detailRow(String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 132, child: Text(label)),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}

DateTime _hoChiMinhDayStartUtc(DateTime date) {
  return DateTime.utc(
    date.year,
    date.month,
    date.day,
  ).subtract(const Duration(hours: 7));
}

DateTime _vnTime(DateTime value) => value.toUtc().add(const Duration(hours: 7));

String _shortId(String value) =>
    value.length <= 8 ? value : value.substring(0, 8);

String _quantity(double? value) {
  if (value == null) return '-';
  return value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(2);
}

String _moneyOrMissing(
  NumberFormat formatter,
  double? value,
  _BmHistoryCopy copy,
) => value == null ? copy.notRecorded : '${formatter.format(value)} VND';

String? _textOrNull(dynamic value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

DateTime? _dateTimeOrNull(dynamic value) {
  final text = _textOrNull(value);
  return text == null ? null : DateTime.tryParse(text)?.toUtc();
}

double? _doubleOrNull(dynamic value) => switch (value) {
  num number => number.toDouble(),
  String text => double.tryParse(text),
  _ => null,
};

double _doubleValue(dynamic value) => _doubleOrNull(value) ?? 0;

int _intValue(dynamic value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};
