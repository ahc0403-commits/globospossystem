import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:intl/intl.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../core/ui/pos_design_tokens.dart';
import '../../../core/ui/toast/toast.dart';
import '../../../core/utils/number_input_utils.dart';
import '../../../core/utils/permission_utils.dart';
import '../../../main.dart';
import '../../../widgets/error_toast.dart';
import '../../auth/auth_provider.dart';
import '../../inventory/inventory_provider.dart';

class InventoryTab extends ConsumerStatefulWidget {
  const InventoryTab({super.key});

  @override
  ConsumerState<InventoryTab> createState() => _InventoryTabState();
}

class _InventorySurfaceKey {
  static const ingredient = 'ingredient';
  static const recipe = 'recipe';
  static const physicalCount = 'physical_count';
  static const report = 'report';
}

class _InventoryTabState extends ConsumerState<InventoryTab>
    with TickerProviderStateMixin {
  TabController? _tabController;
  String? _initializedRestaurantId;
  int _selectedSurfaceIndex = 0;
  String? _selectedMenuItemId;
  DateTime _countDate = DateTime.now();
  DateTime _reportFrom = DateTime.now().subtract(const Duration(days: 6));
  DateTime _reportTo = DateTime.now();
  String? _selectedPurchaseOrderId;
  String? _selectedReceiptId;
  final Map<String, TextEditingController> _actualControllers = {};
  final Map<String, TextEditingController> _noteControllers = {};

  @override
  void dispose() {
    _tabController?.dispose();
    for (final c in _actualControllers.values) {
      c.dispose();
    }
    for (final c in _noteControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _ensureTabController(int length) {
    if (_tabController != null && _tabController!.length == length) {
      return;
    }
    final previousIndex = _tabController?.index ?? 0;
    _tabController?.dispose();
    _tabController = TabController(length: length, vsync: this);
    _tabController!.index = previousIndex.clamp(0, length - 1);
    _selectedSurfaceIndex = _tabController!.index;
    _tabController!.addListener(() {
      if (!mounted) return;
      if (_selectedSurfaceIndex != _tabController!.index) {
        setState(() => _selectedSurfaceIndex = _tabController!.index);
      }
    });
  }

  Future<void> _initialize(String storeId) async {
    await ref.read(ingredientProvider.notifier).load(storeId);
    await ref.read(recipeProvider.notifier).loadAll(storeId);
    await ref
        .read(physicalCountProvider.notifier)
        .load(storeId, DateFormat('yyyy-MM-dd').format(_countDate));
    await ref.read(inventoryPurchaseOverviewProvider.notifier).load(storeId);
    await ref
        .read(inventoryPurchaseRecommendationSnapshotProvider.notifier)
        .loadLatest(storeId);
    await _loadPurchaseOrderSummaryAndDetail(storeId);
    await ref
        .read(inventoryReportProvider.notifier)
        .load(storeId: storeId, from: _reportFrom, to: _reportTo);
  }

  Future<void> _loadPurchaseOrderSummaryAndDetail(
    String storeId, {
    String? preferredOrderId,
    bool clearRuntimeStates = true,
  }) async {
    await ref
        .read(inventoryPurchaseOrderSummaryProvider.notifier)
        .load(storeId);
    final summary = ref.read(inventoryPurchaseOrderSummaryProvider);
    final orders = summary.orders;

    String? nextOrderId = preferredOrderId ?? _selectedPurchaseOrderId;
    if (nextOrderId != null &&
        !orders.any((order) => order['id']?.toString() == nextOrderId)) {
      nextOrderId = null;
    }
    nextOrderId ??= orders.isNotEmpty ? orders.first['id']?.toString() : null;

    if (!mounted) return;
    if (_selectedPurchaseOrderId != nextOrderId) {
      setState(() => _selectedPurchaseOrderId = nextOrderId);
    }

    if (nextOrderId == null) {
      if (_selectedReceiptId != null) {
        setState(() => _selectedReceiptId = null);
      }
      if (clearRuntimeStates) {
        _clearInventoryPurchaseRuntimeStates();
      }
      ref.read(inventoryPurchaseOrderDetailProvider.notifier).clear();
      return;
    }

    if (clearRuntimeStates) {
      _clearInventoryPurchaseRuntimeStates();
    }
    await ref
        .read(inventoryPurchaseOrderDetailProvider.notifier)
        .load(nextOrderId);
    _syncSelectedReceipt();
  }

  Future<void> _selectPurchaseOrder({required String orderId}) async {
    if (_selectedPurchaseOrderId != orderId && mounted) {
      setState(() {
        _selectedPurchaseOrderId = orderId;
        _selectedReceiptId = null;
      });
    }
    _clearInventoryPurchaseRuntimeStates();
    await ref.read(inventoryPurchaseOrderDetailProvider.notifier).load(orderId);
    _syncSelectedReceipt();
  }

  void _syncSelectedReceipt() {
    final detail = ref.read(inventoryPurchaseOrderDetailProvider);
    final receipts = detail.receipts;

    String? nextReceiptId = _selectedReceiptId;
    if (nextReceiptId != null &&
        !receipts.any(
          (receipt) => receipt['id']?.toString() == nextReceiptId,
        )) {
      nextReceiptId = null;
    }
    nextReceiptId ??= receipts.isNotEmpty
        ? receipts.first['id']?.toString()
        : null;

    if (mounted && _selectedReceiptId != nextReceiptId) {
      setState(() => _selectedReceiptId = nextReceiptId);
    }
  }

  void _selectReceipt(String receiptId) {
    if (mounted && _selectedReceiptId != receiptId) {
      setState(() => _selectedReceiptId = receiptId);
    }
  }

  void _clearInventoryPurchaseRuntimeStates() {
    ref.read(inventoryPurchaseApprovalRuntimeProvider.notifier).clear();
    ref.read(inventoryPurchaseReceivingRuntimeProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final storeId = auth.storeId;
    final ingredientState = ref.watch(ingredientProvider);
    final recipeState = ref.watch(recipeProvider);
    final physicalCountState = ref.watch(physicalCountProvider);
    final reportState = ref.watch(inventoryReportProvider);
    final canCount = PermissionUtils.canDoInventoryCount(
      auth.role,
      auth.extraPermissions,
    );

    final tabs = <String>[
      _InventorySurfaceKey.ingredient,
      _InventorySurfaceKey.recipe,
      if (canCount) _InventorySurfaceKey.physicalCount,
      _InventorySurfaceKey.report,
    ];
    _ensureTabController(tabs.length);

    if (storeId != null && _initializedRestaurantId != storeId) {
      _initializedRestaurantId = storeId;
      Future.microtask(() => _initialize(storeId));
    }

    final controller = _tabController;
    if (controller == null) {
      return const SizedBox.shrink();
    }

    return Scaffold(
      key: const Key('inventory_root'),
      backgroundColor: AppColors.surface0,
      body: ToastResponsiveBody(
        maxWidth: 1480,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildInventoryCommandHeader(
              controller: controller,
              tabs: tabs,
              ingredientState: ingredientState,
              recipeState: recipeState,
              physicalCountState: physicalCountState,
              reportState: reportState,
              canCount: canCount,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ToastWorkSurface(
                padding: EdgeInsets.zero,
                child: TabBarView(
                  controller: controller,
                  children: [
                    _buildIngredientsTab(storeId),
                    _buildRecipeTab(storeId),
                    if (canCount) _buildPhysicalCountTab(storeId),
                    _buildReportTab(storeId),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInventoryCommandHeader({
    required TabController controller,
    required List<String> tabs,
    required IngredientState ingredientState,
    required RecipeState recipeState,
    required PhysicalCountState physicalCountState,
    required InventoryReportState reportState,
    required bool canCount,
  }) {
    final l10n = context.l10n;
    final selectedTab = tabs[_selectedSurfaceIndex];
    // Contract anchor: title: l10n.inventoryManagementTitle; subtitle: l10n.inventoryManagementSubtitle.

    return ToastWorkSurface(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      backgroundColor: AppColors.surface1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.inventoryManagementTitle,
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.inventoryManagementSubtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PosColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              ToastStatusBadge(
                label: _inventorySurfaceLabel(selectedTab),
                color: _inventorySurfaceColor(selectedTab),
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 14),
          ToastMetricStrip(
            metrics: [
              ToastMetric(
                label: l10n.inventoryIngredientsStat,
                value: '${ingredientState.items.length}',
              ),
              ToastMetric(
                label: l10n.inventoryRecipeStat,
                value: '${recipeState.allRecipes.length}',
              ),
              ToastMetric(
                label: l10n.inventoryPhysicalCountEntry,
                value: canCount
                    ? '${physicalCountState.counts.length}'
                    : l10n.inventoryLocked,
                tone: canCount ? PosColors.info : PosColors.textSecondary,
              ),
              ToastMetric(
                label: l10n.inventoryTransactionLog,
                value: '${reportState.transactions.length}',
                tone: PosColors.success,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var index = 0; index < tabs.length; index++)
                      _InventorySurfaceTab(
                        label: _inventorySurfaceDisplayLabel(tabs[index]),
                        selected: index == _selectedSurfaceIndex,
                        onTap: () => controller.animateTo(index),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Flexible(
                child: Text(
                  _inventorySurfaceSummary(selectedTab),
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _inventorySurfaceDisplayLabel(String tab) {
    switch (tab) {
      case _InventorySurfaceKey.ingredient:
        return context.l10n.inventorySurfaceIngredient;
      case _InventorySurfaceKey.recipe:
        return context.l10n.inventorySurfaceRecipe;
      case _InventorySurfaceKey.physicalCount:
        return context.l10n.inventorySurfacePhysicalCount;
      case _InventorySurfaceKey.report:
        return context.l10n.inventorySurfaceReport;
      default:
        return tab;
    }
  }

  String _inventorySurfaceLabel(String tab) {
    final l10n = context.l10n;
    switch (tab) {
      case _InventorySurfaceKey.physicalCount:
        return l10n.inventoryExceptionQueue;
      case _InventorySurfaceKey.report:
        return l10n.adminWorkflowBackOffice;
      default:
        return l10n.inventoryCatalogOps;
    }
  }

  String _inventorySurfaceSummary(String tab) {
    switch (tab) {
      case _InventorySurfaceKey.ingredient:
        return context.l10n.inventorySurfaceIngredientSummary;
      case _InventorySurfaceKey.recipe:
        return context.l10n.inventorySurfaceRecipeSummary;
      case _InventorySurfaceKey.physicalCount:
        return context.l10n.inventorySurfacePhysicalCountSummary;
      case _InventorySurfaceKey.report:
        return context.l10n.inventorySurfaceReportSummary;
      default:
        return context.l10n.inventorySurfaceDefaultSummary;
    }
  }

  Color _inventorySurfaceColor(String tab) {
    switch (tab) {
      case _InventorySurfaceKey.physicalCount:
        return PosColors.warning;
      case _InventorySurfaceKey.report:
        return PosColors.textSecondary;
      default:
        return PosColors.accent;
    }
  }

  Widget _buildIngredientsTab(String? storeId) {
    final state = ref.watch(ingredientProvider);
    final notifier = ref.read(ingredientProvider.notifier);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          Row(
            children: [
              Text(
                context.l10n.inventoryIngredientListTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: storeId == null
                    ? null
                    : () => _showIngredientDialog(context, storeId, notifier),
                icon: const Icon(Icons.add),
                label: Text(context.l10n.inventoryAddIngredientAction),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              context.l10n.inventoryIngredientListSubtitle,
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (state.isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: CircularProgressIndicator(color: AppColors.amber500),
              ),
            )
          else if (state.error != null && state.items.isEmpty)
            _buildIngredientInfoState(
              icon: Icons.error_outline,
              title: context.l10n.inventoryFailedLoadIngredientCatalog,
              message: state.error!,
            )
          else if (state.items.isEmpty)
            _buildIngredientInfoState(
              icon: Icons.inventory_2_outlined,
              title: context.l10n.inventoryNoIngredientsRegistered,
              message: context.l10n.inventoryStartCatalogByAddingIngredient,
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: state.items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final item = state.items[index];
                return _buildIngredientCard(
                  context,
                  storeId: storeId,
                  notifier: notifier,
                  item: item,
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildIngredientCard(
    BuildContext context, {
    required String? storeId,
    required IngredientNotifier notifier,
    required Map<String, dynamic> item,
  }) {
    final l10n = context.l10n;
    final stock = (item['current_stock'] as num?)?.toDouble() ?? 0;
    final reorder = (item['reorder_point'] as num?)?.toDouble();
    final cost = (item['cost_per_unit'] as num?)?.toDouble();
    final supplier = item['supplier_name']?.toString();
    final unit = item['unit']?.toString() ?? 'g';
    final needsReorder = item['needs_reorder'] == true;
    final lastUpdatedRaw = item['last_updated']?.toString();
    final lastUpdated = lastUpdatedRaw == null
        ? null
        : DateTime.tryParse(lastUpdatedRaw)?.toLocal();

    final borderColor = stock <= 0
        ? AppColors.statusCancelled
        : needsReorder
        ? AppColors.statusOccupied
        : AppColors.surface2;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item['name']?.toString() ?? '-',
                      style: AppFonts.system(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _buildIngredientMetaChip(
                          l10n.inventoryStockWithUnit(
                            stock.toStringAsFixed(3),
                            unit,
                          ),
                          color: stock <= 0
                              ? AppColors.statusCancelled
                              : AppColors.amber500,
                        ),
                        _buildIngredientMetaChip(
                          reorder == null
                              ? l10n.inventoryNoReorderPoint
                              : l10n.inventoryReorderPointWithUnit(
                                  reorder.toStringAsFixed(3),
                                  unit,
                                ),
                          color: needsReorder
                              ? AppColors.statusOccupied
                              : AppColors.surface2,
                        ),
                        _buildIngredientMetaChip(
                          cost == null
                              ? l10n.inventoryUnitPriceUnset
                              : l10n.inventoryUnitPriceValue(
                                  NumberFormat('#,###', 'vi_VN').format(cost),
                                ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      supplier == null || supplier.isEmpty
                          ? l10n.inventoryNoSupplierInfo
                          : l10n.inventorySupplierName(supplier),
                      style: AppFonts.system(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      lastUpdated == null
                          ? l10n.inventoryNoRecentChangeLog
                          : l10n.inventoryUpdatedAt(
                              DateFormat(
                                'yyyy-MM-dd HH:mm',
                              ).format(lastUpdated),
                            ),
                      style: AppFonts.system(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    if (needsReorder)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          stock <= 0
                              ? l10n.inventoryOutOfStock
                              : l10n.inventoryNeedsReorder,
                          style: AppFonts.system(
                            color: stock <= 0
                                ? AppColors.statusCancelled
                                : AppColors.statusOccupied,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: storeId == null
                        ? null
                        : () => _showRestockWasteDialog(
                            context,
                            storeId: storeId,
                            ingredientId:
                                item['ingredient_id']?.toString() ??
                                item['id']?.toString() ??
                                '',
                            ingredientName: item['name']?.toString() ?? '',
                            unit: item['unit']?.toString() ?? 'g',
                            isWaste: false,
                          ),
                    icon: const Icon(Icons.add_circle_outline, size: 20),
                    color: AppColors.statusAvailable,
                    tooltip: l10n.inventoryReceiving,
                  ),
                  IconButton(
                    onPressed: storeId == null
                        ? null
                        : () => _showRestockWasteDialog(
                            context,
                            storeId: storeId,
                            ingredientId:
                                item['ingredient_id']?.toString() ??
                                item['id']?.toString() ??
                                '',
                            ingredientName: item['name']?.toString() ?? '',
                            unit: item['unit']?.toString() ?? 'g',
                            isWaste: true,
                          ),
                    icon: const Icon(Icons.remove_circle_outline, size: 20),
                    color: AppColors.statusCancelled,
                    tooltip: l10n.inventoryDisposal,
                  ),
                  IconButton(
                    onPressed: storeId == null
                        ? null
                        : () => _showIngredientDialog(
                            context,
                            storeId,
                            notifier,
                            initial: item,
                          ),
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    color: AppColors.textSecondary,
                    tooltip: l10n.inventoryEditIngredient,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildIngredientMetaChip(String label, {Color? color}) {
    final chipColor = color ?? AppColors.surface2;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: chipColor),
      ),
      child: Text(
        label,
        style: AppFonts.system(
          color: AppColors.textPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildIngredientInfoState({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surface1,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.surface2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 30, color: AppColors.amber500),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: AppFonts.system(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: AppFonts.system(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showRestockWasteDialog(
    BuildContext context, {
    required String storeId,
    required String ingredientId,
    required String ingredientName,
    required String unit,
    required bool isWaste,
  }) async {
    final l10n = context.l10n;
    final qtyController = TextEditingController();
    final noteController = TextEditingController();
    final title = isWaste
        ? l10n.inventoryDisposalRecord
        : l10n.inventoryReceivingRecord;
    final actionLabel = isWaste
        ? l10n.inventoryRegisterDisposal
        : l10n.inventoryRegisterReceiving;

    final confirmed = await ToastConfirmDialog.withContent(
      context: context,
      title: '$ingredientName — $title',
      confirmLabel: actionLabel,
      destructive: isWaste,
      confirmTone: isWaste ? null : PosActionTone.affirm,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: qtyController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: InputDecoration(
              labelText: l10n.inventoryQuantityWithUnit(unit),
              labelStyle: const TextStyle(color: AppColors.textSecondary),
              enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.surface2),
              ),
              focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.amber500),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: noteController,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: InputDecoration(
              labelText: l10n.memoOptional,
              labelStyle: const TextStyle(color: AppColors.textSecondary),
              enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.surface2),
              ),
              focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.amber500),
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final qty = parseDecimalInput(qtyController.text);
    if (qty == null || qty <= 0) {
      if (context.mounted) {
        showErrorToast(context, l10n.inventoryEnterQuantityGreaterThanZero);
      }
      return;
    }

    final note = noteController.text.trim();
    final notifier = ref.read(ingredientProvider.notifier);
    final bool success;

    if (isWaste) {
      success = await notifier.recordWaste(
        storeId,
        ingredientId,
        qty,
        note.isEmpty ? null : note,
      );
    } else {
      success = await notifier.restock(
        storeId,
        ingredientId,
        qty,
        note.isEmpty ? null : note,
      );
    }

    if (!success && context.mounted) {
      final error = ref.read(ingredientProvider).error;
      if (error != null) {
        showErrorToast(context, error);
      }
    }
  }

  Widget _buildRecipeTab(String? storeId) {
    final ingredientState = ref.watch(ingredientProvider);
    final recipeState = ref.watch(recipeProvider);
    final notifier = ref.read(recipeProvider.notifier);
    final l10n = context.l10n;
    final menuItems = recipeState.menuItems;
    final gramIngredients = ingredientState.items
        .where((item) => item['unit']?.toString() == 'g')
        .toList();

    if (_selectedMenuItemId != null &&
        menuItems.every((m) => m['id']?.toString() != _selectedMenuItemId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _selectedMenuItemId = null);
      });
    }

    final recipesForMenu = _selectedMenuItemId == null
        ? recipeState.allRecipes
        : recipeState.allRecipes
              .where(
                (r) => r['menu_item_id']?.toString() == _selectedMenuItemId,
              )
              .toList();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                l10n.inventorySurfaceRecipe,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: storeId == null || menuItems.isEmpty
                    ? null
                    : () => _showUpsertRecipeDialog(
                        context: context,
                        storeId: storeId,
                        notifier: notifier,
                        menuItems: menuItems,
                        ingredients: gramIngredients,
                        initialMenuItemId: _selectedMenuItemId,
                      ),
                icon: const Icon(Icons.add),
                label: Text(l10n.inventoryAddRecipeMapping),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            l10n.inventorySurfaceRecipeSummary,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            initialValue: _selectedMenuItemId,
            dropdownColor: AppColors.surface1,
            style: AppFonts.system(color: AppColors.textPrimary),
            decoration: InputDecoration(
              labelText: context.l10n.inventoryMenuFilter,
            ),
            items: [
              DropdownMenuItem<String?>(
                value: null,
                child: Text(context.l10n.inventoryAllMenus),
              ),
              ...menuItems.map(
                (m) => DropdownMenuItem<String?>(
                  value: m['id']?.toString(),
                  child: Text(m['name']?.toString() ?? '-'),
                ),
              ),
            ],
            onChanged: (value) => setState(() => _selectedMenuItemId = value),
          ),
          const SizedBox(height: 8),
          if (recipeState.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                recipeState.error!,
                style: AppFonts.system(
                  color: AppColors.statusCancelled,
                  fontSize: 12,
                ),
              ),
            ),
          Expanded(
            child: recipeState.isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.amber500),
                  )
                : recipesForMenu.isEmpty
                ? _buildIngredientInfoState(
                    icon: Icons.receipt_long_outlined,
                    title: context.l10n.inventoryNoRecipeMappings,
                    message: menuItems.isEmpty
                        ? context.l10n.inventoryPrepareMenusFirst
                        : context.l10n.inventoryStartByAddingRecipeMapping,
                  )
                : ListView.separated(
                    itemCount: recipesForMenu.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final row = recipesForMenu[index];
                      final quantity = (row['quantity_g'] as num?)?.toDouble();
                      final ingredientUnit =
                          row['ingredient_unit']?.toString() ?? 'g';
                      final lastUpdatedRaw = row['last_updated']?.toString();
                      final lastUpdated = lastUpdatedRaw == null
                          ? null
                          : DateTime.tryParse(lastUpdatedRaw)?.toLocal();
                      final menuItemId = row['menu_item_id']?.toString();
                      final ingredientId = row['ingredient_id']?.toString();

                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.surface1,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.surface2),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    row['menu_item_name']?.toString() ?? '-',
                                    style: AppFonts.system(
                                      color: AppColors.textPrimary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${row['ingredient_name'] ?? '-'} · ${quantity?.toStringAsFixed(3) ?? '-'} g',
                                    style: AppFonts.system(
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    context.l10n.inventoryIngredientUnit(
                                      ingredientUnit,
                                    ),
                                    style: AppFonts.system(
                                      color: AppColors.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    lastUpdated == null
                                        ? context.l10n.inventoryNoRecentUpdates
                                        : context.l10n.inventoryUpdatedAt(
                                            DateFormat(
                                              'yyyy-MM-dd HH:mm',
                                            ).format(lastUpdated),
                                          ),
                                    style: AppFonts.system(
                                      color: AppColors.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed:
                                  storeId == null ||
                                      menuItemId == null ||
                                      ingredientId == null
                                  ? null
                                  : () => _showUpsertRecipeDialog(
                                      context: context,
                                      storeId: storeId,
                                      notifier: notifier,
                                      menuItems: menuItems,
                                      ingredients: gramIngredients,
                                      initialMenuItemId: menuItemId,
                                      initialRow: row,
                                    ),
                              icon: const Icon(Icons.edit_outlined),
                              color: AppColors.textSecondary,
                              tooltip: context.l10n.inventoryEditRecipe,
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

  Widget _buildPhysicalCountTab(String? storeId) {
    final countState = ref.watch(physicalCountProvider);
    final sheetRows = countState.counts;

    final currentIds = sheetRows
        .map((row) => row['ingredient_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    final staleActualKeys = _actualControllers.keys
        .where((id) => !currentIds.contains(id))
        .toList(growable: false);
    for (final id in staleActualKeys) {
      _actualControllers.remove(id)?.dispose();
    }
    final staleNoteKeys = _noteControllers.keys
        .where((id) => !currentIds.contains(id))
        .toList(growable: false);
    for (final id in staleNoteKeys) {
      _noteControllers.remove(id)?.dispose();
    }

    for (final row in sheetRows) {
      final id = row['ingredient_id']?.toString();
      if (id == null || id.isEmpty) continue;
      _actualControllers.putIfAbsent(id, () {
        final actual = (row['actual_quantity_g'] as num?)?.toDouble();
        return TextEditingController(
          text: actual == null ? '' : actual.toStringAsFixed(3),
        );
      });
      _noteControllers.putIfAbsent(id, TextEditingController.new);
    }

    final entered = _actualControllers.values
        .where((c) => c.text.trim().isNotEmpty)
        .length;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          Text(
            context.l10n.inventoryCountSheetTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _countDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (picked == null || storeId == null) return;
                  setState(() {
                    _countDate = DateTime(
                      picked.year,
                      picked.month,
                      picked.day,
                    );
                    for (final c in _actualControllers.values) {
                      c.dispose();
                    }
                    _actualControllers.clear();
                    for (final c in _noteControllers.values) {
                      c.dispose();
                    }
                    _noteControllers.clear();
                  });
                  await ref
                      .read(physicalCountProvider.notifier)
                      .load(
                        storeId,
                        DateFormat('yyyy-MM-dd').format(_countDate),
                      );
                },
                icon: const Icon(Icons.event),
                label: Text(DateFormat('yyyy-MM-dd').format(_countDate)),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: storeId == null
                    ? null
                    : () => ref
                          .read(physicalCountProvider.notifier)
                          .load(
                            storeId,
                            DateFormat('yyyy-MM-dd').format(_countDate),
                          ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                child: Text(context.l10n.inventoryStartPhysicalCount),
              ),
              const Spacer(),
              Text(
                context.l10n.inventoryEnteredCount(entered, sheetRows.length),
                style: AppFonts.system(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (countState.error != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                countState.error!,
                style: AppFonts.system(
                  color: AppColors.statusCancelled,
                  fontSize: 12,
                ),
              ),
            ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              context.l10n.inventoryCountSheetSubtitle,
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (countState.isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: CircularProgressIndicator(color: AppColors.amber500),
              ),
            )
          else if (sheetRows.isEmpty)
            Center(
              child: Text(
                context.l10n.inventoryNoIngredientsToCount,
                style: AppFonts.system(color: AppColors.textSecondary),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: sheetRows.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final row = sheetRows[index];
                final id = row['ingredient_id']?.toString() ?? '';
                final theoretical =
                    (row['theoretical_quantity_g'] as num?)?.toDouble() ?? 0;
                final unit = row['ingredient_unit']?.toString() ?? 'g';
                final actualController = _actualControllers[id];
                final noteController = _noteControllers[id];
                if (actualController == null || noteController == null) {
                  return const SizedBox.shrink();
                }
                final existingActual = (row['actual_quantity_g'] as num?)
                    ?.toDouble();
                final storedVariance = (row['variance_quantity_g'] as num?)
                    ?.toDouble();
                final countDateLabel =
                    row['count_date']?.toString() ??
                    DateFormat('yyyy-MM-dd').format(_countDate);
                final lastUpdatedRaw = row['last_updated']?.toString();
                final lastUpdated = lastUpdatedRaw == null
                    ? null
                    : DateTime.tryParse(lastUpdatedRaw)?.toLocal();
                final actual =
                    parseDecimalInput(actualController.text) ??
                    existingActual ??
                    theoretical;
                final variance = actual - theoretical;

                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surface1,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.surface2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row['ingredient_name']?.toString() ?? '-',
                        style: AppFonts.system(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        context.l10n.inventoryTheoreticalWithUnit(
                          theoretical.toStringAsFixed(3),
                          unit,
                        ),
                        style: AppFonts.system(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        existingActual == null
                            ? context.l10n.inventoryNoRecordedActualStock
                            : context.l10n.inventoryRecordedActualWithUnit(
                                existingActual.toStringAsFixed(3),
                                unit,
                              ),
                        style: AppFonts.system(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        storedVariance == null
                            ? context.l10n.inventoryNoRecordedVariance
                            : context.l10n.inventoryRecordedVarianceWithUnit(
                                storedVariance.toStringAsFixed(3),
                                unit,
                              ),
                        style: AppFonts.system(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        context.l10n.inventoryCountDate(countDateLabel),
                        style: AppFonts.system(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        lastUpdated == null
                            ? context.l10n.inventoryNoRecentApplication
                            : context.l10n.inventoryLastApplied(
                                DateFormat(
                                  'yyyy-MM-dd HH:mm',
                                ).format(lastUpdated),
                              ),
                        style: AppFonts.system(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: actualController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: context.l10n.inventoryActualWithUnit(unit),
                          hintText: existingActual?.toStringAsFixed(3),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: noteController,
                        decoration: InputDecoration(
                          labelText: context.l10n.inventoryMemoOptional,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        context.l10n.inventoryPendingVarianceWithUnit(
                          variance.toStringAsFixed(3),
                          unit,
                        ),
                        style: AppFonts.system(
                          color: variance.abs() < 0.001
                              ? AppColors.textSecondary
                              : AppColors.statusOccupied,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton(
                          onPressed: storeId == null
                              ? null
                              : () async {
                                  final parsed = parseDecimalInput(
                                    actualController.text,
                                  );
                                  if (parsed == null) {
                                    showErrorToast(
                                      context,
                                      context
                                          .l10n
                                          .inventoryEnterActualStockNumber,
                                    );
                                    return;
                                  }
                                  if (parsed < 0) {
                                    showErrorToast(
                                      context,
                                      context
                                          .l10n
                                          .inventoryActualStockNonNegative,
                                    );
                                    return;
                                  }
                                  await ref
                                      .read(physicalCountProvider.notifier)
                                      .submit(
                                        storeId: storeId,
                                        ingredientId: id,
                                        countDate: DateFormat(
                                          'yyyy-MM-dd',
                                        ).format(_countDate),
                                        actualQty: parsed,
                                        note: noteController.text.trim().isEmpty
                                            ? null
                                            : noteController.text.trim(),
                                      );
                                  if (!context.mounted) return;
                                  final latest = ref.read(
                                    physicalCountProvider,
                                  );
                                  if (latest.error != null) {
                                    showErrorToast(context, latest.error!);
                                    return;
                                  }
                                  showSuccessToast(
                                    context,
                                    context.l10n.inventoryActualStockApplied,
                                  );
                                  await ref
                                      .read(ingredientProvider.notifier)
                                      .load(storeId);
                                },
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.amber500,
                            foregroundColor: AppColors.surface0,
                          ),
                          child: Text(context.l10n.inventorySaveActualStock),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildReportTab(String? storeId) {
    final report = ref.watch(inventoryReportProvider);
    final purchaseOverview = ref.watch(inventoryPurchaseOverviewProvider);
    final recommendationRun = ref.watch(
      inventoryPurchaseRecommendationRunProvider,
    );
    final recommendationSnapshot = ref.watch(
      inventoryPurchaseRecommendationSnapshotProvider,
    );
    final orderCreation = ref.watch(inventoryPurchaseOrderCreationProvider);
    final orderSummary = ref.watch(inventoryPurchaseOrderSummaryProvider);
    final orderDetail = ref.watch(inventoryPurchaseOrderDetailProvider);
    final operatingSummary = ref.watch(
      inventoryPurchaseOperatingSummaryProvider,
    );
    final deduct = report.transactions
        .where((t) => t['transaction_type'] == 'deduct')
        .fold<double>(
          0,
          (s, t) => s + ((t['quantity_g'] as num?)?.toDouble() ?? 0).abs(),
        );
    final restock = report.transactions
        .where((t) => t['transaction_type'] == 'restock')
        .fold<double>(
          0,
          (s, t) => s + ((t['quantity_g'] as num?)?.toDouble() ?? 0),
        );
    final waste = report.transactions
        .where((t) => t['transaction_type'] == 'waste')
        .fold<double>(
          0,
          (s, t) => s + ((t['quantity_g'] as num?)?.toDouble() ?? 0).abs(),
        );
    final adjustLoss = report.transactions
        .where((t) => t['transaction_type'] == 'adjust')
        .fold<double>(0, (s, t) {
          final q = (t['quantity_g'] as num?)?.toDouble() ?? 0;
          return q < 0 ? s + q.abs() : s;
        });

    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          Text(
            context.l10n.inventorySurfaceReport,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              context.l10n.inventoryReportSubtitle,
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildInventoryPurchaseSecondaryDisclosure(
            context: context,
            storeId: storeId,
            operatingSummary: operatingSummary,
            overview: purchaseOverview,
            recommendationRun: recommendationRun,
            recommendationSnapshot: recommendationSnapshot,
            orderCreation: orderCreation,
            orderSummary: orderSummary,
            orderDetail: orderDetail,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _reportFrom,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) {
                    setState(() => _reportFrom = picked);
                  }
                },
                icon: const Icon(Icons.event),
                label: Text(DateFormat('yyyy-MM-dd').format(_reportFrom)),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _reportTo,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) {
                    setState(
                      () => _reportTo = DateTime(
                        picked.year,
                        picked.month,
                        picked.day,
                        23,
                        59,
                        59,
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.event),
                label: Text(DateFormat('yyyy-MM-dd').format(_reportTo)),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: storeId == null
                    ? null
                    : () => ref
                          .read(inventoryReportProvider.notifier)
                          .load(
                            storeId: storeId,
                            from: _reportFrom,
                            to: _reportTo,
                          ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                child: Text(context.l10n.apply),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _summaryCard(
                  context.l10n.inventoryTotalDeducted,
                  deduct,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _summaryCard(
                  context.l10n.inventoryTotalStockIn,
                  restock,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _summaryCard(context.l10n.inventoryTotalWaste, waste),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _summaryCard(
                  context.l10n.inventoryTotalAdjustmentLoss,
                  adjustLoss,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (report.isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: CircularProgressIndicator(color: AppColors.amber500),
              ),
            )
          else if (report.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  report.error!,
                  style: AppFonts.system(
                    color: AppColors.statusOccupied,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else if (report.transactions.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  context.l10n.inventoryNoTransactionsSelectedPeriod,
                  style: AppFonts.system(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: report.transactions.length,
              itemBuilder: (context, index) {
                final row = report.transactions[index];
                final qty = (row['quantity_g'] as num?)?.toDouble() ?? 0;
                final unit =
                    row['ingredient_unit']?.toString() ??
                    row['unit']?.toString() ??
                    'g';
                final note = row['note']?.toString();
                return ListTile(
                  title: Text(
                    row['ingredient_name']?.toString() ?? '-',
                    style: AppFonts.system(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_txTypeLabel(row['transaction_type']?.toString() ?? '')}  ${qty.toStringAsFixed(3)} $unit',
                        style: AppFonts.system(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      if (note != null && note.trim().isNotEmpty)
                        Text(
                          note,
                          style: AppFonts.system(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                  trailing: Text(
                    row['created_at']?.toString().substring(0, 16) ?? '-',
                    style: AppFonts.system(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildInventoryPurchaseSecondaryDisclosure({
    required BuildContext context,
    required String? storeId,
    required InventoryPurchaseOperatingSummary operatingSummary,
    required InventoryPurchaseOverviewState overview,
    required InventoryPurchaseRecommendationRunState recommendationRun,
    required InventoryPurchaseRecommendationSnapshotState
    recommendationSnapshot,
    required InventoryPurchaseOrderCreationState orderCreation,
    required InventoryPurchaseOrderSummaryState orderSummary,
    required InventoryPurchaseOrderDetailState orderDetail,
  }) {
    final l10n = context.l10n;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: ExpansionTile(
        key: const Key('inventory_purchase_secondary_detail'),
        initiallyExpanded: false,
        iconColor: AppColors.textSecondary,
        collapsedIconColor: AppColors.textSecondary,
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        title: Text(
          l10n.inventoryPurchaseOverviewTitle,
          style: AppFonts.system(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w800,
            fontSize: 14,
          ),
        ),
        subtitle: Text(
          l10n.inventoryPurchaseOverviewSubtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppFonts.system(
            color: AppColors.textSecondary,
            fontSize: 12,
          ),
        ),
        children: [
          _buildInventoryOperatingSummarySection(context, operatingSummary),
          const SizedBox(height: 12),
          _buildInventoryPurchaseOverview(
            context: context,
            storeId: storeId,
            overview: overview,
            recommendationRun: recommendationRun,
            recommendationSnapshot: recommendationSnapshot,
            orderCreation: orderCreation,
            orderSummary: orderSummary,
            orderDetail: orderDetail,
          ),
        ],
      ),
    );
  }

  Widget _buildInventoryPurchaseOverview({
    required BuildContext context,
    required String? storeId,
    required InventoryPurchaseOverviewState overview,
    required InventoryPurchaseRecommendationRunState recommendationRun,
    required InventoryPurchaseRecommendationSnapshotState
    recommendationSnapshot,
    required InventoryPurchaseOrderCreationState orderCreation,
    required InventoryPurchaseOrderSummaryState orderSummary,
    required InventoryPurchaseOrderDetailState orderDetail,
  }) {
    final l10n = context.l10n;
    final dashboard = overview.dashboard;
    final storeCount = (dashboard?['store_count'] as num?)?.toInt() ?? 0;
    final lowStockCount = (dashboard?['low_stock_count'] as num?)?.toInt() ?? 0;
    final totalInventoryAmount =
        (dashboard?['total_inventory_amount'] as num?)?.toDouble() ?? 0;
    final submittedPurchaseAmount =
        (dashboard?['submitted_purchase_amount'] as num?)?.toDouble() ?? 0;
    final approvedPurchaseAmount =
        (dashboard?['approved_purchase_amount'] as num?)?.toDouble() ?? 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.inventoryPurchaseOverviewTitle,
                      style: AppFonts.system(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.inventoryPurchaseOverviewSubtitle,
                      style: AppFonts.system(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed:
                    storeId == null ||
                        overview.isLoading ||
                        recommendationRun.isRunning
                    ? null
                    : () => ref
                          .read(inventoryPurchaseOverviewProvider.notifier)
                          .load(storeId),
                tooltip: l10n.inventoryPurchaseRefreshOverview,
                icon: overview.isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                color: AppColors.amber500,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed:
                      storeId == null ||
                          overview.isLoading ||
                          recommendationRun.isRunning
                      ? null
                      : () => _showRecommendationRunDialog(
                          context: context,
                          storeId: storeId,
                        ),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.amber500,
                    foregroundColor: AppColors.surface0,
                  ),
                  icon: recommendationRun.isRunning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_graph),
                  label: Text(
                    recommendationRun.isRunning
                        ? l10n.inventoryPurchaseGenerating
                        : l10n.inventoryPurchaseGenerateRecommendationSnapshot,
                  ),
                ),
              ),
            ],
          ),
          if (overview.error != null) ...[
            const SizedBox(height: 12),
            Text(
              overview.error!,
              style: AppFonts.system(
                color: AppColors.statusOccupied,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ] else if (dashboard == null) ...[
            const SizedBox(height: 12),
            Text(
              l10n.inventoryPurchaseOverviewAwaitingDashboard,
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _purchaseMetricCard(
                    l10n.inventoryPurchaseStoreScope,
                    l10n.inventoryPurchaseStoreCount(storeCount),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _purchaseMetricCard(
                    l10n.inventoryPurchaseLowStockAlerts,
                    l10n.inventoryPurchaseCountItems(lowStockCount),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _purchaseMetricCard(
                    l10n.inventoryPurchaseAssetAmount,
                    _formatCurrencyCompact(totalInventoryAmount),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _purchaseMetricCard(
                    l10n.inventoryPurchaseSubmittedAmount,
                    _formatCurrencyCompact(submittedPurchaseAmount),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _purchaseMetricCard(
                    l10n.inventoryPurchaseOfficeApprovedAmount,
                    _formatCurrencyCompact(approvedPurchaseAmount),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _purchaseMetricCard(
                    l10n.inventoryPurchaseSliceMode,
                    l10n.inventoryPurchaseSupportingContext,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildPurchaseOverviewDetail(
              context: context,
              lowStockCount: lowStockCount,
              submittedPurchaseAmount: submittedPurchaseAmount,
              approvedPurchaseAmount: approvedPurchaseAmount,
              recommendationRun: recommendationRun,
            ),
            const SizedBox(height: 12),
            _buildLatestRecommendationSnapshot(
              storeId: storeId,
              snapshot: recommendationSnapshot,
              orderCreation: orderCreation,
              orderSummary: orderSummary,
              orderDetail: orderDetail,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPurchaseOverviewDetail({
    required BuildContext context,
    required int lowStockCount,
    required double submittedPurchaseAmount,
    required double approvedPurchaseAmount,
    required InventoryPurchaseRecommendationRunState recommendationRun,
  }) {
    final l10n = context.l10n;
    final approvalGap = submittedPurchaseAmount - approvedPurchaseAmount;
    final normalizedGap = approvalGap > 0 ? approvalGap : 0.0;
    final reviewFocus = lowStockCount > 0
        ? l10n.inventoryPurchaseReviewLowStockFocus
        : l10n.inventoryPurchaseNoLowStockAlerts;
    final approvalStatus = normalizedGap > 0
        ? l10n.inventoryPurchaseApprovalGapStatus(
            _formatCurrencyCompact(normalizedGap),
          )
        : l10n.inventoryPurchaseApprovalAlignedStatus;
    final recommendationStatus = recommendationRun.lastRunId == null
        ? l10n.inventoryPurchaseNoRecommendationSnapshot
        : l10n.inventoryPurchaseLastSnapshotStatus(
            recommendationRun.lastRunId!.substring(0, 8),
            recommendationRun.lastTargetStockDays?.toStringAsFixed(0) ?? '-',
            recommendationRun.lastAsOfDate ?? '-',
          );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.inventoryPurchaseReviewDetailTitle,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 8),
          _purchaseDetailRow(l10n.inventoryPurchaseApprovalGap, approvalStatus),
          const SizedBox(height: 8),
          _purchaseDetailRow(l10n.inventoryPurchaseReviewFocus, reviewFocus),
          const SizedBox(height: 8),
          _purchaseDetailRow(
            l10n.inventoryPurchaseRecommendationStatus,
            recommendationStatus,
          ),
          const SizedBox(height: 8),
          _purchaseDetailRow(
            l10n.inventoryPurchaseBoundary,
            l10n.inventoryPurchaseBoundaryDetail,
          ),
        ],
      ),
    );
  }

  Widget _buildInventoryOperatingSummarySection(
    BuildContext context,
    InventoryPurchaseOperatingSummary summary,
  ) {
    final l10n = context.l10n;
    final reconciliation = summary.reconciliationSummary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.inventoryPurchaseRuntimeSummaryTitle,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.inventoryPurchaseRuntimeSummarySubtitle,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.inventoryPurchaseRuntimeSummaryHint,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          _buildInventoryActionQueueSection(context, summary.actionQueue),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.surface1,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.amber500),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.inventoryPurchaseNextOperatorAction,
                  style: AppFonts.system(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  summary.nextOperatorAction,
                  style: AppFonts.system(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.inventoryPurchaseSelectedRuntimeState,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildIngredientMetaChip(
                summary.selectedPurchaseOrderRuntimeLabel,
              ),
              _buildIngredientMetaChip(
                summary.handoffTarget,
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                summary.approvalHandoffReadinessLabel,
                color: _inventoryApprovalRuntimeStateColor(
                  summary.approvalHandoffReadinessLabel,
                ),
              ),
              _buildIngredientMetaChip(
                summary.receivingReadinessLabel,
                color: _inventoryReceivingRuntimeStateColor(
                  summary.receivingReadinessLabel,
                ),
              ),
              _buildIngredientMetaChip(
                summary.recommendationRuntimeStateLabel,
                color:
                    summary.recommendationRuntimeStateLabel.endsWith('blocked')
                    ? AppColors.statusOccupied
                    : summary.recommendationRuntimeStateLabel.endsWith('ready')
                    ? AppColors.statusAvailable
                    : AppColors.amber500,
              ),
              _buildIngredientMetaChip(summary.latestSnapshotStateLabel),
              _buildIngredientMetaChip(
                summary.purchaseOrderCreationReadinessLabel,
                color:
                    summary.purchaseOrderCreationReadinessLabel.contains(
                      'ready',
                    )
                    ? AppColors.statusAvailable
                    : summary.purchaseOrderCreationReadinessLabel.contains(
                        'blocked',
                      )
                    ? AppColors.statusOccupied
                    : AppColors.amber500,
              ),
              _buildIngredientMetaChip(
                l10n.inventoryPurchaseVisibleSnapshotLines(
                  summary.visibleRecommendationLineCount,
                ),
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                l10n.inventoryPurchaseVisiblePurchaseOrders(
                  summary.visiblePurchaseOrderCount,
                ),
              ),
              _buildIngredientMetaChip(
                l10n.inventoryPurchaseBlockedReasonsCount(
                  summary.visibleBlockedReasonCount,
                ),
                color: summary.visibleBlockedReasonCount > 0
                    ? AppColors.statusOccupied
                    : AppColors.statusAvailable,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            l10n.inventoryPurchaseOperatingBlockedReasons,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          if (summary.blockedReasons.isEmpty)
            Text(
              l10n.inventoryPurchaseNoOperatingBlockers,
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            )
          else
            Column(
              children: summary.blockedReasons
                  .map(
                    (reason) => _buildInventoryRuntimeBlockedReasonRow(reason),
                  )
                  .toList(),
            ),
          const SizedBox(height: 10),
          _buildInventorySupplierBottleneckSection(
            context,
            summary.supplierBottlenecks,
          ),
          const SizedBox(height: 10),
          _buildInventoryReconciliationSummarySection(context, reconciliation),
          const SizedBox(height: 10),
          Text(
            summary.operatingNarrative,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInventoryReconciliationSummarySection(
    BuildContext context,
    InventoryPurchaseReconciliationSummary summary,
  ) {
    final l10n = context.l10n;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _inventoryOperationalToneColor(summary.mismatchIndicatorTone),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.inventoryPurchaseReconciliationSummaryTitle,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.inventoryPurchaseReconciliationSummarySubtitle,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildIngredientMetaChip(
                l10n.inventoryPurchaseRecommendedCount(
                  summary.recommendedCount,
                ),
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                l10n.inventoryPurchaseOrderedCount(summary.orderedCount),
              ),
              _buildIngredientMetaChip(
                l10n.inventoryPurchaseReceivedCount(summary.receivedCount),
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                l10n.inventoryPurchaseRemainingCount(summary.remainingCount),
                color: summary.remainingCount > 0
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                l10n.inventoryPurchaseDelayedCount(summary.delayedCount),
                color: summary.delayedCount > 0
                    ? AppColors.statusOccupied
                    : AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                summary.mismatchIndicatorLabel,
                color: _inventoryOperationalToneColor(
                  summary.mismatchIndicatorTone,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            summary.narrative,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInventoryActionQueueSection(
    BuildContext context,
    List<InventoryPurchaseActionQueueEntry> actionQueue,
  ) {
    final l10n = context.l10n;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.inventoryPurchaseActionQueueTitle,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.inventoryPurchaseActionQueueSubtitle,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          if (actionQueue.isEmpty)
            Text(
              l10n.inventoryPurchaseActionQueueEmpty,
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            )
          else
            Column(
              children: actionQueue
                  .map(
                    (queueItem) =>
                        _buildInventoryActionQueueRow(context, queueItem),
                  )
                  .toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildInventoryActionQueueRow(
    BuildContext context,
    InventoryPurchaseActionQueueEntry queueItem,
  ) {
    final l10n = context.l10n;
    final severityColor = _inventoryReceivingBlockerSeverityColor(
      queueItem.blockerSeverity,
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: queueItem.isSelected ? AppColors.surface0 : AppColors.surface1,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: queueItem.isSelected ? AppColors.amber500 : severityColor,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${queueItem.purchaseOrderNo} · ${queueItem.supplierLabel}',
                      style: AppFonts.system(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      queueItem.operatorReason,
                      style: AppFonts.system(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              _buildIngredientMetaChip(
                queueItem.priorityBucket,
                color: severityColor,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildIngredientMetaChip(queueItem.staleLabel),
              _buildIngredientMetaChip(
                queueItem.handoffTarget,
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                queueItem.blockerSeverity.toUpperCase(),
                color: severityColor,
              ),
              if (queueItem.isSelected)
                _buildIngredientMetaChip(
                  l10n.inventoryPurchaseSelectedPo,
                  color: AppColors.amber500,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.inventoryPurchaseNextAction(queueItem.nextAction),
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInventorySupplierBottleneckSection(
    BuildContext context,
    List<InventoryPurchaseSupplierBottleneckState> bottlenecks,
  ) {
    final l10n = context.l10n;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.inventoryPurchaseSupplierBottleneckTitle,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.inventoryPurchaseSupplierBottleneckSubtitle,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Column(
            children: bottlenecks
                .map(
                  (bottleneck) =>
                      _buildInventorySupplierBottleneckRow(context, bottleneck),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildInventorySupplierBottleneckRow(
    BuildContext context,
    InventoryPurchaseSupplierBottleneckState bottleneck,
  ) {
    final l10n = context.l10n;
    final severityColor = _inventoryReceivingBlockerSeverityColor(
      bottleneck.severity,
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: severityColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bottleneck.supplierLabel,
                      style: AppFonts.system(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      bottleneck.narrative,
                      style: AppFonts.system(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              _buildIngredientMetaChip(
                bottleneck.severity.toUpperCase(),
                color: severityColor,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildIngredientMetaChip(
                l10n.inventoryPurchaseAffectedPoCount(
                  bottleneck.affectedPoCount,
                ),
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(bottleneck.blockedReasonCluster),
              _buildIngredientMetaChip(
                l10n.inventoryPurchaseOldestWait(bottleneck.oldestWaitingAge),
                color: AppColors.amber500,
              ),
              _buildIngredientMetaChip(
                bottleneck.nextFollowUpTarget,
                color: severityColor,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLatestRecommendationSnapshot({
    required String? storeId,
    required InventoryPurchaseRecommendationSnapshotState snapshot,
    required InventoryPurchaseOrderCreationState orderCreation,
    required InventoryPurchaseOrderSummaryState orderSummary,
    required InventoryPurchaseOrderDetailState orderDetail,
  }) {
    final approvalRuntime = ref.watch(inventoryPurchaseApprovalRuntimeProvider);
    final receivingRuntime = ref.watch(
      inventoryPurchaseReceivingRuntimeProvider,
    );
    final runtimeSurface = ref.watch(inventoryPurchaseRuntimeSurfaceProvider);
    final operatingSummary = ref.watch(
      inventoryPurchaseOperatingSummaryProvider,
    );
    final run = snapshot.run;
    final lineCount = snapshot.lines.length;
    final runDate = run?['run_date']?.toString() ?? '-';
    final targetDays = (run?['target_stock_days'] as num?)?.toDouble();
    final createdAtRaw = run?['created_at']?.toString();
    final createdAt = createdAtRaw == null
        ? null
        : DateTime.tryParse(createdAtRaw)?.toLocal();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Latest Recommendation Snapshot',
                      style: AppFonts.system(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Read the most recent recommendation run before deciding whether the next tracked slice should create purchase orders.',
                      style: AppFonts.system(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed:
                    storeId == null ||
                        snapshot.isLoading ||
                        orderSummary.isLoading
                    ? null
                    : () async {
                        await ref
                            .read(
                              inventoryPurchaseRecommendationSnapshotProvider
                                  .notifier,
                            )
                            .loadLatest(storeId);
                        await _loadPurchaseOrderSummaryAndDetail(storeId);
                      },
                tooltip: 'Refresh Recommendation Snapshot',
                icon: snapshot.isLoading || orderSummary.isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                color: AppColors.amber500,
              ),
            ],
          ),
          if (snapshot.error != null) ...[
            const SizedBox(height: 12),
            Text(
              snapshot.error!,
              style: AppFonts.system(
                color: AppColors.statusOccupied,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ] else if (run == null) ...[
            const SizedBox(height: 12),
            Text(
              'No recommendation snapshot detail has been generated for this store yet.',
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        storeId == null ||
                            snapshot.isLoading ||
                            orderCreation.isCreating
                        ? null
                        : () => _showCreatePurchaseOrdersDialog(
                            context: context,
                            storeId: storeId,
                            snapshotRun: run,
                          ),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.amber500,
                      foregroundColor: AppColors.surface0,
                    ),
                    icon: orderCreation.isCreating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.shopping_cart_checkout),
                    label: Text(
                      orderCreation.isCreating
                          ? 'Creating Purchase Orders...'
                          : 'Create Purchase Orders',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildIngredientMetaChip('Run Date $runDate'),
                _buildIngredientMetaChip(
                  'Target ${targetDays?.toStringAsFixed(0) ?? '-'} day(s)',
                  color: AppColors.amber500,
                ),
                _buildIngredientMetaChip(
                  'Visible Lines $lineCount',
                  color: AppColors.statusAvailable,
                ),
                _buildIngredientMetaChip(
                  createdAt == null
                      ? 'Created time unavailable'
                      : 'Created ${DateFormat('yyyy-MM-dd HH:mm').format(createdAt)}',
                ),
              ],
            ),
            if (orderCreation.sourceRunId == run['id']?.toString()) ...[
              const SizedBox(height: 12),
              _buildPurchaseOrderCreationSummary(orderCreation.createdOrders),
            ],
            const SizedBox(height: 12),
            _buildRecentPurchaseOrdersSection(
              storeId: storeId,
              summary: orderSummary,
              operatingSummary: operatingSummary,
              detail: orderDetail,
              runtimeSurface: runtimeSurface,
              approvalRuntime: approvalRuntime,
              receivingRuntime: receivingRuntime,
            ),
            const SizedBox(height: 12),
            if (snapshot.lines.isEmpty)
              Text(
                'This snapshot exists, but no recommendation lines are currently visible in the tracked POS scope.',
                style: AppFonts.system(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              )
            else
              Column(
                children: snapshot.lines
                    .map((line) => _buildRecommendationLineCard(line))
                    .toList(),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildPurchaseOrderCreationSummary(List<Map<String, dynamic>> orders) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Latest Purchase Order Creation',
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            orders.isEmpty
                ? 'The latest snapshot did not produce any supplier-qualified purchase orders.'
                : '${orders.length} submitted purchase order(s) were created from the latest recommendation snapshot.',
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          if (orders.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: orders.map((order) {
                final orderNo = order['purchase_order_no']?.toString() ?? '-';
                final status = order['status']?.toString() ?? 'submitted';
                return _buildIngredientMetaChip(
                  '$orderNo · ${status.toUpperCase()}',
                  color: AppColors.amber500,
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRecentPurchaseOrdersSection({
    required String? storeId,
    required InventoryPurchaseOrderSummaryState summary,
    required InventoryPurchaseOperatingSummary operatingSummary,
    required InventoryPurchaseOrderDetailState detail,
    required InventoryPurchaseRuntimeSurfaceState runtimeSurface,
    required InventoryPurchaseApprovalRuntimeState approvalRuntime,
    required InventoryPurchaseReceivingRuntimeState receivingRuntime,
  }) {
    final queueEntriesByOrderId = {
      for (final queueItem in operatingSummary.actionQueue)
        queueItem.orderId: queueItem,
    };
    final queueOrderedIds = operatingSummary.actionQueue
        .map((queueItem) => queueItem.orderId)
        .toList();
    final ordersById = {
      for (final order in summary.orders) order['id']?.toString() ?? '': order,
    };
    final orderedCards = <Map<String, dynamic>>[
      for (final orderId in queueOrderedIds)
        if (ordersById.containsKey(orderId)) ordersById[orderId]!,
      ...summary.orders.where(
        (order) => !queueOrderedIds.contains(order['id']?.toString() ?? ''),
      ),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Recent Purchase Orders',
                      style: AppFonts.system(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Read the latest POS-created purchase orders, then use only the runtime actions that backend truth currently supports.',
                      style: AppFonts.system(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: storeId == null || summary.isLoading
                    ? null
                    : () => _loadPurchaseOrderSummaryAndDetail(storeId),
                tooltip: 'Refresh Purchase Orders',
                icon: summary.isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                color: AppColors.amber500,
              ),
            ],
          ),
          if (summary.error != null) ...[
            const SizedBox(height: 12),
            Text(
              summary.error!,
              style: AppFonts.system(
                color: AppColors.statusOccupied,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ] else if (summary.orders.isEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'No recent purchase orders are visible for this store yet.',
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Column(
              children: orderedCards
                  .map(
                    (order) => _buildRecentPurchaseOrderCard(
                      storeId: storeId,
                      order: order,
                      queueEntry:
                          queueEntriesByOrderId[order['id']?.toString() ?? ''],
                      isSelected:
                          order['id']?.toString() == detail.selectedOrderId,
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 12),
            _buildPurchaseOrderDetailSection(
              storeId: storeId,
              detail: detail,
              runtimeSurface: runtimeSurface,
              hasOrders: summary.orders.isNotEmpty,
              approvalRuntime: approvalRuntime,
              receivingRuntime: receivingRuntime,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRecentPurchaseOrderCard({
    required String? storeId,
    required Map<String, dynamic> order,
    required InventoryPurchaseActionQueueEntry? queueEntry,
    required bool isSelected,
  }) {
    final supplierMap = order['supplier'] as Map<String, dynamic>?;
    final supplierName = supplierMap?['name']?.toString();
    final orderNo = order['purchase_order_no']?.toString() ?? '-';
    final status = order['status']?.toString() ?? 'submitted';
    final requestedDate = order['requested_delivery_date']?.toString();
    final totalAmount = (order['total_amount'] as num?)?.toDouble() ?? 0;
    final lineCount = (order['line_count'] as num?)?.toInt() ?? 0;
    final createdAtRaw = order['created_at']?.toString();
    final createdAt = createdAtRaw == null
        ? null
        : DateTime.tryParse(createdAtRaw)?.toLocal();

    return InkWell(
      onTap: storeId == null || order['id'] == null
          ? null
          : () => _selectPurchaseOrder(orderId: order['id'].toString()),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface0,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppColors.amber500 : AppColors.surface2,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        orderNo,
                        style: AppFonts.system(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        supplierName == null || supplierName.isEmpty
                            ? 'Supplier unavailable'
                            : 'Supplier $supplierName',
                        style: AppFonts.system(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                _buildIngredientMetaChip(
                  status.toUpperCase(),
                  color: AppColors.amber500,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildIngredientMetaChip(
                  'Lines $lineCount',
                  color: AppColors.statusAvailable,
                ),
                _buildIngredientMetaChip(
                  'Total ${_formatCurrencyCompact(totalAmount)}',
                  color: AppColors.amber500,
                ),
                _buildIngredientMetaChip(
                  requestedDate == null || requestedDate.isEmpty
                      ? 'Requested date not set'
                      : 'Requested $requestedDate',
                ),
                _buildIngredientMetaChip(
                  createdAt == null
                      ? 'Created time unavailable'
                      : 'Created ${DateFormat('yyyy-MM-dd HH:mm').format(createdAt)}',
                ),
                if (queueEntry != null)
                  _buildIngredientMetaChip(
                    queueEntry.priorityBucket,
                    color: _inventoryReceivingBlockerSeverityColor(
                      queueEntry.blockerSeverity,
                    ),
                  ),
                if (queueEntry != null)
                  _buildIngredientMetaChip(queueEntry.staleLabel),
              ],
            ),
            if (queueEntry != null) ...[
              const SizedBox(height: 8),
              Text(
                'Queue next action: ${queueEntry.nextAction}',
                style: AppFonts.system(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPurchaseOrderDetailSection({
    required String? storeId,
    required InventoryPurchaseOrderDetailState detail,
    required InventoryPurchaseRuntimeSurfaceState runtimeSurface,
    required bool hasOrders,
    required InventoryPurchaseApprovalRuntimeState approvalRuntime,
    required InventoryPurchaseReceivingRuntimeState receivingRuntime,
  }) {
    final order = detail.order;
    final receipts = detail.receipts;
    final selectedOrderId = detail.selectedOrderId;
    final supplierMap = order?['supplier'] as Map<String, dynamic>?;
    final supplierName = supplierMap?['name']?.toString();
    final memo = order?['memo']?.toString();
    final status = runtimeSurface.orderStatus;
    final requestedDate = runtimeSurface.requestedDate;
    final totalAmount = (order?['total_amount'] as num?)?.toDouble() ?? 0;
    final supplyAmount =
        (order?['total_supply_amount'] as num?)?.toDouble() ?? 0;
    final taxAmount = (order?['tax_amount'] as num?)?.toDouble() ?? 0;
    final totalRemainingBase = runtimeSurface.remainingBase;
    final latestReceiptStatus = order?['latest_receipt_status']?.toString();
    final sortedLines = _sortedPurchaseOrderLinesForAttention(
      detail.lines,
      requestedDate: requestedDate,
      orderStatus: status,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Purchase Order Detail',
                      style: AppFonts.system(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Inspect the selected order line-by-line, keep approval inside the Office-owned boundary, and open receiving only when backend truth supports it.',
                      style: AppFonts.system(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: selectedOrderId == null || detail.isLoading
                    ? null
                    : () => ref
                          .read(inventoryPurchaseOrderDetailProvider.notifier)
                          .load(selectedOrderId),
                tooltip: 'Refresh Selected Order',
                icon: detail.isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                color: AppColors.amber500,
              ),
            ],
          ),
          if (detail.error != null) ...[
            const SizedBox(height: 12),
            Text(
              detail.error!,
              style: AppFonts.system(
                color: AppColors.statusOccupied,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ] else if (!hasOrders) ...[
            const SizedBox(height: 12),
            Text(
              'Select a purchase order to inspect line-level detail once orders exist in the tracked POS scope.',
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ] else if (order == null) ...[
            const SizedBox(height: 12),
            Text(
              'Select a recent purchase order card above to inspect line-level detail.',
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildIngredientMetaChip(
                  order['purchase_order_no']?.toString() ?? '-',
                  color: AppColors.amber500,
                ),
                _buildIngredientMetaChip(
                  status.toUpperCase(),
                  color: AppColors.statusAvailable,
                ),
                _buildIngredientMetaChip(
                  supplierName == null || supplierName.isEmpty
                      ? 'Supplier unavailable'
                      : 'Supplier $supplierName',
                ),
                _buildIngredientMetaChip(
                  requestedDate == null || requestedDate.isEmpty
                      ? 'Requested date not set'
                      : 'Requested $requestedDate',
                ),
                _buildIngredientMetaChip(
                  'Supply ${_formatCurrencyCompact(supplyAmount)}',
                ),
                _buildIngredientMetaChip(
                  'Tax ${_formatCurrencyCompact(taxAmount)}',
                ),
                _buildIngredientMetaChip(
                  'Total ${_formatCurrencyCompact(totalAmount)}',
                  color: AppColors.amber500,
                ),
              ],
            ),
            if (memo != null && memo.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Order memo: $memo',
                style: AppFonts.system(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 12),
            _buildInventoryOrderAttentionBanner(
              status: status,
              requestedDate: requestedDate,
              remainingBase: totalRemainingBase,
              latestReceiptStatus: latestReceiptStatus,
              lineItems: sortedLines,
            ),
            const SizedBox(height: 12),
            _buildSupplierAttentionOrderingSection(
              lineItems: sortedLines,
              requestedDate: requestedDate,
              orderStatus: status,
            ),
            const SizedBox(height: 12),
            _buildReceivingReadinessSummarySection(
              runtimeSurface: runtimeSurface,
            ),
            const SizedBox(height: 12),
            _buildReceivingBlockersDetailSection(
              blockerRows: runtimeSurface.blockerRows,
            ),
            const SizedBox(height: 12),
            _buildInventoryMutationReadinessPhaseSection(
              runtimeSurface: runtimeSurface,
            ),
            const SizedBox(height: 12),
            _buildInventoryRuntimePathSection(
              storeId: storeId,
              runtimeSurface: runtimeSurface,
              approvalRuntime: approvalRuntime,
              receivingRuntime: receivingRuntime,
            ),
            const SizedBox(height: 12),
            _buildInventoryReceivingSafetySection(
              runtimeSurface.receivingSafety,
            ),
            const SizedBox(height: 12),
            _buildReceiptVisibilitySection(runtimeSurface: runtimeSurface),
            const SizedBox(height: 12),
            _buildRecentReceiptsTimeline(receipts),
            const SizedBox(height: 12),
            _buildReceiptLineProvenanceSection(receipts),
            const SizedBox(height: 12),
            _buildSupplierContextHistorySection(detail.lines),
            const SizedBox(height: 12),
            if (sortedLines.isEmpty)
              Text(
                'No line items are visible for the selected order.',
                style: AppFonts.system(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              )
            else
              Column(
                children: sortedLines
                    .asMap()
                    .entries
                    .map(
                      (entry) => _buildPurchaseOrderLineCard(
                        entry.value,
                        requestedDate: requestedDate,
                        orderStatus: status,
                        attentionRank: entry.key + 1,
                      ),
                    )
                    .toList(),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildReceivingReadinessSummarySection({
    required InventoryPurchaseRuntimeSurfaceState runtimeSurface,
  }) {
    final receivedLineCount = runtimeSurface.receivedLineCount;
    final pendingLineCount = runtimeSurface.pendingLineCount;
    final attentionLineCount = runtimeSurface.attentionLineCount;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _inventoryOperationalToneColor(
            runtimeSurface.receivingReadinessTone,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Receiving Readiness Summary',
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Review inbound receiving posture before opening receipt history or line provenance detail.',
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildIngredientMetaChip(
                'Receiving readiness ${runtimeSurface.receivingReadinessLabel}',
                color: _inventoryOperationalToneColor(
                  runtimeSurface.receivingReadinessTone,
                ),
              ),
              _buildIngredientMetaChip(
                runtimeSurface.receivedLineSummaryLabel,
                color: receivedLineCount > 0
                    ? AppColors.statusAvailable
                    : AppColors.surface2,
              ),
              _buildIngredientMetaChip(
                runtimeSurface.remainingLineSummaryLabel,
                color: pendingLineCount > 0
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Attention lines $attentionLineCount',
                color: attentionLineCount > 0
                    ? AppColors.statusOccupied
                    : AppColors.statusAvailable,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            runtimeSurface.receivingReadinessNarrative,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReceivingBlockersDetailSection({
    required List<Map<String, dynamic>> blockerRows,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Receiving Blockers Detail',
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Read the current receiving blockers without opening receipt confirmation, supplier approval, or stock mutation workflows.',
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Column(
            children: blockerRows
                .map((row) => _buildReceivingBlockerRow(row))
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildReceivingBlockerRow(Map<String, dynamic> row) {
    final severity = row['severity']?.toString() ?? 'healthy';
    final title = row['title']?.toString() ?? 'Receiving blocker';
    final narrative = row['narrative']?.toString() ?? '';
    final nextHint = row['next_hint']?.toString() ?? '';
    final affectedPurchaseOrders = row['affected_po_count']?.toString() ?? '0';
    final impactedSuppliers = row['impacted_supplier_count']?.toString() ?? '0';
    final oldestWaitingAge = row['oldest_waiting_age']?.toString() ?? '0d';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _inventoryReceivingBlockerSeverityColor(severity),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppFonts.system(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      narrative,
                      style: AppFonts.system(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              _buildIngredientMetaChip(
                severity.toUpperCase(),
                color: _inventoryReceivingBlockerSeverityColor(severity),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildIngredientMetaChip(
                context.l10n.inventoryPurchaseAffectedPoCount(
                  int.tryParse(affectedPurchaseOrders) ?? 0,
                ),
              ),
              _buildIngredientMetaChip(
                context.l10n.inventoryPurchaseImpactedSuppliers(
                  int.tryParse(impactedSuppliers) ?? 0,
                ),
                color: AppColors.amber500,
              ),
              _buildIngredientMetaChip(
                context.l10n.inventoryPurchaseOldestWait(oldestWaitingAge),
              ),
              _buildIngredientMetaChip(
                context.l10n.inventoryPurchaseNextHint(nextHint),
                color: AppColors.statusAvailable,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInventoryMutationReadinessPhaseSection({
    required InventoryPurchaseRuntimeSurfaceState runtimeSurface,
  }) {
    final blockerRows = runtimeSurface.blockerRows;
    final receivedLineCount = runtimeSurface.receivedLineCount;
    final pendingLineCount = runtimeSurface.pendingLineCount;
    final attentionLineCount = runtimeSurface.attentionLineCount;
    final approvalHandoffLabel =
        runtimeSurface.runtimeClosure.approvalStateLabel;
    final approvalHandoffColor = _inventoryOperationalToneColor(
      runtimeSurface.approvalStateTone,
    );
    final latestReceiptLabel = runtimeSurface.latestReceiptStatus == null
        ? 'Latest receipt unavailable'
        : 'Latest receipt ${runtimeSurface.receiptVisibilityStatusLabel}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Inventory Mutation Readiness Phase',
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Use these guardrails to confirm POS remains responsible for visibility, readiness, and operator checklist coverage before any Office-owned approval, receipt confirmation, or stock mutation workflow is considered.',
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          _buildInventoryMutationReadinessCard(
            title: 'Approval Handoff',
            borderColor: approvalHandoffColor,
            chips: [
              _buildIngredientMetaChip(
                approvalHandoffLabel,
                color: approvalHandoffColor,
              ),
              _buildIngredientMetaChip(
                'Execution owner Office',
                color: AppColors.statusOccupied,
              ),
              _buildIngredientMetaChip(
                'POS role Visibility and checklist only',
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                runtimeSurface.readyStateLabel,
                color: _inventoryOperationalToneColor(
                  runtimeSurface.readyStateTone,
                ),
              ),
              _buildIngredientMetaChip(
                'Open blockers ${blockerRows.length}',
                color: blockerRows.isNotEmpty
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
            ],
            narrative: runtimeSurface.approvalNarrative,
          ),
          const SizedBox(height: 8),
          _buildInventoryMutationReadinessCard(
            title: 'Receiving Confirmation Readiness',
            borderColor: _inventoryOperationalToneColor(
              runtimeSurface.receivingReadinessTone,
            ),
            chips: [
              _buildIngredientMetaChip(
                'Readiness ${runtimeSurface.receivingReadinessLabel}',
                color: _inventoryOperationalToneColor(
                  runtimeSurface.receivingReadinessTone,
                ),
              ),
              _buildIngredientMetaChip(
                runtimeSurface.receivedLineSummaryLabel,
                color: receivedLineCount > 0
                    ? AppColors.statusAvailable
                    : AppColors.surface2,
              ),
              _buildIngredientMetaChip(
                runtimeSurface.remainingLineSummaryLabel,
                color: pendingLineCount > 0
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Attention lines $attentionLineCount',
                color: attentionLineCount > 0
                    ? AppColors.statusOccupied
                    : AppColors.statusAvailable,
              ),
            ],
            narrative: runtimeSurface.receivingReadinessNarrative,
          ),
          const SizedBox(height: 8),
          _buildInventoryMutationReadinessCard(
            title: 'Stock Mutation Guardrail',
            borderColor: AppColors.surface2,
            chips: [
              _buildIngredientMetaChip(
                runtimeSurface.blockedStateLabel,
                color: _inventoryOperationalToneColor(
                  runtimeSurface.blockedStateTone,
                ),
              ),
              _buildIngredientMetaChip(
                runtimeSurface.staleStateLabel,
                color: _inventoryOperationalToneColor(
                  runtimeSurface.staleStateTone,
                ),
              ),
              _buildIngredientMetaChip(
                'Confirmed receipts ${runtimeSurface.confirmedReceiptCount}',
                color: runtimeSurface.confirmedReceiptCount > 0
                    ? AppColors.statusAvailable
                    : AppColors.surface2,
              ),
              _buildIngredientMetaChip(latestReceiptLabel),
              _buildIngredientMetaChip(
                'Domain boundary Payment / order / menu untouched',
                color: AppColors.statusAvailable,
              ),
            ],
            narrative:
                '${runtimeSurface.operationalPhaseNarrative} Tracked inbound quantities stay operator-facing signals only. This phase does not mutate stock, does not connect payment, order, or menu mutation flows, and does not transfer Office-owned execution into POS.',
          ),
        ],
      ),
    );
  }

  Widget _buildInventoryMutationReadinessCard({
    required String title,
    required Color borderColor,
    required List<Widget> chips,
    required String narrative,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: chips),
          const SizedBox(height: 8),
          Text(
            narrative,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _runInventoryApprovalHandoffCheck(
    BuildContext context, {
    required Map<String, dynamic>? order,
  }) async {
    await ref
        .read(inventoryPurchaseApprovalRuntimeProvider.notifier)
        .evaluate(order);
    if (!context.mounted) return;

    final result = ref.read(inventoryPurchaseApprovalRuntimeProvider).result;
    if (result == null) return;

    if (result.kind == InventoryPurchaseRuntimeResultKind.success) {
      showSuccessToast(context, result.message);
      return;
    }

    showErrorToast(context, result.message);
  }

  Future<void> _showConfirmInventoryPurchaseReceiptDialog(
    BuildContext context, {
    required String storeId,
    required Map<String, dynamic>? order,
  }) async {
    if (order == null) {
      await ref
          .read(inventoryPurchaseReceivingRuntimeProvider.notifier)
          .confirmRemainingReceipt(order: order);
      if (!context.mounted) return;
      final result = ref.read(inventoryPurchaseReceivingRuntimeProvider).result;
      if (result != null) {
        showErrorToast(context, result.message);
      }
      return;
    }

    final noteController = TextEditingController();
    final purchaseOrderNo = order['purchase_order_no']?.toString() ?? '-';
    final confirmed = await ToastConfirmDialog.withContent(
      context: context,
      title:
          '$purchaseOrderNo — ${context.l10n.inventoryPurchaseConfirmRemainingReceipt}',
      confirmLabel: context.l10n.inventoryPurchaseConfirmRemainingReceipt,
      confirmTone: PosActionTone.affirm,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.inventoryPurchaseConfirmRemainingReceiptHelp,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: noteController,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: InputDecoration(
              labelText: context.l10n.memoOptional,
              labelStyle: const TextStyle(color: AppColors.textSecondary),
              enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.surface2),
              ),
              focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.amber500),
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      noteController.dispose();
      ref
          .read(inventoryPurchaseReceivingRuntimeProvider.notifier)
          .markCancelled();
      return;
    }

    final success = await ref
        .read(inventoryPurchaseReceivingRuntimeProvider.notifier)
        .confirmRemainingReceipt(
          order: order,
          memo: noteController.text.trim().isEmpty
              ? null
              : noteController.text.trim(),
        );

    if (!context.mounted) {
      noteController.dispose();
      return;
    }

    final result = ref.read(inventoryPurchaseReceivingRuntimeProvider).result;
    if (!success) {
      noteController.dispose();
      if (result != null) {
        showErrorToast(context, result.message);
      }
      return;
    }

    await ref.read(inventoryPurchaseOverviewProvider.notifier).load(storeId);
    await _loadPurchaseOrderSummaryAndDetail(
      storeId,
      preferredOrderId: order['id']?.toString(),
      clearRuntimeStates: false,
    );
    if (!context.mounted) {
      noteController.dispose();
      return;
    }

    if (result != null) {
      showSuccessToast(context, result.message);
    }
    noteController.dispose();
  }

  Widget _buildInventoryRuntimePathSection({
    required String? storeId,
    required InventoryPurchaseRuntimeSurfaceState runtimeSurface,
    required InventoryPurchaseApprovalRuntimeState approvalRuntime,
    required InventoryPurchaseReceivingRuntimeState receivingRuntime,
  }) {
    final order = runtimeSurface.order;
    final runtimeClosure = runtimeSurface.runtimeClosure;
    final blockedLineCount = runtimeSurface.blockedLineCount;
    final canConfirmReceipt =
        storeId != null && runtimeClosure.canConfirmReceipt;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Inventory Runtime Path',
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Open only the action states that the current POS runtime can support truthfully. Approval remains Office-owned, while receiving is enabled only when the backend receipt contract can safely update stock.',
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          _buildInventoryRuntimeClosureSection(runtimeSurface: runtimeSurface),
          const SizedBox(height: 8),
          _buildInventoryRuntimePathCard(
            title: 'Approval Runtime Path',
            statusLabel: runtimeClosure.approvalStateLabel,
            statusColor: _inventoryOperationalToneColor(
              runtimeSurface.approvalStateTone,
            ),
            narrative: runtimeSurface.approvalNarrative,
            metrics: [
              _buildIngredientMetaChip(
                'Blocked lines $blockedLineCount',
                color: blockedLineCount > 0
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Office-owned execution',
                color: AppColors.statusOccupied,
              ),
            ],
            action: FilledButton.tonalIcon(
              onPressed: runtimeClosure.canCheckApproval
                  ? () =>
                        _runInventoryApprovalHandoffCheck(context, order: order)
                  : null,
              icon: approvalRuntime.isEvaluating
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.rule_folder_outlined),
              label: const Text('Check Approval Handoff'),
            ),
            result: approvalRuntime.result,
          ),
          const SizedBox(height: 8),
          _buildInventoryRuntimePathCard(
            title: 'Receiving Runtime Path',
            statusLabel: runtimeClosure.receivingStateLabel,
            statusColor: _inventoryOperationalToneColor(
              runtimeSurface.receivingStateTone,
            ),
            narrative: runtimeSurface.receivingNarrative,
            metrics: [
              _buildIngredientMetaChip(
                'Confirmed receipts ${runtimeSurface.confirmedReceiptCount}',
                color: runtimeSurface.confirmedReceiptCount > 0
                    ? AppColors.statusAvailable
                    : AppColors.surface2,
              ),
              _buildIngredientMetaChip(
                'Remaining base ${runtimeSurface.remainingBase.toStringAsFixed(3)}',
                color: runtimeSurface.remainingBase > 0
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
            ],
            action: FilledButton.icon(
              onPressed: canConfirmReceipt && runtimeClosure.canConfirmReceipt
                  ? () => _showConfirmInventoryPurchaseReceiptDialog(
                      context,
                      storeId: storeId,
                      order: order,
                    )
                  : null,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
                disabledBackgroundColor: AppColors.surface2,
                disabledForegroundColor: AppColors.textSecondary,
              ),
              icon: receivingRuntime.isSubmitting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.inventory_2_outlined),
              label: Text(
                receivingRuntime.isSubmitting
                    ? context.l10n.inventoryPurchaseConfirmingReceipt
                    : context.l10n.inventoryPurchaseConfirmRemainingReceipt,
              ),
            ),
            result: receivingRuntime.result,
          ),
        ],
      ),
    );
  }

  Widget _buildInventoryReceivingSafetySection(
    InventoryPurchaseReceivingSafetyState receivingSafety,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _inventoryOperationalToneColor(receivingSafety.tone),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Receiving Execution Safety Layer',
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Reduce duplicate receiving fear by showing the last runtime result, retry discipline, unknown outcome handling, and the next safe recovery step from provider truth.',
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildIngredientMetaChip(
                receivingSafety.lastAttemptLabel,
                color: _inventoryOperationalToneColor(receivingSafety.tone),
              ),
              _buildIngredientMetaChip(receivingSafety.retryDisciplineLabel),
              _buildIngredientMetaChip(
                receivingSafety.unknownOutcomeLabel,
                color: AppColors.amber500,
              ),
              _buildIngredientMetaChip(
                receivingSafety.followUpGuidanceLabel,
                color: AppColors.statusAvailable,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            receivingSafety.narrative,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInventoryRuntimeClosureSection({
    required InventoryPurchaseRuntimeSurfaceState runtimeSurface,
  }) {
    final runtimeClosure = runtimeSurface.runtimeClosure;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Inventory Runtime Closure',
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Keep the remaining purchase-order runtime understandable in one operational pass: approval handoff, receiving readiness, blockers, handoff target, and the last known runtime state all stay visible without leaving the POS inventory surface.',
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildIngredientMetaChip(
                runtimeSurface.operationalPhaseLabel,
                color: _inventoryOperationalToneColor(
                  runtimeSurface.operationalPhaseTone,
                ),
              ),
              _buildIngredientMetaChip(
                runtimeSurface.readyStateLabel,
                color: _inventoryOperationalToneColor(
                  runtimeSurface.readyStateTone,
                ),
              ),
              _buildIngredientMetaChip(
                runtimeSurface.blockedStateLabel,
                color: _inventoryOperationalToneColor(
                  runtimeSurface.blockedStateTone,
                ),
              ),
              _buildIngredientMetaChip(
                runtimeSurface.staleStateLabel,
                color: _inventoryOperationalToneColor(
                  runtimeSurface.staleStateTone,
                ),
              ),
              _buildIngredientMetaChip(
                runtimeClosure.lastRuntimeStateLabel,
                color: runtimeClosure.lastRuntimeResult == null
                    ? AppColors.surface2
                    : _inventoryRuntimeResultColor(
                        runtimeClosure.lastRuntimeResult!.kind,
                      ),
              ),
              _buildIngredientMetaChip(
                runtimeClosure.handoffTarget,
                color: AppColors.statusAvailable,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            runtimeClosure.operatorSummary,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Next best operator action: ${runtimeSurface.nextBestOperatorAction}',
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Blocked reasons',
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          if (runtimeClosure.blockedReasons.isEmpty)
            Text(
              'No extra blocked reason is visible beyond the tracked runtime labels.',
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            )
          else
            Column(
              children: runtimeClosure.blockedReasons
                  .map(_buildInventoryRuntimeBlockedReasonRow)
                  .toList(),
            ),
          const SizedBox(height: 10),
          Text(
            'Runtime line context',
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          if (runtimeSurface.lineContexts.isEmpty)
            Text(
              'No line-level runtime context is visible for the selected order.',
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            )
          else
            Column(
              children: runtimeSurface.lineContexts
                  .map(_buildInventoryRuntimeLineContextRow)
                  .toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildInventoryRuntimeBlockedReasonRow(String reason) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Text(
        reason,
        style: AppFonts.system(
          color: AppColors.textSecondary,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildInventoryRuntimeLineContextRow(
    InventoryPurchaseRuntimeLineContextState lineContext,
  ) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            lineContext.productName,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildIngredientMetaChip(
                lineContext.statusLabel,
                color: _inventoryOperationalToneColor(lineContext.statusTone),
              ),
              _buildIngredientMetaChip(
                'Expected ${lineContext.expectedBase.toStringAsFixed(3)}',
              ),
              _buildIngredientMetaChip(
                'Received ${lineContext.receivedBase.toStringAsFixed(3)}',
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Remaining ${lineContext.remainingBase.toStringAsFixed(3)}',
                color: lineContext.remainingBase > 0
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Ordered ${lineContext.orderedBase.toStringAsFixed(3)}',
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Line-level risk / quantity / expected / received context: ${lineContext.riskSummary}. ${lineContext.narrative}',
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInventoryRuntimePathCard({
    required String title,
    required String statusLabel,
    required Color statusColor,
    required String narrative,
    required List<Widget> metrics,
    required Widget action,
    required InventoryPurchaseRuntimeResult? result,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: statusColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: AppFonts.system(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
              _buildIngredientMetaChip(statusLabel, color: statusColor),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: metrics),
          const SizedBox(height: 8),
          Text(
            narrative,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          action,
          if (result != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.surface1,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _inventoryRuntimeResultColor(result.kind),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.title,
                    style: AppFonts.system(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    result.message,
                    style: AppFonts.system(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInventoryOrderAttentionBanner({
    required String status,
    required String? requestedDate,
    required double remainingBase,
    required String? latestReceiptStatus,
    required List<Map<String, dynamic>> lineItems,
  }) {
    final attentionLabel = _inventoryOrderAttentionLabel(
      status: status,
      remainingBase: remainingBase,
      latestReceiptStatus: latestReceiptStatus,
      lineItems: lineItems,
    );
    final attentionColor = _inventoryOrderAttentionColor(attentionLabel);
    final topHighlights = _inventoryTopAttentionHighlights(
      lineItems,
      requestedDate: requestedDate,
      orderStatus: status,
    );
    final highlightedLines = lineItems
        .where(
          (line) =>
              _inventorySupplierAttentionPriority(
                line,
                requestedDate: requestedDate,
                orderStatus: status,
              ) >=
              3,
        )
        .length;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: attentionColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Order Attention Banner',
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Review the current order-level risk posture before scanning individual line supplier signals.',
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildIngredientMetaChip(attentionLabel, color: attentionColor),
              _buildIngredientMetaChip(
                'Highlighted lines $highlightedLines',
                color: highlightedLines > 0
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
            ],
          ),
          if (topHighlights.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Top attention items',
              style: AppFonts.system(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: topHighlights
                  .map(
                    (highlight) => _buildIngredientMetaChip(
                      highlight,
                      color: AppColors.statusOccupied,
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSupplierAttentionOrderingSection({
    required List<Map<String, dynamic>> lineItems,
    required String? requestedDate,
    required String orderStatus,
  }) {
    final escalations = lineItems
        .where(
          (line) =>
              _inventorySupplierAttentionPriority(
                line,
                requestedDate: requestedDate,
                orderStatus: orderStatus,
              ) >=
              4,
        )
        .length;
    final watchLines = lineItems
        .where(
          (line) =>
              _inventorySupplierAttentionPriority(
                line,
                requestedDate: requestedDate,
                orderStatus: orderStatus,
              ) ==
              3,
        )
        .length;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Supplier Attention Ordering',
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Higher-risk supplier lines are shown first so receipt pending, price-up, or overdue lead-time items surface before stable lines.',
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildIngredientMetaChip(
                'Escalation lines $escalations',
                color: escalations > 0
                    ? AppColors.statusOccupied
                    : AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Watch lines $watchLines',
                color: watchLines > 0
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Stable lines ${lineItems.length - escalations - watchLines}',
                color: AppColors.statusAvailable,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSupplierContextHistorySection(List<Map<String, dynamic>> lines) {
    final linesWithHistory = lines
        .where(
          (line) => (line['supplier_history'] as List? ?? const []).isNotEmpty,
        )
        .toList();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Supplier Context History',
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Review recent purchase and receipt history for the same supplier item without opening approval, receipt confirmation, or stock mutation workflows.',
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          if (linesWithHistory.isEmpty)
            Text(
              'No prior supplier history is visible for the current purchase-order lines.',
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            )
          else
            Column(
              children: linesWithHistory
                  .map((line) => _buildSupplierHistoryCard(line))
                  .toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildSupplierHistoryCard(Map<String, dynamic> line) {
    final productMap = line['product'] as Map<String, dynamic>?;
    final supplierItemMap = line['supplier_item'] as Map<String, dynamic>?;
    final productName =
        productMap?['name']?.toString() ??
        line['product_id']?.toString() ??
        '-';
    final supplierSku = supplierItemMap?['supplier_sku']?.toString();
    final history = List<Map<String, dynamic>>.from(
      line['supplier_history'] as List? ?? const [],
    );
    final currentUnitPrice = (line['unit_price'] as num?)?.toDouble() ?? 0;
    final latestHistoryUnitPrice = history.isEmpty
        ? null
        : (history.first['unit_price'] as num?)?.toDouble();
    final unitPriceDriftLabel = _inventoryUnitPriceDriftLabel(
      currentUnitPrice: currentUnitPrice,
      previousUnitPrice: latestHistoryUnitPrice,
    );
    final unitPriceDriftColor = _inventoryUnitPriceDriftColor(
      currentUnitPrice: currentUnitPrice,
      previousUnitPrice: latestHistoryUnitPrice,
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            productName,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            supplierSku == null || supplierSku.isEmpty
                ? 'Supplier SKU unavailable'
                : 'Supplier SKU $supplierSku',
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildIngredientMetaChip(
                'Current unit ${_formatCurrencyCompact(currentUnitPrice)}',
              ),
              _buildIngredientMetaChip(
                unitPriceDriftLabel,
                color: unitPriceDriftColor,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Column(
            children: history.map(_buildSupplierHistoryEntryCard).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildSupplierHistoryEntryCard(Map<String, dynamic> entry) {
    final purchaseOrderNo = entry['purchase_order_no']?.toString() ?? '-';
    final orderStatus = entry['order_status']?.toString() ?? 'submitted';
    final orderedAtRaw = entry['ordered_at']?.toString();
    final orderedAt = orderedAtRaw == null
        ? null
        : DateTime.tryParse(orderedAtRaw)?.toLocal();
    final lastReceiptAtRaw = entry['last_receipt_at']?.toString();
    final lastReceiptAt = lastReceiptAtRaw == null
        ? null
        : DateTime.tryParse(lastReceiptAtRaw)?.toLocal();
    final orderedBase =
        (entry['ordered_quantity_base'] as num?)?.toDouble() ?? 0;
    final orderedUnits =
        (entry['ordered_quantity_unit'] as num?)?.toDouble() ?? 0;
    final orderUnit = entry['order_unit']?.toString() ?? 'unit';
    final unitPrice = (entry['unit_price'] as num?)?.toDouble() ?? 0;
    final receivedBase =
        (entry['received_quantity_base'] as num?)?.toDouble() ?? 0;
    final acceptedBase =
        (entry['accepted_quantity_base'] as num?)?.toDouble() ?? 0;
    final rejectedBase =
        (entry['rejected_quantity_base'] as num?)?.toDouble() ?? 0;
    final lastReceiptStatus = entry['last_receipt_status']?.toString();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildIngredientMetaChip(
                purchaseOrderNo,
                color: AppColors.amber500,
              ),
              _buildIngredientMetaChip(
                orderStatus.toUpperCase(),
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                orderedAt == null
                    ? 'Ordered date unavailable'
                    : 'Ordered ${DateFormat('yyyy-MM-dd').format(orderedAt)}',
              ),
              _buildIngredientMetaChip(
                'Recent unit ${_formatCurrencyCompact(unitPrice)}',
              ),
              _buildIngredientMetaChip(
                'Recent order ${orderedUnits.toStringAsFixed(3)} $orderUnit',
              ),
              _buildIngredientMetaChip(
                'Recent order base ${orderedBase.toStringAsFixed(3)}',
              ),
              _buildIngredientMetaChip(
                'Recent received ${receivedBase.toStringAsFixed(3)}',
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Recent accepted ${acceptedBase.toStringAsFixed(3)}',
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Recent rejected ${rejectedBase.toStringAsFixed(3)}',
                color: rejectedBase > 0
                    ? AppColors.statusOccupied
                    : AppColors.surface2,
              ),
              _buildIngredientMetaChip(
                lastReceiptStatus == null
                    ? 'Receipt status unavailable'
                    : 'Receipt ${lastReceiptStatus.toUpperCase()}',
                color: _receiptVisibilityColor(lastReceiptStatus ?? 'draft'),
              ),
              _buildIngredientMetaChip(
                lastReceiptAt == null
                    ? 'Latest receipt unavailable'
                    : 'Latest receipt ${DateFormat('yyyy-MM-dd').format(lastReceiptAt)}',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecentReceiptsTimeline(List<Map<String, dynamic>> receipts) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recent Receipts',
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Review receipt history in timeline form without opening receipt confirmation or stock mutation workflows.',
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          if (receipts.isEmpty)
            Text(
              'No receipt records are visible for this purchase order yet.',
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            )
          else
            Column(
              children: receipts
                  .map(
                    (receipt) => _buildReceiptTimelineCard(
                      receipt,
                      isSelected:
                          receipt['id']?.toString() == _selectedReceiptId,
                    ),
                  )
                  .toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildReceiptTimelineCard(
    Map<String, dynamic> receipt, {
    required bool isSelected,
  }) {
    final status = receipt['status']?.toString() ?? 'draft';
    final memo = receipt['memo']?.toString();
    final lineCount = (receipt['line_count'] as num?)?.toInt() ?? 0;
    final receivedBase =
        (receipt['received_quantity_base'] as num?)?.toDouble() ?? 0;
    final acceptedBase =
        (receipt['accepted_quantity_base'] as num?)?.toDouble() ?? 0;
    final rejectedBase =
        (receipt['rejected_quantity_base'] as num?)?.toDouble() ?? 0;
    final receivedAtRaw =
        receipt['received_at']?.toString() ?? receipt['created_at']?.toString();
    final receivedAt = receivedAtRaw == null
        ? null
        : DateTime.tryParse(receivedAtRaw)?.toLocal();

    return InkWell(
      onTap: receipt['id'] == null
          ? null
          : () => _selectReceipt(receipt['id'].toString()),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface0,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? AppColors.amber500
                : _receiptVisibilityColor(status),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    receivedAt == null
                        ? 'Receipt time unavailable'
                        : 'Receipt ${DateFormat('yyyy-MM-dd HH:mm').format(receivedAt)}',
                    style: AppFonts.system(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _buildIngredientMetaChip(
                  status.toUpperCase(),
                  color: _receiptVisibilityColor(status),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildIngredientMetaChip(
                  'Lines $lineCount',
                  color: AppColors.statusAvailable,
                ),
                _buildIngredientMetaChip(
                  'Received ${receivedBase.toStringAsFixed(3)} base',
                ),
                _buildIngredientMetaChip(
                  'Accepted ${acceptedBase.toStringAsFixed(3)} base',
                  color: AppColors.amber500,
                ),
                _buildIngredientMetaChip(
                  'Rejected ${rejectedBase.toStringAsFixed(3)} base',
                  color: rejectedBase > 0
                      ? AppColors.statusOccupied
                      : AppColors.surface2,
                ),
              ],
            ),
            if (memo != null && memo.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Receipt memo: $memo',
                style: AppFonts.system(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildReceiptVisibilitySection({
    required InventoryPurchaseRuntimeSurfaceState runtimeSurface,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Receipt Visibility',
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Track receipt readiness and already recorded inbound quantities before deciding whether the backend receipt contract is ready to run.',
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildIngredientMetaChip(
                'Receipt status ${runtimeSurface.receiptVisibilityStatusLabel}',
                color: _inventoryOperationalToneColor(
                  runtimeSurface.receiptVisibilityStatusTone,
                ),
              ),
              _buildIngredientMetaChip(
                'Readiness ${runtimeSurface.receivingReadinessLabel}',
                color: _inventoryOperationalToneColor(
                  runtimeSurface.receivingReadinessTone,
                ),
              ),
              _buildIngredientMetaChip(
                'Expected ${runtimeSurface.expectedBase.toStringAsFixed(3)} base',
              ),
              _buildIngredientMetaChip(
                'Received ${runtimeSurface.receivedBase.toStringAsFixed(3)} base',
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Accepted ${runtimeSurface.acceptedBase.toStringAsFixed(3)} base',
                color: AppColors.amber500,
              ),
              _buildIngredientMetaChip(
                'Remaining ${runtimeSurface.remainingBase.toStringAsFixed(3)} base',
                color: _inventoryOperationalToneColor(
                  runtimeSurface.receivingReadinessTone,
                ),
              ),
              if (runtimeSurface.rejectedBase > 0)
                _buildIngredientMetaChip(
                  'Rejected ${runtimeSurface.rejectedBase.toStringAsFixed(3)} base',
                  color: AppColors.statusOccupied,
                ),
              _buildIngredientMetaChip(
                'Confirmed receipts ${runtimeSurface.confirmedReceiptCount}',
                color: AppColors.statusAvailable,
              ),
              if (runtimeSurface.draftReceiptCount > 0)
                _buildIngredientMetaChip(
                  'Draft receipts ${runtimeSurface.draftReceiptCount}',
                  color: AppColors.statusOccupied,
                ),
              if (runtimeSurface.cancelledReceiptCount > 0)
                _buildIngredientMetaChip(
                  'Cancelled receipts ${runtimeSurface.cancelledReceiptCount}',
                  color: AppColors.statusCancelled,
                ),
              _buildIngredientMetaChip(
                runtimeSurface.latestReceiptAt == null
                    ? 'No receipt timestamp yet'
                    : 'Latest receipt ${DateFormat('yyyy-MM-dd HH:mm').format(runtimeSurface.latestReceiptAt!)}',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            runtimeSurface.receiptVisibilityNarrative,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPurchaseOrderLineCard(
    Map<String, dynamic> line, {
    required String? requestedDate,
    required String orderStatus,
    required int attentionRank,
  }) {
    final productMap = line['product'] as Map<String, dynamic>?;
    final supplierItemMap = line['supplier_item'] as Map<String, dynamic>?;
    final snapshot = line['recommendation_snapshot'] is Map
        ? Map<String, dynamic>.from(line['recommendation_snapshot'] as Map)
        : null;
    final productName =
        productMap?['name']?.toString() ??
        line['product_id']?.toString() ??
        '-';
    final supplierSku = supplierItemMap?['supplier_sku']?.toString();
    final supplierBaseFactor =
        (supplierItemMap?['order_unit_quantity_base'] as num?)?.toDouble() ?? 0;
    final supplierMinOrder =
        (supplierItemMap?['min_order_quantity'] as num?)?.toDouble() ?? 0;
    final supplierLeadTimeDays =
        (supplierItemMap?['lead_time_days'] as num?)?.toInt() ?? 0;
    final supplierPreferred = supplierItemMap?['is_preferred'] == true;
    final riskStatus = snapshot?['risk_status']?.toString() ?? 'stable';
    final orderedUnits =
        (line['ordered_quantity_unit'] as num?)?.toDouble() ?? 0;
    final orderedBase =
        (line['ordered_quantity_base'] as num?)?.toDouble() ?? 0;
    final recommendedBase =
        (line['recommended_quantity_base'] as num?)?.toDouble() ?? 0;
    final unitPrice = (line['unit_price'] as num?)?.toDouble() ?? 0;
    final supplyAmount = (line['supply_amount'] as num?)?.toDouble() ?? 0;
    final taxAmount = (line['tax_amount'] as num?)?.toDouble() ?? 0;
    final memo = line['memo']?.toString();
    final orderUnit = line['order_unit']?.toString() ?? 'unit';
    final snapshotRunId = snapshot?['run_id']?.toString();
    final receivedBase =
        (line['received_quantity_base'] as num?)?.toDouble() ?? 0;
    final acceptedBase =
        (line['accepted_quantity_base'] as num?)?.toDouble() ?? 0;
    final rejectedBase =
        (line['rejected_quantity_base'] as num?)?.toDouble() ?? 0;
    final remainingBase =
        (line['remaining_quantity_base'] as num?)?.toDouble() ?? 0;
    final receiptVisibilityStatus =
        line['receipt_visibility_status']?.toString() ?? 'pending';
    final supplierHistory = List<Map<String, dynamic>>.from(
      line['supplier_history'] as List? ?? const [],
    );
    final latestSupplierHistory = supplierHistory.isEmpty
        ? null
        : supplierHistory.first;
    final latestHistoryUnitPrice =
        (latestSupplierHistory?['unit_price'] as num?)?.toDouble();
    final unitPriceDriftLabel = _inventoryUnitPriceDriftLabel(
      currentUnitPrice: unitPrice,
      previousUnitPrice: latestHistoryUnitPrice,
    );
    final unitPriceDriftColor = _inventoryUnitPriceDriftColor(
      currentUnitPrice: unitPrice,
      previousUnitPrice: latestHistoryUnitPrice,
    );
    final leadTimeRiskLabel = _inventoryLeadTimeRiskLabel(
      requestedDate: requestedDate,
      supplierLeadTimeDays: supplierLeadTimeDays,
      remainingBase: remainingBase,
      orderStatus: orderStatus,
    );
    final leadTimeRiskColor = _inventoryLeadTimeRiskColor(
      requestedDate: requestedDate,
      supplierLeadTimeDays: supplierLeadTimeDays,
      remainingBase: remainingBase,
      orderStatus: orderStatus,
    );
    final combinedRiskSummary = _inventorySupplierRiskSummaryLabel(
      receiptVisibilityStatus: receiptVisibilityStatus,
      unitPriceDriftLabel: unitPriceDriftLabel,
      leadTimeRiskLabel: leadTimeRiskLabel,
    );
    final combinedRiskColor = _inventorySupplierRiskSummaryColor(
      receiptVisibilityStatus: receiptVisibilityStatus,
      unitPriceDriftLabel: unitPriceDriftLabel,
      leadTimeRiskLabel: leadTimeRiskLabel,
    );
    line['supplier_risk_summary'] = combinedRiskSummary;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _recommendationRiskColor(riskStatus)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      productName,
                      style: AppFonts.system(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      supplierSku == null || supplierSku.isEmpty
                          ? 'Supplier SKU unavailable'
                          : 'Supplier SKU $supplierSku',
                      style: AppFonts.system(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              _buildIngredientMetaChip(
                riskStatus.toUpperCase(),
                color: _recommendationRiskColor(riskStatus),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildIngredientMetaChip(
            combinedRiskSummary,
            color: combinedRiskColor,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildIngredientMetaChip(
                'Attention rank $attentionRank',
                color: attentionRank == 1
                    ? AppColors.statusOccupied
                    : attentionRank <= 3
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Ordered ${orderedUnits.toStringAsFixed(3)} $orderUnit',
                color: AppColors.amber500,
              ),
              _buildIngredientMetaChip(
                'Ordered base ${orderedBase.toStringAsFixed(3)}',
              ),
              _buildIngredientMetaChip(
                'Received ${receivedBase.toStringAsFixed(3)}',
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Accepted ${acceptedBase.toStringAsFixed(3)}',
                color: AppColors.amber500,
              ),
              _buildIngredientMetaChip(
                'Remaining ${remainingBase.toStringAsFixed(3)}',
                color: _receiptVisibilityColor(receiptVisibilityStatus),
              ),
              if (rejectedBase > 0)
                _buildIngredientMetaChip(
                  'Rejected ${rejectedBase.toStringAsFixed(3)}',
                  color: AppColors.statusOccupied,
                ),
              _buildIngredientMetaChip(
                'Recommended ${recommendedBase.toStringAsFixed(3)}',
              ),
              _buildIngredientMetaChip(
                'Unit ${_formatCurrencyCompact(unitPrice)}',
              ),
              _buildIngredientMetaChip(
                unitPriceDriftLabel,
                color: unitPriceDriftColor,
              ),
              _buildIngredientMetaChip(
                'Supply ${_formatCurrencyCompact(supplyAmount)}',
              ),
              _buildIngredientMetaChip(
                'Tax ${_formatCurrencyCompact(taxAmount)}',
              ),
              _buildIngredientMetaChip(
                snapshotRunId == null
                    ? 'Recommendation provenance unavailable'
                    : 'Recommendation ${snapshotRunId.substring(0, 8)}',
                color: _recommendationRiskColor(riskStatus),
              ),
              _buildIngredientMetaChip(
                'Receipt ${receiptVisibilityStatus.toUpperCase()}',
                color: _receiptVisibilityColor(receiptVisibilityStatus),
              ),
              _buildIngredientMetaChip(
                supplierBaseFactor > 0
                    ? 'Base factor ${supplierBaseFactor.toStringAsFixed(3)}'
                    : 'Base factor unavailable',
              ),
              _buildIngredientMetaChip(
                supplierMinOrder > 0
                    ? 'Min order ${supplierMinOrder.toStringAsFixed(3)}'
                    : 'Min order unavailable',
              ),
              _buildIngredientMetaChip(
                supplierLeadTimeDays > 0
                    ? 'Lead time $supplierLeadTimeDays day(s)'
                    : 'Lead time unavailable',
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                leadTimeRiskLabel,
                color: leadTimeRiskColor,
              ),
              _buildIngredientMetaChip(
                supplierPreferred
                    ? 'Preferred supplier item'
                    : 'Fallback supplier item',
                color: supplierPreferred
                    ? AppColors.statusAvailable
                    : AppColors.surface2,
              ),
            ],
          ),
          if (memo != null && memo.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Line memo: $memo',
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRecommendationLineCard(Map<String, dynamic> line) {
    final productMap = line['product'] as Map<String, dynamic>?;
    final supplierMap = line['supplier'] as Map<String, dynamic>?;
    final productName =
        productMap?['name']?.toString() ??
        line['product_id']?.toString() ??
        '-';
    final supplierName = supplierMap?['name']?.toString();
    final riskStatus = line['risk_status']?.toString() ?? 'stable';
    final recommendedUnits =
        (line['recommended_order_units'] as num?)?.toDouble() ?? 0;
    final recommendedQuantity =
        (line['recommended_quantity_base'] as num?)?.toDouble() ?? 0;
    final currentStock = (line['current_stock_base'] as num?)?.toDouble() ?? 0;
    final avgDailyConsumption =
        (line['avg_daily_consumption_base'] as num?)?.toDouble() ?? 0;
    final daysRemaining = (line['estimated_days_remaining'] as num?)
        ?.toDouble();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _recommendationRiskColor(riskStatus)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      productName,
                      style: AppFonts.system(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      supplierName == null || supplierName.isEmpty
                          ? 'Supplier not assigned'
                          : 'Supplier $supplierName',
                      style: AppFonts.system(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              _buildIngredientMetaChip(
                riskStatus.toUpperCase(),
                color: _recommendationRiskColor(riskStatus),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildIngredientMetaChip(
                'Order ${recommendedUnits.toStringAsFixed(0)} unit(s)',
                color: AppColors.amber500,
              ),
              _buildIngredientMetaChip(
                'Need ${recommendedQuantity.toStringAsFixed(3)} base',
              ),
              _buildIngredientMetaChip(
                'Stock ${currentStock.toStringAsFixed(3)} base',
              ),
              _buildIngredientMetaChip(
                'Daily ${avgDailyConsumption.toStringAsFixed(3)} base',
              ),
              _buildIngredientMetaChip(
                daysRemaining == null
                    ? 'Days remaining unavailable'
                    : 'Days left ${daysRemaining.toStringAsFixed(1)}',
                color: _recommendationRiskColor(riskStatus),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _recommendationRiskColor(String riskStatus) => switch (riskStatus) {
    'danger' => AppColors.statusCancelled,
    'warning' => AppColors.statusOccupied,
    'normal' => AppColors.amber500,
    _ => AppColors.statusAvailable,
  };

  String _inventoryUnitPriceDriftLabel({
    required double currentUnitPrice,
    required double? previousUnitPrice,
  }) {
    if (previousUnitPrice == null || previousUnitPrice <= 0) {
      return 'Price drift unavailable';
    }

    final deltaRatio =
        (currentUnitPrice - previousUnitPrice) / previousUnitPrice;
    final percent = (deltaRatio.abs() * 100).toStringAsFixed(1);
    if (deltaRatio.abs() < 0.02) {
      return 'Price drift stable ($percent%)';
    }
    if (deltaRatio > 0) {
      return 'Price drift up $percent%';
    }
    return 'Price drift down $percent%';
  }

  Color _inventoryUnitPriceDriftColor({
    required double currentUnitPrice,
    required double? previousUnitPrice,
  }) {
    if (previousUnitPrice == null || previousUnitPrice <= 0) {
      return AppColors.surface2;
    }

    final deltaRatio =
        (currentUnitPrice - previousUnitPrice) / previousUnitPrice;
    if (deltaRatio.abs() < 0.02) {
      return AppColors.statusAvailable;
    }
    if (deltaRatio > 0) {
      return AppColors.statusOccupied;
    }
    return AppColors.amber500;
  }

  String _inventoryLeadTimeRiskLabel({
    required String? requestedDate,
    required int supplierLeadTimeDays,
    required double remainingBase,
    required String orderStatus,
  }) {
    if (remainingBase <= 0 || orderStatus == 'received') {
      return 'Lead-time risk complete';
    }
    if (requestedDate == null ||
        requestedDate.isEmpty ||
        supplierLeadTimeDays <= 0) {
      return 'Lead-time risk unavailable';
    }

    final requestedAt = DateTime.tryParse(requestedDate);
    if (requestedAt == null) {
      return 'Lead-time risk unavailable';
    }

    final today = DateTime.now();
    final requestedLocal = DateTime(
      requestedAt.year,
      requestedAt.month,
      requestedAt.day,
    );
    final currentLocal = DateTime(today.year, today.month, today.day);
    final daysUntilRequested = requestedLocal.difference(currentLocal).inDays;

    if (daysUntilRequested < 0) {
      return 'Lead-time risk overdue';
    }
    if (daysUntilRequested < supplierLeadTimeDays) {
      return 'Lead-time risk tight';
    }
    return 'Lead-time risk on track';
  }

  Color _inventoryLeadTimeRiskColor({
    required String? requestedDate,
    required int supplierLeadTimeDays,
    required double remainingBase,
    required String orderStatus,
  }) {
    final label = _inventoryLeadTimeRiskLabel(
      requestedDate: requestedDate,
      supplierLeadTimeDays: supplierLeadTimeDays,
      remainingBase: remainingBase,
      orderStatus: orderStatus,
    );
    if (label.endsWith('complete') || label.endsWith('on track')) {
      return AppColors.statusAvailable;
    }
    if (label.endsWith('tight')) {
      return AppColors.amber500;
    }
    if (label.endsWith('overdue')) {
      return AppColors.statusOccupied;
    }
    return AppColors.surface2;
  }

  String _inventorySupplierRiskSummaryLabel({
    required String receiptVisibilityStatus,
    required String unitPriceDriftLabel,
    required String leadTimeRiskLabel,
  }) {
    final summaryParts = <String>[];

    if (receiptVisibilityStatus == 'pending' ||
        receiptVisibilityStatus == 'draft') {
      summaryParts.add('receipt pending');
    } else if (receiptVisibilityStatus == 'partially_received') {
      summaryParts.add('receipt partial');
    } else if (receiptVisibilityStatus == 'received' ||
        receiptVisibilityStatus == 'confirmed') {
      summaryParts.add('receipt complete');
    }

    if (unitPriceDriftLabel.contains('up')) {
      summaryParts.add('price up');
    } else if (unitPriceDriftLabel.contains('down')) {
      summaryParts.add('price down');
    } else if (unitPriceDriftLabel.contains('stable')) {
      summaryParts.add('price stable');
    }

    if (leadTimeRiskLabel.contains('overdue')) {
      summaryParts.add('lead overdue');
    } else if (leadTimeRiskLabel.contains('tight')) {
      summaryParts.add('lead tight');
    } else if (leadTimeRiskLabel.contains('on track')) {
      summaryParts.add('lead on track');
    } else if (leadTimeRiskLabel.contains('complete')) {
      summaryParts.add('lead complete');
    }

    if (summaryParts.isEmpty) {
      return 'Supplier risk summary unavailable';
    }
    return 'Supplier risk ${summaryParts.join(' / ')}';
  }

  Color _inventorySupplierRiskSummaryColor({
    required String receiptVisibilityStatus,
    required String unitPriceDriftLabel,
    required String leadTimeRiskLabel,
  }) {
    if (leadTimeRiskLabel.contains('overdue') ||
        unitPriceDriftLabel.contains('up')) {
      return AppColors.statusOccupied;
    }
    if (leadTimeRiskLabel.contains('tight') ||
        receiptVisibilityStatus == 'partially_received') {
      return AppColors.amber500;
    }
    if (receiptVisibilityStatus == 'received' ||
        receiptVisibilityStatus == 'confirmed' ||
        leadTimeRiskLabel.contains('on track') ||
        leadTimeRiskLabel.contains('complete')) {
      return AppColors.statusAvailable;
    }
    return AppColors.surface2;
  }

  List<Map<String, dynamic>> _sortedPurchaseOrderLinesForAttention(
    List<Map<String, dynamic>> lines, {
    required String? requestedDate,
    required String orderStatus,
  }) {
    final sorted = List<Map<String, dynamic>>.from(lines);
    sorted.sort((a, b) {
      final priorityCompare =
          _inventorySupplierAttentionPriority(
            b,
            requestedDate: requestedDate,
            orderStatus: orderStatus,
          ).compareTo(
            _inventorySupplierAttentionPriority(
              a,
              requestedDate: requestedDate,
              orderStatus: orderStatus,
            ),
          );
      if (priorityCompare != 0) {
        return priorityCompare;
      }

      final remainingCompare =
          ((b['remaining_quantity_base'] as num?)?.toDouble() ?? 0).compareTo(
            (a['remaining_quantity_base'] as num?)?.toDouble() ?? 0,
          );
      if (remainingCompare != 0) {
        return remainingCompare;
      }

      final nameA =
          (a['product'] as Map<String, dynamic>?)?['name']?.toString() ?? '';
      final nameB =
          (b['product'] as Map<String, dynamic>?)?['name']?.toString() ?? '';
      return nameA.compareTo(nameB);
    });
    return sorted;
  }

  int _inventorySupplierAttentionPriority(
    Map<String, dynamic> line, {
    required String? requestedDate,
    required String orderStatus,
  }) {
    final receiptVisibilityStatus =
        line['receipt_visibility_status']?.toString() ?? 'pending';
    final supplierHistory = List<Map<String, dynamic>>.from(
      line['supplier_history'] as List? ?? const [],
    );
    final latestSupplierHistory = supplierHistory.isEmpty
        ? null
        : supplierHistory.first;
    final currentUnitPrice = (line['unit_price'] as num?)?.toDouble() ?? 0;
    final previousUnitPrice = (latestSupplierHistory?['unit_price'] as num?)
        ?.toDouble();
    final supplierLeadTimeDays =
        ((line['supplier_item'] as Map<String, dynamic>?)?['lead_time_days']
                as num?)
            ?.toInt() ??
        0;
    final remainingBase =
        (line['remaining_quantity_base'] as num?)?.toDouble() ?? 0;
    final unitPriceDriftLabel = _inventoryUnitPriceDriftLabel(
      currentUnitPrice: currentUnitPrice,
      previousUnitPrice: previousUnitPrice,
    );
    final leadTimeRiskLabel = _inventoryLeadTimeRiskLabel(
      requestedDate: requestedDate,
      supplierLeadTimeDays: supplierLeadTimeDays,
      remainingBase: remainingBase,
      orderStatus: orderStatus,
    );

    if (leadTimeRiskLabel.contains('overdue') ||
        unitPriceDriftLabel.contains('up')) {
      return 4;
    }
    if (receiptVisibilityStatus == 'pending' ||
        leadTimeRiskLabel.contains('tight')) {
      return 3;
    }
    if (receiptVisibilityStatus == 'draft' ||
        unitPriceDriftLabel.contains('down')) {
      return 2;
    }
    if (receiptVisibilityStatus == 'confirmed' ||
        receiptVisibilityStatus == 'received') {
      return 1;
    }
    return 0;
  }

  Color _inventoryReceivingBlockerSeverityColor(String severity) =>
      switch (severity) {
        'healthy' => AppColors.statusAvailable,
        'watch' => AppColors.amber500,
        'risk' => AppColors.statusOccupied,
        'critical' => AppColors.statusCancelled,
        _ => AppColors.surface2,
      };

  Color _inventoryOperationalToneColor(String tone) => switch (tone) {
    'complete' => AppColors.statusAvailable,
    'ready' => AppColors.amber500,
    'watch' => AppColors.amber500,
    'blocked' => AppColors.statusOccupied,
    'critical' => AppColors.statusCancelled,
    _ => AppColors.surface2,
  };

  List<String> _inventoryTopAttentionHighlights(
    List<Map<String, dynamic>> lineItems, {
    required String? requestedDate,
    required String orderStatus,
  }) {
    return lineItems
        .where(
          (line) =>
              _inventorySupplierAttentionPriority(
                line,
                requestedDate: requestedDate,
                orderStatus: orderStatus,
              ) >=
              3,
        )
        .take(3)
        .map((line) {
          final productName =
              (line['product'] as Map<String, dynamic>?)?['name']?.toString() ??
              line['product_id']?.toString() ??
              '-';
          final riskSummary =
              line['supplier_risk_summary']?.toString() ?? 'risk unavailable';
          return '$productName · $riskSummary';
        })
        .toList();
  }

  String _inventoryOrderAttentionLabel({
    required String status,
    required double remainingBase,
    required String? latestReceiptStatus,
    required List<Map<String, dynamic>> lineItems,
  }) {
    final hasEscalatedLine = lineItems.any((line) {
      final summary = line['supplier_risk_summary']?.toString() ?? '';
      return summary.contains('price up') || summary.contains('lead overdue');
    });
    final hasWatchLine = lineItems.any((line) {
      final summary = line['supplier_risk_summary']?.toString() ?? '';
      return summary.contains('lead tight') ||
          summary.contains('receipt pending');
    });

    if (status == 'received' || remainingBase <= 0) {
      return 'Order attention complete';
    }
    if (hasEscalatedLine) {
      return 'Order attention escalation';
    }
    if (hasWatchLine || latestReceiptStatus == 'draft') {
      return 'Order attention watch';
    }
    if (latestReceiptStatus == 'confirmed' ||
        latestReceiptStatus == 'received') {
      return 'Order attention stable';
    }
    return 'Order attention unavailable';
  }

  Color _inventoryOrderAttentionColor(String label) {
    if (label.endsWith('escalation')) {
      return AppColors.statusOccupied;
    }
    if (label.endsWith('watch')) {
      return AppColors.amber500;
    }
    if (label.endsWith('complete') || label.endsWith('stable')) {
      return AppColors.statusAvailable;
    }
    return AppColors.surface2;
  }

  Color _receiptVisibilityColor(String status) => switch (status) {
    'received' || 'confirmed' => AppColors.statusAvailable,
    'partially_received' => AppColors.amber500,
    'draft' => AppColors.statusOccupied,
    'cancelled' => AppColors.statusCancelled,
    _ => AppColors.surface2,
  };

  Color _inventoryApprovalRuntimeStateColor(String label) {
    if (label == 'Ready to approve') {
      return AppColors.amber500;
    }
    if (label == 'Approved') {
      return AppColors.statusAvailable;
    }
    if (label == 'Approval blocked') {
      return AppColors.statusOccupied;
    }
    return AppColors.surface2;
  }

  Color _inventoryReceivingRuntimeStateColor(String label) {
    if (label == 'Ready to receive') {
      return AppColors.amber500;
    }
    if (label == 'Received / closed') {
      return AppColors.statusAvailable;
    }
    if (label == 'Receiving blocked') {
      return AppColors.statusOccupied;
    }
    return AppColors.surface2;
  }

  Color _inventoryRuntimeResultColor(InventoryPurchaseRuntimeResultKind kind) {
    switch (kind) {
      case InventoryPurchaseRuntimeResultKind.success:
        return AppColors.statusAvailable;
      case InventoryPurchaseRuntimeResultKind.failure:
        return AppColors.statusCancelled;
      case InventoryPurchaseRuntimeResultKind.blocked:
        return AppColors.statusOccupied;
      case InventoryPurchaseRuntimeResultKind.cancelled:
        return AppColors.amber500;
      case InventoryPurchaseRuntimeResultKind.idle:
        return AppColors.surface2;
    }
  }

  Future<void> _showRecommendationRunDialog({
    required BuildContext context,
    required String storeId,
  }) async {
    final targetDaysController = TextEditingController(text: '3');
    var selectedDate = DateTime.now();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setModalState) {
            return AlertDialog(
              backgroundColor: AppColors.surface1,
              title: Text(
                'Inventory Recommendation Trigger',
                style: AppFonts.system(color: AppColors.textPrimary),
              ),
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Create a store-scoped recommendation snapshot only. This does not create purchase orders or update stock.',
                      style: AppFonts.system(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: targetDaysController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Target stock days',
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: dialogContext,
                          initialDate: selectedDate,
                          firstDate: DateTime(2020),
                          lastDate: DateTime.now(),
                        );
                        if (picked != null) {
                          setModalState(() => selectedDate = picked);
                        }
                      },
                      icon: const Icon(Icons.event),
                      label: Text(
                        'As of ${DateFormat('yyyy-MM-dd').format(selectedDate)}',
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final targetStockDays = parseDecimalInput(
                      targetDaysController.text,
                    );
                    if (targetStockDays == null || targetStockDays <= 0) {
                      showErrorToast(
                        dialogContext,
                        'Target stock days must be greater than zero.',
                      );
                      return;
                    }

                    final success = await ref
                        .read(
                          inventoryPurchaseRecommendationRunProvider.notifier,
                        )
                        .run(
                          storeId: storeId,
                          targetStockDays: targetStockDays,
                          asOfDate: selectedDate,
                        );
                    if (!dialogContext.mounted) return;

                    final latest = ref.read(
                      inventoryPurchaseRecommendationRunProvider,
                    );
                    if (!success) {
                      showErrorToast(
                        dialogContext,
                        latest.error ??
                            'Failed to generate recommendation snapshot.',
                      );
                      return;
                    }

                    await ref
                        .read(inventoryPurchaseOverviewProvider.notifier)
                        .load(storeId);
                    await ref
                        .read(
                          inventoryPurchaseRecommendationSnapshotProvider
                              .notifier,
                        )
                        .loadLatest(storeId);
                    if (!dialogContext.mounted) return;
                    showSuccessToast(
                      dialogContext,
                      'Recommendation snapshot created.',
                    );
                    Navigator.of(dialogContext).pop();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.amber500,
                    foregroundColor: AppColors.surface0,
                  ),
                  child: const Text('Run Snapshot'),
                ),
              ],
            );
          },
        );
      },
    );

    targetDaysController.dispose();
  }

  Future<void> _showCreatePurchaseOrdersDialog({
    required BuildContext context,
    required String storeId,
    required Map<String, dynamic> snapshotRun,
  }) async {
    DateTime? requestedDeliveryDate;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setModalState) {
            return AlertDialog(
              backgroundColor: AppColors.surface1,
              title: Text(
                'Create Purchase Orders',
                style: AppFonts.system(color: AppColors.textPrimary),
              ),
              content: SizedBox(
                width: 380,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Create submitted purchase orders grouped by supplier from the latest recommendation snapshot. This still does not confirm receipts or mutate stock.',
                      style: AppFonts.system(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Snapshot ${snapshotRun['id']?.toString().substring(0, 8) ?? '-'}',
                      style: AppFonts.system(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: dialogContext,
                          initialDate:
                              requestedDeliveryDate ??
                              DateTime.now().add(const Duration(days: 1)),
                          firstDate: DateTime.now(),
                          lastDate: DateTime.now().add(
                            const Duration(days: 365),
                          ),
                        );
                        if (picked != null) {
                          setModalState(() => requestedDeliveryDate = picked);
                        }
                      },
                      icon: const Icon(Icons.local_shipping_outlined),
                      label: Text(
                        requestedDeliveryDate == null
                            ? 'Requested delivery date (optional)'
                            : 'Requested ${DateFormat('yyyy-MM-dd').format(requestedDeliveryDate!)}',
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final success = await ref
                        .read(inventoryPurchaseOrderCreationProvider.notifier)
                        .createFromRecommendation(
                          runId: snapshotRun['id'].toString(),
                          requestedDeliveryDate: requestedDeliveryDate,
                        );
                    if (!dialogContext.mounted) return;

                    final latest = ref.read(
                      inventoryPurchaseOrderCreationProvider,
                    );
                    if (!success) {
                      showErrorToast(
                        dialogContext,
                        latest.error ??
                            'Failed to create supplier-grouped purchase orders.',
                      );
                      return;
                    }

                    await ref
                        .read(inventoryPurchaseOverviewProvider.notifier)
                        .load(storeId);
                    await _loadPurchaseOrderSummaryAndDetail(
                      storeId,
                      preferredOrderId: latest.createdOrders.isNotEmpty
                          ? latest.createdOrders.first['id']?.toString()
                          : null,
                    );
                    if (!dialogContext.mounted) return;
                    showSuccessToast(
                      dialogContext,
                      latest.createdOrders.isEmpty
                          ? 'No supplier-qualified purchase orders were created.'
                          : '${latest.createdOrders.length} purchase order(s) created.',
                    );
                    Navigator.of(dialogContext).pop();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.amber500,
                    foregroundColor: AppColors.surface0,
                  ),
                  child: const Text('Create Orders'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _txTypeLabel(String type) => switch (type) {
    'deduct' => 'Deduction',
    'restock' => 'Stock In',
    'waste' => 'Waste',
    'adjust' => 'Adjustment',
    _ => type,
  };

  String _formatCurrencyCompact(double value) =>
      '${NumberFormat('#,###', 'vi_VN').format(value.round())} VND';

  Widget _summaryCard(String label, double value) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 11,
            ),
          ),
          Text(
            value.toStringAsFixed(3),
            style: AppFonts.system(
              color: AppColors.amber500,
              fontSize: 26,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReceiptLineProvenanceSection(
    List<Map<String, dynamic>> receipts,
  ) {
    Map<String, dynamic>? selectedReceipt;
    if (_selectedReceiptId != null) {
      for (final receipt in receipts) {
        if (receipt['id']?.toString() == _selectedReceiptId) {
          selectedReceipt = receipt;
          break;
        }
      }
    }
    selectedReceipt ??= receipts.isNotEmpty ? receipts.first : null;
    final lineDetails = selectedReceipt == null
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            selectedReceipt['line_details'] as List? ?? const [],
          );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.inventoryReceiptLineProvenanceTitle,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            context.l10n.inventoryReceiptLineProvenanceSubtitle,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          if (selectedReceipt == null)
            Text(
              context.l10n.inventorySelectReceiptForProvenance,
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            )
          else ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildIngredientMetaChip(
                  context.l10n.inventorySelectedReceipt(
                    selectedReceipt['status']?.toString().toUpperCase() ??
                        'DRAFT',
                  ),
                  color: _receiptVisibilityColor(
                    selectedReceipt['status']?.toString() ?? 'draft',
                  ),
                ),
                _buildIngredientMetaChip(
                  context.l10n.inventoryReceiptLinesCount(lineDetails.length),
                  color: AppColors.statusAvailable,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (lineDetails.isEmpty)
              Text(
                context.l10n.inventoryNoReceiptLineDetail,
                style: AppFonts.system(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              )
            else
              Column(
                children: lineDetails
                    .map((line) => _buildReceiptLineProvenanceCard(line))
                    .toList(),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildReceiptLineProvenanceCard(Map<String, dynamic> line) {
    final productName = line['product_name']?.toString() ?? '-';
    final orderedBase =
        (line['ordered_quantity_base'] as num?)?.toDouble() ?? 0;
    final recommendedBase =
        (line['recommended_quantity_base'] as num?)?.toDouble() ?? 0;
    final receivedBase =
        (line['received_quantity_base'] as num?)?.toDouble() ?? 0;
    final acceptedBase =
        (line['accepted_quantity_base'] as num?)?.toDouble() ?? 0;
    final rejectedBase =
        (line['rejected_quantity_base'] as num?)?.toDouble() ?? 0;
    final lineMemo = line['line_memo']?.toString();
    final riskStatus = line['risk_status']?.toString() ?? 'stable';
    final recommendationRunId = line['recommendation_run_id']?.toString();
    final supplierSku = line['supplier_sku']?.toString();
    final supplierBaseFactor =
        (line['order_unit_quantity_base'] as num?)?.toDouble() ?? 0;
    final supplierMinOrder =
        (line['min_order_quantity'] as num?)?.toDouble() ?? 0;
    final supplierLeadTimeDays = (line['lead_time_days'] as num?)?.toInt() ?? 0;
    final supplierPreferred = line['is_preferred'] == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _recommendationRiskColor(riskStatus)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  productName,
                  style: AppFonts.system(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _buildIngredientMetaChip(
                riskStatus.toUpperCase(),
                color: _recommendationRiskColor(riskStatus),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildIngredientMetaChip(
                context.l10n.inventoryOrderedBase(
                  orderedBase.toStringAsFixed(3),
                ),
              ),
              _buildIngredientMetaChip(
                context.l10n.inventoryRecommendedBase(
                  recommendedBase.toStringAsFixed(3),
                ),
                color: AppColors.amber500,
              ),
              _buildIngredientMetaChip(
                context.l10n.inventoryReceivedBase(
                  receivedBase.toStringAsFixed(3),
                ),
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                context.l10n.inventoryAcceptedBase(
                  acceptedBase.toStringAsFixed(3),
                ),
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                context.l10n.inventoryRejectedBase(
                  rejectedBase.toStringAsFixed(3),
                ),
                color: rejectedBase > 0
                    ? AppColors.statusOccupied
                    : AppColors.surface2,
              ),
              _buildIngredientMetaChip(
                recommendationRunId == null
                    ? context.l10n.inventoryRecommendationProvenanceUnavailable
                    : context.l10n.inventoryRecommendationShort(
                        recommendationRunId.substring(0, 8),
                      ),
                color: _recommendationRiskColor(riskStatus),
              ),
              _buildIngredientMetaChip(
                supplierSku == null || supplierSku.isEmpty
                    ? context.l10n.inventorySupplierSkuUnavailable
                    : context.l10n.inventorySupplierSku(supplierSku),
              ),
              _buildIngredientMetaChip(
                supplierBaseFactor > 0
                    ? context.l10n.inventoryBaseFactor(
                        supplierBaseFactor.toStringAsFixed(3),
                      )
                    : context.l10n.inventoryBaseFactorUnavailable,
              ),
              _buildIngredientMetaChip(
                supplierMinOrder > 0
                    ? context.l10n.inventoryMinOrder(
                        supplierMinOrder.toStringAsFixed(3),
                      )
                    : context.l10n.inventoryMinOrderUnavailable,
              ),
              _buildIngredientMetaChip(
                supplierLeadTimeDays > 0
                    ? context.l10n.inventoryLeadTimeDays(supplierLeadTimeDays)
                    : context.l10n.inventoryLeadTimeUnavailable,
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                supplierPreferred
                    ? context.l10n.inventoryPreferredSupplierItem
                    : context.l10n.inventoryFallbackSupplierItem,
                color: supplierPreferred
                    ? AppColors.statusAvailable
                    : AppColors.surface2,
              ),
            ],
          ),
          if (lineMemo != null && lineMemo.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              context.l10n.inventoryReceiptLineMemo(lineMemo),
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _purchaseMetricCard(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _purchaseDetailRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showIngredientDialog(
    BuildContext context,
    String storeId,
    IngredientNotifier notifier, {
    Map<String, dynamic>? initial,
  }) async {
    final isEdit = initial != null;
    final initialStock = (initial?['current_stock'] as num?)?.toDouble();
    final initialReorder = (initial?['reorder_point'] as num?)?.toDouble();
    final initialCost = (initial?['cost_per_unit'] as num?)?.toDouble();
    final initialSupplier = initial?['supplier_name']?.toString();
    final nameController = TextEditingController(
      text: initial?['name']?.toString() ?? '',
    );
    final stockController = TextEditingController(
      text: initial?['current_stock']?.toString() ?? '',
    );
    final reorderController = TextEditingController(
      text: initial?['reorder_point']?.toString() ?? '',
    );
    final costController = TextEditingController(
      text: initial?['cost_per_unit']?.toString() ?? '',
    );
    final supplierController = TextEditingController(
      text: initial?['supplier_name']?.toString() ?? '',
    );
    String unit = initial?['unit']?.toString() ?? 'g';

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              backgroundColor: AppColors.surface1,
              title: Text(
                isEdit
                    ? context.l10n.inventoryEditIngredient
                    : context.l10n.inventoryAddIngredient,
                style: AppFonts.system(color: AppColors.textPrimary),
              ),
              content: SizedBox(
                width: 360,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: nameController,
                        decoration: InputDecoration(
                          labelText: context.l10n.name,
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        initialValue: unit,
                        items: const [
                          DropdownMenuItem(value: 'g', child: Text('g')),
                          DropdownMenuItem(value: 'ml', child: Text('ml')),
                          DropdownMenuItem(value: 'ea', child: Text('ea')),
                        ],
                        onChanged: (v) => setModalState(() => unit = v ?? 'g'),
                        decoration: InputDecoration(
                          labelText: context.l10n.inventoryUnit,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: stockController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: context.l10n.inventoryCurrentStock,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: reorderController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: context.l10n.inventoryReorderThreshold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: costController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: context.l10n.inventoryUnitPriceVnd,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: supplierController,
                        decoration: InputDecoration(
                          labelText: context.l10n.inventorySupplier,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.l10n.cancel),
                ),
                FilledButton(
                  onPressed: () async {
                    final name = nameController.text.trim();
                    if (name.isEmpty) return;

                    if (isEdit) {
                      final patch = <String, dynamic>{};
                      final parsedStock = parseDecimalInput(
                        stockController.text,
                      );
                      final parsedReorder = parseDecimalInput(
                        reorderController.text,
                      );
                      final parsedCost = parseDecimalInput(costController.text);
                      final supplier = supplierController.text.trim();

                      if (name != (initial['name']?.toString() ?? '')) {
                        patch['name'] = name;
                      }
                      if (unit != (initial['unit']?.toString() ?? 'g')) {
                        patch['unit'] = unit;
                      }
                      if (stockController.text.trim().isNotEmpty &&
                          parsedStock != initialStock) {
                        patch['current_stock'] = parsedStock;
                      }
                      if (reorderController.text.trim().isEmpty &&
                          initialReorder != null) {
                        patch['reorder_point'] = null;
                      } else if (reorderController.text.trim().isNotEmpty &&
                          parsedReorder != initialReorder) {
                        patch['reorder_point'] = parsedReorder;
                      }
                      if (costController.text.trim().isEmpty &&
                          initialCost != null) {
                        patch['cost_per_unit'] = null;
                      } else if (costController.text.trim().isNotEmpty &&
                          parsedCost != initialCost) {
                        patch['cost_per_unit'] = parsedCost;
                      }
                      if (supplier != (initialSupplier ?? '')) {
                        patch['supplier_name'] = supplier.isEmpty
                            ? null
                            : supplier;
                      }

                      if (patch.isEmpty) {
                        showErrorToast(context, context.l10n.noChanges);
                        return;
                      }

                      final success = await notifier.update(
                        initial['id'].toString(),
                        storeId,
                        patch,
                      );
                      if (!success) {
                        if (context.mounted) {
                          showErrorToast(
                            context,
                            ref.read(ingredientProvider).error ??
                                context.l10n.inventoryUpdateIngredientFailed,
                          );
                        }
                        return;
                      }
                      if (!context.mounted) return;
                      showSuccessToast(
                        context,
                        context.l10n.inventoryIngredientSaved,
                      );
                    } else {
                      final success = await notifier.add(
                        storeId: storeId,
                        name: name,
                        unit: unit,
                        currentStock: parseDecimalInput(stockController.text),
                        reorderPoint: parseDecimalInput(reorderController.text),
                        costPerUnit: parseDecimalInput(costController.text),
                        supplierName: supplierController.text.trim().isEmpty
                            ? null
                            : supplierController.text.trim(),
                      );
                      if (!success) {
                        if (context.mounted) {
                          showErrorToast(
                            context,
                            ref.read(ingredientProvider).error ??
                                context.l10n.inventoryAddIngredientFailed,
                          );
                        }
                        return;
                      }
                      if (!context.mounted) return;
                      showSuccessToast(
                        context,
                        context.l10n.inventoryIngredientAdded,
                      );
                    }

                    if (!context.mounted) return;
                    Navigator.of(context).pop();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.amber500,
                    foregroundColor: AppColors.surface0,
                  ),
                  child: Text(context.l10n.save),
                ),
              ],
            );
          },
        );
      },
    );

    nameController.dispose();
    stockController.dispose();
    reorderController.dispose();
    costController.dispose();
    supplierController.dispose();
  }

  Future<void> _showUpsertRecipeDialog({
    required BuildContext context,
    required String storeId,
    required RecipeNotifier notifier,
    required List<Map<String, dynamic>> menuItems,
    required List<Map<String, dynamic>> ingredients,
    String? initialMenuItemId,
    Map<String, dynamic>? initialRow,
  }) async {
    final isEdit = initialRow != null;
    String? menuItemId =
        initialRow?['menu_item_id']?.toString() ?? initialMenuItemId;
    String? ingredientId = initialRow?['ingredient_id']?.toString();
    final qtyController = TextEditingController(
      text: initialRow?['quantity_g']?.toString() ?? '',
    );

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              backgroundColor: AppColors.surface1,
              title: Text(
                isEdit
                    ? context.l10n.inventoryEditRecipe
                    : context.l10n.inventoryAddRecipeMapping,
                style: AppFonts.system(color: AppColors.textPrimary),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: menuItemId,
                    items: menuItems
                        .map(
                          (item) => DropdownMenuItem<String>(
                            value: item['id'].toString(),
                            child: Text(item['name']?.toString() ?? '-'),
                          ),
                        )
                        .toList(),
                    onChanged: isEdit
                        ? null
                        : (v) => setModalState(() => menuItemId = v),
                    decoration: InputDecoration(labelText: context.l10n.menu),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: ingredientId,
                    items: ingredients
                        .map(
                          (item) => DropdownMenuItem<String>(
                            value: item['id'].toString(),
                            child: Text(
                              '${item['name']?.toString() ?? '-'} (g)',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: isEdit
                        ? null
                        : (v) => setModalState(() => ingredientId = v),
                    decoration: InputDecoration(
                      labelText: context.l10n.inventoryIngredientG,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: qtyController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: context.l10n.inventoryUsageG,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.l10n.cancel),
                ),
                FilledButton(
                  onPressed: () async {
                    final qty = parseDecimalInput(qtyController.text);
                    if (menuItemId == null ||
                        ingredientId == null ||
                        qty == null ||
                        qty <= 0) {
                      showErrorToast(
                        context,
                        context.l10n.inventoryCheckMenuIngredientUsage,
                      );
                      return;
                    }
                    final success = await notifier.upsert(
                      storeId: storeId,
                      menuItemId: menuItemId!,
                      ingredientId: ingredientId!,
                      quantityG: qty,
                    );
                    if (!success) {
                      if (context.mounted) {
                        showErrorToast(
                          context,
                          ref.read(recipeProvider).error ??
                              context.l10n.inventorySaveRecipeMappingFailed,
                        );
                      }
                      return;
                    }
                    if (!context.mounted) return;
                    showSuccessToast(
                      context,
                      isEdit
                          ? context.l10n.inventoryRecipeMappingUpdated
                          : context.l10n.inventoryRecipeMappingAdded,
                    );
                    Navigator.of(context).pop();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.amber500,
                    foregroundColor: AppColors.surface0,
                  ),
                  child: Text(context.l10n.save),
                ),
              ],
            );
          },
        );
      },
    );

    qtyController.dispose();
  }
}

class _InventorySurfaceTab extends StatelessWidget {
  const _InventorySurfaceTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.lg,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? PosColors.accentMuted : PosColors.surface,
          borderRadius: AppRadius.lg,
          border: Border.all(
            color: selected ? PosColors.accent : PosColors.border,
          ),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: selected ? PosColors.accent : PosColors.textSecondary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
