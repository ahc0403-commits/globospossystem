import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../core/utils/number_input_utils.dart';
import '../auth/auth_provider.dart';
import '../inventory/inventory_provider.dart';
import 'inventory_purchase_document_service.dart';

class InventoryPurchaseScreen extends ConsumerStatefulWidget {
  const InventoryPurchaseScreen({
    super.key,
    this.initialSectionIndex = 0,
    this.autoLoad = true,
  });

  final int initialSectionIndex;
  final bool autoLoad;

  @override
  ConsumerState<InventoryPurchaseScreen> createState() =>
      _InventoryPurchaseScreenState();
}

class _InventoryPurchaseScreenState
    extends ConsumerState<InventoryPurchaseScreen> {
  late int _selectedIndex;
  String? _loadedStoreId;
  String? _printingOrderId;
  String? _selectedSupplierId;
  String? _selectedProductId;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialSectionIndex.clamp(0, 10);
  }

  List<_InventoryPurchaseSection> _sections(BuildContext context) {
    final l10n = context.l10n;
    return [
      _InventoryPurchaseSection(
        label: l10n.inventoryPurchaseNavDashboard,
        subtitle: l10n.inventoryPurchaseNavDashboardSubtitle,
        icon: Icons.dashboard_outlined,
      ),
      _InventoryPurchaseSection(
        label: l10n.inventoryPurchaseStockStatusTitle,
        subtitle: l10n.inventoryPurchaseNavStockStatusSubtitle,
        icon: Icons.inventory_2_outlined,
      ),
      _InventoryPurchaseSection(
        label: l10n.inventoryPurchaseManagementTitle,
        subtitle: l10n.inventoryPurchaseNavManagementSubtitle,
        icon: Icons.shopping_cart_outlined,
      ),
      _InventoryPurchaseSection(
        label: l10n.inventoryPurchaseHistoryTitle,
        subtitle: l10n.inventoryPurchaseNavHistorySubtitle,
        icon: Icons.receipt_long_outlined,
      ),
      _InventoryPurchaseSection(
        label: l10n.inventoryPurchaseSupplierManagementTitle,
        subtitle: l10n.inventoryPurchaseSupplierManagementSubtitle,
        icon: Icons.storefront_outlined,
      ),
      _InventoryPurchaseSection(
        label: l10n.inventoryPurchaseProductManagementTitle,
        subtitle: l10n.inventoryPurchaseProductManagementSubtitle,
        icon: Icons.category_outlined,
      ),
      _InventoryPurchaseSection(
        label: l10n.inventoryPurchaseRecipeManagementTitle,
        subtitle: l10n.inventoryPurchaseRecipeManagementSubtitle,
        icon: Icons.menu_book_outlined,
      ),
      _InventoryPurchaseSection(
        label: l10n.inventoryPurchaseConsumptionTitle,
        subtitle: l10n.inventoryPurchaseConsumptionSubtitle,
        icon: Icons.show_chart,
      ),
      _InventoryPurchaseSection(
        label: l10n.inventoryPurchaseCostAnalysisTitle,
        subtitle: l10n.inventoryPurchaseCostAnalysisSubtitle,
        icon: Icons.paid_outlined,
      ),
      _InventoryPurchaseSection(
        label: l10n.inventoryPurchaseStockAuditTitle,
        subtitle: l10n.inventoryPurchaseStockAuditSubtitle,
        icon: Icons.fact_check_outlined,
      ),
      _InventoryPurchaseSection(
        label: l10n.inventoryPurchaseNewMenuTitle,
        subtitle: l10n.inventoryPurchaseNewMenuSubtitle,
        icon: Icons.add_box_outlined,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final storeId = auth.storeId;
    if (widget.autoLoad) {
      _scheduleStoreLoad(storeId);
    }

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

    return LayoutBuilder(
      builder: (context, viewport) {
        final compact = viewport.maxWidth < 1080;
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
          return ToastResponsiveScrollBody(
            key: const Key('inventory_root'),
            maxWidth: 1500,
            padding: const EdgeInsets.all(ToastSpacingTokens.lg),
            children: [
              _buildSectionRail(horizontal: true),
              const SizedBox(height: ToastSpacingTokens.md),
              content,
            ],
          );
        }

        return ToastResponsiveBody(
          key: const Key('inventory_root'),
          maxWidth: 1500,
          padding: const EdgeInsets.all(ToastSpacingTokens.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 214, child: _buildSectionRail()),
              const SizedBox(width: ToastSpacingTokens.md),
              Expanded(child: content),
            ],
          ),
        );
      },
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
    final sections = _sections(context);
    final items = <Widget>[
      for (var index = 0; index < sections.length; index++)
        _SectionRailItem(
          key: Key('inventory_section_$index'),
          section: sections[index],
          selected: index == _selectedIndex,
          onTap: () => setState(() => _selectedIndex = index),
        ),
    ];

    if (horizontal) {
      return SizedBox(
        height: 88,
        child: ListView.separated(
          key: const Key('inventory_section_rail'),
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
        key: const Key('inventory_section_rail'),
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
      final l10n = context.l10n;
      return _EmptyWorkspace(
        title: l10n.inventoryPurchaseStoreRequiredTitle,
        subtitle: l10n.inventoryPurchaseStoreRequiredSubtitle,
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
        orders: orders,
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
        section: _sections(context)[7],
        title: context.l10n.inventoryPurchaseConsumptionTrendTitle,
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
    final l10n = context.l10n;
    final dashboard = overview.dashboard ?? const <String, dynamic>{};
    final riskRows = stockStatus.rows
        .where(
          (row) => {'danger', 'warning'}.contains(_string(row['risk_status'])),
        )
        .take(6)
        .toList();
    final recentOrders = orders.orders.take(6).toList();

    return _PageShell(
      title: l10n.inventoryPurchaseDashboardTitle,
      subtitle: l10n.inventoryPurchaseDashboardSubtitle,
      isLoading:
          overview.isLoading || stockStatus.isLoading || orders.isLoading,
      actions: [_RefreshButton(onPressed: () => _reloadStoreScope(storeId))],
      children: [
        ToastMetricStrip(
          metrics: [
            ToastMetric(
              label: l10n.inventoryPurchaseAssetAmount,
              value: _money(dashboard['total_inventory_amount']),
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseSubmittedAmount,
              value: _money(dashboard['submitted_purchase_amount']),
              tone: ToastColorTokens.accent,
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseOfficeApprovedAmount,
              value: _money(dashboard['approved_purchase_amount']),
              tone: ToastColorTokens.success,
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseLowStockItems,
              value: l10n.inventoryPurchaseCountItems(
                _int(dashboard['low_stock_count']),
              ),
              tone: ToastColorTokens.warning,
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _ResponsiveGrid(
          children: [
            _DataCard(
              title: l10n.inventoryPurchaseLowStockAlerts,
              trailing: ToastStatusBadge(
                label: l10n.inventoryPurchaseShownItems(riskRows.length),
                color: ToastColorTokens.warning,
                compact: true,
              ),
              child: _SimpleDataTable(
                columns: [
                  l10n.inventoryPurchaseProductName,
                  l10n.inventoryPurchaseCurrent,
                  l10n.inventoryPurchaseDailyDepletion,
                  l10n.status,
                ],
                rows: riskRows
                    .map(
                      (row) => [
                        _string(row['product_name'], fallback: '-'),
                        _displayStock(row),
                        _quantity(row['avg_daily_consumption_base']),
                        _riskLabel(row['risk_status'], context),
                      ],
                    )
                    .toList(),
              ),
            ),
            _DataCard(
              title: l10n.inventoryPurchaseRecommendationStatus,
              trailing: ToastStatusBadge(
                label: snapshot.run == null
                    ? l10n.inventoryPurchaseNoSnapshotShort
                    : l10n.inventoryPurchaseSnapshotReadyShort,
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
              title: l10n.inventoryPurchaseRecentOrders,
              trailing: ToastStatusBadge(
                label: l10n.inventoryPurchaseCountOrders(recentOrders.length),
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
    final l10n = context.l10n;
    final rows = state.rows;
    final danger = rows
        .where((row) => _string(row['risk_status']) == 'danger')
        .length;
    final warning = rows
        .where((row) => _string(row['risk_status']) == 'warning')
        .length;
    final stable = rows.length - danger - warning;

    return _PageShell(
      title: l10n.inventoryPurchaseStockStatusTitle,
      subtitle: l10n.inventoryPurchaseStockStatusSubtitle,
      isLoading: state.isLoading,
      error: state.error,
      children: [
        ToastMetricStrip(
          metrics: [
            ToastMetric(
              label: l10n.inventoryPurchaseTotalItems,
              value: l10n.inventoryPurchaseCountItems(rows.length),
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseStableStock,
              value: l10n.inventoryPurchaseCountItems(stable < 0 ? 0 : stable),
              tone: ToastColorTokens.success,
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseWarningStock,
              value: l10n.inventoryPurchaseCountItems(warning),
              tone: ToastColorTokens.warning,
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseDangerStock,
              value: l10n.inventoryPurchaseCountItems(danger),
              tone: ToastColorTokens.danger,
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: l10n.inventoryPurchaseProductStockSummary,
          child: _SimpleDataTable(
            columns: [
              l10n.inventoryPurchaseProductName,
              l10n.superAdminCategory,
              l10n.inventoryPurchaseCurrentStock,
              l10n.inventoryPurchaseRecent4DayAvg,
              l10n.inventoryPurchaseRecent7DayAvg,
              l10n.inventoryPurchaseEstimatedDays,
              l10n.status,
            ],
            rows: rows
                .map(
                  (row) => [
                    _string(row['product_name'], fallback: '-'),
                    _string(row['category'], fallback: '-'),
                    _displayStock(row),
                    _quantity(row['recent_4_day_avg']),
                    _quantity(row['recent_7_day_avg']),
                    l10n.inventoryPurchaseDaysValue(
                      _number(row['estimated_days_remaining']),
                    ),
                    _riskLabel(row['risk_status'], context),
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
    required InventoryPurchaseOrderSummaryState orders,
    required InventoryPurchaseSupplierCatalogState supplierCatalog,
    required InventoryPurchaseRecommendationRunState runState,
    required InventoryPurchaseRecommendationAdjustmentState adjustmentState,
    required InventoryPurchaseOrderCreationState creationState,
  }) {
    final l10n = context.l10n;
    final runId = snapshot.run?['id']?.toString();
    final canCreateOrders = runId != null && snapshot.lines.isNotEmpty;
    final canCreateManualOrder =
        supplierCatalog.suppliers.isNotEmpty &&
        supplierCatalog.supplierItems.isNotEmpty;
    final recommendedTotal = snapshot.lines.fold<num>(
      0,
      (sum, line) => sum + _recommendationEstimatedAmount(line),
    );
    final pendingOfficeApprovalCount = orders.orders
        .where((order) => _string(order['status']) == 'submitted')
        .length;

    Future<void> runRecommendation() async {
      final input = await _showRecommendationRunDialog();
      if (!mounted || input == null) return;
      final ok = await ref
          .read(inventoryPurchaseRecommendationRunProvider.notifier)
          .run(
            storeId: storeId,
            targetStockDays: input.targetStockDays,
            asOfDate: input.asOfDate,
          );
      if (!mounted) return;
      if (ok) {
        await ref
            .read(inventoryPurchaseRecommendationSnapshotProvider.notifier)
            .loadLatest(storeId);
      }
    }

    Future<void> createSupplierOrders() async {
      if (runId == null) return;
      final ok = await ref
          .read(inventoryPurchaseOrderCreationProvider.notifier)
          .createFromRecommendation(
            runId: runId,
            requestedDeliveryDate: DateTime.now().add(const Duration(days: 2)),
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

    void showManualOrderDialog() {
      _showManualPurchaseOrderDialog(
        storeId: storeId,
        suppliers: supplierCatalog.suppliers,
        supplierItems: supplierCatalog.supplierItems,
      );
    }

    return _PageShell(
      title: l10n.inventoryPurchaseManagementTitle,
      subtitle: l10n.inventoryPurchaseManagementSubtitle,
      isLoading: snapshot.isLoading || adjustmentState.isUpdating,
      error:
          snapshot.error ??
          runState.error ??
          adjustmentState.error ??
          creationState.error,
      actions: [
        PosActionButton(
          key: const Key('inventory_recommendation_run_action'),
          label: l10n.inventoryPurchaseGenerateRecommendation,
          tone: PosActionTone.primary,
          icon: Icons.auto_graph_outlined,
          loading: runState.isRunning,
          onPressed: runState.isRunning ? null : runRecommendation,
        ),
        SizedBox(
          width: 260,
          child: PosActionTile(
            key: const Key('inventory_purchase_create_order_action'),
            label: l10n.inventoryPurchaseCreateSupplierOrders,
            helper: l10n.inventoryPurchaseCreateOrderActionHelper(
              snapshot.lines.length,
              _money(recommendedTotal),
            ),
            icon: Icons.assignment_turned_in_outlined,
            state: creationState.isCreating
                ? PosActionTileState.processing
                : canCreateOrders
                ? PosActionTileState.selected
                : PosActionTileState.disabled,
            onTap: canCreateOrders && !creationState.isCreating
                ? createSupplierOrders
                : null,
          ),
        ),
        PosActionButton(
          key: const Key('inventory_manual_purchase_order_action'),
          label: l10n.inventoryPurchaseManualOrder,
          tone: PosActionTone.secondary,
          icon: Icons.edit_note_outlined,
          loading: creationState.isCreating,
          disabledReason: !canCreateManualOrder
              ? PosActionDisabledReason.upstreamPending
              : PosActionDisabledReason.noSelection,
          onPressed: creationState.isCreating || !canCreateManualOrder
              ? null
              : showManualOrderDialog,
          compact: true,
        ),
      ],
      children: [
        ToastMetricStrip(
          metrics: [
            ToastMetric(
              label: l10n.inventoryPurchaseRecommendationSnapshot,
              value: runId == null
                  ? l10n.inventoryPurchaseNone
                  : _date(snapshot.run?['run_date']),
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseRecommendedItems,
              value: l10n.inventoryPurchaseCountItems(snapshot.lines.length),
              tone: ToastColorTokens.accent,
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseTargetStockDays,
              value: l10n.inventoryPurchaseDaysValue(
                _number(snapshot.run?['target_stock_days'], fallback: '3'),
              ),
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseCreatedOrders,
              value: l10n.inventoryPurchaseCountOrders(
                creationState.createdOrders.length,
              ),
              tone: ToastColorTokens.success,
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: l10n.inventoryPurchaseRecommendationList,
          trailing: ToastStatusBadge(
            label: l10n.inventoryPurchaseOfficeApprovalOnly,
            color: ToastColorTokens.info,
            compact: true,
          ),
          child: _PurchaseRecommendationGrid(
            lines: snapshot.lines,
            snapshotDateLabel: runId == null
                ? l10n.inventoryPurchaseNoSnapshotShort
                : _date(snapshot.run?['run_date']),
            targetDaysLabel: l10n.inventoryPurchaseDaysValue(
              _number(snapshot.run?['target_stock_days'], fallback: '3'),
            ),
            pendingOfficeApprovalCount: pendingOfficeApprovalCount,
            onRunRecommendation: runState.isRunning ? null : runRecommendation,
            onCreateManualOrder:
                creationState.isCreating || !canCreateManualOrder
                ? null
                : showManualOrderDialog,
          ),
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: l10n.inventoryPurchaseRecommendationAdjustment,
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

  Future<_RecommendationRunInput?> _showRecommendationRunDialog() async {
    final targetDaysController = TextEditingController(text: '3');
    final asOfDateController = TextEditingController(
      text: DateTime.now().toIso8601String().split('T').first,
    );
    final l10n = context.l10n;
    String? targetDaysError;
    String? asOfDateError;

    return showDialog<_RecommendationRunInput>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          void submit() {
            final targetDays = parseDecimalInput(targetDaysController.text);
            final asOfDate = _parseDateOrNull(asOfDateController.text);
            setDialogState(() {
              targetDaysError = targetDays == null || targetDays <= 0
                  ? l10n.inventoryPurchaseRecommendationInvalidTargetDays
                  : null;
              asOfDateError = asOfDate == null
                  ? l10n.inventoryPurchaseRecommendationInvalidDate
                  : null;
            });
            if (targetDays == null || targetDays <= 0 || asOfDate == null) {
              return;
            }
            Navigator.of(dialogContext).pop(
              _RecommendationRunInput(
                targetStockDays: targetDays.toDouble(),
                asOfDate: asOfDate,
              ),
            );
          }

          return AlertDialog(
            key: const Key('inventory_recommendation_run_dialog'),
            title: Text(l10n.inventoryPurchaseRecommendationInputTitle),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.inventoryPurchaseRecommendationInputHelp),
                  const SizedBox(height: ToastSpacingTokens.md),
                  TextField(
                    key: const Key(
                      'inventory_purchase_recommendation_target_days_field',
                    ),
                    controller: targetDaysController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: l10n.inventoryPurchaseTargetStockDays,
                      errorText: targetDaysError,
                    ),
                    onSubmitted: (_) => submit(),
                  ),
                  const SizedBox(height: ToastSpacingTokens.sm),
                  TextField(
                    key: const Key(
                      'inventory_purchase_recommendation_as_of_date_field',
                    ),
                    controller: asOfDateController,
                    keyboardType: TextInputType.datetime,
                    decoration: InputDecoration(
                      labelText: l10n.inventoryPurchaseRecommendationAsOfDate,
                      hintText: l10n.inventoryPurchaseDateHint,
                      errorText: asOfDateError,
                    ),
                    onSubmitted: (_) => submit(),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(l10n.cancel),
              ),
              FilledButton.icon(
                key: const Key(
                  'inventory_purchase_recommendation_submit_action',
                ),
                onPressed: submit,
                icon: const Icon(Icons.auto_graph_outlined),
                label: Text(l10n.inventoryPurchaseGenerateRecommendation),
              ),
            ],
          );
        },
      ),
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
    final l10n = context.l10n;
    final result = await showDialog<_RecommendationAdjustmentInput>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          key: const Key('inventory_recommendation_adjustment_dialog'),
          title: Text(l10n.inventoryPurchaseRecommendationAdjustment),
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
                  decoration: InputDecoration(
                    labelText: l10n.inventoryPurchaseAdjustedOrderUnit,
                    helperText: l10n.inventoryPurchaseClearAdjustmentHint,
                  ),
                ),
                const SizedBox(height: ToastSpacingTokens.sm),
                TextField(
                  controller: memoController,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: l10n.inventoryPurchaseAdjustmentMemo,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(const _RecommendationAdjustmentInput(clear: true)),
              child: Text(l10n.inventoryPurchaseClearAdjustment),
            ),
            FilledButton(
              onPressed: () {
                final rawUnits = unitsController.text.trim();
                final parsed = rawUnits.isEmpty
                    ? null
                    : parseDecimalInput(rawUnits);
                if (rawUnits.isNotEmpty && parsed == null) {
                  return;
                }
                Navigator.of(dialogContext).pop(
                  _RecommendationAdjustmentInput(
                    adjustedOrderUnits: parsed,
                    memo: memoController.text.trim(),
                  ),
                );
              },
              child: Text(l10n.save),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error ?? l10n.inventoryPurchaseAdjustmentFailed),
        ),
      );
    }
  }

  Widget _buildPurchaseHistoryPage({
    required String storeId,
    required InventoryPurchaseOrderSummaryState state,
    required InventoryPurchaseOrderDetailState detail,
    required InventoryPurchaseReceivingRuntimeState receivingRuntime,
    required InventoryPurchaseOrderCreationState creationState,
  }) {
    final l10n = context.l10n;
    final order = detail.order;
    final canConfirmReceipt =
        order != null &&
        _receivableStatus(order['status']) &&
        _num(order['total_remaining_quantity_base']) > 0 &&
        !receivingRuntime.isSubmitting;
    final receivingBlockerMessage = order == null || canConfirmReceipt
        ? null
        : _receivingPilotBlockerMessage(order, context);

    return _PageShell(
      title: l10n.inventoryPurchaseHistoryTitle,
      subtitle: l10n.inventoryPurchaseHistorySubtitle,
      isLoading:
          state.isLoading ||
          detail.isLoading ||
          receivingRuntime.isSubmitting ||
          creationState.isCreating,
      error: state.error ?? detail.error ?? creationState.error,
      children: [
        ToastMetricStrip(
          metrics: [
            ToastMetric(
              label: l10n.inventoryPurchaseVisibleOrders,
              value: l10n.inventoryPurchaseCountOrders(state.orders.length),
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseOrderAmount,
              value: _money(
                state.orders.fold<num>(
                  0,
                  (sum, order) => sum + (_num(order['total_amount'])),
                ),
              ),
              tone: ToastColorTokens.accent,
            ),
            ToastMetric(
              label: l10n.inventoryPurchasePrintableOrders,
              value: l10n.inventoryPurchaseCountOrders(
                state.orders
                    .where((order) => _printableStatus(order['status']))
                    .length,
              ),
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
          title: l10n.inventoryPurchaseOrderList,
          trailing: ToastStatusBadge(
            label: l10n.inventoryPurchasePrintPdf,
            color: ToastColorTokens.accent,
            compact: true,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SimpleDataTable(
                columns: [
                  l10n.inventoryPurchaseOrderNo,
                  l10n.inventoryPurchaseSupplier,
                  l10n.status,
                  l10n.inventoryPurchaseRequestedDeliveryDate,
                  l10n.inventoryPurchaseItems,
                  l10n.inventoryPurchaseAmount,
                ],
                rows: state.orders
                    .map(
                      (order) => [
                        _string(order['purchase_order_no'], fallback: '-'),
                        _nestedName(order['supplier']),
                        _statusLabel(order['status'], context),
                        _date(order['requested_delivery_date']),
                        l10n.inventoryPurchaseCountItems(
                          _int(order['line_count']),
                        ),
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
            title: l10n.inventoryPurchaseSelectedPreview,
            trailing: Wrap(
              spacing: ToastSpacingTokens.sm,
              runSpacing: ToastSpacingTokens.sm,
              alignment: WrapAlignment.end,
              children: [
                PosActionButton(
                  label: l10n.inventoryPurchasePrintPdf,
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
                  key: const Key('inventory_repeat_purchase_order_action'),
                  label: l10n.inventoryPurchaseRepeatOrder,
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
                  key: const Key('inventory_receipt_confirmation_action'),
                  label: l10n.inventoryPurchaseReceiveTitle,
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
                      label: l10n.inventoryPurchaseOrderedBaseQuantity,
                      value: _quantity(order?['total_expected_quantity_base']),
                    ),
                    ToastMetric(
                      label: l10n.inventoryPurchaseAcceptedBaseQuantity,
                      value: _quantity(order?['total_accepted_quantity_base']),
                      tone: ToastColorTokens.success,
                    ),
                    ToastMetric(
                      label: l10n.inventoryPurchaseRemainingQuantity,
                      value: _quantity(order?['total_remaining_quantity_base']),
                      tone: ToastColorTokens.warning,
                    ),
                    ToastMetric(
                      label: l10n.inventoryPurchaseReceiptHistory,
                      value: l10n.inventoryPurchaseCountOrders(
                        detail.receipts.length,
                      ),
                    ),
                  ],
                ),
                if (receivingBlockerMessage != null) ...[
                  const SizedBox(height: ToastSpacingTokens.sm),
                  Container(
                    key: const Key('inventory_receiving_office_gate_notice'),
                    padding: const EdgeInsets.all(ToastSpacingTokens.sm),
                    decoration: BoxDecoration(
                      color: ToastColorTokens.warning.withValues(alpha: 0.08),
                      borderRadius: ToastRadiusTokens.sm,
                      border: Border.all(
                        color: ToastColorTokens.warning.withValues(alpha: 0.36),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.lock_clock_outlined,
                          size: 18,
                          color: ToastColorTokens.warning,
                        ),
                        const SizedBox(width: ToastSpacingTokens.sm),
                        Expanded(
                          child: Text(
                            receivingBlockerMessage,
                            style: _textStyle(
                              size: 12,
                              weight: FontWeight.w700,
                              color: ToastColorTokens.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: ToastSpacingTokens.md),
                _SimpleDataTable(
                  columns: [
                    l10n.inventoryPurchaseProductName,
                    l10n.inventoryPurchaseOrderQuantity,
                    l10n.inventoryPurchaseReceivedShort,
                    l10n.inventoryPurchaseRemainingShort,
                    l10n.inventoryPurchaseUnit,
                    l10n.inventoryPurchaseUnitPrice,
                    l10n.inventoryPurchaseSupplyAmount,
                    l10n.status,
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
                            context,
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
            title: l10n.inventoryPurchaseReceiptHistory,
            child: _SimpleDataTable(
              columns: [
                l10n.inventoryPurchaseReceivedDate,
                l10n.status,
                l10n.inventoryPurchaseLines,
                l10n.inventoryPurchaseReceivedQuantity,
                l10n.inventoryPurchaseAcceptedQuantity,
                l10n.inventoryPurchaseRejectedQuantity,
              ],
              rows: detail.receipts
                  .map(
                    (receipt) => [
                      _date(receipt['received_at'] ?? receipt['created_at']),
                      _receiptStatusLabel(receipt['status'], context),
                      l10n.inventoryPurchaseCountItems(
                        _int(receipt['line_count']),
                      ),
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
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('inventory_receipt_confirmation_dialog'),
        title: Text(l10n.inventoryPurchaseReceiveTitle),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.inventoryPurchaseRemainingForOrder(
                  _string(order['purchase_order_no'], fallback: '-'),
                  _quantity(order['total_remaining_quantity_base']),
                ),
              ),
              const SizedBox(height: ToastSpacingTokens.md),
              ToastStatusBadge(
                label: l10n.inventoryPurchaseConfirmAllRemaining,
                color: ToastColorTokens.warning,
                icon: Icons.info_outline,
              ),
              const SizedBox(height: ToastSpacingTokens.md),
              TextField(
                controller: memoController,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: l10n.inventoryPurchaseReceiptMemo,
                ),
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
              Navigator.of(dialogContext).pop(false);
            },
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.confirm),
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
    final l10n = context.l10n;
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
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final countedCount = _countValidStockAuditLines(
            rows: rows,
            controllers: controllers,
          );
          final previewLines = _stockAuditPreviewLines(
            rows: rows,
            controllers: controllers,
          );

          return AlertDialog(
            key: const Key('inventory_stock_audit_dialog'),
            title: Text(l10n.inventoryPurchaseStockAuditInputTitle),
            content: SizedBox(
              width: 780,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ToastStatusBadge(
                      label: l10n.inventoryPurchaseStockAuditDraftHelp,
                      color: ToastColorTokens.info,
                      icon: Icons.info_outline,
                    ),
                    const SizedBox(height: ToastSpacingTokens.md),
                    _StockAuditPendingPreview(
                      countedCount: countedCount,
                      lines: previewLines,
                    ),
                    const SizedBox(height: ToastSpacingTokens.md),
                    for (final row in rows) ...[
                      _StockAuditInputRow(
                        row: row,
                        controller: controllers[row['product_id']?.toString()]!,
                        onChanged: (_) => setDialogState(() {}),
                      ),
                      if (row != rows.last) const Divider(height: 1),
                    ],
                    const SizedBox(height: ToastSpacingTokens.md),
                    TextField(
                      controller: memoController,
                      maxLines: 3,
                      decoration: InputDecoration(
                        labelText: l10n.inventoryPurchaseStockAuditMemo,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.cancel),
              ),
              TextButton(
                onPressed: countedCount == 0
                    ? null
                    : () => Navigator.of(context).pop(
                        _buildStockAuditSubmitInput(
                          rows: rows,
                          controllers: controllers,
                          memo: memoController.text,
                          complete: false,
                        ),
                      ),
                child: Text(l10n.inventoryPurchaseSaveDraft),
              ),
              FilledButton(
                onPressed: countedCount == 0
                    ? null
                    : () => Navigator.of(context).pop(
                        _buildStockAuditSubmitInput(
                          rows: rows,
                          controllers: controllers,
                          memo: memoController.text,
                          complete: true,
                        ),
                      ),
                child: Text(l10n.inventoryPurchaseCompleteAudit),
              ),
            ],
          );
        },
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
      final actual = _parseStockAuditQuantity(controllers[productId]?.text);
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

  int _countValidStockAuditLines({
    required List<Map<String, dynamic>> rows,
    required Map<String, TextEditingController> controllers,
  }) {
    var count = 0;
    for (final row in rows) {
      final productId = row['product_id']?.toString();
      if (productId == null || productId.isEmpty) continue;
      final actual = _parseStockAuditQuantity(controllers[productId]?.text);
      if (actual == null || actual < 0) continue;
      count += 1;
    }
    return count;
  }

  List<_StockAuditPreviewLine> _stockAuditPreviewLines({
    required List<Map<String, dynamic>> rows,
    required Map<String, TextEditingController> controllers,
  }) {
    final lines = <_StockAuditPreviewLine>[];
    for (final row in rows) {
      final productId = row['product_id']?.toString();
      if (productId == null || productId.isEmpty) continue;
      final actual = _parseStockAuditQuantity(controllers[productId]?.text);
      if (actual == null || actual < 0) continue;
      final systemQuantity = _num(row['current_stock_base']).toDouble();
      final variance = actual - systemQuantity;
      if (variance == 0) continue;
      lines.add(
        _StockAuditPreviewLine(
          productName: _string(row['product_name'], fallback: '-'),
          systemQuantity: systemQuantity,
          actualQuantity: actual,
          variance: variance,
          unit: _string(row['base_unit'], fallback: _string(row['stock_unit'])),
        ),
      );
    }
    return lines;
  }

  double? _parseStockAuditQuantity(String? value) {
    return parseDecimalInput(value);
  }

  Future<void> _printPurchaseOrderPdf(String orderId) async {
    if (_printingOrderId != null) {
      return;
    }

    final l10n = context.l10n;
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
          SnackBar(
            content: Text(
              detail.error ?? l10n.inventoryPurchaseDetailLoadFailed,
            ),
          ),
        );
        return;
      }

      final opened = await inventoryPurchaseDocumentService
          .layoutPurchaseOrderPdf(
            order: order,
            lines: detail.lines,
            l10n: l10n,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            opened
                ? l10n.inventoryPurchasePrinted(
                    _string(order['purchase_order_no'], fallback: '-'),
                  )
                : l10n.inventoryPurchasePrintCancelled,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.inventoryPurchasePrintFailed)),
      );
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
    final l10n = context.l10n;
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
      title: l10n.inventoryPurchaseSupplierManagementTitle,
      subtitle: l10n.inventoryPurchaseSupplierManagementSubtitle,
      isLoading: supplierCatalog.isLoading,
      error: supplierCatalog.error,
      actions: [
        PosActionButton(
          key: const Key('inventory_supplier_add_action'),
          label: l10n.inventoryPurchaseAddSupplier,
          tone: PosActionTone.primary,
          icon: Icons.add_business_outlined,
          loading: supplierCatalog.isSaving,
          onPressed: supplierCatalog.isSaving
              ? null
              : () => _showSupplierDialog(storeId: storeId),
          compact: true,
        ),
        PosActionButton(
          key: const Key('inventory_supplier_item_add_action'),
          label: l10n.inventoryPurchaseLinkItem,
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
            ToastMetric(
              label: l10n.inventoryPurchaseTotalSuppliers,
              value: l10n.inventoryPurchaseCountItems(suppliers.length),
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseActiveSuppliers,
              value: l10n.inventoryPurchaseCountItems(activeSuppliers),
              tone: ToastColorTokens.success,
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseSupplierItems,
              value: l10n.inventoryPurchaseCountItems(supplierItems.length),
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseContractNeedsReview,
              value: l10n.inventoryPurchaseCountItems(
                _contractAttentionCount(suppliers),
              ),
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
              title: l10n.inventoryPurchaseSupplierList,
              trailing: ToastStatusBadge(
                label: selectedSupplier == null ? l10n.all : l10n.selected,
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
              title: l10n.inventoryPurchaseSupplierDetail,
              child: _SupplierDetailPanel(
                supplier: selectedSupplier,
                supplierItemCount: visibleSupplierItems.length,
              ),
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: l10n.inventoryPurchaseSupplierOrderItems,
          trailing: ToastStatusBadge(
            label: l10n.inventoryPurchaseCountItems(
              visibleSupplierItems.length,
            ),
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
    final l10n = context.l10n;
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
      title: l10n.inventoryPurchaseProductManagementTitle,
      subtitle: l10n.inventoryPurchaseProductManagementSubtitle,
      isLoading: productCatalog.isLoading || supplierCatalog.isLoading,
      error: productCatalog.error ?? supplierCatalog.error,
      actions: [
        PosActionButton(
          key: const Key('inventory_product_add_action'),
          label: l10n.inventoryPurchaseAddProduct,
          tone: PosActionTone.primary,
          icon: Icons.add_box_outlined,
          loading: productCatalog.isSaving,
          onPressed: productCatalog.isSaving
              ? null
              : () => _showProductDialog(storeId: storeId),
          compact: true,
        ),
        PosActionButton(
          label: l10n.inventoryPurchaseLinkSupplier,
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
            ToastMetric(
              label: l10n.inventoryPurchaseTotalProducts,
              value: l10n.inventoryPurchaseCountItems(products.length),
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseActiveProducts,
              value: l10n.inventoryPurchaseCountItems(activeProducts),
              tone: ToastColorTokens.success,
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseOrderableProducts,
              value: l10n.inventoryPurchaseCountItems(orderableProducts),
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseSupplierLinks,
              value: l10n.inventoryPurchaseCountOrders(
                supplierCatalog.supplierItems.length,
              ),
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
              title: l10n.inventoryPurchaseProductList,
              trailing: ToastStatusBadge(
                label: selectedProduct == null ? l10n.all : l10n.selected,
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
              title: l10n.inventoryPurchaseProductDetail,
              child: _ProductDetailPanel(
                product: selectedProduct,
                supplierItemCount: supplierItems.length,
              ),
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: l10n.inventoryPurchaseProductSupplierCosts,
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
    final bankAccountController = TextEditingController(
      text: _string(supplier?['bank_account_number']),
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
    final l10n = context.l10n;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('inventory_supplier_dialog'),
        title: Text(
          supplier == null
              ? l10n.inventoryPurchaseAddSupplier
              : l10n.inventoryPurchaseEditSupplier,
        ),
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
                      decoration: InputDecoration(
                        labelText: l10n.inventoryPurchaseSupplierNameRequired,
                      ),
                    ),
                    TextField(
                      controller: typeController,
                      decoration: InputDecoration(
                        labelText: l10n.inventoryPurchaseSupplierType,
                      ),
                    ),
                    TextField(
                      controller: contactController,
                      decoration: InputDecoration(
                        labelText: l10n.inventoryPurchaseContactName,
                      ),
                    ),
                    TextField(
                      controller: phoneController,
                      decoration: InputDecoration(
                        labelText: l10n.inventoryPurchasePhone,
                      ),
                    ),
                    TextField(
                      controller: emailController,
                      decoration: InputDecoration(labelText: l10n.email),
                    ),
                    TextField(
                      controller: paymentController,
                      decoration: InputDecoration(
                        labelText: l10n.inventoryPurchasePaymentTerms,
                      ),
                    ),
                    TextField(
                      controller: businessController,
                      decoration: InputDecoration(
                        labelText: l10n.inventoryPurchaseBusinessNo,
                      ),
                    ),
                    TextField(
                      key: const Key('inventory_supplier_bank_account_field'),
                      controller: bankAccountController,
                      keyboardType: TextInputType.text,
                      decoration: InputDecoration(
                        labelText: l10n.inventoryPurchaseBankAccountNumber,
                      ),
                    ),
                    TextField(
                      controller: startController,
                      decoration: InputDecoration(
                        labelText: l10n.inventoryPurchaseContractStartDate,
                        hintText: l10n.inventoryPurchaseDateHint,
                      ),
                    ),
                    TextField(
                      controller: endController,
                      decoration: InputDecoration(
                        labelText: l10n.inventoryPurchaseContractEndDate,
                        hintText: l10n.inventoryPurchaseDateHint,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: ToastSpacingTokens.md),
                TextField(
                  controller: addressController,
                  decoration: InputDecoration(labelText: l10n.address),
                ),
                const SizedBox(height: ToastSpacingTokens.md),
                TextField(
                  controller: memoController,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: l10n.inventoryPurchaseMemo,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
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
                    bankAccountNumber: _nullableText(
                      bankAccountController.text,
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
            child: Text(l10n.save),
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
    final l10n = context.l10n;
    final existingCategories =
        ref
            .read(inventoryPurchaseProductCatalogProvider)
            .products
            .map((row) => _string(row['category']))
            .where((category) => category.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    String? validationMessage;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            key: const Key('inventory_product_dialog'),
            title: Text(
              product == null
                  ? l10n.inventoryPurchaseAddProduct
                  : l10n.inventoryPurchaseEditProduct,
            ),
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
                          decoration: InputDecoration(
                            labelText: '${l10n.inventoryPurchaseProductCode} *',
                            helperText:
                                'Unique per store. Use the agreed pilot product-code rule before saving.',
                          ),
                        ),
                        TextField(
                          controller: nameController,
                          decoration: InputDecoration(
                            labelText:
                                l10n.inventoryPurchaseProductNameRequired,
                          ),
                        ),
                        TextField(
                          controller: categoryController,
                          decoration: InputDecoration(
                            labelText: '${l10n.superAdminCategory} *',
                            helperText:
                                'Choose an existing category below or enter a new category name.',
                          ),
                        ),
                        TextField(
                          controller: stockUnitController,
                          decoration: InputDecoration(
                            labelText:
                                l10n.inventoryPurchaseDisplayStockUnitRequired,
                          ),
                        ),
                        DropdownButtonFormField<String>(
                          initialValue: baseUnit,
                          decoration: InputDecoration(
                            labelText: l10n.inventoryPurchaseBaseUnitRequired,
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
                          decoration: InputDecoration(
                            labelText:
                                l10n.inventoryPurchaseBaseUnitFactorRequired,
                          ),
                        ),
                        TextField(
                          controller: storageController,
                          decoration: InputDecoration(
                            labelText: l10n.inventoryPurchaseStorageType,
                          ),
                        ),
                        TextField(
                          controller: shelfLifeController,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText:
                                '${l10n.inventoryPurchaseShelfLifeDays} *',
                            helperText:
                                'Required for pilot receiving and expiry checks.',
                          ),
                        ),
                      ],
                    ),
                    if (existingCategories.isNotEmpty) ...[
                      const SizedBox(height: ToastSpacingTokens.sm),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          key: const Key(
                            'inventory_product_category_quick_pick',
                          ),
                          spacing: ToastSpacingTokens.xs,
                          runSpacing: ToastSpacingTokens.xs,
                          children: [
                            for (final category in existingCategories.take(8))
                              ActionChip(
                                label: Text(category),
                                onPressed: () {
                                  categoryController.text = category;
                                  setDialogState(() {});
                                },
                              ),
                          ],
                        ),
                      ),
                    ],
                    if (validationMessage != null) ...[
                      const SizedBox(height: ToastSpacingTokens.sm),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          key: const Key(
                            'inventory_product_validation_message',
                          ),
                          validationMessage!,
                          style: _textStyle(
                            size: 12,
                            weight: FontWeight.w700,
                            color: ToastColorTokens.danger,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: ToastSpacingTokens.md),
                    TextField(
                      controller: imageController,
                      decoration: InputDecoration(
                        labelText: l10n.inventoryPurchaseImageUrl,
                      ),
                    ),
                    const SizedBox(height: ToastSpacingTokens.md),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: isOrderable,
                      onChanged: (value) =>
                          setDialogState(() => isOrderable = value),
                      title: Text(l10n.inventoryPurchaseOrderable),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () async {
                  final productCode = codeController.text.trim();
                  final name = nameController.text.trim();
                  final category = categoryController.text.trim();
                  final stockUnit = stockUnitController.text.trim();
                  final factor = parseDecimalInput(factorController.text);
                  final shelfLife = shelfLifeController.text.trim().isEmpty
                      ? null
                      : parseIntInput(shelfLifeController.text);
                  if (productCode.isEmpty) {
                    setDialogState(() {
                      validationMessage =
                          'Product code is required so testers can identify the item consistently.';
                    });
                    return;
                  }
                  if (name.isEmpty) {
                    setDialogState(() {
                      validationMessage = 'Product name is required.';
                    });
                    return;
                  }
                  if (category.isEmpty) {
                    setDialogState(() {
                      validationMessage =
                          'Category is required. Choose an existing category or type a new one.';
                    });
                    return;
                  }
                  if (stockUnit.isEmpty || factor == null) {
                    setDialogState(() {
                      validationMessage =
                          'Display stock unit and base-unit factor are required.';
                    });
                    return;
                  }
                  if (shelfLife == null || shelfLife < 0) {
                    setDialogState(() {
                      validationMessage =
                          'Shelf life days is required and must be zero or higher.';
                    });
                    return;
                  }
                  setDialogState(() => validationMessage = null);
                  final ok = await ref
                      .read(inventoryPurchaseProductCatalogProvider.notifier)
                      .saveProduct(
                        storeId: storeId,
                        productId: product?['id']?.toString(),
                        productCode: productCode,
                        name: name,
                        category: category,
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
                child: Text(l10n.save),
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
    final l10n = context.l10n;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            key: const Key('inventory_supplier_item_dialog'),
            title: Text(
              supplierItem == null
                  ? l10n.inventoryPurchaseLinkSupplierItem
                  : l10n.inventoryPurchaseEditSupplierItem,
            ),
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
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: l10n.inventoryPurchaseSupplierRequired,
                          ),
                          items: [
                            for (final supplier in selectableSuppliers)
                              DropdownMenuItem(
                                value: supplier['id'].toString(),
                                child: Text(
                                  _string(
                                    supplier['supplier_name'],
                                    fallback: '-',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
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
                          decoration: InputDecoration(
                            labelText: l10n.inventoryPurchaseProductRequired,
                          ),
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
                          decoration: InputDecoration(
                            labelText: l10n.inventoryPurchaseSupplierSku,
                          ),
                        ),
                        TextField(
                          controller: orderUnitController,
                          decoration: InputDecoration(
                            labelText: l10n.inventoryPurchaseOrderUnitRequired,
                          ),
                        ),
                        TextField(
                          controller: orderUnitBaseController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: l10n
                                .inventoryPurchaseOrderUnitBaseQuantityRequired,
                          ),
                        ),
                        TextField(
                          controller: minOrderController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText:
                                l10n.inventoryPurchaseMinOrderQuantityRequired,
                          ),
                        ),
                        TextField(
                          controller: unitPriceController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: l10n.inventoryPurchaseUnitPriceRequired,
                          ),
                        ),
                        TextField(
                          controller: taxRateController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: l10n.inventoryPurchaseTaxRatePercent,
                          ),
                        ),
                        TextField(
                          controller: leadTimeController,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: l10n.inventoryPurchaseLeadTimeDays,
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
                      title: Text(
                        l10n.inventoryPurchasePreferredRecommendationSupplier,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () async {
                  final orderUnit = orderUnitController.text.trim();
                  final orderUnitBase = parseDecimalInput(
                    orderUnitBaseController.text,
                  );
                  final minOrder = parseDecimalInput(minOrderController.text);
                  final unitPrice = parseDecimalInput(unitPriceController.text);
                  final taxRate = parseDecimalInput(taxRateController.text);
                  final leadTime = parseIntInput(leadTimeController.text);
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
                child: Text(l10n.save),
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
    final l10n = context.l10n;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final selectedItem = _firstWhereOrNull(
            selectedSupplierItems,
            (item) => item['id']?.toString() == supplierItemId,
          );
          return AlertDialog(
            key: const Key('inventory_manual_purchase_order_dialog'),
            title: Text(l10n.inventoryPurchaseManualOrder),
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
                          decoration: InputDecoration(
                            labelText: l10n.inventoryPurchaseSupplierRequired,
                          ),
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
                          decoration: InputDecoration(
                            labelText:
                                l10n.inventoryPurchaseRequestedDeliveryDate,
                            hintText: l10n.inventoryPurchaseDateHint,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: ToastSpacingTokens.md),
                    _DataCard(
                      title: l10n.inventoryPurchaseProducts,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _DialogGrid(
                            children: [
                              DropdownButtonFormField<String>(
                                initialValue: supplierItemId,
                                isExpanded: true,
                                decoration: InputDecoration(
                                  labelText: l10n.inventoryPurchaseItemRequired,
                                ),
                                items: [
                                  for (final item in selectedSupplierItems)
                                    DropdownMenuItem(
                                      value: item['id'].toString(),
                                      child: Text(
                                        _supplierItemLabel(item),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
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
                                  labelText: l10n
                                      .inventoryPurchaseOrderQuantityWithUnit(
                                        _string(
                                          selectedItem?['order_unit'],
                                          fallback: 'unit',
                                        ),
                                      ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: ToastSpacingTokens.md),
                          Align(
                            alignment: Alignment.centerRight,
                            child: PosActionButton(
                              label: l10n.inventoryPurchaseAddLine,
                              tone: PosActionTone.secondary,
                              icon: Icons.add_outlined,
                              compact: true,
                              onPressed: () {
                                final item = selectedItem;
                                final qty = parseDecimalInput(
                                  quantityController.text,
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
                            columns: [
                              l10n.inventoryPurchaseItems,
                              l10n.inventoryPurchaseQuantity,
                              l10n.inventoryPurchaseUnit,
                            ],
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
                      decoration: InputDecoration(
                        labelText: l10n.inventoryPurchaseOrderMemo,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l10n.cancel),
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
                child: Text(l10n.inventoryPurchaseCreateOrder),
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
    final l10n = context.l10n;
    final sourceOrderNo = _string(order['purchase_order_no'], fallback: '-');
    final memoController = TextEditingController(
      text: l10n.inventoryPurchaseRepeatMemo(sourceOrderNo),
    );

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('inventory_repeat_purchase_order_dialog'),
        title: Text(l10n.inventoryPurchaseRepeatOrder),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ToastStatusBadge(
                  label: l10n.inventoryPurchaseRepeatHelp(sourceOrderNo),
                  color: ToastColorTokens.info,
                  icon: Icons.repeat_outlined,
                ),
                const SizedBox(height: ToastSpacingTokens.md),
                _DialogGrid(
                  children: [
                    TextField(
                      controller: requestedDateController,
                      decoration: InputDecoration(
                        labelText: l10n.inventoryPurchaseRequestedDeliveryDate,
                        hintText: l10n.inventoryPurchaseDateHint,
                      ),
                    ),
                    TextField(
                      controller: memoController,
                      decoration: InputDecoration(
                        labelText: l10n.inventoryPurchaseOrderMemo,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: ToastSpacingTokens.md),
                _SimpleDataTable(
                  columns: [
                    l10n.inventoryPurchaseItems,
                    l10n.inventoryPurchaseQuantity,
                    l10n.inventoryPurchaseUnit,
                    l10n.inventoryPurchaseUnitPrice,
                    l10n.inventoryPurchaseSupplyAmount,
                  ],
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
            child: Text(l10n.cancel),
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
            child: Text(l10n.inventoryPurchaseCreateRepeatOrder),
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
    final l10n = context.l10n;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            key: const Key('inventory_recipe_line_dialog'),
            title: Text(
              recipe == null
                  ? l10n.inventoryPurchaseAddRecipeLine
                  : l10n.inventoryPurchaseEditRecipeLine,
            ),
            content: SizedBox(
              width: 560,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: menuItemId,
                    decoration: InputDecoration(
                      labelText: l10n.inventoryPurchaseMenuRequired,
                    ),
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
                    decoration: InputDecoration(
                      labelText: l10n.inventoryPurchaseIngredientRequired,
                    ),
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
                    decoration: InputDecoration(
                      labelText: l10n.inventoryPurchaseUsagePerServingRequired,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () async {
                  final product = _firstWhereOrNull(
                    selectableProducts,
                    (row) => row['id']?.toString() == productId,
                  );
                  final ingredientId = product?['inventory_item_id']
                      ?.toString();
                  final quantity = parseDecimalInput(quantityController.text);
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
                child: Text(l10n.save),
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
    final l10n = context.l10n;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final selectedProduct = _firstWhereOrNull(
            products,
            (product) => product['id']?.toString() == productId,
          );
          return AlertDialog(
            key: const Key('inventory_new_menu_dialog'),
            title: Text(l10n.inventoryPurchaseNewMenuTitle),
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
                          decoration: InputDecoration(
                            labelText: l10n.inventoryPurchaseMenuNameRequired,
                          ),
                        ),
                        TextField(
                          controller: priceController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: l10n.inventoryPurchaseSalePriceRequired,
                          ),
                        ),
                        DropdownButtonFormField<String?>(
                          initialValue: categoryId,
                          decoration: InputDecoration(
                            labelText: l10n.superAdminCategory,
                          ),
                          items: [
                            DropdownMenuItem<String?>(
                              value: null,
                              child: Text(l10n.inventoryPurchaseNoCategory),
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
                          decoration: InputDecoration(
                            labelText: l10n.inventoryPurchaseDescription,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: ToastSpacingTokens.lg),
                    _DataCard(
                      title: l10n.inventoryPurchaseIngredientComposition,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _DialogGrid(
                            children: [
                              DropdownButtonFormField<String>(
                                initialValue: productId,
                                decoration: InputDecoration(
                                  labelText: l10n.inventoryPurchaseIngredient,
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
                                decoration: InputDecoration(
                                  labelText:
                                      l10n.inventoryPurchaseUsagePerServing,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: ToastSpacingTokens.md),
                          Align(
                            alignment: Alignment.centerRight,
                            child: PosActionButton(
                              label: l10n.inventoryPurchaseAddIngredient,
                              tone: PosActionTone.secondary,
                              icon: Icons.add_outlined,
                              compact: true,
                              onPressed: () {
                                final usage = parseDecimalInput(
                                  usageController.text,
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
                            columns: [
                              l10n.inventoryPurchaseIngredient,
                              l10n.inventoryPurchaseUsageG,
                            ],
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
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () async {
                  final name = nameController.text.trim();
                  final price = parseDecimalInput(priceController.text);
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
                child: Text(l10n.inventoryPurchaseRegister),
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
    final l10n = context.l10n;
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
      title: l10n.inventoryPurchaseRecipeManagementTitle,
      subtitle: l10n.inventoryPurchaseRecipeManagementSubtitle,
      isLoading: recipeState.isLoading || productCatalog.isLoading,
      error: recipeState.error ?? productCatalog.error,
      actions: [
        PosActionButton(
          key: const Key('inventory_recipe_line_add_action'),
          label: l10n.inventoryPurchaseAddRecipeLine,
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
            ToastMetric(
              label: l10n.inventoryPurchaseRecipeMenus,
              value: l10n.inventoryPurchaseCountItems(menuCount),
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseRecipeLines,
              value: l10n.inventoryPurchaseCountItems(recipes.length),
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseLinkedIngredients,
              value: l10n.inventoryPurchaseCountItems(ingredientCount),
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseTotalStandardUsage,
              value: l10n.inventoryPurchaseGramValue(_quantity(totalUsage)),
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: l10n.inventoryPurchaseRecipeLinesByMenu,
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
    final l10n = context.l10n;
    final categoryShares = _buildConsumptionShares(
      consumptionRows,
      categoryFallback: l10n.inventoryPurchaseNoCategory,
    );
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
          label: l10n.inventoryPurchaseRefreshConsumption,
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
              label: l10n.inventoryPurchaseTotalDailyConsumption,
              value: l10n.inventoryPurchasePerDayValue(
                _quantity(totalDailyQuantity),
              ),
            ),
            ToastMetric(
              label: l10n.inventoryPurchasePeriodConsumptionCost,
              value: _money(periodConsumedAmount),
              tone: ToastColorTokens.accent,
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseAverageEstimatedDays,
              value: averageDays <= 0
                  ? '-'
                  : l10n.inventoryPurchaseDaysValue(_number(averageDays)),
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseConsumptionTrend,
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
              label: l10n.inventoryPurchaseConsumptionRiskItems,
              value: l10n.inventoryPurchaseCountItems(alertRows.length),
              tone: ToastColorTokens.warning,
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: title,
          trailing: ToastStatusBadge(
            label: l10n.inventoryPurchaseTopItems(
              consumptionRows.take(8).length,
            ),
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
              title: l10n.inventoryPurchaseConsumptionShareByCategory,
              child: _ConsumptionShareList(rows: categoryShares),
            ),
            _DataCard(
              title: l10n.inventoryPurchaseConsumptionAlerts,
              child: _ConsumptionAlertList(rows: alertRows.take(5).toList()),
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: l10n.inventoryPurchaseConsumptionAnalysisByProduct,
          child: _SimpleDataTable(
            columns: [
              l10n.inventoryPurchaseProductName,
              l10n.superAdminCategory,
              l10n.inventoryPurchaseRecent4DayAvg,
              l10n.inventoryPurchaseRecent7DayAvg,
              l10n.inventoryPurchaseDailyDepletion,
              l10n.inventoryPurchaseEstimatedDays,
              l10n.status,
            ],
            rows: consumptionRows
                .map(
                  (row) => [
                    _string(row['product_name'], fallback: '-'),
                    _string(row['category'], fallback: '-'),
                    _quantity(row['recent_4_day_avg']),
                    _quantity(row['recent_7_day_avg']),
                    _quantity(row['avg_daily_consumption_base']),
                    l10n.inventoryPurchaseDaysValue(
                      _number(row['estimated_days_remaining']),
                    ),
                    _riskLabel(row['risk_status'], context),
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
    final l10n = context.l10n;
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
      title: l10n.inventoryPurchaseCostAnalysisTitle,
      subtitle: l10n.inventoryPurchaseCostAnalysisSubtitle,
      isLoading:
          overview.isLoading ||
          costAnalysis.isLoading ||
          costAnalysis.isRefreshing,
      error: overview.error ?? costAnalysis.error,
      actions: [
        PosActionButton(
          label: l10n.inventoryPurchaseRefreshConsumption,
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
              label: l10n.inventoryPurchaseAssetAmount,
              value: _money(inventoryAmount),
            ),
            ToastMetric(
              label: l10n.inventoryPurchasePeriodConsumptionCost,
              value: _money(consumedAmount),
              tone: ToastColorTokens.accent,
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseAnalyzedItems,
              value: l10n.inventoryPurchaseCountItems(rows.length),
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseCostAttention,
              value: l10n.inventoryPurchaseCountItems(warningCount),
              tone: ToastColorTokens.warning,
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseRefreshResult,
              value: costAnalysis.lastRefreshCount == null
                  ? '-'
                  : l10n.inventoryPurchaseCountOrders(
                      costAnalysis.lastRefreshCount!,
                    ),
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: l10n.inventoryPurchaseCostByProduct,
          child: _SimpleDataTable(
            columns: [
              l10n.inventoryPurchaseProductName,
              l10n.superAdminCategory,
              l10n.inventoryPurchaseConsumedQuantity,
              l10n.inventoryPurchaseConsumedAmount,
              l10n.inventoryPurchaseAverageCost,
              l10n.inventoryPurchaseSupplierBaseline,
              l10n.status,
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
                    _costStatusLabel(row['cost_status'], context),
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
    final l10n = context.l10n;
    final rows = stockStatus.rows
        .take(10)
        .map(
          (row) => [
            _string(row['product_name'], fallback: '-'),
            _displayStock(row),
            '-',
            '-',
            _riskLabel(row['risk_status'], context),
          ],
        )
        .toList();

    return _PageShell(
      title: l10n.inventoryPurchaseStockAuditTitle,
      subtitle: l10n.inventoryPurchaseStockAuditDetailSubtitle,
      isLoading: stockStatus.isLoading || stockAuditState.isSaving,
      error: stockStatus.error ?? stockAuditState.error,
      actions: [
        PosActionButton(
          key: const Key('inventory_stock_audit_action'),
          label: l10n.inventoryPurchaseStockAuditInput,
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
            ToastMetric(
              label: l10n.inventoryPurchaseAuditTargets,
              value: l10n.inventoryPurchaseCountItems(stockStatus.rows.length),
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseRecentSession,
              value: stockAuditState.lastSessionId == null
                  ? '-'
                  : l10n.inventoryPurchaseSaved,
              tone: ToastColorTokens.accent,
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseRecentStatus,
              value: stockAuditState.lastCompleted
                  ? l10n.inventoryPurchaseCompleted
                  : l10n.inventoryPurchaseInProgress,
              tone: stockAuditState.lastCompleted
                  ? ToastColorTokens.success
                  : ToastColorTokens.warning,
            ),
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        _DataCard(
          title: l10n.inventoryPurchaseAuditTargetItems,
          trailing: ToastStatusBadge(
            label: l10n.inventoryPurchaseApplyStockOnComplete,
            color: ToastColorTokens.warning,
            compact: true,
          ),
          child: _SimpleDataTable(
            columns: [
              l10n.inventoryPurchaseProductName,
              l10n.inventoryPurchaseSystemStock,
              l10n.inventoryPurchaseCountedQuantity,
              l10n.inventoryPurchaseVariance,
              l10n.status,
            ],
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
    final l10n = context.l10n;
    final gramProducts = _gramRecipeProducts(productCatalog.products);

    return _PageShell(
      title: l10n.inventoryPurchaseNewMenuTitle,
      subtitle: l10n.inventoryPurchaseNewMenuFlowSubtitle,
      isLoading: newMenuState.isLoading || productCatalog.isLoading,
      error: newMenuState.error ?? productCatalog.error,
      actions: [
        PosActionButton(
          key: const Key('inventory_new_menu_action'),
          label: l10n.inventoryPurchaseNewMenuTitle,
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
        _StepFlow(
          steps: [
            l10n.inventoryPurchaseStepBasicInfo,
            l10n.inventoryPurchaseStepIngredients,
            l10n.inventoryPurchaseStepCooking,
            l10n.inventoryPurchaseStepCostCheck,
            l10n.inventoryPurchaseStepComplete,
          ],
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        ToastMetricStrip(
          metrics: [
            ToastMetric(
              label: l10n.inventoryPurchaseMenuCategories,
              value: l10n.inventoryPurchaseCountItems(
                newMenuState.categories.length,
              ),
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseRecipeCapableIngredients,
              value: l10n.inventoryPurchaseCountItems(gramProducts.length),
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseExistingMenus,
              value: l10n.inventoryPurchaseCountItems(
                recipeState.menuItems.length,
              ),
            ),
            ToastMetric(
              label: l10n.inventoryPurchaseRecentRegistration,
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
          title: l10n.inventoryPurchaseRecipeIngredientCandidates,
          child: _SimpleDataTable(
            columns: [
              l10n.inventoryPurchaseProductName,
              l10n.superAdminCategory,
              l10n.inventoryPurchaseDisplayStockUnit,
              l10n.inventoryPurchaseBaseUnit,
            ],
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
    super.key,
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
    return Semantics(
      button: true,
      enabled: true,
      selected: selected,
      label: section.label,
      child: Material(
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compactPhone = constraints.maxWidth < 430;
          final stackHeader =
              constraints.maxWidth < 760 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.5;
          final body = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          );
          final titleBlock = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: _textStyle(
                  size: compactPhone ? 21 : 24,
                  weight: FontWeight.w900,
                  color: ToastColorTokens.textPrimary,
                ),
              ),
              const SizedBox(height: ToastSpacingTokens.xs),
              Text(
                subtitle,
                style: _textStyle(
                  size: compactPhone ? 12.5 : 13,
                  weight: FontWeight.w500,
                  color: ToastColorTokens.textSecondary,
                ),
              ),
            ],
          );
          final actionWrap = Wrap(
            spacing: ToastSpacingTokens.sm,
            runSpacing: ToastSpacingTokens.sm,
            alignment: stackHeader ? WrapAlignment.start : WrapAlignment.end,
            children: actions,
          );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compactPhone ? 16 : 20,
                  18,
                  compactPhone ? 16 : 20,
                  14,
                ),
                child: stackHeader
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          titleBlock,
                          if (actions.isNotEmpty) ...[
                            const SizedBox(height: ToastSpacingTokens.sm),
                            actionWrap,
                          ],
                        ],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: titleBlock),
                          if (actions.isNotEmpty) ...[
                            const SizedBox(width: ToastSpacingTokens.md),
                            actionWrap,
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
              if (constraints.hasBoundedHeight)
                Expanded(
                  child: ToastViewportScroll(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: body,
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: body,
                ),
            ],
          );
        },
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
          LayoutBuilder(
            builder: (context, constraints) {
              final titleText = Text(
                title,
                style: _textStyle(
                  size: 15,
                  weight: FontWeight.w900,
                  color: ToastColorTokens.textPrimary,
                ),
              );
              if (trailing == null) return titleText;

              final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.5;
              if (constraints.maxWidth < 520 || largeText) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    titleText,
                    const SizedBox(height: ToastSpacingTokens.sm),
                    trailing!,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: titleText),
                  const SizedBox(width: ToastSpacingTokens.sm),
                  trailing!,
                ],
              );
            },
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
      return _EmptyInline(
        label: context.l10n.inventoryPurchaseNoData,
        icon: Icons.inbox_outlined,
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: 720,
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
      return _EmptyInline(
        label: context.l10n.inventoryPurchaseNoConsumptionTrendData,
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
      return _EmptyInline(
        label: context.l10n.inventoryPurchaseNoConsumptionShareData,
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
    final l10n = context.l10n;
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
              l10n.inventoryPurchaseShareRowValue(
                _quantity(row.quantity),
                row.count,
              ),
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
      return _EmptyInline(
        label: context.l10n.inventoryPurchaseNoConsumptionAlerts,
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
                          label: _riskLabel(
                            rows[index]['risk_status'],
                            context,
                          ),
                          color: _riskColor(rows[index]['risk_status']),
                          compact: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.l10n.inventoryPurchaseAlertRowSubtitle(
                        _displayStock(rows[index]),
                        _number(rows[index]['estimated_days_remaining']),
                        _quantity(rows[index]['avg_daily_consumption_base']),
                      ),
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
      return _EmptyInline(
        label: context.l10n.inventoryPurchaseNoSuppliers,
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
    final l10n = context.l10n;
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
                      l10n.inventoryPurchaseSupplierRowSubtitle(
                        _string(
                          supplier['supplier_type'],
                          fallback: l10n.inventoryPurchaseNoCategory,
                        ),
                        _string(
                          supplier['contact_name'],
                          fallback: l10n.inventoryPurchaseNoContact,
                        ),
                        _string(supplier['phone'], fallback: '-'),
                      ),
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
                label: _supplierStatusLabel(status, context),
                color: _supplierStatusColor(status),
                compact: true,
              ),
              const SizedBox(width: ToastSpacingTokens.sm),
              PosActionButton(
                label: l10n.edit,
                tone: PosActionTone.secondary,
                icon: Icons.edit_outlined,
                onPressed: saving ? null : () => onEdit(supplier),
                compact: true,
              ),
              const SizedBox(width: ToastSpacingTokens.sm),
              PosActionButton(
                label: status == 'active'
                    ? l10n.inventoryPurchasePause
                    : l10n.use,
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
      return _EmptyInline(
        label: context.l10n.inventoryPurchaseSelectSupplierForDetails,
        icon: Icons.storefront_outlined,
      );
    }
    final l10n = context.l10n;

    return Column(
      children: [
        _KeyValueRow(
          label: l10n.inventoryPurchaseSupplierName,
          value: _string(supplier!['supplier_name'], fallback: '-'),
          helper: _string(
            supplier!['supplier_type'],
            fallback: l10n.inventoryPurchaseNoCategory,
          ),
        ),
        const Divider(height: 1),
        _KeyValueRow(
          label: l10n.inventoryPurchaseContactName,
          value: _string(supplier!['contact_name'], fallback: '-'),
          helper: _string(supplier!['phone'], fallback: '-'),
        ),
        const Divider(height: 1),
        _KeyValueRow(
          label: l10n.inventoryPurchasePaymentTerms,
          value: _string(supplier!['payment_terms'], fallback: '-'),
          helper:
              '${_date(supplier!['contract_start_date'])} ~ ${_date(supplier!['contract_end_date'])}',
        ),
        const Divider(height: 1),
        _KeyValueRow(
          label: l10n.inventoryPurchaseBankAccountNumber,
          value: _string(supplier!['bank_account_number'], fallback: '-'),
          helper: _string(supplier!['business_registration_no'], fallback: '-'),
        ),
        const Divider(height: 1),
        _KeyValueRow(
          label: l10n.inventoryPurchaseSupplierItems,
          value: l10n.inventoryPurchaseCountItems(supplierItemCount),
          helper: _string(
            supplier!['address'],
            fallback: l10n.inventoryPurchaseNoAddress,
          ),
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
      return _EmptyInline(
        label: context.l10n.inventoryPurchaseNoProductsRegistered,
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
    final l10n = context.l10n;
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
                      l10n.inventoryPurchaseProductRowSubtitle(
                        _string(
                          product['product_code'],
                          fallback: l10n.inventoryPurchaseNoCode,
                        ),
                        _string(
                          product['category'],
                          fallback: l10n.inventoryPurchaseNoCategory,
                        ),
                        _string(product['stock_unit'], fallback: '-'),
                        _string(product['base_unit'], fallback: '-'),
                      ),
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
                label: orderable
                    ? l10n.inventoryPurchaseOrderable
                    : l10n.inventoryPurchaseOrderPaused,
                color: orderable
                    ? ToastColorTokens.success
                    : ToastColorTokens.warning,
                compact: true,
              ),
              const SizedBox(width: ToastSpacingTokens.sm),
              ToastStatusBadge(
                label: active
                    ? l10n.inventoryPurchaseActive
                    : l10n.inventoryPurchaseInactive,
                color: active
                    ? ToastColorTokens.success
                    : ToastColorTokens.textSecondary,
                compact: true,
              ),
              const SizedBox(width: ToastSpacingTokens.sm),
              PosActionButton(
                label: l10n.edit,
                tone: PosActionTone.secondary,
                icon: Icons.edit_outlined,
                onPressed: saving ? null : () => onEdit(product),
                compact: true,
              ),
              const SizedBox(width: ToastSpacingTokens.sm),
              PosActionButton(
                label: active ? l10n.inventoryPurchasePause : l10n.use,
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
      return _EmptyInline(
        label: context.l10n.inventoryPurchaseSelectProductForDetails,
        icon: Icons.category_outlined,
      );
    }
    final l10n = context.l10n;

    final inventoryItem = product!['inventory_item'] is Map
        ? Map<String, dynamic>.from(product!['inventory_item'] as Map)
        : const <String, dynamic>{};

    return Column(
      children: [
        _KeyValueRow(
          label: l10n.inventoryPurchaseProductName,
          value: _string(product!['name'], fallback: '-'),
          helper: _string(
            product!['product_code'],
            fallback: l10n.inventoryPurchaseNoCode,
          ),
        ),
        const Divider(height: 1),
        _KeyValueRow(
          label: l10n.inventoryPurchaseUnit,
          value: _string(product!['stock_unit'], fallback: '-'),
          helper: l10n.inventoryPurchaseBaseUnitFactorSummary(
            _string(product!['base_unit'], fallback: '-'),
            _quantity(product!['base_unit_factor']),
          ),
        ),
        const Divider(height: 1),
        _KeyValueRow(
          label: l10n.inventoryPurchaseCurrentStock,
          value: _quantity(inventoryItem['current_stock']),
          helper:
              '${l10n.inventoryPurchaseReorderPoint(_quantity(inventoryItem['reorder_point']))} · ${l10n.inventoryNeedsReorder} when stock is below this value',
        ),
        const Divider(height: 1),
        _KeyValueRow(
          label: l10n.inventoryPurchaseProductSupplierCosts,
          value: l10n.inventoryPurchaseCountOrders(supplierItemCount),
          helper: l10n.inventoryPurchaseDefaultUnitPrice(
            _money(inventoryItem['cost_per_unit']),
          ),
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
      return _EmptyInline(
        label: context.l10n.inventoryPurchaseNoLinkedSupplierItems,
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
    final l10n = context.l10n;
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
                  l10n.inventoryPurchaseSupplierItemRowSubtitle(
                    _string(item['order_unit'], fallback: '-'),
                    _quantity(item['order_unit_quantity_base']),
                    _string(product['base_unit'], fallback: ''),
                    _quantity(item['min_order_quantity']),
                    _int(item['lead_time_days']),
                  ),
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
            ToastStatusBadge(
              label: l10n.inventoryPurchaseDefault,
              color: ToastColorTokens.accent,
              compact: true,
            ),
          const SizedBox(width: ToastSpacingTokens.sm),
          ToastStatusBadge(
            label: active
                ? l10n.inventoryPurchaseActive
                : l10n.inventoryPurchasePaused,
            color: active
                ? ToastColorTokens.success
                : ToastColorTokens.textSecondary,
            compact: true,
          ),
          const SizedBox(width: ToastSpacingTokens.sm),
          PosActionButton(
            label: l10n.edit,
            tone: PosActionTone.secondary,
            icon: Icons.edit_outlined,
            onPressed: saving ? null : () => onEdit(item),
            compact: true,
          ),
          const SizedBox(width: ToastSpacingTokens.sm),
          PosActionButton(
            label: active ? l10n.inventoryPurchasePause : l10n.use,
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
      return _EmptyInline(
        label: context.l10n.inventoryPurchaseNoRecipeLines,
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
    final l10n = context.l10n;
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
            label: l10n.edit,
            tone: PosActionTone.secondary,
            icon: Icons.edit_outlined,
            onPressed: () => onEdit(recipe),
            compact: true,
          ),
          const SizedBox(width: ToastSpacingTokens.sm),
          PosActionButton(
            label: l10n.inventoryPurchaseDelete,
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
      return _EmptyInline(
        label: context.l10n.inventoryPurchaseNoRecommendationSnapshot,
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
                '${_nestedName(line['supplier'])} · ${_riskLabel(line['risk_status'], context)}',
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

class _RecommendationRunInput {
  const _RecommendationRunInput({
    required this.targetStockDays,
    required this.asOfDate,
  });

  final double targetStockDays;
  final DateTime asOfDate;
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

class _StockAuditPreviewLine {
  const _StockAuditPreviewLine({
    required this.productName,
    required this.systemQuantity,
    required this.actualQuantity,
    required this.variance,
    required this.unit,
  });

  final String productName;
  final double systemQuantity;
  final double actualQuantity;
  final double variance;
  final String unit;
}

class _StockAuditPendingPreview extends StatelessWidget {
  const _StockAuditPendingPreview({
    required this.countedCount,
    required this.lines,
  });

  final int countedCount;
  final List<_StockAuditPreviewLine> lines;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Container(
      key: const Key('pending_stock_audit_preview'),
      padding: const EdgeInsets.all(ToastSpacingTokens.md),
      decoration: BoxDecoration(
        color: ToastColorTokens.canvasAlt,
        borderRadius: ToastRadiusTokens.md,
        border: Border.all(color: ToastColorTokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.fact_check_outlined,
                size: 18,
                color: ToastColorTokens.info,
              ),
              const SizedBox(width: ToastSpacingTokens.sm),
              Expanded(
                child: Text(
                  l10n.inventoryPurchaseBeforeSaveAuditReview,
                  style: _textStyle(
                    size: 12.5,
                    weight: FontWeight.w900,
                    color: ToastColorTokens.textPrimary,
                  ),
                ),
              ),
              ToastStatusBadge(
                label: l10n.inventoryPurchaseCountedInput(countedCount),
                color: ToastColorTokens.info,
                compact: true,
              ),
              const SizedBox(width: ToastSpacingTokens.xs),
              ToastStatusBadge(
                label: l10n.inventoryPurchaseVarianceCount(lines.length),
                color: lines.isEmpty
                    ? ToastColorTokens.textSecondary
                    : ToastColorTokens.warning,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: ToastSpacingTokens.sm),
          if (lines.isEmpty)
            Text(
              l10n.inventoryPurchaseNoVarianceSaveHelp,
              style: _textStyle(
                size: 11.5,
                weight: FontWeight.w600,
                color: ToastColorTokens.textSecondary,
              ),
            )
          else
            SizedBox(
              height: 70,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: lines.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: ToastSpacingTokens.sm),
                itemBuilder: (context, index) {
                  final line = lines[index];
                  final varianceColor = line.variance > 0
                      ? ToastColorTokens.info
                      : ToastColorTokens.danger;
                  final varianceLabel = line.variance > 0
                      ? '+${_quantity(line.variance)}'
                      : _quantity(line.variance);
                  return Container(
                    width: 220,
                    padding: const EdgeInsets.all(ToastSpacingTokens.sm),
                    decoration: BoxDecoration(
                      color: ToastColorTokens.surface,
                      borderRadius: ToastRadiusTokens.sm,
                      border: Border.all(color: ToastColorTokens.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          line.productName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _textStyle(
                            size: 12,
                            weight: FontWeight.w900,
                            color: ToastColorTokens.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.inventoryPurchaseAuditPreviewQuantities(
                            _quantity(line.systemQuantity),
                            _quantity(line.actualQuantity),
                            line.unit,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _textStyle(
                            size: 10.8,
                            weight: FontWeight.w600,
                            color: ToastColorTokens.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        ToastStatusBadge(
                          label: l10n.inventoryPurchaseVarianceValue(
                            varianceLabel,
                          ),
                          color: varianceColor,
                          compact: true,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _StockAuditInputRow extends StatelessWidget {
  const _StockAuditInputRow({
    required this.row,
    required this.controller,
    this.onChanged,
  });

  final Map<String, dynamic> row;
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
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
                  l10n.inventoryPurchaseSystemStockAndCategory(
                    _displayStock(row),
                    _string(row['category'], fallback: '-'),
                  ),
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
              onChanged: onChanged,
              textAlign: TextAlign.right,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: l10n.inventoryPurchaseCountedQuantityWithUnit(
                  _string(row['base_unit'], fallback: '-'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PurchaseRecommendationGrid extends StatelessWidget {
  const _PurchaseRecommendationGrid({
    required this.lines,
    required this.snapshotDateLabel,
    required this.targetDaysLabel,
    required this.pendingOfficeApprovalCount,
    required this.onRunRecommendation,
    required this.onCreateManualOrder,
  });

  final List<Map<String, dynamic>> lines;
  final String snapshotDateLabel;
  final String targetDaysLabel;
  final int pendingOfficeApprovalCount;
  final VoidCallback? onRunRecommendation;
  final VoidCallback? onCreateManualOrder;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (lines.isEmpty) {
      return _RecommendationEmptyPanel(
        snapshotDateLabel: snapshotDateLabel,
        targetDaysLabel: targetDaysLabel,
        pendingOfficeApprovalCount: pendingOfficeApprovalCount,
        onRunRecommendation: onRunRecommendation,
        onCreateManualOrder: onCreateManualOrder,
      );
    }

    final totalAmount = lines.fold<num>(
      0,
      (sum, line) => sum + _recommendationEstimatedAmount(line),
    );
    final supplierTotals = <String, num>{};
    for (final line in lines) {
      final supplier = _nestedName(line['supplier']);
      supplierTotals[supplier] =
          (supplierTotals[supplier] ?? 0) +
          _recommendationEstimatedAmount(line);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RecommendationTotalsBand(
          lineCount: lines.length,
          totalAmount: totalAmount,
          supplierTotals: supplierTotals,
        ),
        const SizedBox(height: ToastSpacingTokens.md),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: 1240,
            child: Column(
              children: [
                PosDataGridRow(
                  statusColor: ToastColorTokens.border,
                  cells: [
                    _RecommendationHeaderCell(
                      l10n.inventoryPurchaseProductName,
                    ),
                    _RecommendationHeaderCell(
                      l10n.inventoryPurchaseCurrentStock,
                    ),
                    _RecommendationHeaderCell(
                      l10n.inventoryPurchaseRecommendedQuantity,
                    ),
                    _RecommendationHeaderCell(
                      l10n.inventoryPurchaseEffectiveOrderUnit,
                    ),
                    _RecommendationHeaderCell(l10n.inventoryPurchasePackUnit),
                    _RecommendationHeaderCell(l10n.inventoryPurchaseUnitPrice),
                    _RecommendationHeaderCell(
                      l10n.inventoryPurchaseEstimatedAmount,
                    ),
                    _RecommendationHeaderCell(l10n.status),
                  ],
                ),
                const SizedBox(height: ToastSpacingTokens.xs),
                for (final line in lines) ...[
                  _PurchaseRecommendationRow(line: line),
                  if (line != lines.last)
                    const SizedBox(height: ToastSpacingTokens.xs),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RecommendationEmptyPanel extends StatelessWidget {
  const _RecommendationEmptyPanel({
    required this.snapshotDateLabel,
    required this.targetDaysLabel,
    required this.pendingOfficeApprovalCount,
    required this.onRunRecommendation,
    required this.onCreateManualOrder,
  });

  final String snapshotDateLabel;
  final String targetDaysLabel;
  final int pendingOfficeApprovalCount;
  final VoidCallback? onRunRecommendation;
  final VoidCallback? onCreateManualOrder;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return Container(
      key: const Key('inventory_purchase_zero_recommendations_panel'),
      padding: const EdgeInsets.all(ToastSpacingTokens.lg),
      decoration: BoxDecoration(
        color: PosSurfaceRole.background.fill,
        borderRadius: ToastRadiusTokens.md,
        border: Border.all(color: PosSurfaceRole.background.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: PosSurfaceRole.action.fill,
                  borderRadius: ToastRadiusTokens.sm,
                  border: Border.all(color: PosSurfaceRole.action.stroke),
                ),
                child: Icon(
                  Icons.shopping_cart_checkout_outlined,
                  color: PosSurfaceRole.action.text,
                ),
              ),
              const SizedBox(width: ToastSpacingTokens.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.inventoryPurchaseZeroRecommendationTitle,
                      style: _textStyle(
                        size: 16,
                        weight: FontWeight.w900,
                        color: PosSurfaceRole.background.text,
                      ),
                    ),
                    const SizedBox(height: ToastSpacingTokens.xs),
                    Text(
                      l10n.inventoryPurchaseZeroRecommendationDetail,
                      style: _textStyle(
                        size: 12,
                        weight: FontWeight.w600,
                        color: PosSurfaceRole.background.helper,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: ToastSpacingTokens.md),
          Wrap(
            spacing: ToastSpacingTokens.sm,
            runSpacing: ToastSpacingTokens.sm,
            children: [
              ToastStatusBadge(
                label: l10n.inventoryPurchaseSnapshotBasis(snapshotDateLabel),
                color: ToastColorTokens.info,
                compact: true,
              ),
              ToastStatusBadge(
                label: l10n.inventoryPurchaseTargetStockDaysWithValue(
                  targetDaysLabel,
                ),
                color: ToastColorTokens.accent,
                compact: true,
              ),
              ToastStatusBadge(
                label: l10n.inventoryPurchasePendingOfficeApprovalCount(
                  pendingOfficeApprovalCount,
                ),
                color: pendingOfficeApprovalCount > 0
                    ? ToastColorTokens.warning
                    : ToastColorTokens.textSecondary,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: ToastSpacingTokens.md),
          Wrap(
            spacing: ToastSpacingTokens.sm,
            runSpacing: ToastSpacingTokens.sm,
            children: [
              PosActionTile(
                label: l10n.inventoryPurchaseGenerateRecommendation,
                helper: l10n.inventoryPurchaseGenerateRecommendationHelp,
                icon: Icons.auto_graph_outlined,
                state: onRunRecommendation == null
                    ? PosActionTileState.processing
                    : PosActionTileState.idle,
                onTap: onRunRecommendation,
              ),
              PosActionTile(
                label: l10n.inventoryPurchaseManualOrder,
                helper: l10n.inventoryPurchaseManualOrderHelp,
                icon: Icons.edit_note_outlined,
                state: onCreateManualOrder == null
                    ? PosActionTileState.disabled
                    : PosActionTileState.idle,
                onTap: onCreateManualOrder,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecommendationTotalsBand extends StatelessWidget {
  const _RecommendationTotalsBand({
    required this.lineCount,
    required this.totalAmount,
    required this.supplierTotals,
  });

  final int lineCount;
  final num totalAmount;
  final Map<String, num> supplierTotals;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final visibleSupplierTotals = supplierTotals.entries.take(3).toList();

    return Wrap(
      spacing: ToastSpacingTokens.sm,
      runSpacing: ToastSpacingTokens.sm,
      children: [
        SizedBox(
          width: 260,
          child: PosAmountAnchor(
            label: l10n.inventoryPurchaseEstimatedAmount,
            amount: _money(totalAmount),
            helper: l10n.inventoryPurchaseCountItems(lineCount),
            role: PosSurfaceRole.selected,
            amountStyle: PosNumericText.amountLarge,
          ),
        ),
        for (final entry in visibleSupplierTotals)
          SizedBox(
            width: 220,
            child: PosAmountAnchor(
              label: entry.key,
              amount: _money(entry.value),
              helper: l10n.inventoryPurchaseSupplier,
              role: PosSurfaceRole.operating,
              amountStyle: PosNumericText.amountLarge,
            ),
          ),
      ],
    );
  }
}

class _PurchaseRecommendationRow extends StatelessWidget {
  const _PurchaseRecommendationRow({required this.line});

  final Map<String, dynamic> line;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final baseUnit = _recommendationBaseUnit(line);
    final orderUnit = _recommendationOrderUnit(line);
    final effectiveUnits =
        line['adjusted_order_units'] ?? line['recommended_order_units'];
    final adjusted = line['adjusted_order_units'] != null;
    final unitPrice = _recommendationUnitPrice(line);
    final estimatedAmount = _recommendationEstimatedAmount(line);
    final packQuantity = _recommendationOrderUnitQuantityBase(line);
    final hasSupplierItem = _recommendationHasSupplierItem(line);
    final daysRemaining = _number(line['estimated_days_remaining']);

    return PosDataGridRow(
      statusColor: _riskColor(line['risk_status']).withValues(alpha: 0.72),
      cells: [
        _RecommendationValueCell(
          value: _nestedName(line['product']),
          helper: _nestedName(line['supplier']),
          leading: Icons.inventory_2_outlined,
        ),
        _RecommendationValueCell(
          value: _quantityWithUnit(line['current_stock_base'], baseUnit),
          helper: l10n.inventoryPurchaseUsageWithUnit(
            _quantityWithUnit(line['avg_daily_consumption_base'], baseUnit),
          ),
          valueStyle: PosNumericText.qtyUnit,
        ),
        _RecommendationValueCell(
          value: _quantityWithUnit(line['recommended_quantity_base'], baseUnit),
          helper: l10n.inventoryPurchaseDaysValue(
            _number(line['target_stock_days'], fallback: '3'),
          ),
          valueStyle: PosNumericText.qtyUnit,
        ),
        _RecommendationValueCell(
          value: _quantityWithUnit(effectiveUnits, orderUnit),
          helper: adjusted
              ? l10n.inventoryPurchaseAdjusted
              : l10n.inventoryPurchaseRecommendedValue,
          valueStyle: PosNumericText.qtyUnit,
        ),
        _RecommendationValueCell(
          value: packQuantity == 0
              ? l10n.inventoryPurchaseSupplierItemMissing
              : _quantityWithUnit(packQuantity, baseUnit),
          helper: hasSupplierItem
              ? orderUnit
              : l10n.inventoryPurchaseSupplierItemMissing,
          valueStyle: PosNumericText.qtyUnit,
        ),
        _RecommendationValueCell(
          value: _money(unitPrice),
          helper: orderUnit == '-'
              ? l10n.inventoryPurchaseSupplierItemMissing
              : '/ $orderUnit',
          alignEnd: true,
          valueStyle: PosNumericText.unitPrice,
        ),
        _RecommendationValueCell(
          value: _money(estimatedAmount),
          helper: l10n.inventoryPurchaseSupplyAmount,
          alignEnd: true,
          amount: true,
          valueStyle: PosNumericText.lineAmount,
        ),
        _RecommendationStatusCell(
          label: _riskLabel(line['risk_status'], context),
          color: _riskColor(line['risk_status']),
          helper: daysRemaining == '-'
              ? l10n.inventoryPurchaseEstimatedDays
              : l10n.inventoryPurchaseDaysValue(daysRemaining),
        ),
      ],
    );
  }
}

class _RecommendationHeaderCell extends StatelessWidget {
  const _RecommendationHeaderCell(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _textStyle(
        size: 11,
        weight: FontWeight.w900,
        color: ToastColorTokens.textSecondary,
      ),
    );
  }
}

class _RecommendationValueCell extends StatelessWidget {
  const _RecommendationValueCell({
    required this.value,
    required this.helper,
    this.leading,
    this.alignEnd = false,
    this.amount = false,
    this.valueStyle,
  });

  final String value;
  final String helper;
  final IconData? leading;
  final bool alignEnd;
  final bool amount;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.visible,
            textAlign: alignEnd ? TextAlign.right : TextAlign.left,
            style:
                valueStyle?.copyWith(color: ToastColorTokens.textPrimary) ??
                (amount
                    ? PosNumericText.lineAmount.copyWith(
                        color: ToastColorTokens.textPrimary,
                      )
                    : _textStyle(
                        size: 12.5,
                        weight: FontWeight.w900,
                        color: ToastColorTokens.textPrimary,
                      )),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          helper,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: alignEnd ? TextAlign.right : TextAlign.left,
          style: _textStyle(
            size: 10.5,
            weight: FontWeight.w700,
            color: ToastColorTokens.textSecondary,
          ),
        ),
      ],
    );

    if (leading == null) {
      return Align(
        alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
        child: content,
      );
    }

    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: ToastColorTokens.mutedSurface,
            borderRadius: ToastRadiusTokens.sm,
            border: Border.all(color: ToastColorTokens.border),
          ),
          child: Icon(leading, size: 16, color: ToastColorTokens.textSecondary),
        ),
        const SizedBox(width: ToastSpacingTokens.sm),
        Expanded(child: content),
      ],
    );
  }
}

class _RecommendationStatusCell extends StatelessWidget {
  const _RecommendationStatusCell({
    required this.label,
    required this.color,
    required this.helper,
  });

  final String label;
  final Color color;
  final String helper;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ToastStatusBadge(label: label, color: color, compact: true),
        const SizedBox(height: 5),
        Text(
          helper,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _textStyle(
            size: 10.5,
            weight: FontWeight.w700,
            color: ToastColorTokens.textSecondary,
          ),
        ),
      ],
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
      return _EmptyInline(
        label: context.l10n.inventoryPurchaseNoAdjustableRecommendationLines,
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
    final l10n = context.l10n;
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
                  l10n.inventoryPurchaseRecommendationAdjustmentSubtitle(
                    _nestedName(line['supplier']),
                    _quantity(line['recommended_order_units']),
                    _quantity(effectiveUnits),
                  ),
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
            label: adjusted
                ? l10n.inventoryPurchaseAdjusted
                : l10n.inventoryPurchaseRecommendedValue,
            color: adjusted
                ? ToastColorTokens.warning
                : ToastColorTokens.textSecondary,
            compact: true,
          ),
          const SizedBox(width: ToastSpacingTokens.sm),
          PosActionButton(
            key: ValueKey('inventory_recommendation_adjust_${line['id']}'),
            label: l10n.inventoryPurchaseAdjustQuantity,
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
      return _EmptyInline(
        label: context.l10n.inventoryPurchaseNoRecentOrders,
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
                '${_nestedName(order['supplier'])} · ${_statusLabel(order['status'], context)}',
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
      return _EmptyInline(
        label: context.l10n.inventoryPurchaseNoPrintableOrders,
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
    final l10n = context.l10n;
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
                      ToastStatusBadge(
                        label: l10n.selected,
                        color: ToastColorTokens.accent,
                        compact: true,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '$supplier · ${_statusLabel(order['status'], context)} · ${_money(order['total_amount'])}',
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
            label: l10n.inventoryPurchaseDetail,
            tone: PosActionTone.secondary,
            icon: Icons.visibility_outlined,
            onPressed: orderId == null ? null : () => onSelect(orderId),
            compact: true,
          ),
          const SizedBox(width: ToastSpacingTokens.sm),
          PosActionButton(
            label: l10n.inventoryPurchasePrintPdf,
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
    final l10n = context.l10n;
    return _DataCard(
      title: l10n.inventoryPurchaseQuickMenu,
      child: Wrap(
        spacing: ToastSpacingTokens.sm,
        runSpacing: ToastSpacingTokens.sm,
        children: [
          _QuickAction(
            icon: Icons.inventory_2_outlined,
            label: l10n.inventoryPurchaseStockStatusTitle,
            onTap: onSelectStock,
          ),
          _QuickAction(
            icon: Icons.shopping_cart_outlined,
            label: l10n.inventoryPurchaseGenerateRecommendation,
            onTap: onSelectPurchase,
          ),
          _QuickAction(
            icon: Icons.print_outlined,
            label: l10n.inventoryPurchasePrintPdf,
            onTap: onSelectPrint,
          ),
          _QuickAction(
            icon: Icons.fact_check_outlined,
            label: l10n.inventoryPurchaseStockAuditTitle,
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
      title: context.l10n.inventoryPurchaseRecipeRegistrationProcess,
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
      label: context.l10n.refresh,
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
  return AppFonts.system(
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
  List<Map<String, dynamic>> rows, {
  required String categoryFallback,
}) {
  final totals = <String, num>{};
  final counts = <String, int>{};
  for (final row in rows) {
    final category = _string(row['category'], fallback: categoryFallback);
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

String _supplierStatusLabel(String status, BuildContext context) {
  final l10n = context.l10n;
  return switch (status) {
    'active' => l10n.inventoryPurchaseActive,
    'inactive' => l10n.inventoryPurchaseInactive,
    'suspended' => l10n.inventoryPurchaseSuspended,
    _ => l10n.inventoryPurchaseRiskCheck,
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
  final formatter = NumberFormat('#,###', 'vi_VN');
  return '${formatter.format(_num(value))} VND';
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

Map<String, dynamic> _nestedMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const <String, dynamic>{};
}

String _displayStock(Map<String, dynamic> row) {
  final unit = _string(row['stock_unit'], fallback: _string(row['base_unit']));
  final value = row['current_stock_display'] ?? row['current_stock_base'];
  return '${_quantity(value)} $unit'.trim();
}

String _quantityWithUnit(Object? value, String unit) {
  final quantity = _quantity(value);
  final cleanUnit = _string(unit);
  return cleanUnit.isEmpty || cleanUnit == '-'
      ? quantity
      : '$quantity $cleanUnit';
}

String _recommendationBaseUnit(Map<String, dynamic> line) {
  final product = _nestedMap(line['product']);
  final supplierItem = _nestedMap(line['supplier_item']);
  final supplierProduct = _nestedMap(supplierItem['product']);
  return _string(
    product['base_unit'] ??
        product['stock_unit'] ??
        supplierProduct['base_unit'] ??
        supplierProduct['stock_unit'],
    fallback: '-',
  );
}

String _recommendationOrderUnit(Map<String, dynamic> line) {
  final supplierItem = _nestedMap(line['supplier_item']);
  return _string(
    line['order_unit'] ?? supplierItem['order_unit'],
    fallback: '-',
  );
}

num _recommendationOrderUnitQuantityBase(Map<String, dynamic> line) {
  final supplierItem = _nestedMap(line['supplier_item']);
  return _num(
    line['order_unit_quantity_base'] ??
        supplierItem['order_unit_quantity_base'],
  );
}

num _recommendationUnitPrice(Map<String, dynamic> line) {
  final supplierItem = _nestedMap(line['supplier_item']);
  return _num(line['unit_price'] ?? supplierItem['unit_price']);
}

num _recommendationEstimatedAmount(Map<String, dynamic> line) {
  final savedEstimate = line['estimated_amount'];
  if (savedEstimate != null) {
    return _num(savedEstimate);
  }
  final effectiveUnits =
      line['adjusted_order_units'] ?? line['recommended_order_units'];
  return _num(effectiveUnits) * _recommendationUnitPrice(line);
}

bool _recommendationHasSupplierItem(Map<String, dynamic> line) {
  if (_nestedMap(line['supplier_item']).isNotEmpty) {
    return true;
  }
  return _string(line['order_unit']).isNotEmpty ||
      _num(line['order_unit_quantity_base']) > 0 ||
      _num(line['unit_price']) > 0;
}

String _riskLabel(Object? value, BuildContext context) {
  final l10n = context.l10n;
  return switch (_string(value)) {
    'danger' => l10n.inventoryPurchaseRiskDanger,
    'warning' => l10n.inventoryPurchaseRiskWarning,
    'normal' => l10n.inventoryPurchaseRiskNormal,
    'stable' => l10n.inventoryPurchaseRiskStable,
    _ => l10n.inventoryPurchaseRiskCheck,
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

String _receivingPilotBlockerMessage(
  Map<String, dynamic> order,
  BuildContext context,
) {
  final status = _string(order['status']);
  final statusLabel = _statusLabel(status, context);
  if (status == 'submitted' || status == 'office_returned') {
    return '$statusLabel: Office approval is required before POS can confirm receiving or increase stock. Hand this order to the Office approval queue, then retest with office_approved or ordered status.';
  }
  if (status == 'office_rejected' || status == 'cancelled') {
    return '$statusLabel: this purchase order cannot be received. Create or select an approved purchase order for the receiving test.';
  }
  if (_num(order['total_remaining_quantity_base']) <= 0) {
    return '$statusLabel: no remaining quantity is available to receive.';
  }
  return '$statusLabel: POS can receive only office_approved, ordered, or partially_received purchase orders.';
}

String _receiptVisibilityLabel(Object? value, BuildContext context) {
  final l10n = context.l10n;
  return switch (_string(value)) {
    'received' => l10n.inventoryPurchaseStatusReceived,
    'partially_received' => l10n.inventoryPurchaseStatusPartiallyReceived,
    'pending' => l10n.inventoryPurchaseReceiptPending,
    _ => l10n.inventoryPurchaseRiskCheck,
  };
}

String _receiptStatusLabel(Object? value, BuildContext context) {
  final l10n = context.l10n;
  return switch (_string(value)) {
    'confirmed' => l10n.inventoryPurchaseReceiptConfirmed,
    'draft' => l10n.inventoryPurchaseStatusDraft,
    'cancelled' => l10n.inventoryPurchaseStatusCancelled,
    _ => _string(value, fallback: '-'),
  };
}

String _costStatusLabel(Object? value, BuildContext context) {
  final l10n = context.l10n;
  return switch (_string(value)) {
    'warning' => l10n.inventoryPurchaseRiskWarning,
    'missing_supplier_cost' => l10n.inventoryPurchaseMissingSupplierCost,
    'normal' => l10n.inventoryPurchaseCostNormal,
    'stable' => l10n.inventoryPurchaseRiskStable,
    _ => l10n.inventoryPurchaseRiskCheck,
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

String _statusLabel(Object? value, BuildContext context) {
  final l10n = context.l10n;
  return switch (_string(value)) {
    'draft' => l10n.inventoryPurchaseStatusDraft,
    'submitted' => l10n.inventoryPurchaseStatusSubmitted,
    'office_approved' => l10n.inventoryPurchaseStatusOfficeApproved,
    'office_returned' => l10n.inventoryPurchaseStatusOfficeReturned,
    'office_rejected' => l10n.inventoryPurchaseStatusOfficeRejected,
    'ordered' => l10n.inventoryPurchaseStatusOrdered,
    'partially_received' => l10n.inventoryPurchaseStatusPartiallyReceived,
    'received' => l10n.inventoryPurchaseStatusReceived,
    'cancelled' => l10n.inventoryPurchaseStatusCancelled,
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
