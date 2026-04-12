import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

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
    await ref
        .read(inventoryReportProvider.notifier)
        .load(storeId: storeId, from: _reportFrom, to: _reportTo);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final storeId = auth.storeId;
    final canCount = PermissionUtils.canDoInventoryCount(
      auth.role,
      auth.extraPermissions,
    );

    final tabs = <String>['Ingredient Management', 'Recipe Management', if (canCount) 'Physical Count', 'Inventory Report'];
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
                    : () => _showIngredientDialog(
                        context,
                        storeId,
                        notifier,
                      ),
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
                            ingredientId: item['ingredient_id']?.toString() ?? item['id']?.toString() ?? '',
                            ingredientName: item['name']?.toString() ?? '',
                            unit: item['unit']?.toString() ?? 'g',
                            isWaste: false,
                          ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.statusAvailable,
                    side: const BorderSide(color: AppColors.statusAvailable),
                  ),
                  icon: const Icon(Icons.add_circle_outline, size: 16),
                  label: Text('Stock In',
                      style: GoogleFonts.notoSansKr(fontSize: 12)),
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
                            ingredientId: item['ingredient_id']?.toString() ?? item['id']?.toString() ?? '',
                            ingredientName: item['name']?.toString() ?? '',
                            unit: item['unit']?.toString() ?? 'g',
                            isWaste: true,
                          ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.statusCancelled,
                    side: const BorderSide(color: AppColors.statusCancelled),
                  ),
                  icon: const Icon(Icons.remove_circle_outline, size: 16),
                  label: Text('Waste',
                      style: GoogleFonts.notoSansKr(fontSize: 12)),
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
    final actionColor =
        isWaste ? AppColors.statusCancelled : AppColors.statusAvailable;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Text('$ingredientName — $title',
            style: GoogleFonts.notoSansKr(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: qtyController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: 'Quantity ($unit)',
                labelStyle:
                    const TextStyle(color: AppColors.textSecondary),
                enabledBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: AppColors.surface2)),
                focusedBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: AppColors.amber500)),
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
                    borderSide: BorderSide(color: AppColors.surface2)),
                focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: AppColors.amber500)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: actionColor,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(actionLabel),
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

  String _txTypeLabel(String type) => switch (type) {
    'deduct' => 'Deduction',
    'restock' => 'Stock In',
    'waste' => 'Waste',
    'adjust' => 'Adjustment',
    _ => type,
  };

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
                        decoration: const InputDecoration(labelText: 'Current Stock'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: reorderController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(labelText: 'Reorder Threshold'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: costController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(labelText: 'Unit Price (VND)'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: supplierController,
                        decoration: const InputDecoration(labelText: 'Supplier'),
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
                            ref.read(ingredientProvider).error ?? 'Failed to update ingredient',
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
                            ref.read(ingredientProvider).error ?? 'Failed to add ingredient',
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
                    decoration: const InputDecoration(labelText: 'Ingredient (g)'),
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
                      showErrorToast(context, 'Check the menu, ingredient, and usage (g).');
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
                          ref.read(recipeProvider).error ?? 'Failed to save recipe mapping',
                        );
                      }
                      return;
                    }
                    if (!context.mounted) return;
                    showSuccessToast(
                      context,
                      isEdit ? 'Recipe mapping updated.' : 'Recipe mapping added.',
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
