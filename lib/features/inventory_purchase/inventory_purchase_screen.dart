import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../auth/auth_provider.dart';
import '../inventory/inventory_provider.dart';
import 'inventory_purchase_document_service.dart';

class InventoryPurchaseScreen extends ConsumerStatefulWidget {
  const InventoryPurchaseScreen({super.key});

  @override
  ConsumerState<InventoryPurchaseScreen> createState() =>
      _InventoryPurchaseScreenState();
}

class _InventoryPurchaseScreenState
    extends ConsumerState<InventoryPurchaseScreen> {
  int _selectedIndex = 0;
  String? _loadedStoreId;
  String? _printingOrderId;
  String? _selectedSupplierId;
  String? _selectedProductId;

  static const _sections = <_InventoryPurchaseSection>[
    _InventoryPurchaseSection(
      label: '대시보드',
      subtitle: '매장별 재고와 발주 현황',
      icon: Icons.dashboard_outlined,
    ),
    _InventoryPurchaseSection(
      label: '재고 현황',
      subtitle: '정상/주의/부족 재고',
      icon: Icons.inventory_2_outlined,
    ),
    _InventoryPurchaseSection(
      label: '발주 관리',
      subtitle: '추천 발주와 수량 조정',
      icon: Icons.shopping_cart_outlined,
    ),
    _InventoryPurchaseSection(
      label: '발주 내역',
      subtitle: '진행 상태와 상세 이력',
      icon: Icons.receipt_long_outlined,
    ),
    _InventoryPurchaseSection(
      label: '거래처 관리',
      subtitle: '공급처와 계약 기준',
      icon: Icons.storefront_outlined,
    ),
    _InventoryPurchaseSection(
      label: '제품 관리',
      subtitle: '제품 코드와 단위',
      icon: Icons.category_outlined,
    ),
    _InventoryPurchaseSection(
      label: '레시피 관리',
      subtitle: '메뉴별 재료 소진',
      icon: Icons.menu_book_outlined,
    ),
    _InventoryPurchaseSection(
      label: '소진량 분석',
      subtitle: '판매 기반 소진 추이',
      icon: Icons.show_chart,
    ),
    _InventoryPurchaseSection(
      label: '원가 분석',
      subtitle: '식재료 원가와 원가율',
      icon: Icons.paid_outlined,
    ),
    _InventoryPurchaseSection(
      label: '실재고 실사',
      subtitle: '실사 진행과 차이 분석',
      icon: Icons.fact_check_outlined,
    ),
    _InventoryPurchaseSection(
      label: '신메뉴 등록',
      subtitle: '레시피 등록 과정',
      icon: Icons.add_box_outlined,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final storeId = auth.storeId;
    _scheduleStoreLoad(storeId);

    final overview = ref.watch(inventoryPurchaseOverviewProvider);
    final stockStatus = ref.watch(inventoryPurchaseStockStatusProvider);
    final snapshot = ref.watch(inventoryPurchaseRecommendationSnapshotProvider);
    final orders = ref.watch(inventoryPurchaseOrderSummaryProvider);
    final orderDetail = ref.watch(inventoryPurchaseOrderDetailProvider);
    final supplierCatalog = ref.watch(inventoryPurchaseSupplierCatalogProvider);
    final productCatalog = ref.watch(inventoryPurchaseProductCatalogProvider);
    final recipeState = ref.watch(recipeProvider);
    final newMenuState = ref.watch(inventoryPurchaseNewMenuProvider);
    final receivingRuntime = ref.watch(
      inventoryPurchaseReceivingRuntimeProvider,
    );
    final stockAuditState = ref.watch(inventoryPurchaseStockAuditProvider);
    final costAnalysis = ref.watch(inventoryPurchaseCostAnalysisProvider);
    final runState = ref.watch(inventoryPurchaseRecommendationRunProvider);
    final adjustmentState = ref.watch(
      inventoryPurchaseRecommendationAdjustmentProvider,
    );
    final creationState = ref.watch(inventoryPurchaseOrderCreationProvider);

    return ToastResponsiveBody(
      maxWidth: 1500,
      padding: const EdgeInsets.all(ToastSpacingTokens.lg),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 1080;
          final content = _buildSelectedPage(
            storeId: storeId,
            overview: overview,
            stockStatus: stockStatus,
            snapshot: snapshot,
            orders: orders,
            orderDetail: orderDetail,
            supplierCatalog: supplierCatalog,
            productCatalog: productCatalog,
            recipeState: recipeState,
            newMenuState: newMenuState,
            receivingRuntime: receivingRuntime,
            stockAuditState: stockAuditState,
            costAnalysis: costAnalysis,
            runState: runState,
            adjustmentState: adjustmentState,
            creationState: creationState,
          );

          if (compact) {
            return Column(
              children: [
                _buildSectionRail(horizontal: true),
                const SizedBox(height: ToastSpacingTokens.md),
                Expanded(child: content),
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 214, child: _buildSectionRail()),
              const SizedBox(width: ToastSpacingTokens.md),
              Expanded(child: content),
            ],
          );
        },
      ),
    );
  }

  void _scheduleStoreLoad(String? storeId) {
    if (storeId == null || storeId == _loadedStoreId) {
      return;
    }
    _loadedStoreId = storeId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reloadStoreScope(storeId);
    });
  }

  Future<void> _reloadStoreScope(String storeId) async {
    await Future.wait([
      ref.read(inventoryPurchaseOverviewProvider.notifier).load(storeId),
      ref.read(inventoryPurchaseStockStatusProvider.notifier).load(storeId),
      ref.read(inventoryPurchaseSupplierCatalogProvider.notifier).load(storeId),
      ref.read(inventoryPurchaseProductCatalogProvider.notifier).load(storeId),
      ref.read(recipeProvider.notifier).loadAll(storeId),
      ref
          .read(inventoryPurchaseNewMenuProvider.notifier)
          .loadCategories(storeId),
      ref.read(inventoryPurchaseCostAnalysisProvider.notifier).load(storeId),
      ref
          .read(inventoryPurchaseRecommendationSnapshotProvider.notifier)
          .loadLatest(storeId),
      ref.read(inventoryPurchaseOrderSummaryProvider.notifier).load(storeId),
    ]);
  }

  Widget _buildSectionRail({bool horizontal = false}) {
    final items = <Widget>[
      for (var index = 0; index < _sections.length; index++)
        _SectionRailItem(
          section: _sections[index],
          selected: index == _selectedIndex,
          onTap: () => setState(() => _selectedIndex = index),
        ),
    ];

    if (horizontal) {
      return SizedBox(
        height: 76,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: items.length,
          separatorBuilder: (_, __) =>
              const SizedBox(width: ToastSpacingTokens.sm),
          itemBuilder: (_, index) => SizedBox(width: 168, child: items[index]),
        ),
      );
    }

    return ToastWorkSurface(
      padding: const EdgeInsets.all(ToastSpacingTokens.sm),
      child: ListView.separated(
        itemCount: items.length,
        separatorBuilder: (_, __) =>
            const SizedBox(height: ToastSpacingTokens.xs),
        itemBuilder: (_, index) => items[index],
      ),
    );
  }

  Widget _buildSelectedPage({
    required String? storeId,
    required InventoryPurchaseOverviewState overview,
    required InventoryPurchaseStockStatusState stockStatus,
    required InventoryPurchaseRecommendationSnapshotState snapshot,
    required InventoryPurchaseOrderSummaryState orders,
    required InventoryPurchaseOrderDetailState orderDetail,
    required InventoryPurchaseSupplierCatalogState supplierCatalog,
    required InventoryPurchaseProductCatalogState productCatalog,
    required RecipeState recipeState,
    required InventoryPurchaseNewMenuState newMenuState,
    required InventoryPurchaseReceivingRuntimeState receivingRuntime,
    required InventoryPurchaseStockAuditState stockAuditState,
    required InventoryPurchaseCostAnalysisState costAnalysis,
    required InventoryPurchaseRecommendationRunState runState,
    required InventoryPurchaseRecommendationAdjustmentState adjustmentState,
    required InventoryPurchaseOrderCreationState creationState,
  }) {
    if (storeId == null) {
      return _EmptyWorkspace(
        title: '매장 선택 필요',
        subtitle: '재고/발주 데이터를 불러올 매장을 먼저 선택해야 합니다.',
        icon: Icons.store_outlined,
      );
    }

    return switch (_selectedIndex) {
      0 => _buildDashboardPage(
        overview: overview,
        stockStatus: stockStatus,
        snapshot: snapshot,
        orders: orders,
        storeId: storeId,
      ),
      1 => _buildStockStatusPage(stockStatus),
      2 => _buildPurchaseManagementPage(
        storeId: storeId,
        snapshot: snapshot,
        supplierCatalog: supplierCatalog,
        runState: runState,
        adjustmentState: adjustmentState,
        creationState: creationState,
      ),
      3 => _buildPurchaseHistoryPage(
        storeId: storeId,
        state: orders,
        detail: orderDetail,
        receivingRuntime: receivingRuntime,
        creationState: creationState,
      ),
      4 => _buildSupplierManagementPage(
        storeId: storeId,
        supplierCatalog: supplierCatalog,
        productCatalog: productCatalog,
      ),
      5 => _buildProductManagementPage(
        storeId: storeId,
        productCatalog: productCatalog,
        supplierCatalog: supplierCatalog,
      ),
      6 => _buildRecipePage(
        storeId: storeId,
        recipeState: recipeState,
        productCatalog: productCatalog,
      ),
      7 => _buildAnalysisPage(
        storeId: storeId,
        section: _sections[7],
        title: '소진량 추이',
        stockStatus: stockStatus,
        costAnalysis: costAnalysis,
      ),
      8 => _buildCostPage(
        storeId: storeId,
        overview: overview,
        costAnalysis: costAnalysis,
      ),
      9 => _buildAuditPage(
        storeId: storeId,
        stockStatus: stockStatus,
        stockAuditState: stockAuditState,
      ),
      _ => _buildNewMenuPage(
        storeId: storeId,
        newMenuState: newMenuState,
        productCatalog: productCatalog,
        recipeState: recipeState,
      ),
    };
  }

  Widget _buildDashboardPage({
    required InventoryPurchaseOverviewState overview,
    required InventoryPurchaseStockStatusState stockStatus,
    required InventoryPurchaseRecommendationSnapshotState snapshot,
    required InventoryPurchaseOrderSummaryState orders,
    required String storeId,
  }) {
    final dashboard = overview.dashboard ?? const <String, dynamic>{};
    final riskRows = stockStatus.rows
        .where(
          (row) => {'danger', 'warning'}.contains(_string(row['risk_status'])),
        )
        .take(6)
        .toList();
    final recentOrders = orders.orders.take(6).toList();

    return _PageShell(
      title: '재고/발주 관리 대시보드',
      subtitle: 'QSC Manager 기준의 재고 현황, 추천 발주, 입고 흐름을 한 화면에서 관리합니다.',
      isLoading:
          overview.isLoading || stockStatus.isLoading || orders.isLoading,
      actions: [_RefreshButton(onPressed: () => _reloadStoreScope(storeId))],
      children: [
        ToastMetricStrip(
          metrics: [
            ToastMetric(
              label: '총 보유 재고 금액',
              value: _money(dashboard['total_inventory_amount']),
            ),
            ToastMetric(
              label: '예상 발주 금액',
              value: _money(dashboard['submitted_purchase_amount']),
              tone: ToastColorTokens.accent,
            ),
            ToastMetric(
              label: 'Office 승인 금액',
              value: _money(dashboard['approved_purchase_amount']),
              tone: ToastColorTokens.success,
            ),
            ToastMetric(
              label: '주의 재고 품목',
              value: '${_int(dashboard['low_stock_count'])}개',
              tone: ToastColorTokens.warning,
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _ResponsiveGrid(
          children: [
            _DataCard(
              title: '재고 주의 항목',
              trailing: ToastStatusBadge(
                label: '${riskRows.length}개 표시',
                color: ToastColorTokens.warning,
                compact: true,
              ),
              child: _SimpleDataTable(
                columns: const ['제품', '현재', '일소진', '상태'],
                rows: riskRows
                    .map(
                      (row) => [
                        _string(row['product_name'], fallback: '-'),
                        _displayStock(row),
                        _quantity(row['avg_daily_consumption_base']),
                        _riskLabel(row['risk_status']),
                      ],
                    )
                    .toList(),
              ),
            ),
            _DataCard(
              title: '발주 추천 현황',
              trailing: ToastStatusBadge(
                label: snapshot.run == null ? '스냅샷 없음' : '스냅샷 있음',
                color: snapshot.run == null
                    ? ToastColorTokens.textSecondary
                    : ToastColorTokens.accent,
                compact: true,
              ),
              child: _RecommendationList(
                lines: snapshot.lines.take(5).toList(),
              ),
            ),
            _DataCard(
              title: '최근 발주',
              trailing: ToastStatusBadge(
                label: '${recentOrders.length}건',
                color: ToastColorTokens.info,
                compact: true,
              ),
              child: _OrderList(orders: recentOrders),
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _QuickActionBand(
          onSelectStock: () => setState(() => _selectedIndex = 1),
          onSelectPurchase: () => setState(() => _selectedIndex = 2),
          onSelectPrint: () => setState(() => _selectedIndex = 3),
          onSelectAudit: () => setState(() => _selectedIndex = 9),
        ),
      ],
    );
  }

  Widget _buildStockStatusPage(InventoryPurchaseStockStatusState state) {
    final rows = state.rows;
    final danger = rows
        .where((row) => _string(row['risk_status']) == 'danger')
        .length;
    final warning = rows
        .where((row) => _string(row['risk_status']) == 'warning')
        .length;
    final stable = rows.length - danger - warning;

    return _PageShell(
      title: '재고 현황',
      subtitle: '현재 재고, 이론 재고 기준 소진일, 위험 상태를 제품 단위로 확인합니다.',
      isLoading: state.isLoading,
      error: state.error,
      children: [
        ToastMetricStrip(
          metrics: [
            ToastMetric(label: '전체 품목', value: '${rows.length}개'),
            ToastMetric(
              label: '정상 재고',
              value: '${stable < 0 ? 0 : stable}개',
              tone: ToastColorTokens.success,
            ),
            ToastMetric(
              label: '주의 재고',
              value: '$warning개',
              tone: ToastColorTokens.warning,
            ),
            ToastMetric(
              label: '부족 재고',
              value: '$danger개',
              tone: ToastColorTokens.danger,
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: '제품별 재고 요약',
          child: _SimpleDataTable(
            columns: const [
              '제품',
              '카테고리',
              '현재 재고',
              '4일 평균',
              '7일 평균',
              '예상 소진일',
              '상태',
            ],
            rows: rows
                .map(
                  (row) => [
                    _string(row['product_name'], fallback: '-'),
                    _string(row['category'], fallback: '-'),
                    _displayStock(row),
                    _quantity(row['recent_4_day_avg']),
                    _quantity(row['recent_7_day_avg']),
                    '${_number(row['estimated_days_remaining'])}일',
                    _riskLabel(row['risk_status']),
                  ],
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildPurchaseManagementPage({
    required String storeId,
    required InventoryPurchaseRecommendationSnapshotState snapshot,
    required InventoryPurchaseSupplierCatalogState supplierCatalog,
    required InventoryPurchaseRecommendationRunState runState,
    required InventoryPurchaseRecommendationAdjustmentState adjustmentState,
    required InventoryPurchaseOrderCreationState creationState,
  }) {
    final runId = snapshot.run?['id']?.toString();
    final canCreateOrders = runId != null && snapshot.lines.isNotEmpty;

    return _PageShell(
      title: '발주 관리',
      subtitle: '최근 4일 70%와 최근 7일 30% 기준의 추천 발주를 실행하고 공급처별 발주를 생성합니다.',
      isLoading: snapshot.isLoading || adjustmentState.isUpdating,
      error:
          snapshot.error ??
          runState.error ??
          adjustmentState.error ??
          creationState.error,
      actions: [
        PosActionButton(
          label: '추천 발주 생성',
          tone: PosActionTone.primary,
          icon: Icons.auto_graph_outlined,
          loading: runState.isRunning,
          onPressed: runState.isRunning
              ? null
              : () async {
                  final ok = await ref
                      .read(inventoryPurchaseRecommendationRunProvider.notifier)
                      .run(
                        storeId: storeId,
                        targetStockDays: 3,
                        asOfDate: DateTime.now(),
                      );
                  if (!mounted) return;
                  if (ok) {
                    await ref
                        .read(
                          inventoryPurchaseRecommendationSnapshotProvider
                              .notifier,
                        )
                        .loadLatest(storeId);
                  }
                },
        ),
        PosActionButton(
          label: '공급처별 발주 생성',
          tone: PosActionTone.affirm,
          icon: Icons.assignment_turned_in_outlined,
          loading: creationState.isCreating,
          disabledReason: canCreateOrders
              ? null
              : PosActionDisabledReason.upstreamPending,
          onPressed: canCreateOrders && !creationState.isCreating
              ? () async {
                  final ok = await ref
                      .read(inventoryPurchaseOrderCreationProvider.notifier)
                      .createFromRecommendation(
                        runId: runId,
                        requestedDeliveryDate: DateTime.now().add(
                          const Duration(days: 2),
                        ),
                      );
                  if (!mounted) return;
                  if (ok) {
                    await ref
                        .read(inventoryPurchaseOrderSummaryProvider.notifier)
                        .load(storeId);
                    await ref
                        .read(inventoryPurchaseOverviewProvider.notifier)
                        .load(storeId);
                  }
                }
              : null,
        ),
        PosActionButton(
          label: '직접 발주 등록',
          tone: PosActionTone.secondary,
          icon: Icons.edit_note_outlined,
          loading: creationState.isCreating,
          disabledReason:
              supplierCatalog.suppliers.isEmpty ||
                  supplierCatalog.supplierItems.isEmpty
              ? PosActionDisabledReason.upstreamPending
              : PosActionDisabledReason.noSelection,
          onPressed:
              creationState.isCreating ||
                  supplierCatalog.suppliers.isEmpty ||
                  supplierCatalog.supplierItems.isEmpty
              ? null
              : () => _showManualPurchaseOrderDialog(
                  storeId: storeId,
                  suppliers: supplierCatalog.suppliers,
                  supplierItems: supplierCatalog.supplierItems,
                ),
          compact: true,
        ),
      ],
      children: [
        ToastMetricStrip(
          metrics: [
            ToastMetric(
              label: '추천 스냅샷',
              value: runId == null ? '없음' : _date(snapshot.run?['run_date']),
            ),
            ToastMetric(
              label: '추천 품목',
              value: '${snapshot.lines.length}개',
              tone: ToastColorTokens.accent,
            ),
            ToastMetric(
              label: '목표 재고일',
              value:
                  '${_number(snapshot.run?['target_stock_days'], fallback: '3')}일',
            ),
            ToastMetric(
              label: '생성 발주',
              value: '${creationState.createdOrders.length}건',
              tone: ToastColorTokens.success,
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: '추천 발주 목록',
          trailing: ToastStatusBadge(
            label: 'Office 승인은 Office 전용',
            color: ToastColorTokens.info,
            compact: true,
          ),
          child: _SimpleDataTable(
            columns: const [
              '제품',
              '공급처',
              '현재',
              '일소진',
              '추천 수량',
              '주문 단위',
              '조정 단위',
              '상태',
            ],
            rows: snapshot.lines
                .map(
                  (line) => [
                    _nestedName(line['product']),
                    _nestedName(line['supplier']),
                    _quantity(line['current_stock_base']),
                    _quantity(line['avg_daily_consumption_base']),
                    _quantity(line['recommended_quantity_base']),
                    _quantity(line['recommended_order_units']),
                    _quantity(line['adjusted_order_units']),
                    _riskLabel(line['risk_status']),
                  ],
                )
                .toList(),
          ),
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: '추천 수량 조정',
          child: _RecommendationAdjustmentList(
            lines: snapshot.lines,
            updatingLineId: adjustmentState.updatingLineId,
            onAdjust: (line) => _showRecommendationAdjustmentDialog(
              storeId: storeId,
              line: line,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showRecommendationAdjustmentDialog({
    required String storeId,
    required Map<String, dynamic> line,
  }) async {
    final lineId = line['id']?.toString();
    if (lineId == null || lineId.isEmpty) {
      return;
    }

    final currentUnits =
        line['adjusted_order_units'] ?? line['recommended_order_units'];
    final unitsController = TextEditingController(
      text: _quantity(currentUnits),
    );
    final memoController = TextEditingController(
      text: _string(line['adjustment_memo']),
    );
    final result = await showDialog<_RecommendationAdjustmentInput>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('추천 수량 조정'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${_nestedName(line['product'])} · ${_nestedName(line['supplier'])}',
                ),
                const SizedBox(height: ToastSpacingTokens.md),
                TextField(
                  controller: unitsController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '조정 주문 단위',
                    helperText: '비우면 조정값을 해제합니다.',
                  ),
                ),
                const SizedBox(height: ToastSpacingTokens.sm),
                TextField(
                  controller: memoController,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: '조정 메모'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.of(
                context,
              ).pop(const _RecommendationAdjustmentInput(clear: true)),
              child: const Text('조정 해제'),
            ),
            FilledButton(
              onPressed: () {
                final rawUnits = unitsController.text.trim();
                final parsed = rawUnits.isEmpty
                    ? null
                    : double.tryParse(rawUnits.replaceAll(',', ''));
                if (rawUnits.isNotEmpty && parsed == null) {
                  return;
                }
                Navigator.of(context).pop(
                  _RecommendationAdjustmentInput(
                    adjustedOrderUnits: parsed,
                    memo: memoController.text.trim(),
                  ),
                );
              },
              child: const Text('저장'),
            ),
          ],
        );
      },
    );
    unitsController.dispose();
    memoController.dispose();

    if (result == null) {
      return;
    }

    final ok = await ref
        .read(inventoryPurchaseRecommendationAdjustmentProvider.notifier)
        .update(
          lineId: lineId,
          adjustedOrderUnits: result.clear ? null : result.adjustedOrderUnits,
          memo: result.clear ? null : result.memo,
        );
    if (!mounted) return;
    if (ok) {
      await ref
          .read(inventoryPurchaseRecommendationSnapshotProvider.notifier)
          .loadLatest(storeId);
    } else {
      final error = ref
          .read(inventoryPurchaseRecommendationAdjustmentProvider)
          .error;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error ?? '추천 수량 조정에 실패했습니다.')));
    }
  }

  Widget _buildPurchaseHistoryPage({
    required String storeId,
    required InventoryPurchaseOrderSummaryState state,
    required InventoryPurchaseOrderDetailState detail,
    required InventoryPurchaseReceivingRuntimeState receivingRuntime,
    required InventoryPurchaseOrderCreationState creationState,
  }) {
    final order = detail.order;
    final canConfirmReceipt =
        order != null &&
        _receivableStatus(order['status']) &&
        _num(order['total_remaining_quantity_base']) > 0 &&
        !receivingRuntime.isSubmitting;

    return _PageShell(
      title: '발주 내역',
      subtitle: '공급처별 발주 진행 상태, 발주서 출력/PDF, 입고 확정 대상 목록입니다.',
      isLoading:
          state.isLoading ||
          detail.isLoading ||
          receivingRuntime.isSubmitting ||
          creationState.isCreating,
      error: state.error ?? detail.error ?? creationState.error,
      children: [
        ToastMetricStrip(
          metrics: [
            ToastMetric(label: '표시 발주', value: '${state.orders.length}건'),
            ToastMetric(
              label: '발주 금액',
              value: _money(
                state.orders.fold<num>(
                  0,
                  (sum, order) => sum + (_num(order['total_amount'])),
                ),
              ),
              tone: ToastColorTokens.accent,
            ),
            ToastMetric(
              label: '출력 가능',
              value:
                  '${state.orders.where((order) => _printableStatus(order['status'])).length}건',
            ),
          ],
        ),
        if (receivingRuntime.result != null) ...[
          const SizedBox(height: ToastSpacingTokens.md),
          ToastStatusBadge(
            label:
                '${receivingRuntime.result!.title}: ${receivingRuntime.result!.message}',
            color: _runtimeResultColor(receivingRuntime.result!.kind),
            icon: _runtimeResultIcon(receivingRuntime.result!.kind),
          ),
        ],
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: '발주 목록',
          trailing: ToastStatusBadge(
            label: '발주서 출력/PDF',
            color: ToastColorTokens.accent,
            compact: true,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SimpleDataTable(
                columns: const ['발주번호', '공급처', '상태', '납품 예정일', '품목', '금액'],
                rows: state.orders
                    .map(
                      (order) => [
                        _string(order['purchase_order_no'], fallback: '-'),
                        _nestedName(order['supplier']),
                        _statusLabel(order['status']),
                        _date(order['requested_delivery_date']),
                        '${_int(order['line_count'])}개',
                        _money(order['total_amount']),
                      ],
                    )
                    .toList(),
              ),
              const SizedBox(height: ToastSpacingTokens.md),
              _PurchaseOrderActionList(
                orders: state.orders,
                selectedOrderId: detail.selectedOrderId,
                printingOrderId: _printingOrderId,
                onSelect: _selectPurchaseOrder,
                onPrint: _printPurchaseOrderPdf,
              ),
            ],
          ),
        ),
        if (detail.order != null) ...[
          const SizedBox(height: ToastSpacingTokens.md),
          _DataCard(
            title: '선택 발주서 미리보기',
            trailing: Wrap(
              spacing: ToastSpacingTokens.sm,
              runSpacing: ToastSpacingTokens.sm,
              alignment: WrapAlignment.end,
              children: [
                PosActionButton(
                  label: '출력 / PDF',
                  tone: PosActionTone.primary,
                  icon: Icons.print_outlined,
                  loading: _printingOrderId == detail.selectedOrderId,
                  onPressed:
                      detail.selectedOrderId == null ||
                          _printingOrderId == detail.selectedOrderId
                      ? null
                      : () => _printPurchaseOrderPdf(detail.selectedOrderId!),
                  compact: true,
                ),
                PosActionButton(
                  label: '반복 발주',
                  tone: PosActionTone.secondary,
                  icon: Icons.repeat_outlined,
                  loading: creationState.isCreating,
                  disabledReason: detail.selectedOrderId == null
                      ? PosActionDisabledReason.noSelection
                      : creationState.isCreating
                      ? PosActionDisabledReason.upstreamPending
                      : null,
                  onPressed:
                      detail.selectedOrderId == null || creationState.isCreating
                      ? null
                      : () => _showRepeatPurchaseOrderDialog(
                          storeId: storeId,
                          detail: detail,
                        ),
                  compact: true,
                ),
                PosActionButton(
                  label: '입고 확정',
                  tone: PosActionTone.affirm,
                  icon: Icons.local_shipping_outlined,
                  loading: receivingRuntime.isSubmitting,
                  disabledReason: canConfirmReceipt
                      ? PosActionDisabledReason.noSelection
                      : PosActionDisabledReason.upstreamPending,
                  onPressed: canConfirmReceipt
                      ? () => _showReceiptConfirmationDialog(
                          storeId: storeId,
                          detail: detail,
                        )
                      : null,
                  compact: true,
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ToastMetricStrip(
                  metrics: [
                    ToastMetric(
                      label: '발주 기준 수량',
                      value: _quantity(order?['total_expected_quantity_base']),
                    ),
                    ToastMetric(
                      label: '입고 승인 수량',
                      value: _quantity(order?['total_accepted_quantity_base']),
                      tone: ToastColorTokens.success,
                    ),
                    ToastMetric(
                      label: '잔여 수량',
                      value: _quantity(order?['total_remaining_quantity_base']),
                      tone: ToastColorTokens.warning,
                    ),
                    ToastMetric(
                      label: '입고 이력',
                      value: '${detail.receipts.length}건',
                    ),
                  ],
                ),
                const SizedBox(height: ToastSpacingTokens.md),
                _SimpleDataTable(
                  columns: const [
                    '상품명',
                    '발주수량',
                    '입고',
                    '잔여',
                    '단위',
                    '단가',
                    '공급가액',
                    '상태',
                  ],
                  rows: detail.lines
                      .map(
                        (line) => [
                          _nestedName(line['product']),
                          _quantity(line['ordered_quantity_base']),
                          _quantity(line['accepted_quantity_base']),
                          _quantity(line['remaining_quantity_base']),
                          _string(line['order_unit'], fallback: '-'),
                          _money(line['unit_price']),
                          _money(line['supply_amount']),
                          _receiptVisibilityLabel(
                            line['receipt_visibility_status'],
                          ),
                        ],
                      )
                      .toList(),
                ),
              ],
            ),
          ),
          const SizedBox(height: ToastSpacingTokens.md),
          _DataCard(
            title: '입고 이력',
            child: _SimpleDataTable(
              columns: const ['입고일', '상태', '라인', '입고 수량', '승인 수량', '반려 수량'],
              rows: detail.receipts
                  .map(
                    (receipt) => [
                      _date(receipt['received_at'] ?? receipt['created_at']),
                      _receiptStatusLabel(receipt['status']),
                      '${_int(receipt['line_count'])}개',
                      _quantity(receipt['received_quantity_base']),
                      _quantity(receipt['accepted_quantity_base']),
                      _quantity(receipt['rejected_quantity_base']),
                    ],
                  )
                  .toList(),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _selectPurchaseOrder(String orderId) async {
    await ref.read(inventoryPurchaseOrderDetailProvider.notifier).load(orderId);
  }

  Future<void> _showReceiptConfirmationDialog({
    required String storeId,
    required InventoryPurchaseOrderDetailState detail,
  }) async {
    final order = detail.order;
    if (order == null) return;

    final memoController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('입고 확정'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${_string(order['purchase_order_no'], fallback: '-')} · 잔여 ${_quantity(order['total_remaining_quantity_base'])}',
              ),
              const SizedBox(height: ToastSpacingTokens.md),
              const ToastStatusBadge(
                label: '전체 잔여 수량을 입고 승인 수량으로 확정합니다.',
                color: ToastColorTokens.warning,
                icon: Icons.info_outline,
              ),
              const SizedBox(height: ToastSpacingTokens.md),
              TextField(
                controller: memoController,
                maxLines: 3,
                decoration: const InputDecoration(labelText: '입고 메모'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              ref
                  .read(inventoryPurchaseReceivingRuntimeProvider.notifier)
                  .markCancelled();
              Navigator.of(context).pop(false);
            },
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('확정'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final ok = await ref
        .read(inventoryPurchaseReceivingRuntimeProvider.notifier)
        .confirmRemainingReceipt(
          order: order,
          memo: _nullableText(memoController.text),
        );
    if (!mounted) return;
    if (ok) {
      final orderId = detail.selectedOrderId;
      if (orderId != null) {
        await ref
            .read(inventoryPurchaseOrderDetailProvider.notifier)
            .load(orderId);
      }
      await Future.wait([
        ref.read(inventoryPurchaseOrderSummaryProvider.notifier).load(storeId),
        ref.read(inventoryPurchaseOverviewProvider.notifier).load(storeId),
        ref.read(inventoryPurchaseStockStatusProvider.notifier).load(storeId),
        ref
            .read(inventoryPurchaseProductCatalogProvider.notifier)
            .load(storeId),
      ]);
    }
  }

  Future<void> _showStockAuditDialog({
    required String storeId,
    required List<Map<String, dynamic>> stockRows,
    String? currentSessionId,
  }) async {
    final rows = stockRows
        .where((row) => _string(row['product_id']).isNotEmpty)
        .take(20)
        .toList();
    if (rows.isEmpty) return;
    final controllers = <String, TextEditingController>{};
    for (final row in rows) {
      final productId = row['product_id']?.toString();
      if (productId == null) continue;
      controllers[productId] = TextEditingController(
        text: _quantity(row['current_stock_base']),
      );
    }
    final memoController = TextEditingController();

    final input = await showDialog<_StockAuditSubmitInput>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('실재고 실사 입력'),
        content: SizedBox(
          width: 780,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const ToastStatusBadge(
                  label: '임시저장은 재고를 바꾸지 않고, 완료만 실제 재고에 반영합니다.',
                  color: ToastColorTokens.info,
                  icon: Icons.info_outline,
                ),
                const SizedBox(height: ToastSpacingTokens.md),
                for (final row in rows) ...[
                  _StockAuditInputRow(
                    row: row,
                    controller: controllers[row['product_id']?.toString()]!,
                  ),
                  if (row != rows.last) const Divider(height: 1),
                ],
                const SizedBox(height: ToastSpacingTokens.md),
                TextField(
                  controller: memoController,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: '실사 메모'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(
              _buildStockAuditSubmitInput(
                rows: rows,
                controllers: controllers,
                memo: memoController.text,
                complete: false,
              ),
            ),
            child: const Text('임시저장'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(
              _buildStockAuditSubmitInput(
                rows: rows,
                controllers: controllers,
                memo: memoController.text,
                complete: true,
              ),
            ),
            child: const Text('실사 완료'),
          ),
        ],
      ),
    );

    for (final controller in controllers.values) {
      controller.dispose();
    }
    memoController.dispose();

    if (input == null || !mounted) return;

    final ok = await ref
        .read(inventoryPurchaseStockAuditProvider.notifier)
        .save(
          storeId: storeId,
          lines: input.lines,
          memo: input.memo,
          complete: input.complete,
          sessionId: currentSessionId,
        );
    if (!mounted) return;
    if (ok) {
      await Future.wait([
        ref.read(inventoryPurchaseStockStatusProvider.notifier).load(storeId),
        ref.read(inventoryPurchaseOverviewProvider.notifier).load(storeId),
        ref
            .read(inventoryPurchaseProductCatalogProvider.notifier)
            .load(storeId),
      ]);
    }
  }

  _StockAuditSubmitInput _buildStockAuditSubmitInput({
    required List<Map<String, dynamic>> rows,
    required Map<String, TextEditingController> controllers,
    required String memo,
    required bool complete,
  }) {
    final lines = <Map<String, dynamic>>[];
    for (final row in rows) {
      final productId = row['product_id']?.toString();
      if (productId == null || productId.isEmpty) continue;
      final actual = double.tryParse(controllers[productId]?.text.trim() ?? '');
      if (actual == null || actual < 0) continue;
      lines.add({
        'product_id': productId,
        'actual_quantity_base': actual,
        'memo': null,
      });
    }
    return _StockAuditSubmitInput(
      lines: lines,
      memo: _nullableText(memo),
      complete: complete,
    );
  }

  Future<void> _printPurchaseOrderPdf(String orderId) async {
    if (_printingOrderId != null) {
      return;
    }

    setState(() => _printingOrderId = orderId);
    try {
      await ref
          .read(inventoryPurchaseOrderDetailProvider.notifier)
          .load(orderId);
      final detail = ref.read(inventoryPurchaseOrderDetailProvider);
      final order = detail.order;
      if (!mounted) return;
      if (order == null || detail.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(detail.error ?? '발주 상세 정보를 불러오지 못했습니다.')),
        );
        return;
      }

      final opened = await inventoryPurchaseDocumentService
          .layoutPurchaseOrderPdf(order: order, lines: detail.lines);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            opened
                ? '${_string(order['purchase_order_no'], fallback: '-')} 발주서 출력/PDF 창을 열었습니다.'
                : '발주서 출력/PDF가 취소되었습니다.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('발주서 출력/PDF 생성에 실패했습니다.')));
    } finally {
      if (mounted) {
        setState(() => _printingOrderId = null);
      }
    }
  }

  Widget _buildSupplierManagementPage({
    required String storeId,
    required InventoryPurchaseSupplierCatalogState supplierCatalog,
    required InventoryPurchaseProductCatalogState productCatalog,
  }) {
    final suppliers = supplierCatalog.suppliers;
    final supplierItems = supplierCatalog.supplierItems;
    final activeSuppliers = suppliers
        .where((supplier) => _string(supplier['status']) == 'active')
        .length;
    final selectedSupplier = _firstWhereOrNull(
      suppliers,
      (row) => row['id']?.toString() == _selectedSupplierId,
    );
    final visibleSupplierItems = selectedSupplier == null
        ? supplierItems.take(10).toList()
        : supplierItems
              .where(
                (item) =>
                    item['supplier_id']?.toString() ==
                    selectedSupplier['id']?.toString(),
              )
              .toList();

    return _PageShell(
      title: '거래처 관리',
      subtitle: '공급처 기본 정보, 계약 조건, 공급처별 발주 품목을 관리합니다.',
      isLoading: supplierCatalog.isLoading,
      error: supplierCatalog.error,
      actions: [
        PosActionButton(
          label: '거래처 등록',
          tone: PosActionTone.primary,
          icon: Icons.add_business_outlined,
          loading: supplierCatalog.isSaving,
          onPressed: supplierCatalog.isSaving
              ? null
              : () => _showSupplierDialog(storeId: storeId),
          compact: true,
        ),
        PosActionButton(
          label: '품목 연결',
          tone: PosActionTone.secondary,
          icon: Icons.link_outlined,
          loading: supplierCatalog.isSaving,
          disabledReason: suppliers.isEmpty || productCatalog.products.isEmpty
              ? PosActionDisabledReason.upstreamPending
              : PosActionDisabledReason.noSelection,
          onPressed:
              supplierCatalog.isSaving ||
                  suppliers.isEmpty ||
                  productCatalog.products.isEmpty
              ? null
              : () => _showSupplierItemDialog(
                  storeId: storeId,
                  suppliers: suppliers,
                  products: productCatalog.products,
                  preferredSupplierId: selectedSupplier?['id']?.toString(),
                ),
          compact: true,
        ),
      ],
      children: [
        ToastMetricStrip(
          metrics: [
            ToastMetric(label: '전체 거래처', value: '${suppliers.length}개'),
            ToastMetric(
              label: '활성 거래처',
              value: '$activeSuppliers개',
              tone: ToastColorTokens.success,
            ),
            ToastMetric(label: '공급 품목', value: '${supplierItems.length}개'),
            ToastMetric(
              label: '계약 확인 필요',
              value: '${_contractAttentionCount(suppliers)}개',
              tone: ToastColorTokens.warning,
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _ResponsiveSplit(
          leftFlex: 2,
          rightFlex: 1,
          children: [
            _DataCard(
              title: '거래처 목록',
              trailing: ToastStatusBadge(
                label: selectedSupplier == null ? '전체' : '선택됨',
                color: ToastColorTokens.accent,
                compact: true,
              ),
              child: _SupplierManagementList(
                suppliers: suppliers,
                selectedSupplierId: _selectedSupplierId,
                saving: supplierCatalog.isSaving,
                onSelect: (supplier) => setState(
                  () => _selectedSupplierId = supplier['id']?.toString(),
                ),
                onEdit: (supplier) =>
                    _showSupplierDialog(storeId: storeId, supplier: supplier),
                onToggleStatus: (supplier) =>
                    _toggleSupplierStatus(storeId: storeId, supplier: supplier),
              ),
            ),
            _DataCard(
              title: '거래처 상세',
              child: _SupplierDetailPanel(
                supplier: selectedSupplier,
                supplierItemCount: visibleSupplierItems.length,
              ),
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: '공급처별 발주 품목',
          trailing: ToastStatusBadge(
            label: '${visibleSupplierItems.length}개',
            color: ToastColorTokens.info,
            compact: true,
          ),
          child: _SupplierItemList(
            supplierItems: visibleSupplierItems,
            saving: supplierCatalog.isSaving,
            onEdit: (item) => _showSupplierItemDialog(
              storeId: storeId,
              suppliers: suppliers,
              products: productCatalog.products,
              supplierItem: item,
            ),
            onToggleActive: (item) =>
                _toggleSupplierItemActive(storeId: storeId, supplierItem: item),
          ),
        ),
      ],
    );
  }

  Widget _buildProductManagementPage({
    required String storeId,
    required InventoryPurchaseProductCatalogState productCatalog,
    required InventoryPurchaseSupplierCatalogState supplierCatalog,
  }) {
    final products = productCatalog.products;
    final activeProducts = products
        .where((product) => product['is_active'] == true)
        .length;
    final orderableProducts = products
        .where((product) => product['is_orderable'] == true)
        .length;
    final selectedProduct = _firstWhereOrNull(
      products,
      (row) => row['id']?.toString() == _selectedProductId,
    );
    final supplierItems = selectedProduct == null
        ? supplierCatalog.supplierItems.take(10).toList()
        : supplierCatalog.supplierItems
              .where(
                (item) =>
                    item['product_id']?.toString() ==
                    selectedProduct['id']?.toString(),
              )
              .toList();

    return _PageShell(
      title: '제품 관리',
      subtitle: '재고 기준 품목, 표시 단위, 발주 가능 여부와 공급처 단가를 관리합니다.',
      isLoading: productCatalog.isLoading || supplierCatalog.isLoading,
      error: productCatalog.error ?? supplierCatalog.error,
      actions: [
        PosActionButton(
          label: '제품 등록',
          tone: PosActionTone.primary,
          icon: Icons.add_box_outlined,
          loading: productCatalog.isSaving,
          onPressed: productCatalog.isSaving
              ? null
              : () => _showProductDialog(storeId: storeId),
          compact: true,
        ),
        PosActionButton(
          label: '공급처 연결',
          tone: PosActionTone.secondary,
          icon: Icons.link_outlined,
          loading: supplierCatalog.isSaving,
          disabledReason: supplierCatalog.suppliers.isEmpty || products.isEmpty
              ? PosActionDisabledReason.upstreamPending
              : PosActionDisabledReason.noSelection,
          onPressed:
              supplierCatalog.isSaving ||
                  supplierCatalog.suppliers.isEmpty ||
                  products.isEmpty
              ? null
              : () => _showSupplierItemDialog(
                  storeId: storeId,
                  suppliers: supplierCatalog.suppliers,
                  products: products,
                  preferredProductId: selectedProduct?['id']?.toString(),
                ),
          compact: true,
        ),
      ],
      children: [
        ToastMetricStrip(
          metrics: [
            ToastMetric(label: '전체 제품', value: '${products.length}개'),
            ToastMetric(
              label: '사용 중',
              value: '$activeProducts개',
              tone: ToastColorTokens.success,
            ),
            ToastMetric(label: '발주 가능', value: '$orderableProducts개'),
            ToastMetric(
              label: '공급처 연결',
              value: '${supplierCatalog.supplierItems.length}건',
              tone: ToastColorTokens.accent,
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _ResponsiveSplit(
          leftFlex: 2,
          rightFlex: 1,
          children: [
            _DataCard(
              title: '제품 목록',
              trailing: ToastStatusBadge(
                label: selectedProduct == null ? '전체' : '선택됨',
                color: ToastColorTokens.accent,
                compact: true,
              ),
              child: _ProductManagementList(
                products: products,
                selectedProductId: _selectedProductId,
                saving: productCatalog.isSaving,
                onSelect: (product) => setState(
                  () => _selectedProductId = product['id']?.toString(),
                ),
                onEdit: (product) =>
                    _showProductDialog(storeId: storeId, product: product),
                onToggleActive: (product) =>
                    _toggleProductActive(storeId: storeId, product: product),
              ),
            ),
            _DataCard(
              title: '제품 상세',
              child: _ProductDetailPanel(
                product: selectedProduct,
                supplierItemCount: supplierItems.length,
              ),
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: '제품별 공급처 단가',
          child: _SupplierItemList(
            supplierItems: supplierItems,
            saving: supplierCatalog.isSaving,
            onEdit: (item) => _showSupplierItemDialog(
              storeId: storeId,
              suppliers: supplierCatalog.suppliers,
              products: products,
              supplierItem: item,
            ),
            onToggleActive: (item) =>
                _toggleSupplierItemActive(storeId: storeId, supplierItem: item),
          ),
        ),
      ],
    );
  }

  Future<void> _showSupplierDialog({
    required String storeId,
    Map<String, dynamic>? supplier,
  }) async {
    final nameController = TextEditingController(
      text: _string(supplier?['supplier_name']),
    );
    final typeController = TextEditingController(
      text: _string(supplier?['supplier_type']),
    );
    final contactController = TextEditingController(
      text: _string(supplier?['contact_name']),
    );
    final phoneController = TextEditingController(
      text: _string(supplier?['phone']),
    );
    final emailController = TextEditingController(
      text: _string(supplier?['email']),
    );
    final addressController = TextEditingController(
      text: _string(supplier?['address']),
    );
    final businessController = TextEditingController(
      text: _string(supplier?['business_registration_no']),
    );
    final paymentController = TextEditingController(
      text: _string(supplier?['payment_terms']),
    );
    final startController = TextEditingController(
      text: _dateOrBlank(supplier?['contract_start_date']),
    );
    final endController = TextEditingController(
      text: _dateOrBlank(supplier?['contract_end_date']),
    );
    final memoController = TextEditingController(
      text: _string(supplier?['memo']),
    );

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(supplier == null ? '거래처 등록' : '거래처 수정'),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _DialogGrid(
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: '거래처명 *'),
                    ),
                    TextField(
                      controller: typeController,
                      decoration: const InputDecoration(labelText: '거래 유형'),
                    ),
                    TextField(
                      controller: contactController,
                      decoration: const InputDecoration(labelText: '담당자'),
                    ),
                    TextField(
                      controller: phoneController,
                      decoration: const InputDecoration(labelText: '연락처'),
                    ),
                    TextField(
                      controller: emailController,
                      decoration: const InputDecoration(labelText: '이메일'),
                    ),
                    TextField(
                      controller: paymentController,
                      decoration: const InputDecoration(labelText: '결제 조건'),
                    ),
                    TextField(
                      controller: businessController,
                      decoration: const InputDecoration(labelText: '사업자번호'),
                    ),
                    TextField(
                      controller: startController,
                      decoration: const InputDecoration(
                        labelText: '계약 시작일',
                        hintText: 'YYYY-MM-DD',
                      ),
                    ),
                    TextField(
                      controller: endController,
                      decoration: const InputDecoration(
                        labelText: '계약 종료일',
                        hintText: 'YYYY-MM-DD',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: ToastSpacingTokens.md),
                TextField(
                  controller: addressController,
                  decoration: const InputDecoration(labelText: '주소'),
                ),
                const SizedBox(height: ToastSpacingTokens.md),
                TextField(
                  controller: memoController,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: '메모'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) {
                return;
              }
              final ok = await ref
                  .read(inventoryPurchaseSupplierCatalogProvider.notifier)
                  .saveSupplier(
                    storeId: storeId,
                    supplierId: supplier?['id']?.toString(),
                    supplierName: name,
                    supplierType: _nullableText(typeController.text),
                    contactName: _nullableText(contactController.text),
                    phone: _nullableText(phoneController.text),
                    email: _nullableText(emailController.text),
                    address: _nullableText(addressController.text),
                    businessRegistrationNo: _nullableText(
                      businessController.text,
                    ),
                    paymentTerms: _nullableText(paymentController.text),
                    contractStartDate: _parseDateOrNull(startController.text),
                    contractEndDate: _parseDateOrNull(endController.text),
                    memo: _nullableText(memoController.text),
                  );
              if (context.mounted) {
                Navigator.of(context).pop(ok);
              }
            },
            child: const Text('저장'),
          ),
        ],
      ),
    );

    if (saved == true && mounted) {
      await _reloadStoreScope(storeId);
    }
  }

  Future<void> _showProductDialog({
    required String storeId,
    Map<String, dynamic>? product,
  }) async {
    final codeController = TextEditingController(
      text: _string(product?['product_code']),
    );
    final nameController = TextEditingController(
      text: _string(product?['name']),
    );
    final categoryController = TextEditingController(
      text: _string(product?['category']),
    );
    final stockUnitController = TextEditingController(
      text: _string(product?['stock_unit'], fallback: 'kg'),
    );
    var baseUnit = _string(product?['base_unit'], fallback: 'g');
    final factorController = TextEditingController(
      text: _quantity(product?['base_unit_factor'] ?? 1000),
    );
    final imageController = TextEditingController(
      text: _string(product?['image_url']),
    );
    final storageController = TextEditingController(
      text: _string(product?['storage_type']),
    );
    final shelfLifeController = TextEditingController(
      text: product?['shelf_life_days']?.toString() ?? '',
    );
    var isOrderable = product?['is_orderable'] != false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(product == null ? '제품 등록' : '제품 수정'),
            content: SizedBox(
              width: 720,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _DialogGrid(
                      children: [
                        TextField(
                          controller: codeController,
                          decoration: const InputDecoration(labelText: '제품 코드'),
                        ),
                        TextField(
                          controller: nameController,
                          decoration: const InputDecoration(labelText: '제품명 *'),
                        ),
                        TextField(
                          controller: categoryController,
                          decoration: const InputDecoration(labelText: '카테고리'),
                        ),
                        TextField(
                          controller: stockUnitController,
                          decoration: const InputDecoration(
                            labelText: '표시 재고 단위 *',
                          ),
                        ),
                        DropdownButtonFormField<String>(
                          initialValue: baseUnit,
                          decoration: const InputDecoration(
                            labelText: '기준 단위 *',
                          ),
                          items: const [
                            DropdownMenuItem(value: 'g', child: Text('g')),
                            DropdownMenuItem(value: 'ml', child: Text('ml')),
                            DropdownMenuItem(value: 'ea', child: Text('ea')),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setDialogState(() => baseUnit = value);
                            }
                          },
                        ),
                        TextField(
                          controller: factorController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: '기준 단위 환산값 *',
                          ),
                        ),
                        TextField(
                          controller: storageController,
                          decoration: const InputDecoration(labelText: '보관 방식'),
                        ),
                        TextField(
                          controller: shelfLifeController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '유통기한 일수',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: ToastSpacingTokens.md),
                    TextField(
                      controller: imageController,
                      decoration: const InputDecoration(labelText: '이미지 URL'),
                    ),
                    const SizedBox(height: ToastSpacingTokens.md),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: isOrderable,
                      onChanged: (value) =>
                          setDialogState(() => isOrderable = value),
                      title: const Text('발주 가능'),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () async {
                  final name = nameController.text.trim();
                  final stockUnit = stockUnitController.text.trim();
                  final factor = double.tryParse(factorController.text.trim());
                  final shelfLife = shelfLifeController.text.trim().isEmpty
                      ? null
                      : int.tryParse(shelfLifeController.text.trim());
                  if (name.isEmpty || stockUnit.isEmpty || factor == null) {
                    return;
                  }
                  final ok = await ref
                      .read(inventoryPurchaseProductCatalogProvider.notifier)
                      .saveProduct(
                        storeId: storeId,
                        productId: product?['id']?.toString(),
                        productCode: _nullableText(codeController.text),
                        name: name,
                        category: _nullableText(categoryController.text),
                        stockUnit: stockUnit,
                        baseUnit: baseUnit,
                        baseUnitFactor: factor,
                        imageUrl: _nullableText(imageController.text),
                        storageType: _nullableText(storageController.text),
                        shelfLifeDays: shelfLife,
                        isOrderable: isOrderable,
                      );
                  if (context.mounted) {
                    Navigator.of(context).pop(ok);
                  }
                },
                child: const Text('저장'),
              ),
            ],
          );
        },
      ),
    );

    if (saved == true && mounted) {
      await _reloadStoreScope(storeId);
    }
  }

  Future<void> _showSupplierItemDialog({
    required String storeId,
    required List<Map<String, dynamic>> suppliers,
    required List<Map<String, dynamic>> products,
    Map<String, dynamic>? supplierItem,
    String? preferredSupplierId,
    String? preferredProductId,
  }) async {
    final selectableSuppliers = suppliers
        .where((supplier) => _string(supplier['id']).isNotEmpty)
        .toList();
    final selectableProducts = products
        .where((product) => _string(product['id']).isNotEmpty)
        .toList();

    if (selectableSuppliers.isEmpty || selectableProducts.isEmpty) {
      return;
    }
    var supplierId =
        supplierItem?['supplier_id']?.toString() ??
        preferredSupplierId ??
        selectableSuppliers.first['id']?.toString();
    var productId =
        supplierItem?['product_id']?.toString() ??
        preferredProductId ??
        selectableProducts.first['id']?.toString();
    if (!selectableSuppliers.any(
      (supplier) => supplier['id']?.toString() == supplierId,
    )) {
      supplierId = selectableSuppliers.first['id']?.toString();
    }
    if (!selectableProducts.any(
      (product) => product['id']?.toString() == productId,
    )) {
      productId = selectableProducts.first['id']?.toString();
    }
    final skuController = TextEditingController(
      text: _string(supplierItem?['supplier_sku']),
    );
    final orderUnitController = TextEditingController(
      text: _string(supplierItem?['order_unit'], fallback: 'box'),
    );
    final orderUnitBaseController = TextEditingController(
      text: _quantity(supplierItem?['order_unit_quantity_base'] ?? 1000),
    );
    final minOrderController = TextEditingController(
      text: _quantity(supplierItem?['min_order_quantity'] ?? 1),
    );
    final unitPriceController = TextEditingController(
      text: _quantity(supplierItem?['unit_price'] ?? 0),
    );
    final taxRateController = TextEditingController(
      text: _quantity(supplierItem?['tax_rate'] ?? 0),
    );
    final leadTimeController = TextEditingController(
      text: '${_int(supplierItem?['lead_time_days'] ?? 1)}',
    );
    var isPreferred = supplierItem?['is_preferred'] == true;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(supplierItem == null ? '공급처 품목 연결' : '공급처 품목 수정'),
            content: SizedBox(
              width: 720,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _DialogGrid(
                      children: [
                        DropdownButtonFormField<String>(
                          initialValue: supplierId,
                          decoration: const InputDecoration(labelText: '공급처 *'),
                          items: [
                            for (final supplier in selectableSuppliers)
                              DropdownMenuItem(
                                value: supplier['id'].toString(),
                                child: Text(
                                  _string(
                                    supplier['supplier_name'],
                                    fallback: '-',
                                  ),
                                ),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setDialogState(() => supplierId = value);
                            }
                          },
                        ),
                        DropdownButtonFormField<String>(
                          initialValue: productId,
                          decoration: const InputDecoration(labelText: '제품 *'),
                          items: [
                            for (final product in selectableProducts)
                              DropdownMenuItem(
                                value: product['id'].toString(),
                                child: Text(
                                  _string(product['name'], fallback: '-'),
                                ),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setDialogState(() => productId = value);
                            }
                          },
                        ),
                        TextField(
                          controller: skuController,
                          decoration: const InputDecoration(
                            labelText: '공급처 SKU',
                          ),
                        ),
                        TextField(
                          controller: orderUnitController,
                          decoration: const InputDecoration(
                            labelText: '발주 단위 *',
                          ),
                        ),
                        TextField(
                          controller: orderUnitBaseController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: '발주 단위 기준 수량 *',
                          ),
                        ),
                        TextField(
                          controller: minOrderController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: '최소 발주 수량 *',
                          ),
                        ),
                        TextField(
                          controller: unitPriceController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(labelText: '단가 *'),
                        ),
                        TextField(
                          controller: taxRateController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: '세율 (%)',
                          ),
                        ),
                        TextField(
                          controller: leadTimeController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '리드타임(일)',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: ToastSpacingTokens.md),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: isPreferred,
                      onChanged: (value) =>
                          setDialogState(() => isPreferred = value),
                      title: const Text('추천 발주 기본 공급처'),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () async {
                  final orderUnit = orderUnitController.text.trim();
                  final orderUnitBase = double.tryParse(
                    orderUnitBaseController.text.trim(),
                  );
                  final minOrder = double.tryParse(
                    minOrderController.text.trim(),
                  );
                  final unitPrice = double.tryParse(
                    unitPriceController.text.trim(),
                  );
                  final taxRate = double.tryParse(
                    taxRateController.text.trim(),
                  );
                  final leadTime = int.tryParse(leadTimeController.text.trim());
                  if (supplierId == null ||
                      productId == null ||
                      orderUnit.isEmpty ||
                      orderUnitBase == null ||
                      minOrder == null ||
                      unitPrice == null ||
                      taxRate == null ||
                      leadTime == null) {
                    return;
                  }
                  final ok = await ref
                      .read(inventoryPurchaseSupplierCatalogProvider.notifier)
                      .saveSupplierItem(
                        storeId: storeId,
                        supplierItemId: supplierItem?['id']?.toString(),
                        supplierId: supplierId!,
                        productId: productId!,
                        supplierSku: _nullableText(skuController.text),
                        orderUnit: orderUnit,
                        orderUnitQuantityBase: orderUnitBase,
                        minOrderQuantity: minOrder,
                        unitPrice: unitPrice,
                        taxRate: taxRate,
                        leadTimeDays: leadTime,
                        isPreferred: isPreferred,
                      );
                  if (context.mounted) {
                    Navigator.of(context).pop(ok);
                  }
                },
                child: const Text('저장'),
              ),
            ],
          );
        },
      ),
    );

    if (saved == true && mounted) {
      await _reloadStoreScope(storeId);
    }
  }

  Future<void> _showManualPurchaseOrderDialog({
    required String storeId,
    required List<Map<String, dynamic>> suppliers,
    required List<Map<String, dynamic>> supplierItems,
  }) async {
    final activeSuppliers = suppliers
        .where(
          (supplier) =>
              _string(supplier['id']).isNotEmpty &&
              _string(supplier['status']) == 'active',
        )
        .toList();
    if (activeSuppliers.isEmpty) return;

    var supplierId = activeSuppliers.first['id'].toString();
    var selectedSupplierItems = _activeSupplierItemsForSupplier(
      supplierItems,
      supplierId,
    );
    if (selectedSupplierItems.isEmpty) return;

    var supplierItemId = selectedSupplierItems.first['id'].toString();
    final quantityController = TextEditingController(text: '1');
    final requestedDateController = TextEditingController(
      text: DateTime.now()
          .add(const Duration(days: 2))
          .toIso8601String()
          .split('T')
          .first,
    );
    final memoController = TextEditingController();
    final lines = <Map<String, dynamic>>[];

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final selectedItem = _firstWhereOrNull(
            selectedSupplierItems,
            (item) => item['id']?.toString() == supplierItemId,
          );
          return AlertDialog(
            title: const Text('직접 발주 등록'),
            content: SizedBox(
              width: 760,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _DialogGrid(
                      children: [
                        DropdownButtonFormField<String>(
                          initialValue: supplierId,
                          decoration: const InputDecoration(labelText: '공급처 *'),
                          items: [
                            for (final supplier in activeSuppliers)
                              DropdownMenuItem(
                                value: supplier['id'].toString(),
                                child: Text(
                                  _string(
                                    supplier['supplier_name'],
                                    fallback: '-',
                                  ),
                                ),
                              ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setDialogState(() {
                              supplierId = value;
                              selectedSupplierItems =
                                  _activeSupplierItemsForSupplier(
                                    supplierItems,
                                    supplierId,
                                  );
                              supplierItemId = selectedSupplierItems.isEmpty
                                  ? ''
                                  : selectedSupplierItems.first['id']
                                        .toString();
                              lines.clear();
                            });
                          },
                        ),
                        TextField(
                          controller: requestedDateController,
                          decoration: const InputDecoration(
                            labelText: '납품 요청일',
                            hintText: 'YYYY-MM-DD',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: ToastSpacingTokens.md),
                    _DataCard(
                      title: '발주 품목',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _DialogGrid(
                            children: [
                              DropdownButtonFormField<String>(
                                initialValue: supplierItemId,
                                decoration: const InputDecoration(
                                  labelText: '품목 *',
                                ),
                                items: [
                                  for (final item in selectedSupplierItems)
                                    DropdownMenuItem(
                                      value: item['id'].toString(),
                                      child: Text(_supplierItemLabel(item)),
                                    ),
                                ],
                                onChanged: (value) {
                                  if (value != null) {
                                    setDialogState(
                                      () => supplierItemId = value,
                                    );
                                  }
                                },
                              ),
                              TextField(
                                controller: quantityController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: InputDecoration(
                                  labelText:
                                      '발주 수량(${_string(selectedItem?['order_unit'], fallback: 'unit')})',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: ToastSpacingTokens.md),
                          Align(
                            alignment: Alignment.centerRight,
                            child: PosActionButton(
                              label: '라인 추가',
                              tone: PosActionTone.secondary,
                              icon: Icons.add_outlined,
                              compact: true,
                              onPressed: () {
                                final item = selectedItem;
                                final qty = double.tryParse(
                                  quantityController.text.trim(),
                                );
                                if (item == null || qty == null || qty <= 0) {
                                  return;
                                }
                                setDialogState(() {
                                  lines.removeWhere(
                                    (line) =>
                                        line['supplier_item_id']?.toString() ==
                                        item['id']?.toString(),
                                  );
                                  lines.add({
                                    'supplier_item_id': item['id']?.toString(),
                                    'ordered_quantity_unit': qty,
                                    'memo': null,
                                    'label': _supplierItemLabel(item),
                                    'order_unit': _string(
                                      item['order_unit'],
                                      fallback: 'unit',
                                    ),
                                  });
                                });
                              },
                            ),
                          ),
                          const SizedBox(height: ToastSpacingTokens.md),
                          _SimpleDataTable(
                            columns: const ['품목', '수량', '단위'],
                            rows: lines
                                .map(
                                  (line) => [
                                    _string(line['label'], fallback: '-'),
                                    _quantity(line['ordered_quantity_unit']),
                                    _string(line['order_unit'], fallback: '-'),
                                  ],
                                )
                                .toList(),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: ToastSpacingTokens.md),
                    TextField(
                      controller: memoController,
                      maxLines: 2,
                      decoration: const InputDecoration(labelText: '발주 메모'),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () async {
                  if (lines.isEmpty) return;
                  final ok = await ref
                      .read(inventoryPurchaseOrderCreationProvider.notifier)
                      .createManual(
                        storeId: storeId,
                        supplierId: supplierId,
                        requestedDeliveryDate: _parseDateOrNull(
                          requestedDateController.text,
                        ),
                        memo: _nullableText(memoController.text),
                        lines: lines
                            .map(
                              (line) => {
                                'supplier_item_id': line['supplier_item_id'],
                                'ordered_quantity_unit':
                                    line['ordered_quantity_unit'],
                                'memo': line['memo'],
                              },
                            )
                            .toList(),
                      );
                  if (context.mounted) {
                    Navigator.of(context).pop(ok);
                  }
                },
                child: const Text('발주 생성'),
              ),
            ],
          );
        },
      ),
    );

    if (saved == true && mounted) {
      await _reloadStoreScope(storeId);
    }
  }

  Future<void> _showRepeatPurchaseOrderDialog({
    required String storeId,
    required InventoryPurchaseOrderDetailState detail,
  }) async {
    final order = detail.order;
    final sourceOrderId = detail.selectedOrderId;
    if (order == null || sourceOrderId == null || detail.lines.isEmpty) {
      return;
    }

    final requestedDateController = TextEditingController(
      text: DateTime.now()
          .add(const Duration(days: 2))
          .toIso8601String()
          .split('T')
          .first,
    );
    final memoController = TextEditingController(
      text: 'Repeat from ${_string(order['purchase_order_no'], fallback: '-')}',
    );

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('반복 발주 등록'),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ToastStatusBadge(
                  label:
                      '${_string(order['purchase_order_no'], fallback: '-')} 기준으로 동일 공급처/품목/수량의 새 발주를 생성합니다.',
                  color: ToastColorTokens.info,
                  icon: Icons.repeat_outlined,
                ),
                const SizedBox(height: ToastSpacingTokens.md),
                _DialogGrid(
                  children: [
                    TextField(
                      controller: requestedDateController,
                      decoration: const InputDecoration(
                        labelText: '납품 요청일',
                        hintText: 'YYYY-MM-DD',
                      ),
                    ),
                    TextField(
                      controller: memoController,
                      decoration: const InputDecoration(labelText: '발주 메모'),
                    ),
                  ],
                ),
                const SizedBox(height: ToastSpacingTokens.md),
                _SimpleDataTable(
                  columns: const ['품목', '수량', '단위', '단가', '공급가액'],
                  rows: detail.lines
                      .map(
                        (line) => [
                          _nestedName(line['product']),
                          _quantity(line['ordered_quantity_unit']),
                          _string(line['order_unit'], fallback: '-'),
                          _money(line['unit_price']),
                          _money(line['supply_amount']),
                        ],
                      )
                      .toList(),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () async {
              final ok = await ref
                  .read(inventoryPurchaseOrderCreationProvider.notifier)
                  .createRepeat(
                    sourcePurchaseOrderId: sourceOrderId,
                    requestedDeliveryDate: _parseDateOrNull(
                      requestedDateController.text,
                    ),
                    memo: _nullableText(memoController.text),
                  );
              if (context.mounted) {
                Navigator.of(context).pop(ok);
              }
            },
            child: const Text('반복 발주 생성'),
          ),
        ],
      ),
    );

    requestedDateController.dispose();
    memoController.dispose();

    if (saved == true && mounted) {
      final createdOrders = ref
          .read(inventoryPurchaseOrderCreationProvider)
          .createdOrders;
      final createdOrderId = createdOrders.isEmpty
          ? null
          : createdOrders.first['id']?.toString();
      await _reloadStoreScope(storeId);
      if (createdOrderId != null && createdOrderId.isNotEmpty) {
        await _selectPurchaseOrder(createdOrderId);
      }
    }
  }

  Future<void> _showRecipeLineDialog({
    required String storeId,
    required List<Map<String, dynamic>> menuItems,
    required List<Map<String, dynamic>> products,
    Map<String, dynamic>? recipe,
  }) async {
    final selectableMenus = menuItems
        .where((menu) => _string(menu['id']).isNotEmpty)
        .toList();
    final selectableProducts = _gramRecipeProducts(products);
    if (selectableMenus.isEmpty || selectableProducts.isEmpty) {
      return;
    }

    var menuItemId =
        recipe?['menu_item_id']?.toString() ??
        selectableMenus.first['id'].toString();
    final recipeIngredientId = recipe?['ingredient_id']?.toString();
    var productId =
        _firstWhereOrNull(
          selectableProducts,
          (product) =>
              product['inventory_item_id']?.toString() == recipeIngredientId,
        )?['id']?.toString() ??
        selectableProducts.first['id'].toString();
    final quantityController = TextEditingController(
      text: _quantity(recipe?['quantity_g'] ?? 100),
    );

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(recipe == null ? '레시피 라인 추가' : '레시피 라인 수정'),
            content: SizedBox(
              width: 560,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: menuItemId,
                    decoration: const InputDecoration(labelText: '메뉴 *'),
                    items: [
                      for (final menu in selectableMenus)
                        DropdownMenuItem(
                          value: menu['id'].toString(),
                          child: Text(_string(menu['name'], fallback: '-')),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => menuItemId = value);
                      }
                    },
                  ),
                  const SizedBox(height: ToastSpacingTokens.md),
                  DropdownButtonFormField<String>(
                    initialValue: productId,
                    decoration: const InputDecoration(labelText: '재료 *'),
                    items: [
                      for (final product in selectableProducts)
                        DropdownMenuItem(
                          value: product['id'].toString(),
                          child: Text(_string(product['name'], fallback: '-')),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => productId = value);
                      }
                    },
                  ),
                  const SizedBox(height: ToastSpacingTokens.md),
                  TextField(
                    controller: quantityController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: '1인분 사용량(g) *',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () async {
                  final product = _firstWhereOrNull(
                    selectableProducts,
                    (row) => row['id']?.toString() == productId,
                  );
                  final ingredientId = product?['inventory_item_id']
                      ?.toString();
                  final quantity = double.tryParse(
                    quantityController.text.trim(),
                  );
                  if (ingredientId == null ||
                      quantity == null ||
                      quantity <= 0) {
                    return;
                  }
                  final ok = await ref
                      .read(recipeProvider.notifier)
                      .upsert(
                        storeId: storeId,
                        menuItemId: menuItemId,
                        ingredientId: ingredientId,
                        quantityG: quantity,
                      );
                  if (context.mounted) {
                    Navigator.of(context).pop(ok);
                  }
                },
                child: const Text('저장'),
              ),
            ],
          );
        },
      ),
    );

    if (saved == true && mounted) {
      await _reloadStoreScope(storeId);
    }
  }

  Future<void> _deleteRecipeLine({
    required String storeId,
    required Map<String, dynamic> recipe,
  }) async {
    final menuItemId = recipe['menu_item_id']?.toString();
    final ingredientId = recipe['ingredient_id']?.toString();
    if (menuItemId == null || ingredientId == null) return;
    await ref
        .read(recipeProvider.notifier)
        .delete(storeId, menuItemId, ingredientId);
    if (mounted) {
      await _reloadStoreScope(storeId);
    }
  }

  Future<void> _showNewMenuDialog({
    required String storeId,
    required List<Map<String, dynamic>> categories,
    required List<Map<String, dynamic>> products,
  }) async {
    final nameController = TextEditingController();
    final priceController = TextEditingController(text: '0');
    final descriptionController = TextEditingController();
    final usageController = TextEditingController(text: '100');
    var categoryId = categories.isEmpty
        ? null
        : categories.first['id']?.toString();
    var productId = products.first['id']?.toString();
    final recipeLines = <Map<String, dynamic>>[];

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final selectedProduct = _firstWhereOrNull(
            products,
            (product) => product['id']?.toString() == productId,
          );
          return AlertDialog(
            title: const Text('신메뉴 등록'),
            content: SizedBox(
              width: 760,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _DialogGrid(
                      children: [
                        TextField(
                          controller: nameController,
                          decoration: const InputDecoration(labelText: '메뉴명 *'),
                        ),
                        TextField(
                          controller: priceController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(labelText: '판매가 *'),
                        ),
                        DropdownButtonFormField<String?>(
                          initialValue: categoryId,
                          decoration: const InputDecoration(labelText: '카테고리'),
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('카테고리 없음'),
                            ),
                            for (final category in categories)
                              DropdownMenuItem<String?>(
                                value: category['id']?.toString(),
                                child: Text(
                                  _string(category['name'], fallback: '-'),
                                ),
                              ),
                          ],
                          onChanged: (value) =>
                              setDialogState(() => categoryId = value),
                        ),
                        TextField(
                          controller: descriptionController,
                          decoration: const InputDecoration(labelText: '설명'),
                        ),
                      ],
                    ),
                    const SizedBox(height: ToastSpacingTokens.lg),
                    _DataCard(
                      title: '재료 구성',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _DialogGrid(
                            children: [
                              DropdownButtonFormField<String>(
                                initialValue: productId,
                                decoration: const InputDecoration(
                                  labelText: '재료',
                                ),
                                items: [
                                  for (final product in products)
                                    DropdownMenuItem(
                                      value: product['id'].toString(),
                                      child: Text(
                                        _string(product['name'], fallback: '-'),
                                      ),
                                    ),
                                ],
                                onChanged: (value) {
                                  if (value != null) {
                                    setDialogState(() => productId = value);
                                  }
                                },
                              ),
                              TextField(
                                controller: usageController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: const InputDecoration(
                                  labelText: '1인분 사용량(g)',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: ToastSpacingTokens.md),
                          Align(
                            alignment: Alignment.centerRight,
                            child: PosActionButton(
                              label: '재료 추가',
                              tone: PosActionTone.secondary,
                              icon: Icons.add_outlined,
                              compact: true,
                              onPressed: () {
                                final usage = double.tryParse(
                                  usageController.text.trim(),
                                );
                                final product = selectedProduct;
                                final ingredientId =
                                    product?['inventory_item_id']?.toString();
                                if (product == null ||
                                    ingredientId == null ||
                                    usage == null ||
                                    usage <= 0) {
                                  return;
                                }
                                setDialogState(() {
                                  recipeLines.removeWhere(
                                    (line) =>
                                        line['ingredient_id']?.toString() ==
                                        ingredientId,
                                  );
                                  recipeLines.add({
                                    'ingredient_id': ingredientId,
                                    'product_name': _string(
                                      product['name'],
                                      fallback: '-',
                                    ),
                                    'quantity_g': usage,
                                  });
                                });
                              },
                            ),
                          ),
                          const SizedBox(height: ToastSpacingTokens.md),
                          _SimpleDataTable(
                            columns: const ['재료', '사용량(g)'],
                            rows: recipeLines
                                .map(
                                  (line) => [
                                    _string(
                                      line['product_name'],
                                      fallback: '-',
                                    ),
                                    _quantity(line['quantity_g']),
                                  ],
                                )
                                .toList(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () async {
                  final name = nameController.text.trim();
                  final price = double.tryParse(priceController.text.trim());
                  if (name.isEmpty || price == null || recipeLines.isEmpty) {
                    return;
                  }
                  final ok = await ref
                      .read(inventoryPurchaseNewMenuProvider.notifier)
                      .create(
                        storeId: storeId,
                        categoryId: categoryId,
                        name: name,
                        price: price,
                        description: _nullableText(descriptionController.text),
                        recipeLines: recipeLines
                            .map(
                              (line) => {
                                'ingredient_id': line['ingredient_id'],
                                'quantity_g': line['quantity_g'],
                              },
                            )
                            .toList(),
                      );
                  if (context.mounted) {
                    Navigator.of(context).pop(ok);
                  }
                },
                child: const Text('등록'),
              ),
            ],
          );
        },
      ),
    );

    if (saved == true && mounted) {
      await _reloadStoreScope(storeId);
    }
  }

  Future<void> _toggleSupplierStatus({
    required String storeId,
    required Map<String, dynamic> supplier,
  }) async {
    final supplierId = supplier['id']?.toString();
    if (supplierId == null) return;
    final nextStatus = _string(supplier['status']) == 'active'
        ? 'inactive'
        : 'active';
    await ref
        .read(inventoryPurchaseSupplierCatalogProvider.notifier)
        .setSupplierStatus(
          storeId: storeId,
          supplierId: supplierId,
          status: nextStatus,
        );
  }

  Future<void> _toggleProductActive({
    required String storeId,
    required Map<String, dynamic> product,
  }) async {
    final productId = product['id']?.toString();
    if (productId == null) return;
    await ref
        .read(inventoryPurchaseProductCatalogProvider.notifier)
        .setProductActive(
          storeId: storeId,
          productId: productId,
          isActive: product['is_active'] != true,
        );
    if (mounted) {
      await _reloadStoreScope(storeId);
    }
  }

  Future<void> _toggleSupplierItemActive({
    required String storeId,
    required Map<String, dynamic> supplierItem,
  }) async {
    final supplierItemId = supplierItem['id']?.toString();
    if (supplierItemId == null) return;
    await ref
        .read(inventoryPurchaseSupplierCatalogProvider.notifier)
        .setSupplierItemActive(
          storeId: storeId,
          supplierItemId: supplierItemId,
          isActive: supplierItem['is_active'] != true,
        );
  }

  Widget _buildRecipePage({
    required String storeId,
    required RecipeState recipeState,
    required InventoryPurchaseProductCatalogState productCatalog,
  }) {
    final recipes = recipeState.allRecipes;
    final menuCount = recipes
        .map((recipe) => recipe['menu_item_id']?.toString())
        .whereType<String>()
        .toSet()
        .length;
    final ingredientCount = recipes
        .map((recipe) => recipe['ingredient_id']?.toString())
        .whereType<String>()
        .toSet()
        .length;
    final totalUsage = recipes.fold<num>(
      0,
      (sum, recipe) => sum + _num(recipe['quantity_g']),
    );

    return _PageShell(
      title: '레시피 관리',
      subtitle: '메뉴별 표준량과 판매 기반 재료 소진량을 연결합니다.',
      isLoading: recipeState.isLoading || productCatalog.isLoading,
      error: recipeState.error ?? productCatalog.error,
      actions: [
        PosActionButton(
          label: '레시피 라인 추가',
          tone: PosActionTone.primary,
          icon: Icons.add_outlined,
          disabledReason:
              recipeState.menuItems.isEmpty || productCatalog.products.isEmpty
              ? PosActionDisabledReason.upstreamPending
              : PosActionDisabledReason.noSelection,
          onPressed:
              recipeState.menuItems.isEmpty || productCatalog.products.isEmpty
              ? null
              : () => _showRecipeLineDialog(
                  storeId: storeId,
                  menuItems: recipeState.menuItems,
                  products: productCatalog.products,
                ),
          compact: true,
        ),
      ],
      children: [
        ToastMetricStrip(
          metrics: [
            ToastMetric(label: '레시피 메뉴', value: '$menuCount개'),
            ToastMetric(label: '레시피 라인', value: '${recipes.length}개'),
            ToastMetric(label: '연결 재료', value: '$ingredientCount개'),
            ToastMetric(label: '총 표준 사용량', value: '${_quantity(totalUsage)}g'),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: '메뉴별 레시피 라인',
          child: _RecipeLineList(
            recipes: recipes,
            onEdit: (recipe) => _showRecipeLineDialog(
              storeId: storeId,
              menuItems: recipeState.menuItems,
              products: productCatalog.products,
              recipe: recipe,
            ),
            onDelete: (recipe) =>
                _deleteRecipeLine(storeId: storeId, recipe: recipe),
          ),
        ),
      ],
    );
  }

  Widget _buildAnalysisPage({
    required String storeId,
    required _InventoryPurchaseSection section,
    required String title,
    required InventoryPurchaseStockStatusState stockStatus,
    required InventoryPurchaseCostAnalysisState costAnalysis,
  }) {
    final consumptionRows =
        stockStatus.rows
            .where((row) => _num(row['avg_daily_consumption_base']) > 0)
            .toList()
          ..sort(
            (a, b) => _num(
              b['avg_daily_consumption_base'],
            ).compareTo(_num(a['avg_daily_consumption_base'])),
          );
    final alertRows =
        stockStatus.rows
            .where(
              (row) =>
                  {'danger', 'warning'}.contains(_string(row['risk_status'])),
            )
            .toList()
          ..sort(
            (a, b) => _num(
              a['estimated_days_remaining'],
            ).compareTo(_num(b['estimated_days_remaining'])),
          );
    final categoryShares = _buildConsumptionShares(consumptionRows);
    final totalDailyQuantity = consumptionRows.fold<num>(
      0,
      (sum, row) => sum + _num(row['avg_daily_consumption_base']),
    );
    final recentFourDay = consumptionRows.fold<num>(
      0,
      (sum, row) => sum + _num(row['recent_4_day_avg']),
    );
    final recentSevenDay = consumptionRows.fold<num>(
      0,
      (sum, row) => sum + _num(row['recent_7_day_avg']),
    );
    final averageDays = consumptionRows.isEmpty
        ? 0
        : consumptionRows.fold<num>(
                0,
                (sum, row) => sum + _num(row['estimated_days_remaining']),
              ) /
              consumptionRows.length;
    final periodConsumedAmount = costAnalysis.rows.fold<num>(
      0,
      (sum, row) => sum + _num(row['consumed_amount']),
    );
    final trendPercent = recentSevenDay <= 0
        ? null
        : ((recentFourDay - recentSevenDay) / recentSevenDay) * 100;

    return _PageShell(
      title: section.label,
      subtitle: section.subtitle,
      isLoading:
          stockStatus.isLoading ||
          costAnalysis.isLoading ||
          costAnalysis.isRefreshing,
      error: stockStatus.error ?? costAnalysis.error,
      actions: [
        PosActionButton(
          label: '소진 데이터 갱신',
          tone: PosActionTone.secondary,
          icon: Icons.sync_outlined,
          loading: costAnalysis.isRefreshing,
          onPressed: costAnalysis.isRefreshing
              ? null
              : () => _refreshCostAnalysis(storeId),
          compact: true,
        ),
      ],
      children: [
        ToastMetricStrip(
          metrics: [
            ToastMetric(
              label: '총 일평균 소진량',
              value: '${_quantity(totalDailyQuantity)} /일',
            ),
            ToastMetric(
              label: '기간 소진 원가',
              value: _money(periodConsumedAmount),
              tone: ToastColorTokens.accent,
            ),
            ToastMetric(
              label: '평균 예상 소진일',
              value: averageDays <= 0 ? '-' : '${_number(averageDays)}일',
            ),
            ToastMetric(
              label: '소진 추세',
              value: trendPercent == null
                  ? '-'
                  : '${trendPercent >= 0 ? '+' : ''}${_number(trendPercent)}%',
              tone: trendPercent == null
                  ? null
                  : trendPercent > 0
                  ? ToastColorTokens.warning
                  : ToastColorTokens.success,
            ),
            ToastMetric(
              label: '소진 위험 품목',
              value: '${alertRows.length}개',
              tone: ToastColorTokens.warning,
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: title,
          trailing: ToastStatusBadge(
            label: '상위 ${consumptionRows.take(8).length}개',
            color: ToastColorTokens.info,
            compact: true,
          ),
          child: _ConsumptionTrendChart(rows: consumptionRows.take(8).toList()),
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _ResponsiveSplit(
          leftFlex: 1,
          rightFlex: 1,
          children: [
            _DataCard(
              title: '카테고리별 소진 비중',
              child: _ConsumptionShareList(rows: categoryShares),
            ),
            _DataCard(
              title: '소진 이상 알림',
              child: _ConsumptionAlertList(rows: alertRows.take(5).toList()),
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: '제품별 소진 분석',
          child: _SimpleDataTable(
            columns: const [
              '제품',
              '카테고리',
              '최근 4일',
              '최근 7일',
              '일 평균 소진',
              '예상 소진일',
              '상태',
            ],
            rows: consumptionRows
                .map(
                  (row) => [
                    _string(row['product_name'], fallback: '-'),
                    _string(row['category'], fallback: '-'),
                    _quantity(row['recent_4_day_avg']),
                    _quantity(row['recent_7_day_avg']),
                    _quantity(row['avg_daily_consumption_base']),
                    '${_number(row['estimated_days_remaining'])}일',
                    _riskLabel(row['risk_status']),
                  ],
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildCostPage({
    required String storeId,
    required InventoryPurchaseOverviewState overview,
    required InventoryPurchaseCostAnalysisState costAnalysis,
  }) {
    final inventoryAmount = overview.dashboard?['total_inventory_amount'] ?? 0;
    final rows = costAnalysis.rows;
    final consumedAmount = rows.fold<num>(
      0,
      (sum, row) => sum + _num(row['consumed_amount']),
    );
    final warningCount = rows
        .where((row) => _string(row['cost_status']) == 'warning')
        .length;

    return _PageShell(
      title: '원가 분석',
      subtitle: 'POS 판매 기반 소진 원가와 공급처 단가를 비교합니다.',
      isLoading:
          overview.isLoading ||
          costAnalysis.isLoading ||
          costAnalysis.isRefreshing,
      error: overview.error ?? costAnalysis.error,
      actions: [
        PosActionButton(
          label: '소진 데이터 갱신',
          tone: PosActionTone.secondary,
          icon: Icons.sync_outlined,
          loading: costAnalysis.isRefreshing,
          onPressed: costAnalysis.isRefreshing
              ? null
              : () => _refreshCostAnalysis(storeId),
          compact: true,
        ),
      ],
      children: [
        ToastMetricStrip(
          metrics: [
            ToastMetric(label: '재고 자산 금액', value: _money(inventoryAmount)),
            ToastMetric(
              label: '기간 소진 원가',
              value: _money(consumedAmount),
              tone: ToastColorTokens.accent,
            ),
            ToastMetric(label: '분석 품목', value: '${rows.length}개'),
            ToastMetric(
              label: '원가 주의',
              value: '$warningCount개',
              tone: ToastColorTokens.warning,
            ),
            ToastMetric(
              label: '갱신 결과',
              value: costAnalysis.lastRefreshCount == null
                  ? '-'
                  : '${costAnalysis.lastRefreshCount}건',
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: '제품별 소진 원가',
          child: _SimpleDataTable(
            columns: const [
              '제품',
              '카테고리',
              '소진 수량',
              '소진 금액',
              '평균 원가',
              '공급처 기준',
              '상태',
            ],
            rows: rows
                .map(
                  (row) => [
                    _string(row['product_name'], fallback: '-'),
                    _string(row['category'], fallback: '-'),
                    _quantity(row['consumed_quantity_base']),
                    _money(row['consumed_amount']),
                    _money(row['avg_unit_cost']),
                    _money(row['preferred_unit_cost']),
                    _costStatusLabel(row['cost_status']),
                  ],
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  Future<void> _refreshCostAnalysis(String storeId) async {
    final ok = await ref
        .read(inventoryPurchaseCostAnalysisProvider.notifier)
        .refreshConsumption(storeId);
    if (!mounted || !ok) return;
    await Future.wait([
      ref.read(inventoryPurchaseOverviewProvider.notifier).load(storeId),
      ref.read(inventoryPurchaseStockStatusProvider.notifier).load(storeId),
    ]);
  }

  Widget _buildAuditPage({
    required String storeId,
    required InventoryPurchaseStockStatusState stockStatus,
    required InventoryPurchaseStockAuditState stockAuditState,
  }) {
    final rows = stockStatus.rows
        .take(10)
        .map(
          (row) => [
            _string(row['product_name'], fallback: '-'),
            _displayStock(row),
            '-',
            '-',
            _riskLabel(row['risk_status']),
          ],
        )
        .toList();

    return _PageShell(
      title: '실재고 실사',
      subtitle: '현재 시스템 재고와 실사 수량의 차이를 확인하고 입고/조정 이력을 분리합니다.',
      isLoading: stockStatus.isLoading || stockAuditState.isSaving,
      error: stockStatus.error ?? stockAuditState.error,
      actions: [
        PosActionButton(
          label: '실사 입력',
          tone: PosActionTone.primary,
          icon: Icons.fact_check_outlined,
          loading: stockAuditState.isSaving,
          disabledReason: stockStatus.rows.isEmpty
              ? PosActionDisabledReason.upstreamPending
              : PosActionDisabledReason.noSelection,
          onPressed: stockStatus.rows.isEmpty || stockAuditState.isSaving
              ? null
              : () => _showStockAuditDialog(
                  storeId: storeId,
                  stockRows: stockStatus.rows,
                  currentSessionId: stockAuditState.lastSessionId,
                ),
          compact: true,
        ),
      ],
      children: [
        ToastMetricStrip(
          metrics: [
            ToastMetric(label: '실사 대상', value: '${stockStatus.rows.length}개'),
            ToastMetric(
              label: '최근 세션',
              value: stockAuditState.lastSessionId == null ? '-' : '저장됨',
              tone: ToastColorTokens.accent,
            ),
            ToastMetric(
              label: '최근 상태',
              value: stockAuditState.lastCompleted ? '완료' : '진행 중',
              tone: stockAuditState.lastCompleted
                  ? ToastColorTokens.success
                  : ToastColorTokens.warning,
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: '실사 대상 품목',
          trailing: ToastStatusBadge(
            label: '완료 시 재고 반영',
            color: ToastColorTokens.warning,
            compact: true,
          ),
          child: _SimpleDataTable(
            columns: const ['제품', '시스템 재고', '실사 수량', '차이', '상태'],
            rows: rows,
          ),
        ),
      ],
    );
  }

  Widget _buildNewMenuPage({
    required String storeId,
    required InventoryPurchaseNewMenuState newMenuState,
    required InventoryPurchaseProductCatalogState productCatalog,
    required RecipeState recipeState,
  }) {
    final gramProducts = _gramRecipeProducts(productCatalog.products);

    return _PageShell(
      title: '신메뉴 등록',
      subtitle: '기본 정보, 재료 구성, 조리 순서, 원가 확인, 등록 완료 흐름을 분리합니다.',
      isLoading: newMenuState.isLoading || productCatalog.isLoading,
      error: newMenuState.error ?? productCatalog.error,
      actions: [
        PosActionButton(
          label: '신메뉴 등록',
          tone: PosActionTone.primary,
          icon: Icons.restaurant_menu_outlined,
          loading: newMenuState.isSaving,
          disabledReason: gramProducts.isEmpty
              ? PosActionDisabledReason.upstreamPending
              : PosActionDisabledReason.noSelection,
          onPressed: newMenuState.isSaving || gramProducts.isEmpty
              ? null
              : () => _showNewMenuDialog(
                  storeId: storeId,
                  categories: newMenuState.categories,
                  products: gramProducts,
                ),
          compact: true,
        ),
      ],
      children: [
        _StepFlow(steps: const ['기본 정보', '재료 구성', '조리 순서', '원가 확인', '등록 완료']),
        const SizedBox(height: ToastSpacingTokens.md),
        ToastMetricStrip(
          metrics: [
            ToastMetric(
              label: '메뉴 카테고리',
              value: '${newMenuState.categories.length}개',
            ),
            ToastMetric(label: '레시피 가능 재료', value: '${gramProducts.length}개'),
            ToastMetric(
              label: '기존 메뉴',
              value: '${recipeState.menuItems.length}개',
            ),
            ToastMetric(
              label: '최근 등록',
              value: _string(
                newMenuState.lastCreatedMenu?['name'],
                fallback: '-',
              ),
              tone: ToastColorTokens.success,
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: '레시피 재료 후보',
          child: _SimpleDataTable(
            columns: const ['제품', '카테고리', '표시 단위', '기준 단위'],
            rows: gramProducts
                .take(10)
                .map(
                  (product) => [
                    _string(product['name'], fallback: '-'),
                    _string(product['category'], fallback: '-'),
                    _string(product['stock_unit'], fallback: '-'),
                    _string(product['base_unit'], fallback: '-'),
                  ],
                )
                .toList(),
          ),
        ),
      ],
    );
  }
}

class _InventoryPurchaseSection {
  const _InventoryPurchaseSection({
    required this.label,
    required this.subtitle,
    required this.icon,
  });

  final String label;
  final String subtitle;
  final IconData icon;
}

class _SectionRailItem extends StatelessWidget {
  const _SectionRailItem({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final _InventoryPurchaseSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? ToastColorTokens.accent
        : ToastColorTokens.textSecondary;
    return Material(
      color: selected ? ToastColorTokens.accentMuted : Colors.transparent,
      borderRadius: ToastRadiusTokens.sm,
      child: InkWell(
        borderRadius: ToastRadiusTokens.sm,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 54),
          padding: const EdgeInsets.symmetric(
            horizontal: ToastSpacingTokens.md,
            vertical: ToastSpacingTokens.sm,
          ),
          decoration: BoxDecoration(
            borderRadius: ToastRadiusTokens.sm,
            border: Border.all(
              color: selected
                  ? ToastColorTokens.accent.withValues(alpha: 0.2)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Icon(section.icon, color: color, size: 18),
              const SizedBox(width: ToastSpacingTokens.sm),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      section.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _textStyle(
                        size: 13,
                        weight: FontWeight.w800,
                        color: selected
                            ? ToastColorTokens.accentStrong
                            : ToastColorTokens.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      section.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _textStyle(
                        size: 10.5,
                        weight: FontWeight.w600,
                        color: ToastColorTokens.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PageShell extends StatelessWidget {
  const _PageShell({
    required this.title,
    required this.subtitle,
    required this.children,
    this.actions = const [],
    this.isLoading = false,
    this.error,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final List<Widget> actions;
  final bool isLoading;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return ToastWorkSurface(
      padding: EdgeInsets.zero,
      clip: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: _textStyle(
                          size: 24,
                          weight: FontWeight.w900,
                          color: ToastColorTokens.textPrimary,
                        ),
                      ),
                      const SizedBox(height: ToastSpacingTokens.xs),
                      Text(
                        subtitle,
                        style: _textStyle(
                          size: 13,
                          weight: FontWeight.w500,
                          color: ToastColorTokens.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (actions.isNotEmpty) ...[
                  const SizedBox(width: ToastSpacingTokens.md),
                  Wrap(
                    spacing: ToastSpacingTokens.sm,
                    runSpacing: ToastSpacingTokens.sm,
                    alignment: WrapAlignment.end,
                    children: actions,
                  ),
                ],
              ],
            ),
          ),
          if (isLoading) const LinearProgressIndicator(minHeight: 2),
          if (error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: ToastStatusBadge(
                label: error!,
                color: ToastColorTokens.danger,
                icon: Icons.error_outline,
              ),
            ),
          Expanded(
            child: ToastViewportScroll(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DataCard extends StatelessWidget {
  const _DataCard({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: ToastColorTokens.surface,
        borderRadius: ToastRadiusTokens.md,
        border: Border.all(color: ToastColorTokens.border),
      ),
      padding: const EdgeInsets.all(ToastSpacingTokens.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: _textStyle(
                    size: 15,
                    weight: FontWeight.w900,
                    color: ToastColorTokens.textPrimary,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: ToastSpacingTokens.md),
          child,
        ],
      ),
    );
  }
}

class _SimpleDataTable extends StatelessWidget {
  const _SimpleDataTable({required this.columns, required this.rows});

  final List<String> columns;
  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const _EmptyInline(
        label: '표시할 데이터가 없습니다.',
        icon: Icons.inbox_outlined,
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 720),
        child: Table(
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          columnWidths: {
            for (var index = 0; index < columns.length; index++)
              index: const FlexColumnWidth(),
          },
          children: [
            TableRow(
              decoration: const BoxDecoration(
                color: ToastColorTokens.mutedSurface,
              ),
              children: [
                for (final column in columns)
                  _TableCellText(column, header: true),
              ],
            ),
            for (final row in rows)
              TableRow(
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: ToastColorTokens.border),
                  ),
                ),
                children: [
                  for (var index = 0; index < columns.length; index++)
                    _TableCellText(index < row.length ? row[index] : '-'),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _TableCellText extends StatelessWidget {
  const _TableCellText(this.value, {this.header = false});

  final String value;
  final bool header;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ToastSpacingTokens.sm,
        vertical: ToastSpacingTokens.sm,
      ),
      child: Text(
        value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: _textStyle(
          size: header ? 11 : 12,
          weight: header ? FontWeight.w800 : FontWeight.w600,
          color: header
              ? ToastColorTokens.textSecondary
              : ToastColorTokens.textPrimary,
        ),
      ),
    );
  }
}

class _ConsumptionTrendChart extends StatelessWidget {
  const _ConsumptionTrendChart({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final chartRows = rows
        .where((row) => _num(row['avg_daily_consumption_base']) > 0)
        .take(8)
        .toList();
    if (chartRows.isEmpty) {
      return const _EmptyInline(
        label: '소진 추이 데이터가 없습니다.',
        icon: Icons.show_chart,
      );
    }

    final maxY = chartRows
        .map((row) => _num(row['avg_daily_consumption_base']).toDouble())
        .fold<double>(0, (left, right) => left > right ? left : right);

    return SizedBox(
      height: 280,
      child: BarChart(
        BarChartData(
          maxY: maxY <= 0 ? 1 : maxY * 1.2,
          alignment: BarChartAlignment.spaceAround,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) =>
                const FlLine(color: ToastColorTokens.border, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 48,
                getTitlesWidget: (value, meta) => Text(
                  _number(value),
                  style: _textStyle(
                    size: 10,
                    weight: FontWeight.w700,
                    color: ToastColorTokens.textMuted,
                  ),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 46,
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  if (index < 0 || index >= chartRows.length) {
                    return const SizedBox.shrink();
                  }
                  final name = _string(
                    chartRows[index]['product_name'],
                    fallback: '-',
                  );
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SizedBox(
                      width: 72,
                      child: Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: _textStyle(
                          size: 10,
                          weight: FontWeight.w700,
                          color: ToastColorTokens.textSecondary,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          barGroups: [
            for (var index = 0; index < chartRows.length; index++)
              BarChartGroupData(
                x: index,
                barRods: [
                  BarChartRodData(
                    toY: _num(
                      chartRows[index]['avg_daily_consumption_base'],
                    ).toDouble(),
                    color: _riskColor(chartRows[index]['risk_status']),
                    width: 22,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ConsumptionShareList extends StatelessWidget {
  const _ConsumptionShareList({required this.rows});

  final List<_ConsumptionShare> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const _EmptyInline(
        label: '카테고리별 소진 데이터가 없습니다.',
        icon: Icons.donut_large_outlined,
      );
    }

    final total = rows.fold<num>(0, (sum, row) => sum + row.quantity);
    return Column(
      children: [
        for (var index = 0; index < rows.length; index++) ...[
          _ConsumptionShareRow(row: rows[index], total: total),
          if (index != rows.length - 1)
            const SizedBox(height: ToastSpacingTokens.sm),
        ],
      ],
    );
  }
}

class _ConsumptionShareRow extends StatelessWidget {
  const _ConsumptionShareRow({required this.row, required this.total});

  final _ConsumptionShare row;
  final num total;

  @override
  Widget build(BuildContext context) {
    final ratio = total <= 0
        ? 0.0
        : (row.quantity / total).clamp(0.0, 1.0).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: row.color,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            const SizedBox(width: ToastSpacingTokens.sm),
            Expanded(
              child: Text(
                row.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _textStyle(
                  size: 12,
                  weight: FontWeight.w800,
                  color: ToastColorTokens.textPrimary,
                ),
              ),
            ),
            Text(
              '${_quantity(row.quantity)} /일 · ${row.count}개',
              style: _textStyle(
                size: 12,
                weight: FontWeight.w700,
                color: ToastColorTokens.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            minHeight: 7,
            value: ratio,
            color: row.color,
            backgroundColor: ToastColorTokens.mutedSurface,
          ),
        ),
      ],
    );
  }
}

class _ConsumptionAlertList extends StatelessWidget {
  const _ConsumptionAlertList({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const _EmptyInline(
        label: '소진 위험 알림이 없습니다.',
        icon: Icons.check_circle_outline,
      );
    }

    return Column(
      children: [
        for (var index = 0; index < rows.length; index++) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_outlined,
                color: _riskColor(rows[index]['risk_status']),
                size: 20,
              ),
              const SizedBox(width: ToastSpacingTokens.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _string(rows[index]['product_name'], fallback: '-'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _textStyle(
                              size: 13,
                              weight: FontWeight.w900,
                              color: ToastColorTokens.textPrimary,
                            ),
                          ),
                        ),
                        ToastStatusBadge(
                          label: _riskLabel(rows[index]['risk_status']),
                          color: _riskColor(rows[index]['risk_status']),
                          compact: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '현재 ${_displayStock(rows[index])} · 예상 ${_number(rows[index]['estimated_days_remaining'])}일 · 일소진 ${_quantity(rows[index]['avg_daily_consumption_base'])}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: _textStyle(
                        size: 11.5,
                        weight: FontWeight.w600,
                        color: ToastColorTokens.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (index != rows.length - 1)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: ToastSpacingTokens.sm),
              child: Divider(height: 1, color: ToastColorTokens.border),
            ),
        ],
      ],
    );
  }
}

class _ConsumptionShare {
  const _ConsumptionShare({
    required this.label,
    required this.quantity,
    required this.count,
    required this.color,
  });

  final String label;
  final num quantity;
  final int count;
  final Color color;
}

class _ResponsiveGrid extends StatelessWidget {
  const _ResponsiveGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 900 ? 1 : 3;
        final width =
            (constraints.maxWidth - (ToastSpacingTokens.md * (columns - 1))) /
            columns;

        return Wrap(
          spacing: ToastSpacingTokens.md,
          runSpacing: ToastSpacingTokens.md,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }
}

class _ResponsiveSplit extends StatelessWidget {
  const _ResponsiveSplit({
    required this.children,
    this.leftFlex = 1,
    this.rightFlex = 1,
  });

  final List<Widget> children;
  final int leftFlex;
  final int rightFlex;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 960 || children.length < 2) {
          return Column(
            children: [
              for (var index = 0; index < children.length; index++) ...[
                children[index],
                if (index != children.length - 1)
                  const SizedBox(height: ToastSpacingTokens.md),
              ],
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: leftFlex, child: children[0]),
            const SizedBox(width: ToastSpacingTokens.md),
            Expanded(flex: rightFlex, child: children[1]),
          ],
        );
      },
    );
  }
}

class _DialogGrid extends StatelessWidget {
  const _DialogGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 620 ? 1 : 2;
        final width =
            (constraints.maxWidth - (ToastSpacingTokens.md * (columns - 1))) /
            columns;
        return Wrap(
          spacing: ToastSpacingTokens.md,
          runSpacing: ToastSpacingTokens.md,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }
}

class _SupplierManagementList extends StatelessWidget {
  const _SupplierManagementList({
    required this.suppliers,
    required this.selectedSupplierId,
    required this.saving,
    required this.onSelect,
    required this.onEdit,
    required this.onToggleStatus,
  });

  final List<Map<String, dynamic>> suppliers;
  final String? selectedSupplierId;
  final bool saving;
  final ValueChanged<Map<String, dynamic>> onSelect;
  final ValueChanged<Map<String, dynamic>> onEdit;
  final ValueChanged<Map<String, dynamic>> onToggleStatus;

  @override
  Widget build(BuildContext context) {
    if (suppliers.isEmpty) {
      return const _EmptyInline(
        label: '등록된 거래처가 없습니다.',
        icon: Icons.storefront_outlined,
      );
    }

    return Column(
      children: [
        for (final supplier in suppliers) ...[
          _SupplierManagementRow(
            supplier: supplier,
            selected: supplier['id']?.toString() == selectedSupplierId,
            saving: saving,
            onSelect: onSelect,
            onEdit: onEdit,
            onToggleStatus: onToggleStatus,
          ),
          if (supplier != suppliers.last) const Divider(height: 1),
        ],
      ],
    );
  }
}

class _SupplierManagementRow extends StatelessWidget {
  const _SupplierManagementRow({
    required this.supplier,
    required this.selected,
    required this.saving,
    required this.onSelect,
    required this.onEdit,
    required this.onToggleStatus,
  });

  final Map<String, dynamic> supplier;
  final bool selected;
  final bool saving;
  final ValueChanged<Map<String, dynamic>> onSelect;
  final ValueChanged<Map<String, dynamic>> onEdit;
  final ValueChanged<Map<String, dynamic>> onToggleStatus;

  @override
  Widget build(BuildContext context) {
    final status = _string(supplier['status'], fallback: 'inactive');
    return Material(
      color: selected ? ToastColorTokens.accentMuted : Colors.transparent,
      borderRadius: ToastRadiusTokens.sm,
      child: InkWell(
        borderRadius: ToastRadiusTokens.sm,
        onTap: () => onSelect(supplier),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: ToastSpacingTokens.sm),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _string(supplier['supplier_name'], fallback: '-'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _textStyle(
                        size: 12.5,
                        weight: FontWeight.w900,
                        color: ToastColorTokens.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_string(supplier['supplier_type'], fallback: '분류 없음')} · ${_string(supplier['contact_name'], fallback: '담당자 없음')} · ${_string(supplier['phone'], fallback: '-')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _textStyle(
                        size: 11,
                        weight: FontWeight.w600,
                        color: ToastColorTokens.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: ToastSpacingTokens.sm),
              ToastStatusBadge(
                label: _supplierStatusLabel(status),
                color: _supplierStatusColor(status),
                compact: true,
              ),
              const SizedBox(width: ToastSpacingTokens.sm),
              PosActionButton(
                label: '수정',
                tone: PosActionTone.secondary,
                icon: Icons.edit_outlined,
                onPressed: saving ? null : () => onEdit(supplier),
                compact: true,
              ),
              const SizedBox(width: ToastSpacingTokens.sm),
              PosActionButton(
                label: status == 'active' ? '중지' : '사용',
                tone: status == 'active'
                    ? PosActionTone.destructive
                    : PosActionTone.affirm,
                icon: status == 'active'
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
                onPressed: saving ? null : () => onToggleStatus(supplier),
                compact: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SupplierDetailPanel extends StatelessWidget {
  const _SupplierDetailPanel({
    required this.supplier,
    required this.supplierItemCount,
  });

  final Map<String, dynamic>? supplier;
  final int supplierItemCount;

  @override
  Widget build(BuildContext context) {
    if (supplier == null) {
      return const _EmptyInline(
        label: '거래처를 선택하면 상세 정보가 표시됩니다.',
        icon: Icons.storefront_outlined,
      );
    }

    return Column(
      children: [
        _KeyValueRow(
          label: '거래처명',
          value: _string(supplier!['supplier_name'], fallback: '-'),
          helper: _string(supplier!['supplier_type'], fallback: '분류 없음'),
        ),
        const Divider(height: 1),
        _KeyValueRow(
          label: '담당자',
          value: _string(supplier!['contact_name'], fallback: '-'),
          helper: _string(supplier!['phone'], fallback: '-'),
        ),
        const Divider(height: 1),
        _KeyValueRow(
          label: '결제 조건',
          value: _string(supplier!['payment_terms'], fallback: '-'),
          helper:
              '${_date(supplier!['contract_start_date'])} ~ ${_date(supplier!['contract_end_date'])}',
        ),
        const Divider(height: 1),
        _KeyValueRow(
          label: '공급 품목',
          value: '$supplierItemCount개',
          helper: _string(supplier!['address'], fallback: '주소 없음'),
        ),
      ],
    );
  }
}

class _ProductManagementList extends StatelessWidget {
  const _ProductManagementList({
    required this.products,
    required this.selectedProductId,
    required this.saving,
    required this.onSelect,
    required this.onEdit,
    required this.onToggleActive,
  });

  final List<Map<String, dynamic>> products;
  final String? selectedProductId;
  final bool saving;
  final ValueChanged<Map<String, dynamic>> onSelect;
  final ValueChanged<Map<String, dynamic>> onEdit;
  final ValueChanged<Map<String, dynamic>> onToggleActive;

  @override
  Widget build(BuildContext context) {
    if (products.isEmpty) {
      return const _EmptyInline(
        label: '등록된 제품이 없습니다.',
        icon: Icons.category_outlined,
      );
    }

    return Column(
      children: [
        for (final product in products) ...[
          _ProductManagementRow(
            product: product,
            selected: product['id']?.toString() == selectedProductId,
            saving: saving,
            onSelect: onSelect,
            onEdit: onEdit,
            onToggleActive: onToggleActive,
          ),
          if (product != products.last) const Divider(height: 1),
        ],
      ],
    );
  }
}

class _ProductManagementRow extends StatelessWidget {
  const _ProductManagementRow({
    required this.product,
    required this.selected,
    required this.saving,
    required this.onSelect,
    required this.onEdit,
    required this.onToggleActive,
  });

  final Map<String, dynamic> product;
  final bool selected;
  final bool saving;
  final ValueChanged<Map<String, dynamic>> onSelect;
  final ValueChanged<Map<String, dynamic>> onEdit;
  final ValueChanged<Map<String, dynamic>> onToggleActive;

  @override
  Widget build(BuildContext context) {
    final active = product['is_active'] == true;
    final orderable = product['is_orderable'] == true;
    return Material(
      color: selected ? ToastColorTokens.accentMuted : Colors.transparent,
      borderRadius: ToastRadiusTokens.sm,
      child: InkWell(
        borderRadius: ToastRadiusTokens.sm,
        onTap: () => onSelect(product),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: ToastSpacingTokens.sm),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _string(product['name'], fallback: '-'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _textStyle(
                        size: 12.5,
                        weight: FontWeight.w900,
                        color: ToastColorTokens.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_string(product['product_code'], fallback: '코드 없음')} · ${_string(product['category'], fallback: '분류 없음')} · ${_string(product['stock_unit'], fallback: '-')} / ${_string(product['base_unit'], fallback: '-')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _textStyle(
                        size: 11,
                        weight: FontWeight.w600,
                        color: ToastColorTokens.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: ToastSpacingTokens.sm),
              ToastStatusBadge(
                label: orderable ? '발주 가능' : '발주 중지',
                color: orderable
                    ? ToastColorTokens.success
                    : ToastColorTokens.warning,
                compact: true,
              ),
              const SizedBox(width: ToastSpacingTokens.sm),
              ToastStatusBadge(
                label: active ? '사용 중' : '사용 중지',
                color: active
                    ? ToastColorTokens.success
                    : ToastColorTokens.textSecondary,
                compact: true,
              ),
              const SizedBox(width: ToastSpacingTokens.sm),
              PosActionButton(
                label: '수정',
                tone: PosActionTone.secondary,
                icon: Icons.edit_outlined,
                onPressed: saving ? null : () => onEdit(product),
                compact: true,
              ),
              const SizedBox(width: ToastSpacingTokens.sm),
              PosActionButton(
                label: active ? '중지' : '사용',
                tone: active ? PosActionTone.destructive : PosActionTone.affirm,
                icon: active
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
                onPressed: saving ? null : () => onToggleActive(product),
                compact: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProductDetailPanel extends StatelessWidget {
  const _ProductDetailPanel({
    required this.product,
    required this.supplierItemCount,
  });

  final Map<String, dynamic>? product;
  final int supplierItemCount;

  @override
  Widget build(BuildContext context) {
    if (product == null) {
      return const _EmptyInline(
        label: '제품을 선택하면 상세 정보가 표시됩니다.',
        icon: Icons.category_outlined,
      );
    }

    final inventoryItem = product!['inventory_item'] is Map
        ? Map<String, dynamic>.from(product!['inventory_item'] as Map)
        : const <String, dynamic>{};

    return Column(
      children: [
        _KeyValueRow(
          label: '제품명',
          value: _string(product!['name'], fallback: '-'),
          helper: _string(product!['product_code'], fallback: '코드 없음'),
        ),
        const Divider(height: 1),
        _KeyValueRow(
          label: '단위',
          value: _string(product!['stock_unit'], fallback: '-'),
          helper:
              '${_string(product!['base_unit'], fallback: '-')} 기준 ${_quantity(product!['base_unit_factor'])}',
        ),
        const Divider(height: 1),
        _KeyValueRow(
          label: '현재 재고',
          value: _quantity(inventoryItem['current_stock']),
          helper: '재주문 ${_quantity(inventoryItem['reorder_point'])}',
        ),
        const Divider(height: 1),
        _KeyValueRow(
          label: '공급처 단가',
          value: '$supplierItemCount건',
          helper: '기본 단가 ${_money(inventoryItem['cost_per_unit'])}',
        ),
      ],
    );
  }
}

class _SupplierItemList extends StatelessWidget {
  const _SupplierItemList({
    required this.supplierItems,
    required this.saving,
    required this.onEdit,
    required this.onToggleActive,
  });

  final List<Map<String, dynamic>> supplierItems;
  final bool saving;
  final ValueChanged<Map<String, dynamic>> onEdit;
  final ValueChanged<Map<String, dynamic>> onToggleActive;

  @override
  Widget build(BuildContext context) {
    if (supplierItems.isEmpty) {
      return const _EmptyInline(
        label: '연결된 공급처 품목이 없습니다.',
        icon: Icons.link_off_outlined,
      );
    }

    return Column(
      children: [
        for (final item in supplierItems) ...[
          _SupplierItemRow(
            item: item,
            saving: saving,
            onEdit: onEdit,
            onToggleActive: onToggleActive,
          ),
          if (item != supplierItems.last) const Divider(height: 1),
        ],
      ],
    );
  }
}

class _SupplierItemRow extends StatelessWidget {
  const _SupplierItemRow({
    required this.item,
    required this.saving,
    required this.onEdit,
    required this.onToggleActive,
  });

  final Map<String, dynamic> item;
  final bool saving;
  final ValueChanged<Map<String, dynamic>> onEdit;
  final ValueChanged<Map<String, dynamic>> onToggleActive;

  @override
  Widget build(BuildContext context) {
    final supplier = item['supplier'] is Map
        ? Map<String, dynamic>.from(item['supplier'] as Map)
        : const <String, dynamic>{};
    final product = item['product'] is Map
        ? Map<String, dynamic>.from(item['product'] as Map)
        : const <String, dynamic>{};
    final active = item['is_active'] == true;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ToastSpacingTokens.sm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_string(product['name'], fallback: '-')} · ${_string(supplier['supplier_name'], fallback: '-')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _textStyle(
                    size: 12.5,
                    weight: FontWeight.w900,
                    color: ToastColorTokens.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_string(item['order_unit'], fallback: '-')}당 ${_quantity(item['order_unit_quantity_base'])}${_string(product['base_unit'], fallback: '')} · 최소 ${_quantity(item['min_order_quantity'])} · 리드타임 ${_int(item['lead_time_days'])}일',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _textStyle(
                    size: 11,
                    weight: FontWeight.w600,
                    color: ToastColorTokens.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: ToastSpacingTokens.sm),
          Text(
            _money(item['unit_price']),
            style: _textStyle(
              size: 12.5,
              weight: FontWeight.w900,
              color: ToastColorTokens.textPrimary,
            ),
          ),
          const SizedBox(width: ToastSpacingTokens.sm),
          if (item['is_preferred'] == true)
            const ToastStatusBadge(
              label: '기본',
              color: ToastColorTokens.accent,
              compact: true,
            ),
          const SizedBox(width: ToastSpacingTokens.sm),
          ToastStatusBadge(
            label: active ? '사용 중' : '중지',
            color: active
                ? ToastColorTokens.success
                : ToastColorTokens.textSecondary,
            compact: true,
          ),
          const SizedBox(width: ToastSpacingTokens.sm),
          PosActionButton(
            label: '수정',
            tone: PosActionTone.secondary,
            icon: Icons.edit_outlined,
            onPressed: saving ? null : () => onEdit(item),
            compact: true,
          ),
          const SizedBox(width: ToastSpacingTokens.sm),
          PosActionButton(
            label: active ? '중지' : '사용',
            tone: active ? PosActionTone.destructive : PosActionTone.affirm,
            icon: active
                ? Icons.pause_circle_outline
                : Icons.play_circle_outline,
            onPressed: saving ? null : () => onToggleActive(item),
            compact: true,
          ),
        ],
      ),
    );
  }
}

class _RecipeLineList extends StatelessWidget {
  const _RecipeLineList({
    required this.recipes,
    required this.onEdit,
    required this.onDelete,
  });

  final List<Map<String, dynamic>> recipes;
  final ValueChanged<Map<String, dynamic>> onEdit;
  final ValueChanged<Map<String, dynamic>> onDelete;

  @override
  Widget build(BuildContext context) {
    if (recipes.isEmpty) {
      return const _EmptyInline(
        label: '등록된 레시피 라인이 없습니다.',
        icon: Icons.menu_book_outlined,
      );
    }

    return Column(
      children: [
        for (final recipe in recipes) ...[
          _RecipeLineRow(recipe: recipe, onEdit: onEdit, onDelete: onDelete),
          if (recipe != recipes.last) const Divider(height: 1),
        ],
      ],
    );
  }
}

class _RecipeLineRow extends StatelessWidget {
  const _RecipeLineRow({
    required this.recipe,
    required this.onEdit,
    required this.onDelete,
  });

  final Map<String, dynamic> recipe;
  final ValueChanged<Map<String, dynamic>> onEdit;
  final ValueChanged<Map<String, dynamic>> onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ToastSpacingTokens.sm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _string(recipe['menu_item_name'], fallback: '-'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _textStyle(
                    size: 12.5,
                    weight: FontWeight.w900,
                    color: ToastColorTokens.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_string(recipe['ingredient_name'], fallback: '-')} · ${_date(recipe['last_updated'])}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _textStyle(
                    size: 11,
                    weight: FontWeight.w600,
                    color: ToastColorTokens.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: ToastSpacingTokens.sm),
          Text(
            '${_quantity(recipe['quantity_g'])}g',
            style: _textStyle(
              size: 12.5,
              weight: FontWeight.w900,
              color: ToastColorTokens.textPrimary,
            ),
          ),
          const SizedBox(width: ToastSpacingTokens.sm),
          PosActionButton(
            label: '수정',
            tone: PosActionTone.secondary,
            icon: Icons.edit_outlined,
            onPressed: () => onEdit(recipe),
            compact: true,
          ),
          const SizedBox(width: ToastSpacingTokens.sm),
          PosActionButton(
            label: '삭제',
            tone: PosActionTone.destructive,
            icon: Icons.delete_outline,
            onPressed: () => onDelete(recipe),
            compact: true,
          ),
        ],
      ),
    );
  }
}

class _RecommendationList extends StatelessWidget {
  const _RecommendationList({required this.lines});

  final List<Map<String, dynamic>> lines;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) {
      return const _EmptyInline(
        label: '추천 스냅샷이 없습니다.',
        icon: Icons.auto_graph_outlined,
      );
    }

    return Column(
      children: [
        for (final line in lines) ...[
          _KeyValueRow(
            label: _nestedName(line['product']),
            value: _quantity(line['recommended_quantity_base']),
            helper:
                '${_nestedName(line['supplier'])} · ${_riskLabel(line['risk_status'])}',
          ),
          if (line != lines.last) const Divider(height: 1),
        ],
      ],
    );
  }
}

class _RecommendationAdjustmentInput {
  const _RecommendationAdjustmentInput({
    this.adjustedOrderUnits,
    this.memo,
    this.clear = false,
  });

  final double? adjustedOrderUnits;
  final String? memo;
  final bool clear;
}

class _StockAuditSubmitInput {
  const _StockAuditSubmitInput({
    required this.lines,
    required this.complete,
    this.memo,
  });

  final List<Map<String, dynamic>> lines;
  final String? memo;
  final bool complete;
}

class _StockAuditInputRow extends StatelessWidget {
  const _StockAuditInputRow({required this.row, required this.controller});

  final Map<String, dynamic> row;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ToastSpacingTokens.sm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _string(row['product_name'], fallback: '-'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _textStyle(
                    size: 12.5,
                    weight: FontWeight.w900,
                    color: ToastColorTokens.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '시스템 ${_displayStock(row)} · ${_string(row['category'], fallback: '-')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _textStyle(
                    size: 11,
                    weight: FontWeight.w600,
                    color: ToastColorTokens.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: ToastSpacingTokens.md),
          SizedBox(
            width: 160,
            child: TextField(
              controller: controller,
              textAlign: TextAlign.right,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: '실사 수량(${_string(row['base_unit'], fallback: '-')})',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecommendationAdjustmentList extends StatelessWidget {
  const _RecommendationAdjustmentList({
    required this.lines,
    required this.updatingLineId,
    required this.onAdjust,
  });

  final List<Map<String, dynamic>> lines;
  final String? updatingLineId;
  final ValueChanged<Map<String, dynamic>> onAdjust;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) {
      return const _EmptyInline(
        label: '조정할 추천 발주 라인이 없습니다.',
        icon: Icons.tune_outlined,
      );
    }

    return Column(
      children: [
        for (final line in lines) ...[
          _RecommendationAdjustmentRow(
            line: line,
            updating: line['id']?.toString() == updatingLineId,
            busy: updatingLineId != null,
            onAdjust: onAdjust,
          ),
          if (line != lines.last) const Divider(height: 1),
        ],
      ],
    );
  }
}

class _RecommendationAdjustmentRow extends StatelessWidget {
  const _RecommendationAdjustmentRow({
    required this.line,
    required this.updating,
    required this.busy,
    required this.onAdjust,
  });

  final Map<String, dynamic> line;
  final bool updating;
  final bool busy;
  final ValueChanged<Map<String, dynamic>> onAdjust;

  @override
  Widget build(BuildContext context) {
    final adjustedUnits = line['adjusted_order_units'];
    final effectiveUnits = adjustedUnits ?? line['recommended_order_units'];
    final adjusted = adjustedUnits != null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ToastSpacingTokens.sm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _nestedName(line['product']),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _textStyle(
                    size: 12.5,
                    weight: FontWeight.w900,
                    color: ToastColorTokens.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_nestedName(line['supplier'])} · 추천 ${_quantity(line['recommended_order_units'])} · 적용 ${_quantity(effectiveUnits)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _textStyle(
                    size: 11,
                    weight: FontWeight.w600,
                    color: ToastColorTokens.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: ToastSpacingTokens.sm),
          ToastStatusBadge(
            label: adjusted ? '조정됨' : '추천값',
            color: adjusted
                ? ToastColorTokens.warning
                : ToastColorTokens.textSecondary,
            compact: true,
          ),
          const SizedBox(width: ToastSpacingTokens.sm),
          PosActionButton(
            label: '수량 조정',
            tone: PosActionTone.secondary,
            icon: Icons.tune_outlined,
            loading: updating,
            disabledReason: busy
                ? PosActionDisabledReason.upstreamPending
                : PosActionDisabledReason.noSelection,
            onPressed: busy ? null : () => onAdjust(line),
            compact: true,
          ),
        ],
      ),
    );
  }
}

class _OrderList extends StatelessWidget {
  const _OrderList({required this.orders});

  final List<Map<String, dynamic>> orders;

  @override
  Widget build(BuildContext context) {
    if (orders.isEmpty) {
      return const _EmptyInline(
        label: '최근 발주가 없습니다.',
        icon: Icons.receipt_long_outlined,
      );
    }

    return Column(
      children: [
        for (final order in orders) ...[
          _KeyValueRow(
            label: _string(order['purchase_order_no'], fallback: '-'),
            value: _money(order['total_amount']),
            helper:
                '${_nestedName(order['supplier'])} · ${_statusLabel(order['status'])}',
          ),
          if (order != orders.last) const Divider(height: 1),
        ],
      ],
    );
  }
}

class _PurchaseOrderActionList extends StatelessWidget {
  const _PurchaseOrderActionList({
    required this.orders,
    required this.selectedOrderId,
    required this.printingOrderId,
    required this.onSelect,
    required this.onPrint,
  });

  final List<Map<String, dynamic>> orders;
  final String? selectedOrderId;
  final String? printingOrderId;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onPrint;

  @override
  Widget build(BuildContext context) {
    if (orders.isEmpty) {
      return const _EmptyInline(
        label: '출력할 발주서가 없습니다.',
        icon: Icons.print_outlined,
      );
    }

    return Column(
      children: [
        for (final order in orders) ...[
          _PurchaseOrderActionRow(
            order: order,
            selected: order['id']?.toString() == selectedOrderId,
            printing: order['id']?.toString() == printingOrderId,
            busy: printingOrderId != null,
            onSelect: onSelect,
            onPrint: onPrint,
          ),
          if (order != orders.last) const Divider(height: 1),
        ],
      ],
    );
  }
}

class _PurchaseOrderActionRow extends StatelessWidget {
  const _PurchaseOrderActionRow({
    required this.order,
    required this.selected,
    required this.printing,
    required this.busy,
    required this.onSelect,
    required this.onPrint,
  });

  final Map<String, dynamic> order;
  final bool selected;
  final bool printing;
  final bool busy;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onPrint;

  @override
  Widget build(BuildContext context) {
    final orderId = order['id']?.toString();
    final orderNo = _string(order['purchase_order_no'], fallback: '-');
    final supplier = _nestedName(order['supplier']);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ToastSpacingTokens.sm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        orderNo,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _textStyle(
                          size: 12.5,
                          weight: FontWeight.w900,
                          color: ToastColorTokens.textPrimary,
                        ),
                      ),
                    ),
                    if (selected) ...[
                      const SizedBox(width: ToastSpacingTokens.sm),
                      const ToastStatusBadge(
                        label: '선택됨',
                        color: ToastColorTokens.accent,
                        compact: true,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '$supplier · ${_statusLabel(order['status'])} · ${_money(order['total_amount'])}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _textStyle(
                    size: 11,
                    weight: FontWeight.w600,
                    color: ToastColorTokens.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: ToastSpacingTokens.sm),
          PosActionButton(
            label: '상세',
            tone: PosActionTone.secondary,
            icon: Icons.visibility_outlined,
            onPressed: orderId == null ? null : () => onSelect(orderId),
            compact: true,
          ),
          const SizedBox(width: ToastSpacingTokens.sm),
          PosActionButton(
            label: '출력/PDF',
            tone: PosActionTone.primary,
            icon: Icons.print_outlined,
            loading: printing,
            disabledReason: busy
                ? PosActionDisabledReason.upstreamPending
                : PosActionDisabledReason.noSelection,
            onPressed: orderId == null || busy ? null : () => onPrint(orderId),
            compact: true,
          ),
        ],
      ),
    );
  }
}

class _KeyValueRow extends StatelessWidget {
  const _KeyValueRow({
    required this.label,
    required this.value,
    required this.helper,
  });

  final String label;
  final String value;
  final String helper;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ToastSpacingTokens.sm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _textStyle(
                    size: 12.5,
                    weight: FontWeight.w800,
                    color: ToastColorTokens.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  helper,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _textStyle(
                    size: 11,
                    weight: FontWeight.w600,
                    color: ToastColorTokens.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: ToastSpacingTokens.sm),
          Text(
            value,
            style: _textStyle(
              size: 12.5,
              weight: FontWeight.w900,
              color: ToastColorTokens.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickActionBand extends StatelessWidget {
  const _QuickActionBand({
    required this.onSelectStock,
    required this.onSelectPurchase,
    required this.onSelectPrint,
    required this.onSelectAudit,
  });

  final VoidCallback onSelectStock;
  final VoidCallback onSelectPurchase;
  final VoidCallback onSelectPrint;
  final VoidCallback onSelectAudit;

  @override
  Widget build(BuildContext context) {
    return _DataCard(
      title: '빠른 메뉴',
      child: Wrap(
        spacing: ToastSpacingTokens.sm,
        runSpacing: ToastSpacingTokens.sm,
        children: [
          _QuickAction(
            icon: Icons.inventory_2_outlined,
            label: '재고 현황',
            onTap: onSelectStock,
          ),
          _QuickAction(
            icon: Icons.shopping_cart_outlined,
            label: '발주 추천',
            onTap: onSelectPurchase,
          ),
          _QuickAction(
            icon: Icons.print_outlined,
            label: '발주서 출력',
            onTap: onSelectPrint,
          ),
          _QuickAction(
            icon: Icons.fact_check_outlined,
            label: '실재고 실사',
            onTap: onSelectAudit,
          ),
        ],
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 168,
      child: Material(
        color: ToastColorTokens.mutedSurface,
        borderRadius: ToastRadiusTokens.sm,
        child: InkWell(
          borderRadius: ToastRadiusTokens.sm,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(ToastSpacingTokens.md),
            child: Row(
              children: [
                Icon(icon, color: ToastColorTokens.accent, size: 18),
                const SizedBox(width: ToastSpacingTokens.sm),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _textStyle(
                      size: 12,
                      weight: FontWeight.w800,
                      color: ToastColorTokens.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StepFlow extends StatelessWidget {
  const _StepFlow({required this.steps});

  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return _DataCard(
      title: '레시피 등록 과정',
      child: Wrap(
        spacing: ToastSpacingTokens.sm,
        runSpacing: ToastSpacingTokens.sm,
        children: [
          for (var index = 0; index < steps.length; index++)
            Container(
              width: 176,
              padding: const EdgeInsets.all(ToastSpacingTokens.md),
              decoration: BoxDecoration(
                color: index == 0
                    ? ToastColorTokens.accentMuted
                    : ToastColorTokens.mutedSurface,
                borderRadius: ToastRadiusTokens.sm,
                border: Border.all(color: ToastColorTokens.border),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: index == 0
                        ? ToastColorTokens.accent
                        : ToastColorTokens.borderStrong,
                    child: Text(
                      '${index + 1}',
                      style: _textStyle(
                        size: 11,
                        weight: FontWeight.w900,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: ToastSpacingTokens.sm),
                  Expanded(
                    child: Text(
                      steps[index],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _textStyle(
                        size: 12,
                        weight: FontWeight.w800,
                        color: ToastColorTokens.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return PosActionButton(
      label: '새로고침',
      tone: PosActionTone.secondary,
      icon: Icons.refresh,
      onPressed: onPressed,
      compact: true,
    );
  }
}

class _EmptyWorkspace extends StatelessWidget {
  const _EmptyWorkspace({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return ToastWorkSurface(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: ToastColorTokens.textMuted, size: 40),
            const SizedBox(height: ToastSpacingTokens.md),
            Text(
              title,
              style: _textStyle(
                size: 22,
                weight: FontWeight.w900,
                color: ToastColorTokens.textPrimary,
              ),
            ),
            const SizedBox(height: ToastSpacingTokens.xs),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: _textStyle(
                size: 13,
                weight: FontWeight.w600,
                color: ToastColorTokens.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyInline extends StatelessWidget {
  const _EmptyInline({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(ToastSpacingTokens.lg),
      decoration: BoxDecoration(
        color: ToastColorTokens.mutedSurface,
        borderRadius: ToastRadiusTokens.sm,
        border: Border.all(color: ToastColorTokens.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: ToastColorTokens.textMuted, size: 18),
          const SizedBox(width: ToastSpacingTokens.sm),
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: _textStyle(
                size: 12,
                weight: FontWeight.w700,
                color: ToastColorTokens.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

TextStyle _textStyle({
  required double size,
  required FontWeight weight,
  required Color color,
}) {
  return GoogleFonts.notoSansKr(
    fontSize: size,
    fontWeight: weight,
    color: color,
    height: 1.25,
    letterSpacing: 0,
  );
}

Map<String, dynamic>? _firstWhereOrNull(
  List<Map<String, dynamic>> rows,
  bool Function(Map<String, dynamic>) test,
) {
  for (final row in rows) {
    if (test(row)) return row;
  }
  return null;
}

List<_ConsumptionShare> _buildConsumptionShares(
  List<Map<String, dynamic>> rows,
) {
  final totals = <String, num>{};
  final counts = <String, int>{};
  for (final row in rows) {
    final category = _string(row['category'], fallback: '분류 없음');
    totals[category] =
        (totals[category] ?? 0) + _num(row['avg_daily_consumption_base']);
    counts[category] = (counts[category] ?? 0) + 1;
  }

  final palette = <Color>[
    ToastColorTokens.accent,
    ToastColorTokens.success,
    ToastColorTokens.warning,
    ToastColorTokens.danger,
    ToastColorTokens.info,
    ToastColorTokens.textMuted,
  ];
  final entries = totals.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  return [
    for (var index = 0; index < entries.length; index++)
      _ConsumptionShare(
        label: entries[index].key,
        quantity: entries[index].value,
        count: counts[entries[index].key] ?? 0,
        color: palette[index % palette.length],
      ),
  ];
}

String? _nullableText(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

DateTime? _parseDateOrNull(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return DateTime.tryParse(trimmed);
}

String _dateOrBlank(Object? value) {
  final text = _string(value);
  if (text.length >= 10) return text.substring(0, 10);
  return text;
}

int _contractAttentionCount(List<Map<String, dynamic>> suppliers) {
  final today = DateTime.now();
  final threshold = today.add(const Duration(days: 30));
  return suppliers.where((supplier) {
    if (_string(supplier['status']) != 'active') return false;
    final endDate = _parseDateOrNull(
      _dateOrBlank(supplier['contract_end_date']),
    );
    if (endDate == null) return false;
    return !endDate.isBefore(today) && !endDate.isAfter(threshold);
  }).length;
}

List<Map<String, dynamic>> _gramRecipeProducts(
  List<Map<String, dynamic>> products,
) {
  return products
      .where(
        (product) =>
            product['is_active'] == true &&
            _string(product['base_unit']) == 'g' &&
            _string(product['id']).isNotEmpty &&
            _string(product['inventory_item_id']).isNotEmpty,
      )
      .toList();
}

List<Map<String, dynamic>> _activeSupplierItemsForSupplier(
  List<Map<String, dynamic>> supplierItems,
  String supplierId,
) {
  return supplierItems
      .where(
        (item) =>
            item['is_active'] == true &&
            item['supplier_id']?.toString() == supplierId &&
            _string(item['id']).isNotEmpty,
      )
      .toList();
}

String _supplierItemLabel(Map<String, dynamic> item) {
  final product = item['product'] is Map
      ? Map<String, dynamic>.from(item['product'] as Map)
      : const <String, dynamic>{};
  return '${_string(product['name'], fallback: '-')} · ${_money(item['unit_price'])}/${_string(item['order_unit'], fallback: 'unit')}';
}

String _supplierStatusLabel(String status) {
  return switch (status) {
    'active' => '사용 중',
    'inactive' => '사용 중지',
    'suspended' => '보류',
    _ => '확인',
  };
}

Color _supplierStatusColor(String status) {
  return switch (status) {
    'active' => ToastColorTokens.success,
    'suspended' => ToastColorTokens.warning,
    'inactive' => ToastColorTokens.textSecondary,
    _ => ToastColorTokens.textMuted,
  };
}

String _money(Object? value) {
  final formatter = NumberFormat.currency(
    locale: 'ko_KR',
    symbol: '₩ ',
    decimalDigits: 0,
  );
  return formatter.format(_num(value));
}

num _num(Object? value) {
  if (value is num) return value;
  return num.tryParse(value?.toString() ?? '') ?? 0;
}

int _int(Object? value) => _num(value).round();

String _number(Object? value, {String fallback = '-'}) {
  if (value == null) return fallback;
  final parsed = _num(value);
  if (parsed == 0 && value.toString() != '0') return fallback;
  return NumberFormat('#,##0.##').format(parsed);
}

String _quantity(Object? value) => _number(value, fallback: '0');

String _string(Object? value, {String fallback = ''}) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? fallback : text;
}

String _date(Object? value) {
  final text = _string(value, fallback: '-');
  if (text.length >= 10) return text.substring(0, 10);
  return text;
}

String _nestedName(Object? value) {
  if (value is Map) {
    return _string(value['name'] ?? value['supplier_name'], fallback: '-');
  }
  return _string(value, fallback: '-');
}

String _displayStock(Map<String, dynamic> row) {
  final unit = _string(row['stock_unit'], fallback: _string(row['base_unit']));
  final value = row['current_stock_display'] ?? row['current_stock_base'];
  return '${_quantity(value)} $unit'.trim();
}

String _riskLabel(Object? value) {
  return switch (_string(value)) {
    'danger' => '위험',
    'warning' => '주의',
    'normal' => '보통',
    'stable' => '안정',
    _ => '확인',
  };
}

Color _riskColor(Object? value) {
  return switch (_string(value)) {
    'danger' => ToastColorTokens.danger,
    'warning' => ToastColorTokens.warning,
    'normal' => ToastColorTokens.info,
    'stable' => ToastColorTokens.success,
    _ => ToastColorTokens.textSecondary,
  };
}

bool _receivableStatus(Object? value) {
  return {
    'office_approved',
    'ordered',
    'partially_received',
  }.contains(_string(value));
}

String _receiptVisibilityLabel(Object? value) {
  return switch (_string(value)) {
    'received' => '입고 완료',
    'partially_received' => '부분 입고',
    'pending' => '입고 대기',
    _ => '확인',
  };
}

String _receiptStatusLabel(Object? value) {
  return switch (_string(value)) {
    'confirmed' => '확정',
    'draft' => '임시',
    'cancelled' => '취소',
    _ => _string(value, fallback: '-'),
  };
}

String _costStatusLabel(Object? value) {
  return switch (_string(value)) {
    'warning' => '주의',
    'missing_supplier_cost' => '단가 없음',
    'normal' => '정상',
    'stable' => '안정',
    _ => '확인',
  };
}

Color _runtimeResultColor(InventoryPurchaseRuntimeResultKind kind) {
  return switch (kind) {
    InventoryPurchaseRuntimeResultKind.success => ToastColorTokens.success,
    InventoryPurchaseRuntimeResultKind.failure => ToastColorTokens.danger,
    InventoryPurchaseRuntimeResultKind.blocked => ToastColorTokens.warning,
    InventoryPurchaseRuntimeResultKind.cancelled =>
      ToastColorTokens.textSecondary,
    InventoryPurchaseRuntimeResultKind.idle => ToastColorTokens.info,
  };
}

IconData _runtimeResultIcon(InventoryPurchaseRuntimeResultKind kind) {
  return switch (kind) {
    InventoryPurchaseRuntimeResultKind.success => Icons.check_circle_outline,
    InventoryPurchaseRuntimeResultKind.failure => Icons.error_outline,
    InventoryPurchaseRuntimeResultKind.blocked => Icons.warning_amber_outlined,
    InventoryPurchaseRuntimeResultKind.cancelled => Icons.cancel_outlined,
    InventoryPurchaseRuntimeResultKind.idle => Icons.info_outline,
  };
}

String _statusLabel(Object? value) {
  return switch (_string(value)) {
    'draft' => '임시',
    'submitted' => '승인 대기',
    'office_approved' => 'Office 승인',
    'office_returned' => '반환',
    'office_rejected' => '반려',
    'ordered' => '발주 진행',
    'partially_received' => '부분 입고',
    'received' => '입고 완료',
    'cancelled' => '취소',
    _ => _string(value, fallback: '-'),
  };
}

bool _printableStatus(Object? value) {
  return {
    'submitted',
    'office_approved',
    'ordered',
    'partially_received',
    'received',
  }.contains(_string(value));
}
