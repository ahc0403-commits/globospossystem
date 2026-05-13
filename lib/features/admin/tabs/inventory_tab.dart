import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../../core/ui/toast/toast.dart';
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

class _InventoryTabState extends ConsumerState<InventoryTab>
    with TickerProviderStateMixin {
  TabController? _tabController;
  String? _initializedRestaurantId;
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
    final canCount = PermissionUtils.canDoInventoryCount(
      auth.role,
      auth.extraPermissions,
    );

    final tabs = <String>[
      'Ingredient Management',
      'Recipe Management',
      if (canCount) 'Physical Count',
      'Inventory Report',
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
      body: Column(
        children: [
          Container(
            color: AppColors.surface0,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: TabBar(
              controller: controller,
              indicatorColor: AppColors.amber500,
              labelColor: AppColors.amber500,
              unselectedLabelColor: AppColors.textSecondary,
              labelStyle: GoogleFonts.notoSansKr(fontWeight: FontWeight.w700),
              tabs: tabs.map((t) => Tab(text: t)).toList(),
            ),
          ),
          Expanded(
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
        ],
      ),
    );
  }

  Widget _buildIngredientsTab(String? storeId) {
    final state = ref.watch(ingredientProvider);
    final notifier = ref.read(ingredientProvider.notifier);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                'Ingredients',
                style: GoogleFonts.bebasNeue(
                  color: AppColors.textPrimary,
                  fontSize: 30,
                ),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: storeId == null
                    ? null
                    : () => _showIngredientDialog(context, storeId, notifier),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                icon: const Icon(Icons.add),
                label: const Text('Add Ingredient'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'This catalog covers only basic ingredient information. Create/update events are recorded in the audit log.',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: state.isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.amber500),
                  )
                : state.error != null && state.items.isEmpty
                ? _buildIngredientInfoState(
                    icon: Icons.error_outline,
                    title: 'Failed to load ingredient catalog.',
                    message: state.error!,
                  )
                : state.items.isEmpty
                ? _buildIngredientInfoState(
                    icon: Icons.inventory_2_outlined,
                    title: 'No ingredients registered.',
                    message: 'Start the catalog by adding an ingredient.',
                  )
                : ListView.separated(
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
                      style: GoogleFonts.notoSansKr(
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
                          'Inventory ${stock.toStringAsFixed(3)} $unit',
                          color: stock <= 0
                              ? AppColors.statusCancelled
                              : AppColors.amber500,
                        ),
                        _buildIngredientMetaChip(
                          reorder == null
                              ? 'Reorder threshold not set'
                              : 'Reorder Threshold ${reorder.toStringAsFixed(3)} $unit',
                          color: needsReorder
                              ? AppColors.statusOccupied
                              : AppColors.surface2,
                        ),
                        _buildIngredientMetaChip(
                          cost == null
                              ? 'Unit price not set'
                              : 'Unit price ${NumberFormat('#,###', 'vi_VN').format(cost)} VND',
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      supplier == null || supplier.isEmpty
                          ? 'No supplier info'
                          : 'Supplier $supplier',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      lastUpdated == null
                          ? 'No recent updates'
                          : 'Updated ${DateFormat('yyyy-MM-dd HH:mm').format(lastUpdated)}',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    if (needsReorder)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          stock <= 0 ? 'Out of stock' : 'Reorder needed',
                          style: GoogleFonts.notoSansKr(
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
              IconButton(
                onPressed: storeId == null
                    ? null
                    : () => _showIngredientDialog(
                        context,
                        storeId,
                        notifier,
                        initial: item,
                      ),
                icon: const Icon(Icons.edit_outlined),
                color: AppColors.textSecondary,
                tooltip: 'Edit Ingredient',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
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
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.statusAvailable,
                    side: const BorderSide(color: AppColors.statusAvailable),
                  ),
                  icon: const Icon(Icons.add_circle_outline, size: 16),
                  label: Text(
                    'Stock In',
                    style: GoogleFonts.notoSansKr(fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
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
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.statusCancelled,
                    side: const BorderSide(color: AppColors.statusCancelled),
                  ),
                  icon: const Icon(Icons.remove_circle_outline, size: 16),
                  label: Text(
                    'Waste',
                    style: GoogleFonts.notoSansKr(fontSize: 12),
                  ),
                ),
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
        style: GoogleFonts.notoSansKr(
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
                style: GoogleFonts.notoSansKr(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: GoogleFonts.notoSansKr(
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
    final qtyController = TextEditingController();
    final noteController = TextEditingController();
    final title = isWaste ? 'Waste Record' : 'Stock-In Record';
    final actionLabel = isWaste ? 'Waste' : 'Stock In';

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
              labelText: 'Quantity ($unit)',
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
            decoration: const InputDecoration(
              labelText: 'Memo (optional)',
              labelStyle: TextStyle(color: AppColors.textSecondary),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.surface2),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.amber500),
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final qty = double.tryParse(qtyController.text.trim());
    if (qty == null || qty <= 0) {
      if (context.mounted) {
        showErrorToast(context, 'Enter a quantity greater than 0.');
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
                'Recipe Mapping',
                style: GoogleFonts.bebasNeue(
                  color: AppColors.textPrimary,
                  fontSize: 30,
                ),
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
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                icon: const Icon(Icons.add),
                label: const Text('Add Recipe Mapping'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'v1 scope: only create/edit of menu-ingredient recipe mappings is supported. Only ingredients with unit g can be linked.',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Save operations are recorded in the inventory_recipe_upserted audit log.',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            initialValue: _selectedMenuItemId,
            dropdownColor: AppColors.surface1,
            style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
            decoration: const InputDecoration(labelText: 'Menu Filter'),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('All Menus'),
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
                style: GoogleFonts.notoSansKr(
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
                    title: 'No recipe mappings.',
                    message: menuItems.isEmpty
                        ? 'Prepare menus first, then add recipe mappings.'
                        : 'Start by adding a recipe mapping.',
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
                                    style: GoogleFonts.notoSansKr(
                                      color: AppColors.textPrimary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${row['ingredient_name'] ?? '-'} · ${quantity?.toStringAsFixed(3) ?? '-'} g',
                                    style: GoogleFonts.notoSansKr(
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Ingredients Unit: $ingredientUnit',
                                    style: GoogleFonts.notoSansKr(
                                      color: AppColors.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    lastUpdated == null
                                        ? 'No recent updates'
                                        : 'Updated ${DateFormat('yyyy-MM-dd HH:mm').format(lastUpdated)}',
                                    style: GoogleFonts.notoSansKr(
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
                              tooltip: 'Edit Recipe',
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
      child: Column(
        children: [
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
                child: const Text('Start Physical Count'),
              ),
              const Spacer(),
              Text(
                '$entered / ${sheetRows.length} entered',
                style: GoogleFonts.notoSansKr(
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
                style: GoogleFonts.notoSansKr(
                  color: AppColors.statusCancelled,
                  fontSize: 12,
                ),
              ),
            ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Applied line-by-line from a date-based physical count sheet. Application events are recorded in the inventory_physical_count_applied audit log.',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: countState.isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.amber500),
                  )
                : sheetRows.isEmpty
                ? Center(
                    child: Text(
                      'No ingredients to count.',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: sheetRows.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final row = sheetRows[index];
                      final id = row['ingredient_id']?.toString() ?? '';
                      final theoretical =
                          (row['theoretical_quantity_g'] as num?)?.toDouble() ??
                          0;
                      final unit = row['ingredient_unit']?.toString() ?? 'g';
                      final actualController = _actualControllers[id];
                      final noteController = _noteControllers[id];
                      if (actualController == null || noteController == null) {
                        return const SizedBox.shrink();
                      }
                      final existingActual = (row['actual_quantity_g'] as num?)
                          ?.toDouble();
                      final storedVariance =
                          (row['variance_quantity_g'] as num?)?.toDouble();
                      final countDateLabel =
                          row['count_date']?.toString() ??
                          DateFormat('yyyy-MM-dd').format(_countDate);
                      final lastUpdatedRaw = row['last_updated']?.toString();
                      final lastUpdated = lastUpdatedRaw == null
                          ? null
                          : DateTime.tryParse(lastUpdatedRaw)?.toLocal();
                      final actual =
                          (double.tryParse(actualController.text.trim()) ??
                              existingActual) ??
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
                              style: GoogleFonts.notoSansKr(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Theoretical ${theoretical.toStringAsFixed(3)} $unit',
                              style: GoogleFonts.notoSansKr(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              existingActual == null
                                  ? 'No recorded actual stock'
                                  : 'Recorded actual ${existingActual.toStringAsFixed(3)} $unit',
                              style: GoogleFonts.notoSansKr(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              storedVariance == null
                                  ? 'No recorded variance'
                                  : 'Recorded variance ${storedVariance.toStringAsFixed(3)} $unit',
                              style: GoogleFonts.notoSansKr(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              'Count date $countDateLabel',
                              style: GoogleFonts.notoSansKr(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              lastUpdated == null
                                  ? 'No recent application'
                                  : 'Last applied ${DateFormat('yyyy-MM-dd HH:mm').format(lastUpdated)}',
                              style: GoogleFonts.notoSansKr(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: actualController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: InputDecoration(
                                labelText: 'Actual ($unit)',
                                hintText: existingActual?.toStringAsFixed(3),
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: noteController,
                              decoration: const InputDecoration(
                                labelText: 'Memo (optional)',
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Pending variance ${variance.toStringAsFixed(3)} $unit',
                              style: GoogleFonts.notoSansKr(
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
                                        final parsed = double.tryParse(
                                          actualController.text.trim(),
                                        );
                                        if (parsed == null) {
                                          showErrorToast(
                                            context,
                                            'Enter actual stock as a number.',
                                          );
                                          return;
                                        }
                                        if (parsed < 0) {
                                          showErrorToast(
                                            context,
                                            'Actual stock must be 0 or greater.',
                                          );
                                          return;
                                        }
                                        await ref
                                            .read(
                                              physicalCountProvider.notifier,
                                            )
                                            .submit(
                                              storeId: storeId,
                                              ingredientId: id,
                                              countDate: DateFormat(
                                                'yyyy-MM-dd',
                                              ).format(_countDate),
                                              actualQty: parsed,
                                              note:
                                                  noteController.text
                                                      .trim()
                                                      .isEmpty
                                                  ? null
                                                  : noteController.text.trim(),
                                            );
                                        if (!context.mounted) return;
                                        final latest = ref.read(
                                          physicalCountProvider,
                                        );
                                        if (latest.error != null) {
                                          showErrorToast(
                                            context,
                                            latest.error!,
                                          );
                                          return;
                                        }
                                        showSuccessToast(
                                          context,
                                          'Actual stock applied.',
                                        );
                                        await ref
                                            .read(ingredientProvider.notifier)
                                            .load(storeId);
                                      },
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.amber500,
                                  foregroundColor: AppColors.surface0,
                                ),
                                child: const Text('Save Actual Stock'),
                              ),
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
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Inventory Transactions',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'View deductions, stock-ins, waste, and adjustments for the selected period. Reorder status and physical counts are managed on other inventory screens.',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildInventoryPurchaseOverview(
            storeId: storeId,
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
                child: const Text('Apply'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _summaryCard('Total Deducted', deduct),
              const SizedBox(width: 8),
              _summaryCard('Total Stock-In', restock),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _summaryCard('Total Waste', waste),
              const SizedBox(width: 8),
              _summaryCard('Total Adjustment Loss', adjustLoss),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: report.isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.amber500),
                  )
                : report.error != null
                ? Center(
                    child: Text(
                      report.error!,
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.statusOccupied,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  )
                : report.transactions.isEmpty
                ? Center(
                    child: Text(
                      'No inventory transactions for the selected period.',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
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
                          style: GoogleFonts.notoSansKr(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_txTypeLabel(row['transaction_type']?.toString() ?? '')}  ${qty.toStringAsFixed(3)} $unit',
                              style: GoogleFonts.notoSansKr(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            if (note != null && note.trim().isNotEmpty)
                              Text(
                                note,
                                style: GoogleFonts.notoSansKr(
                                  color: AppColors.textSecondary,
                                  fontSize: 11,
                                ),
                              ),
                          ],
                        ),
                        trailing: Text(
                          row['created_at']?.toString().substring(0, 16) ?? '-',
                          style: GoogleFonts.notoSansKr(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildInventoryPurchaseOverview({
    required String? storeId,
    required InventoryPurchaseOverviewState overview,
    required InventoryPurchaseRecommendationRunState recommendationRun,
    required InventoryPurchaseRecommendationSnapshotState
    recommendationSnapshot,
    required InventoryPurchaseOrderCreationState orderCreation,
    required InventoryPurchaseOrderSummaryState orderSummary,
    required InventoryPurchaseOrderDetailState orderDetail,
  }) {
    final dashboard = overview.dashboard;
    final storeCount = (dashboard?['store_count'] as num?)?.toInt() ?? 0;
    final lowStockCount = (dashboard?['low_stock_count'] as num?)?.toInt() ?? 0;
    final totalInventoryAmount =
        (dashboard?['total_inventory_amount'] as num?)?.toDouble() ?? 0;
    final submittedPurchaseAmount =
        (dashboard?['submitted_purchase_amount'] as num?)?.toDouble() ?? 0;
    final approvedPurchaseAmount =
        (dashboard?['approved_purchase_amount'] as num?)?.toDouble() ?? 0;
    final operatingSummary = ref.watch(
      inventoryPurchaseOperatingSummaryProvider,
    );

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
                      'Purchase Overview',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'View the tracked purchase dashboard and generate a scoped recommendation snapshot without creating purchase orders or mutating stock.',
                      style: GoogleFonts.notoSansKr(
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
                tooltip: 'Refresh Purchase Overview',
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
                        ? 'Generating Recommendation...'
                        : 'Generate Recommendation Snapshot',
                  ),
                ),
              ),
            ],
          ),
          if (overview.error != null) ...[
            const SizedBox(height: 12),
            Text(
              overview.error!,
              style: GoogleFonts.notoSansKr(
                color: AppColors.statusOccupied,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ] else if (dashboard == null) ...[
            const SizedBox(height: 12),
            Text(
              'Purchase overview will appear after a store-scoped dashboard load.',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Row(
              children: [
                _purchaseMetricCard('Store Scope', '$storeCount store(s)'),
                const SizedBox(width: 8),
                _purchaseMetricCard(
                  'Low Stock Alerts',
                  '$lowStockCount item(s)',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _purchaseMetricCard(
                  'Inventory Value',
                  _formatCurrencyCompact(totalInventoryAmount),
                ),
                const SizedBox(width: 8),
                _purchaseMetricCard(
                  'Submitted Orders',
                  _formatCurrencyCompact(submittedPurchaseAmount),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _purchaseMetricCard(
                  'Approved Orders',
                  _formatCurrencyCompact(approvedPurchaseAmount),
                ),
                const SizedBox(width: 8),
                _purchaseMetricCard('Slice Mode', 'Scoped mutation'),
              ],
            ),
            const SizedBox(height: 12),
            _buildPurchaseOverviewDetail(
              lowStockCount: lowStockCount,
              submittedPurchaseAmount: submittedPurchaseAmount,
              approvedPurchaseAmount: approvedPurchaseAmount,
              recommendationRun: recommendationRun,
            ),
            const SizedBox(height: 12),
            _buildInventoryOperatingSummarySection(operatingSummary),
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
    required int lowStockCount,
    required double submittedPurchaseAmount,
    required double approvedPurchaseAmount,
    required InventoryPurchaseRecommendationRunState recommendationRun,
  }) {
    final approvalGap = submittedPurchaseAmount - approvedPurchaseAmount;
    final normalizedGap = approvalGap > 0 ? approvalGap : 0.0;
    final reviewFocus = lowStockCount > 0
        ? 'Review low-stock items before creating any new purchase workflow.'
        : 'No low-stock alerts in the current scoped dashboard snapshot.';
    final approvalStatus = normalizedGap > 0
        ? 'Submitted orders exceed approved orders by ${_formatCurrencyCompact(normalizedGap)}.'
        : 'Approved purchase volume is aligned with or ahead of submitted volume.';
    final recommendationStatus = recommendationRun.lastRunId == null
        ? 'No recommendation snapshot has been generated from the tracked POS workspace yet.'
        : 'Last snapshot ${recommendationRun.lastRunId!.substring(0, 8)} ran for ${recommendationRun.lastTargetStockDays?.toStringAsFixed(0) ?? '-'} day coverage as of ${recommendationRun.lastAsOfDate ?? '-'}.';

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
            'Purchase Review Detail',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 8),
          _purchaseDetailRow('Approval Gap', approvalStatus),
          const SizedBox(height: 8),
          _purchaseDetailRow('Review Focus', reviewFocus),
          const SizedBox(height: 8),
          _purchaseDetailRow('Recommendation Status', recommendationStatus),
          const SizedBox(height: 8),
          _purchaseDetailRow(
            'Boundary',
            'This slice may create recommendation snapshots and supplier-grouped purchase orders, but approval stays Office-owned and receiving runs only through the tracked backend receipt contract.',
          ),
        ],
      ),
    );
  }

  Widget _buildInventoryOperatingSummarySection(
    InventoryPurchaseOperatingSummary summary,
  ) {
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
            'Inventory Operating Runtime Summary',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Read the full inventory operating flow from one POS surface: recommendation runtime, latest snapshot state, purchase-order creation readiness, approval handoff, receiving readiness, selected purchase-order closure, blocked reasons, and the next operator action.',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
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
                summary.selectedPurchaseOrderRuntimeLabel,
              ),
              _buildIngredientMetaChip(summary.handoffTarget),
              _buildIngredientMetaChip(
                'Visible snapshot lines ${summary.visibleRecommendationLineCount}',
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Visible purchase orders ${summary.visiblePurchaseOrderCount}',
              ),
              _buildIngredientMetaChip(
                'Blocked reasons ${summary.visibleBlockedReasonCount}',
                color: summary.visibleBlockedReasonCount > 0
                    ? AppColors.statusOccupied
                    : AppColors.statusAvailable,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            summary.operatingNarrative,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
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
                  'Next Operator Action',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  summary.nextOperatorAction,
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Operating blocked reasons',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          if (summary.blockedReasons.isEmpty)
            Text(
              'No operating blocker is currently visible beyond the tracked runtime labels.',
              style: GoogleFonts.notoSansKr(
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
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Read the most recent recommendation run before deciding whether the next tracked slice should create purchase orders.',
                      style: GoogleFonts.notoSansKr(
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
              style: GoogleFonts.notoSansKr(
                color: AppColors.statusOccupied,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ] else if (run == null) ...[
            const SizedBox(height: 12),
            Text(
              'No recommendation snapshot detail has been generated for this store yet.',
              style: GoogleFonts.notoSansKr(
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
              detail: orderDetail,
              runtimeSurface: runtimeSurface,
              approvalRuntime: approvalRuntime,
              receivingRuntime: receivingRuntime,
            ),
            const SizedBox(height: 12),
            if (snapshot.lines.isEmpty)
              Text(
                'This snapshot exists, but no recommendation lines are currently visible in the tracked POS scope.',
                style: GoogleFonts.notoSansKr(
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
            style: GoogleFonts.notoSansKr(
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
            style: GoogleFonts.notoSansKr(
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
    required InventoryPurchaseOrderDetailState detail,
    required InventoryPurchaseRuntimeSurfaceState runtimeSurface,
    required InventoryPurchaseApprovalRuntimeState approvalRuntime,
    required InventoryPurchaseReceivingRuntimeState receivingRuntime,
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
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Recent Purchase Orders',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Read the latest POS-created purchase orders, then use only the runtime actions that backend truth currently supports.',
                      style: GoogleFonts.notoSansKr(
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
              style: GoogleFonts.notoSansKr(
                color: AppColors.statusOccupied,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ] else if (summary.orders.isEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'No recent purchase orders are visible for this store yet.',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Column(
              children: summary.orders
                  .map(
                    (order) => _buildRecentPurchaseOrderCard(
                      storeId: storeId,
                      order: order,
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
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        supplierName == null || supplierName.isEmpty
                            ? 'Supplier unavailable'
                            : 'Supplier $supplierName',
                        style: GoogleFonts.notoSansKr(
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
              ],
            ),
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
    final totalExpectedBase =
        (order?['total_expected_quantity_base'] as num?)?.toDouble() ?? 0;
    final totalReceivedBase =
        (order?['total_received_quantity_base'] as num?)?.toDouble() ?? 0;
    final totalAcceptedBase =
        (order?['total_accepted_quantity_base'] as num?)?.toDouble() ?? 0;
    final totalRejectedBase =
        (order?['total_rejected_quantity_base'] as num?)?.toDouble() ?? 0;
    final totalRemainingBase = runtimeSurface.remainingBase;
    final confirmedReceiptCount = runtimeSurface.confirmedReceiptCount;
    final draftReceiptCount =
        (order?['draft_receipt_count'] as num?)?.toInt() ?? 0;
    final cancelledReceiptCount =
        (order?['cancelled_receipt_count'] as num?)?.toInt() ?? 0;
    final latestReceiptStatus = order?['latest_receipt_status']?.toString();
    final latestReceiptAtRaw = order?['latest_receipt_at']?.toString();
    final latestReceiptAt = latestReceiptAtRaw == null
        ? null
        : DateTime.tryParse(latestReceiptAtRaw)?.toLocal();
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
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Inspect the selected order line-by-line, keep approval inside the Office-owned boundary, and open receiving only when backend truth supports it.',
                      style: GoogleFonts.notoSansKr(
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
              style: GoogleFonts.notoSansKr(
                color: AppColors.statusOccupied,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ] else if (!hasOrders) ...[
            const SizedBox(height: 12),
            Text(
              'Select a purchase order to inspect line-level detail once orders exist in the tracked POS scope.',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ] else if (order == null) ...[
            const SizedBox(height: 12),
            Text(
              'Select a recent purchase order card above to inspect line-level detail.',
              style: GoogleFonts.notoSansKr(
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
                style: GoogleFonts.notoSansKr(
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
              latestReceiptStatus: latestReceiptStatus,
            ),
            const SizedBox(height: 12),
            _buildInventoryRuntimePathSection(
              storeId: storeId,
              runtimeSurface: runtimeSurface,
              lineItems: sortedLines,
              approvalRuntime: approvalRuntime,
              receivingRuntime: receivingRuntime,
            ),
            const SizedBox(height: 12),
            _buildReceiptVisibilitySection(
              orderStatus: status,
              expectedBase: totalExpectedBase,
              receivedBase: totalReceivedBase,
              acceptedBase: totalAcceptedBase,
              rejectedBase: totalRejectedBase,
              remainingBase: totalRemainingBase,
              confirmedReceiptCount: confirmedReceiptCount,
              draftReceiptCount: draftReceiptCount,
              cancelledReceiptCount: cancelledReceiptCount,
              latestReceiptStatus: latestReceiptStatus,
              latestReceiptAt: latestReceiptAt,
              receipts: receipts,
            ),
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
                style: GoogleFonts.notoSansKr(
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
    final readinessState = runtimeSurface.runtimeClosure.receivingStateLabel;
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
          color: _inventoryReceivingRuntimeStateColor(readinessState),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Receiving Readiness Summary',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Review inbound receiving posture before opening receipt history or line provenance detail.',
            style: GoogleFonts.notoSansKr(
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
                'Receiving readiness $readinessState',
                color: _inventoryReceivingRuntimeStateColor(readinessState),
              ),
              _buildIngredientMetaChip(
                'Received lines $receivedLineCount',
                color: receivedLineCount > 0
                    ? AppColors.statusAvailable
                    : AppColors.surface2,
              ),
              _buildIngredientMetaChip(
                'Pending lines $pendingLineCount',
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
            _inventoryReceivingReadinessOperatorNarrative(
              receivedLineCount: receivedLineCount,
              pendingLineCount: pendingLineCount,
              attentionLineCount: attentionLineCount,
            ),
            style: GoogleFonts.notoSansKr(
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
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Read the current receiving blockers without opening receipt confirmation, supplier approval, or stock mutation workflows.',
            style: GoogleFonts.notoSansKr(
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
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      narrative,
                      style: GoogleFonts.notoSansKr(
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
              _buildIngredientMetaChip('Affected PO $affectedPurchaseOrders'),
              _buildIngredientMetaChip(
                'Impacted suppliers $impactedSuppliers',
                color: AppColors.amber500,
              ),
              _buildIngredientMetaChip('Oldest wait $oldestWaitingAge'),
              _buildIngredientMetaChip(
                'Next hint $nextHint',
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
    required String? latestReceiptStatus,
  }) {
    final blockerRows = runtimeSurface.blockerRows;
    final receivedLineCount = runtimeSurface.receivedLineCount;
    final pendingLineCount = runtimeSurface.pendingLineCount;
    final attentionLineCount = runtimeSurface.attentionLineCount;
    final remainingBase = runtimeSurface.remainingBase;
    final confirmedReceiptCount = runtimeSurface.confirmedReceiptCount;
    final readinessState = runtimeSurface.runtimeClosure.receivingStateLabel;
    final approvalHandoffLabel =
        runtimeSurface.runtimeClosure.approvalStateLabel;
    final approvalHandoffColor = _inventoryApprovalRuntimeStateColor(
      approvalHandoffLabel,
    );
    final latestReceiptLabel = latestReceiptStatus == null
        ? 'Latest receipt unavailable'
        : 'Latest receipt ${latestReceiptStatus.toUpperCase()}';

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
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Use these guardrails to confirm POS remains responsible for visibility, readiness, and operator checklist coverage before any Office-owned approval, receipt confirmation, or stock mutation workflow is considered.',
            style: GoogleFonts.notoSansKr(
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
                'Open blockers ${blockerRows.length}',
                color: blockerRows.isNotEmpty
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
            ],
            narrative:
                'POS keeps the approval handoff visible only. Office remains the execution owner for purchase-order approval, and this surface does not expose approval actions or supplier-response mutations.',
          ),
          const SizedBox(height: 8),
          _buildInventoryMutationReadinessCard(
            title: 'Receiving Confirmation Readiness',
            borderColor: _inventoryReceivingRuntimeStateColor(readinessState),
            chips: [
              _buildIngredientMetaChip(
                'Readiness $readinessState',
                color: _inventoryReceivingRuntimeStateColor(readinessState),
              ),
              _buildIngredientMetaChip(
                'Received lines $receivedLineCount',
                color: receivedLineCount > 0
                    ? AppColors.statusAvailable
                    : AppColors.surface2,
              ),
              _buildIngredientMetaChip(
                'Pending lines $pendingLineCount',
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
            narrative:
                '${runtimeSurface.runtimeClosure.operatorSummary} Receipt history and blocker detail remain review-only here, so operators can assess readiness without opening receipt execution.',
          ),
          const SizedBox(height: 8),
          _buildInventoryMutationReadinessCard(
            title: 'Stock Mutation Guardrail',
            borderColor: AppColors.surface2,
            chips: [
              _buildIngredientMetaChip(
                'Stock mutation unavailable',
                color: AppColors.statusCancelled,
              ),
              _buildIngredientMetaChip(
                'Remaining base ${remainingBase.toStringAsFixed(3)}',
                color: remainingBase > 0
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Confirmed receipts $confirmedReceiptCount',
                color: confirmedReceiptCount > 0
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
                'Tracked inbound quantities stay operator-facing signals only. This phase does not mutate stock, does not connect payment, order, or menu mutation flows, and does not transfer Office-owned execution into POS.',
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
            style: GoogleFonts.notoSansKr(
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
            style: GoogleFonts.notoSansKr(
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
      title: '$purchaseOrderNo — Confirm Remaining Receipt',
      confirmLabel: 'Confirm Remaining Receipt',
      confirmTone: PosActionTone.affirm,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Confirm the currently remaining inbound quantity from backend truth. This will create confirmed receipt records and update stock only through the tracked inventory receipt contract.',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: noteController,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: const InputDecoration(
              labelText: 'Memo (optional)',
              labelStyle: TextStyle(color: AppColors.textSecondary),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.surface2),
              ),
              focusedBorder: UnderlineInputBorder(
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
    required List<Map<String, dynamic>> lineItems,
    required InventoryPurchaseApprovalRuntimeState approvalRuntime,
    required InventoryPurchaseReceivingRuntimeState receivingRuntime,
  }) {
    final order = runtimeSurface.order;
    final orderStatus = runtimeSurface.orderStatus;
    final remainingBase = runtimeSurface.remainingBase;
    final confirmedReceiptCount = runtimeSurface.confirmedReceiptCount;
    final runtimeClosure = runtimeSurface.runtimeClosure;
    final approvalStateLabel = _inventoryApprovalRuntimeStateLabel(orderStatus);
    final approvalStateColor = _inventoryApprovalRuntimeStateColor(
      approvalStateLabel,
    );
    final approvalNarrative = _inventoryApprovalRuntimeNarrative(orderStatus);
    final receivingStateLabel = _inventoryReceivingRuntimeStateLabel(
      orderStatus: orderStatus,
      remainingBase: remainingBase,
      confirmedReceiptCount: confirmedReceiptCount,
    );
    final receivingStateColor = _inventoryReceivingRuntimeStateColor(
      receivingStateLabel,
    );
    final receivingNarrative = _inventoryReceivingRuntimeNarrative(
      orderStatus: orderStatus,
      remainingBase: remainingBase,
      confirmedReceiptCount: confirmedReceiptCount,
    );
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
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Open only the action states that the current POS runtime can support truthfully. Approval remains Office-owned, while receiving is enabled only when the backend receipt contract can safely update stock.',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          _buildInventoryRuntimeClosureSection(
            runtimeSurface: runtimeSurface,
            lineItems: lineItems,
          ),
          const SizedBox(height: 8),
          _buildInventoryRuntimePathCard(
            title: 'Approval Runtime Path',
            statusLabel: approvalStateLabel,
            statusColor: approvalStateColor,
            narrative: approvalNarrative,
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
            statusLabel: receivingStateLabel,
            statusColor: receivingStateColor,
            narrative: receivingNarrative,
            metrics: [
              _buildIngredientMetaChip(
                'Confirmed receipts $confirmedReceiptCount',
                color: confirmedReceiptCount > 0
                    ? AppColors.statusAvailable
                    : AppColors.surface2,
              ),
              _buildIngredientMetaChip(
                'Remaining base ${remainingBase.toStringAsFixed(3)}',
                color: remainingBase > 0
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
                    ? 'Confirming Receipt...'
                    : 'Confirm Remaining Receipt',
              ),
            ),
            result: receivingRuntime.result,
          ),
        ],
      ),
    );
  }

  Widget _buildInventoryRuntimeClosureSection({
    required InventoryPurchaseRuntimeSurfaceState runtimeSurface,
    required List<Map<String, dynamic>> lineItems,
  }) {
    final runtimeClosure = runtimeSurface.runtimeClosure;
    final topRuntimeLines = lineItems.take(3).toList();
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
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Keep the remaining purchase-order runtime understandable in one operational pass: approval handoff, receiving readiness, blockers, handoff target, and the last known runtime state all stay visible without leaving the POS inventory surface.',
            style: GoogleFonts.notoSansKr(
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
                runtimeClosure.approvalStateLabel,
                color: _inventoryApprovalRuntimeStateColor(
                  runtimeClosure.approvalStateLabel,
                ),
              ),
              _buildIngredientMetaChip(
                runtimeClosure.receivingStateLabel,
                color: _inventoryReceivingRuntimeStateColor(
                  runtimeClosure.receivingStateLabel,
                ),
              ),
              _buildIngredientMetaChip(
                runtimeClosure.handoffTarget,
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                runtimeClosure.lastRuntimeStateLabel,
                color: runtimeClosure.lastRuntimeResult == null
                    ? AppColors.surface2
                    : _inventoryRuntimeResultColor(
                        runtimeClosure.lastRuntimeResult!.kind,
                      ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            runtimeClosure.operatorSummary,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Blocked reasons',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          if (runtimeClosure.blockedReasons.isEmpty)
            Text(
              'No extra blocked reason is visible beyond the tracked runtime labels.',
              style: GoogleFonts.notoSansKr(
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
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          if (topRuntimeLines.isEmpty)
            Text(
              'No line-level runtime context is visible for the selected order.',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            )
          else
            Column(
              children: topRuntimeLines
                  .map(
                    (line) => _buildInventoryRuntimeLineContextRow(
                      line,
                      requestedDate: runtimeSurface.requestedDate,
                      orderStatus: runtimeSurface.orderStatus,
                    ),
                  )
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
        style: GoogleFonts.notoSansKr(
          color: AppColors.textSecondary,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildInventoryRuntimeLineContextRow(
    Map<String, dynamic> line, {
    required String? requestedDate,
    required String orderStatus,
  }) {
    final productMap = line['product'] as Map<String, dynamic>?;
    final productName =
        productMap?['name']?.toString() ??
        line['product_id']?.toString() ??
        line['id']?.toString() ??
        '-';
    final orderedBase =
        (line['ordered_quantity_base'] as num?)?.toDouble() ?? 0;
    final expectedBase =
        (line['recommended_quantity_base'] as num?)?.toDouble() ?? 0;
    final receivedBase =
        (line['received_quantity_base'] as num?)?.toDouble() ?? 0;
    final remainingBase =
        (line['remaining_quantity_base'] as num?)?.toDouble() ?? 0;
    final riskSummary =
        line['supplier_risk_summary']?.toString() ??
        _inventorySupplierRiskSummaryLabel(
          receiptVisibilityStatus:
              line['receipt_visibility_status']?.toString() ?? 'pending',
          unitPriceDriftLabel: _inventoryUnitPriceDriftLabel(
            currentUnitPrice: (line['unit_price'] as num?)?.toDouble() ?? 0,
            previousUnitPrice:
                ((line['supplier_history'] as List?)?.isNotEmpty ?? false)
                ? ((((line['supplier_history'] as List).first
                              as Map<String, dynamic>)['unit_price']
                          as num?)
                      ?.toDouble())
                : null,
          ),
          leadTimeRiskLabel: _inventoryLeadTimeRiskLabel(
            requestedDate: requestedDate,
            supplierLeadTimeDays:
                ((line['supplier_item']
                            as Map<String, dynamic>?)?['lead_time_days']
                        as num?)
                    ?.toInt() ??
                0,
            remainingBase: remainingBase,
            orderStatus: orderStatus,
          ),
        );

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
            productName,
            style: GoogleFonts.notoSansKr(
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
                'Expected ${expectedBase.toStringAsFixed(3)}',
              ),
              _buildIngredientMetaChip(
                'Received ${receivedBase.toStringAsFixed(3)}',
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Remaining ${remainingBase.toStringAsFixed(3)}',
                color: remainingBase > 0
                    ? AppColors.amber500
                    : AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Ordered ${orderedBase.toStringAsFixed(3)}',
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Line-level risk / quantity / expected / received context: $riskSummary.',
            style: GoogleFonts.notoSansKr(
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
                  style: GoogleFonts.notoSansKr(
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
            style: GoogleFonts.notoSansKr(
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
                    style: GoogleFonts.notoSansKr(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    result.message,
                    style: GoogleFonts.notoSansKr(
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
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Review the current order-level risk posture before scanning individual line supplier signals.',
            style: GoogleFonts.notoSansKr(
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
              style: GoogleFonts.notoSansKr(
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
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Higher-risk supplier lines are shown first so receipt pending, price-up, or overdue lead-time items surface before stable lines.',
            style: GoogleFonts.notoSansKr(
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
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Review recent purchase and receipt history for the same supplier item without opening approval, receipt confirmation, or stock mutation workflows.',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          if (linesWithHistory.isEmpty)
            Text(
              'No prior supplier history is visible for the current purchase-order lines.',
              style: GoogleFonts.notoSansKr(
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
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            supplierSku == null || supplierSku.isEmpty
                ? 'Supplier SKU unavailable'
                : 'Supplier SKU $supplierSku',
            style: GoogleFonts.notoSansKr(
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
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Review receipt history in timeline form without opening receipt confirmation or stock mutation workflows.',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          if (receipts.isEmpty)
            Text(
              'No receipt records are visible for this purchase order yet.',
              style: GoogleFonts.notoSansKr(
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
                    style: GoogleFonts.notoSansKr(
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
                style: GoogleFonts.notoSansKr(
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
    required String orderStatus,
    required double expectedBase,
    required double receivedBase,
    required double acceptedBase,
    required double rejectedBase,
    required double remainingBase,
    required int confirmedReceiptCount,
    required int draftReceiptCount,
    required int cancelledReceiptCount,
    required String? latestReceiptStatus,
    required DateTime? latestReceiptAt,
    required List<Map<String, dynamic>> receipts,
  }) {
    final readiness = _inventoryReceiptReadinessLabel(
      orderStatus: orderStatus,
      remainingBase: remainingBase,
      confirmedReceiptCount: confirmedReceiptCount,
    );
    final visibilityStatus =
        latestReceiptStatus ??
        (confirmedReceiptCount > 0
            ? 'confirmed'
            : draftReceiptCount > 0
            ? 'draft'
            : 'none');

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
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Track receipt readiness and already recorded inbound quantities before deciding whether the backend receipt contract is ready to run.',
            style: GoogleFonts.notoSansKr(
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
                'Receipt status ${visibilityStatus.toUpperCase()}',
                color: _receiptVisibilityColor(visibilityStatus),
              ),
              _buildIngredientMetaChip(
                'Readiness $readiness',
                color: _receiptReadinessColor(orderStatus, remainingBase),
              ),
              _buildIngredientMetaChip(
                'Expected ${expectedBase.toStringAsFixed(3)} base',
              ),
              _buildIngredientMetaChip(
                'Received ${receivedBase.toStringAsFixed(3)} base',
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Accepted ${acceptedBase.toStringAsFixed(3)} base',
                color: AppColors.amber500,
              ),
              _buildIngredientMetaChip(
                'Remaining ${remainingBase.toStringAsFixed(3)} base',
                color: _receiptReadinessColor(orderStatus, remainingBase),
              ),
              if (rejectedBase > 0)
                _buildIngredientMetaChip(
                  'Rejected ${rejectedBase.toStringAsFixed(3)} base',
                  color: AppColors.statusOccupied,
                ),
              _buildIngredientMetaChip(
                'Confirmed receipts $confirmedReceiptCount',
                color: AppColors.statusAvailable,
              ),
              if (draftReceiptCount > 0)
                _buildIngredientMetaChip(
                  'Draft receipts $draftReceiptCount',
                  color: AppColors.statusOccupied,
                ),
              if (cancelledReceiptCount > 0)
                _buildIngredientMetaChip(
                  'Cancelled receipts $cancelledReceiptCount',
                  color: AppColors.statusCancelled,
                ),
              _buildIngredientMetaChip(
                latestReceiptAt == null
                    ? 'No receipt timestamp yet'
                    : 'Latest receipt ${DateFormat('yyyy-MM-dd HH:mm').format(latestReceiptAt)}',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _inventoryReceiptReadinessNarrative(
              orderStatus: orderStatus,
              remainingBase: remainingBase,
              confirmedReceiptCount: confirmedReceiptCount,
              hasReceiptHistory: receipts.isNotEmpty,
            ),
            style: GoogleFonts.notoSansKr(
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
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      supplierSku == null || supplierSku.isEmpty
                          ? 'Supplier SKU unavailable'
                          : 'Supplier SKU $supplierSku',
                      style: GoogleFonts.notoSansKr(
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
              style: GoogleFonts.notoSansKr(
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
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      supplierName == null || supplierName.isEmpty
                          ? 'Supplier not assigned'
                          : 'Supplier $supplierName',
                      style: GoogleFonts.notoSansKr(
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

  String _inventoryReceivingReadinessOperatorNarrative({
    required int receivedLineCount,
    required int pendingLineCount,
    required int attentionLineCount,
  }) {
    if (attentionLineCount > 0) {
      return 'Operators should review attention lines first; this summary remains read-only and does not confirm receipts or mutate stock.';
    }
    if (pendingLineCount > 0) {
      return 'Pending lines remain visible for receiving follow-up, but this surface does not open approval or receipt confirmation actions.';
    }
    if (receivedLineCount > 0) {
      return 'All visible lines already look received from the tracked POS read model, so operators can use receipt history only for verification.';
    }
    return 'Receiving posture is currently unavailable from the tracked read model, so operators should rely on the existing receipt visibility surfaces only.';
  }

  Color _inventoryReceivingBlockerSeverityColor(String severity) =>
      switch (severity) {
        'healthy' => AppColors.statusAvailable,
        'watch' => AppColors.amber500,
        'risk' => AppColors.statusOccupied,
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

  Color _receiptReadinessColor(String orderStatus, double remainingBase) {
    if (orderStatus == 'received' || remainingBase <= 0) {
      return AppColors.statusAvailable;
    }
    if (orderStatus == 'office_approved' ||
        orderStatus == 'ordered' ||
        orderStatus == 'partially_received') {
      return AppColors.amber500;
    }
    return AppColors.statusOccupied;
  }

  String _inventoryReceiptReadinessLabel({
    required String orderStatus,
    required double remainingBase,
    required int confirmedReceiptCount,
  }) {
    if (orderStatus == 'received' || remainingBase <= 0) {
      return 'Complete';
    }
    if (orderStatus == 'partially_received' || confirmedReceiptCount > 0) {
      return 'Partial';
    }
    if (orderStatus == 'office_approved' || orderStatus == 'ordered') {
      return 'Ready';
    }
    if (orderStatus == 'cancelled' || orderStatus == 'office_rejected') {
      return 'Blocked';
    }
    return 'Hold';
  }

  String _inventoryReceiptReadinessNarrative({
    required String orderStatus,
    required double remainingBase,
    required int confirmedReceiptCount,
    required bool hasReceiptHistory,
  }) {
    if (orderStatus == 'received' || remainingBase <= 0) {
      return 'This purchase order is fully received in the tracked POS scope. No receipt confirmation action is exposed here.';
    }
    if (orderStatus == 'partially_received' || confirmedReceiptCount > 0) {
      return 'Confirmed receipts already exist for this order. Use the remaining quantity signal to understand what is still outstanding without mutating stock.';
    }
    if (orderStatus == 'office_approved' || orderStatus == 'ordered') {
      return hasReceiptHistory
          ? 'Receipt history exists, but confirmed inbound quantity is still incomplete for this order.'
          : 'This order is receipt-ready once goods arrive, but no receipt history is visible yet.';
    }
    if (orderStatus == 'cancelled' || orderStatus == 'office_rejected') {
      return 'This order is not receipt-ready in its current status. Visibility is read-only and does not open approval or correction flows.';
    }
    return 'This order still waits on an earlier workflow step before receipt confirmation becomes relevant. Visibility remains read-only here.';
  }

  String _inventoryApprovalRuntimeStateLabel(String orderStatus) {
    switch (orderStatus) {
      case 'submitted':
      case 'office_returned':
        return 'Ready to approve';
      case 'office_approved':
      case 'ordered':
      case 'partially_received':
      case 'received':
        return 'Approved';
      case 'office_rejected':
      case 'cancelled':
        return 'Approval blocked';
      default:
        return 'Approval pending';
    }
  }

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

  String _inventoryApprovalRuntimeNarrative(String orderStatus) {
    switch (orderStatus) {
      case 'submitted':
      case 'office_returned':
        return 'The purchase order is ready for Office review, but POS does not execute approval. Operators can verify readiness and hand off the order to the Office-owned workflow only.';
      case 'office_approved':
      case 'ordered':
      case 'partially_received':
      case 'received':
        return 'Backend truth already shows this order beyond the approval gate. POS keeps the approved state visible and does not replay Office approval execution.';
      case 'office_rejected':
        return 'Office review rejected this order. POS leaves the rejection visible and does not override the Office decision.';
      case 'cancelled':
        return 'This order is cancelled in backend truth, so approval execution stays unavailable from POS.';
      default:
        return 'The order has not reached a stable approval handoff state yet. POS keeps the boundary visible only.';
    }
  }

  String _inventoryReceivingRuntimeStateLabel({
    required String orderStatus,
    required double remainingBase,
    required int confirmedReceiptCount,
  }) {
    if (orderStatus == 'received' || remainingBase <= 0) {
      return 'Received / closed';
    }
    if (_canConfirmInventoryReceipt(
      orderStatus: orderStatus,
      remainingBase: remainingBase,
    )) {
      return 'Ready to receive';
    }
    if (confirmedReceiptCount > 0 || orderStatus == 'partially_received') {
      return 'Receiving blocked';
    }
    return 'Receiving blocked';
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

  String _inventoryReceivingRuntimeNarrative({
    required String orderStatus,
    required double remainingBase,
    required int confirmedReceiptCount,
  }) {
    if (orderStatus == 'received' || remainingBase <= 0) {
      return 'Backend truth already shows this order as fully received. POS keeps the final state visible without sending another receipt confirmation.';
    }
    if (_canConfirmInventoryReceipt(
      orderStatus: orderStatus,
      remainingBase: remainingBase,
    )) {
      return 'The receipt confirmation contract exists and can update stock truthfully for the remaining quantity. Use the runtime action only when the inbound goods are physically verified.';
    }
    if (orderStatus == 'submitted' || orderStatus == 'office_returned') {
      return 'Receiving stays blocked until Office approval completes. POS must not mutate stock or create confirmed receipts before that backend state exists.';
    }
    if (orderStatus == 'office_rejected' || orderStatus == 'cancelled') {
      return 'This order is no longer receivable in backend truth, so POS keeps the receiving state blocked.';
    }
    if (confirmedReceiptCount > 0 || orderStatus == 'partially_received') {
      return 'Receipt history already exists, but the current order status still needs backend-truth eligibility before POS can confirm more receiving.';
    }
    return 'Receiving is currently blocked because the backend order state is not receivable.';
  }

  bool _canConfirmInventoryReceipt({
    required String orderStatus,
    required double remainingBase,
  }) {
    if (remainingBase <= 0) {
      return false;
    }
    return orderStatus == 'office_approved' ||
        orderStatus == 'ordered' ||
        orderStatus == 'partially_received';
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
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
              ),
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Create a store-scoped recommendation snapshot only. This does not create purchase orders or update stock.',
                      style: GoogleFonts.notoSansKr(
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
                    final targetStockDays = double.tryParse(
                      targetDaysController.text.trim(),
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
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
              ),
              content: SizedBox(
                width: 380,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Create submitted purchase orders grouped by supplier from the latest recommendation snapshot. This still does not confirm receipts or mutate stock.',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Snapshot ${snapshotRun['id']?.toString().substring(0, 8) ?? '-'}',
                      style: GoogleFonts.notoSansKr(
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
    return Expanded(
      child: Container(
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
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 11,
              ),
            ),
            Text(
              value.toStringAsFixed(3),
              style: GoogleFonts.bebasNeue(
                color: AppColors.amber500,
                fontSize: 26,
              ),
            ),
          ],
        ),
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
            'Receipt Line Provenance',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Inspect the selected receipt line-by-line to understand ordered quantity, accepted quantity, rejected quantity, and recommendation provenance without opening any mutation workflow.',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          if (selectedReceipt == null)
            Text(
              'Select a receipt above to inspect receipt line provenance.',
              style: GoogleFonts.notoSansKr(
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
                  'Selected receipt ${selectedReceipt['status']?.toString().toUpperCase() ?? 'DRAFT'}',
                  color: _receiptVisibilityColor(
                    selectedReceipt['status']?.toString() ?? 'draft',
                  ),
                ),
                _buildIngredientMetaChip(
                  'Receipt lines ${lineDetails.length}',
                  color: AppColors.statusAvailable,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (lineDetails.isEmpty)
              Text(
                'No receipt line detail is visible for the selected receipt.',
                style: GoogleFonts.notoSansKr(
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
                  style: GoogleFonts.notoSansKr(
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
                'Ordered ${orderedBase.toStringAsFixed(3)} base',
              ),
              _buildIngredientMetaChip(
                'Recommended ${recommendedBase.toStringAsFixed(3)} base',
                color: AppColors.amber500,
              ),
              _buildIngredientMetaChip(
                'Received ${receivedBase.toStringAsFixed(3)} base',
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Accepted ${acceptedBase.toStringAsFixed(3)} base',
                color: AppColors.statusAvailable,
              ),
              _buildIngredientMetaChip(
                'Rejected ${rejectedBase.toStringAsFixed(3)} base',
                color: rejectedBase > 0
                    ? AppColors.statusOccupied
                    : AppColors.surface2,
              ),
              _buildIngredientMetaChip(
                recommendationRunId == null
                    ? 'Recommendation provenance unavailable'
                    : 'Recommendation ${recommendationRunId.substring(0, 8)}',
                color: _recommendationRiskColor(riskStatus),
              ),
              _buildIngredientMetaChip(
                supplierSku == null || supplierSku.isEmpty
                    ? 'Supplier SKU unavailable'
                    : 'Supplier SKU $supplierSku',
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
                supplierPreferred
                    ? 'Preferred supplier item'
                    : 'Fallback supplier item',
                color: supplierPreferred
                    ? AppColors.statusAvailable
                    : AppColors.surface2,
              ),
            ],
          ),
          if (lineMemo != null && lineMemo.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Receipt line memo: $lineMemo',
              style: GoogleFonts.notoSansKr(
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
    return Expanded(
      child: Container(
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
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: GoogleFonts.notoSansKr(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
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
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: GoogleFonts.notoSansKr(
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
                isEdit ? 'Edit Ingredient' : 'Add Ingredient',
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
              ),
              content: SizedBox(
                width: 360,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: nameController,
                        decoration: const InputDecoration(labelText: 'Name'),
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
                        decoration: const InputDecoration(labelText: 'Unit'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: stockController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Current Stock',
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: reorderController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Reorder Threshold',
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: costController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Unit Price (VND)',
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: supplierController,
                        decoration: const InputDecoration(
                          labelText: 'Supplier',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final name = nameController.text.trim();
                    if (name.isEmpty) return;

                    if (isEdit) {
                      final patch = <String, dynamic>{};
                      final parsedStock = double.tryParse(stockController.text);
                      final parsedReorder = double.tryParse(
                        reorderController.text,
                      );
                      final parsedCost = double.tryParse(costController.text);
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
                        showErrorToast(context, 'No changes.');
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
                                'Failed to update ingredient',
                          );
                        }
                        return;
                      }
                      if (!context.mounted) return;
                      showSuccessToast(context, 'Ingredient info saved.');
                    } else {
                      final success = await notifier.add(
                        storeId: storeId,
                        name: name,
                        unit: unit,
                        currentStock: double.tryParse(stockController.text),
                        reorderPoint: double.tryParse(reorderController.text),
                        costPerUnit: double.tryParse(costController.text),
                        supplierName: supplierController.text.trim().isEmpty
                            ? null
                            : supplierController.text.trim(),
                      );
                      if (!success) {
                        if (context.mounted) {
                          showErrorToast(
                            context,
                            ref.read(ingredientProvider).error ??
                                'Failed to add ingredient',
                          );
                        }
                        return;
                      }
                      if (!context.mounted) return;
                      showSuccessToast(context, 'Ingredient added.');
                    }

                    if (!context.mounted) return;
                    Navigator.of(context).pop();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.amber500,
                    foregroundColor: AppColors.surface0,
                  ),
                  child: const Text('Save'),
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
                isEdit ? 'Edit Recipe Mapping' : 'Add Recipe Mapping',
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
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
                    decoration: const InputDecoration(labelText: 'Menu'),
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
                    decoration: const InputDecoration(
                      labelText: 'Ingredient (g)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: qtyController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Usage (g)'),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final qty = double.tryParse(qtyController.text.trim());
                    if (menuItemId == null ||
                        ingredientId == null ||
                        qty == null ||
                        qty <= 0) {
                      showErrorToast(
                        context,
                        'Check the menu, ingredient, and usage (g).',
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
                              'Failed to save recipe mapping',
                        );
                      }
                      return;
                    }
                    if (!context.mounted) return;
                    showSuccessToast(
                      context,
                      isEdit
                          ? 'Recipe mapping updated.'
                          : 'Recipe mapping added.',
                    );
                    Navigator.of(context).pop();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.amber500,
                    foregroundColor: AppColors.surface0,
                  ),
                  child: const Text('Save'),
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
