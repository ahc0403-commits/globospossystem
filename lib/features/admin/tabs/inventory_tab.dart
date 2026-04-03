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

  @override
  void dispose() {
    _tabController?.dispose();
    for (final c in _actualControllers.values) {
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

  Future<void> _initialize(String restaurantId) async {
    await ref.read(ingredientProvider.notifier).load(restaurantId);
    await ref.read(recipeProvider.notifier).loadAll(restaurantId);
    await ref
        .read(physicalCountProvider.notifier)
        .load(restaurantId, DateFormat('yyyy-MM-dd').format(_countDate));
    await ref
        .read(inventoryReportProvider.notifier)
        .load(restaurantId: restaurantId, from: _reportFrom, to: _reportTo);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final restaurantId = auth.restaurantId;
    final canCount = PermissionUtils.canDoInventoryCount(
      auth.role,
      auth.extraPermissions,
    );

    final tabs = <String>['원재료 관리', '배합비 관리', if (canCount) '실재고 실사', '재고 리포트'];
    _ensureTabController(tabs.length);

    if (restaurantId != null && _initializedRestaurantId != restaurantId) {
      _initializedRestaurantId = restaurantId;
      Future.microtask(() => _initialize(restaurantId));
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
                _buildIngredientsTab(restaurantId),
                _buildRecipeTab(restaurantId),
                if (canCount) _buildPhysicalCountTab(restaurantId),
                _buildReportTab(restaurantId),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIngredientsTab(String? restaurantId) {
    final state = ref.watch(ingredientProvider);
    final notifier = ref.read(ingredientProvider.notifier);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                '원재료',
                style: GoogleFonts.bebasNeue(
                  color: AppColors.textPrimary,
                  fontSize: 30,
                ),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: restaurantId == null
                    ? null
                    : () => _showIngredientDialog(
                        context,
                        restaurantId,
                        notifier,
                      ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                icon: const Icon(Icons.add),
                label: const Text('원재료 추가'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: state.isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.amber500),
                  )
                : ListView.separated(
                    itemCount: state.items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final item = state.items[index];
                      final stock =
                          (item['current_stock'] as num?)?.toDouble() ?? 0;
                      final reorder =
                          (item['reorder_point'] as num?)?.toDouble() ?? 0;
                      final outOfStock = stock <= 0;
                      final needReorder = stock <= reorder;

                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: outOfStock
                              ? AppColors.statusCancelled.withValues(
                                  alpha: 0.12,
                                )
                              : AppColors.surface1,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: outOfStock
                                ? AppColors.statusCancelled
                                : needReorder
                                ? AppColors.statusOccupied
                                : AppColors.surface2,
                          ),
                        ),
                        child: Row(
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
                                  Text(
                                    '재고 ${stock.toStringAsFixed(3)} ${item['unit'] ?? 'g'}',
                                    style: GoogleFonts.notoSansKr(
                                      color: AppColors.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                  if (needReorder)
                                    Text(
                                      outOfStock ? '재고 없음' : '⚠️ 발주 필요',
                                      style: GoogleFonts.notoSansKr(
                                        color: outOfStock
                                            ? AppColors.statusCancelled
                                            : AppColors.statusOccupied,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            OutlinedButton(
                              onPressed: restaurantId == null
                                  ? null
                                  : () => _showRestockDialog(
                                      context,
                                      restaurantId,
                                      item,
                                    ),
                              child: const Text('입고'),
                            ),
                            const SizedBox(width: 6),
                            IconButton(
                              onPressed: restaurantId == null
                                  ? null
                                  : () => _showIngredientDialog(
                                      context,
                                      restaurantId,
                                      notifier,
                                      initial: item,
                                    ),
                              icon: const Icon(Icons.edit_outlined),
                              color: AppColors.textSecondary,
                            ),
                            IconButton(
                              onPressed: restaurantId == null
                                  ? null
                                  : () async {
                                      await notifier.delete(
                                        item['id'].toString(),
                                        restaurantId,
                                      );
                                    },
                              icon: const Icon(Icons.delete_outline),
                              color: AppColors.statusCancelled,
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

  Widget _buildRecipeTab(String? restaurantId) {
    final ingredientState = ref.watch(ingredientProvider);
    final recipeState = ref.watch(recipeProvider);
    final notifier = ref.read(recipeProvider.notifier);

    final recipesForMenu = recipeState.allRecipes
        .where((r) => r['menu_item_id']?.toString() == _selectedMenuItemId)
        .toList();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          DropdownButtonFormField<String>(
            initialValue: _selectedMenuItemId,
            dropdownColor: AppColors.surface1,
            style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
            decoration: const InputDecoration(labelText: '메뉴 선택'),
            items: recipeState.menuItems
                .map(
                  (m) => DropdownMenuItem<String>(
                    value: m['id']?.toString(),
                    child: Text(m['name']?.toString() ?? '-'),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => _selectedMenuItemId = value),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: restaurantId == null || _selectedMenuItemId == null
                  ? null
                  : () => _showAddRecipeDialog(
                      context,
                      restaurantId,
                      _selectedMenuItemId!,
                      ingredientState.items,
                      notifier,
                    ),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              icon: const Icon(Icons.add),
              label: const Text('원재료 추가'),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: recipeState.isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.amber500),
                  )
                : ListView.builder(
                    itemCount: recipesForMenu.length,
                    itemBuilder: (context, index) {
                      final row = recipesForMenu[index];
                      final ingredient =
                          row['inventory_items'] as Map<String, dynamic>?;
                      return ListTile(
                        title: Text(
                          ingredient?['name']?.toString() ?? '-',
                          style: GoogleFonts.notoSansKr(
                            color: AppColors.textPrimary,
                          ),
                        ),
                        subtitle: Text(
                          '${row['quantity_g']} ${ingredient?['unit'] ?? 'g'}',
                          style: GoogleFonts.notoSansKr(
                            color: AppColors.textSecondary,
                          ),
                        ),
                        trailing: IconButton(
                          onPressed: restaurantId == null
                              ? null
                              : () => notifier.delete(
                                  restaurantId,
                                  _selectedMenuItemId!,
                                  row['ingredient_id'].toString(),
                                ),
                          icon: const Icon(Icons.delete_outline),
                          color: AppColors.statusCancelled,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhysicalCountTab(String? restaurantId) {
    final ingredientState = ref.watch(ingredientProvider);
    final countState = ref.watch(physicalCountProvider);

    final countsByIngredient = <String, Map<String, dynamic>>{};
    for (final c in countState.counts) {
      countsByIngredient[c['ingredient_id'].toString()] = c;
    }

    for (final item in ingredientState.items) {
      final id = item['id'].toString();
      _actualControllers.putIfAbsent(id, () {
        final existing = countsByIngredient[id];
        return TextEditingController(
          text: existing == null ? '' : '${existing['actual_quantity_g']}',
        );
      });
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
                  if (picked == null || restaurantId == null) return;
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
                  });
                  await ref
                      .read(physicalCountProvider.notifier)
                      .load(
                        restaurantId,
                        DateFormat('yyyy-MM-dd').format(_countDate),
                      );
                },
                icon: const Icon(Icons.event),
                label: Text(DateFormat('yyyy-MM-dd').format(_countDate)),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: restaurantId == null
                    ? null
                    : () => ref
                          .read(physicalCountProvider.notifier)
                          .load(
                            restaurantId,
                            DateFormat('yyyy-MM-dd').format(_countDate),
                          ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                child: const Text('실사 시작'),
              ),
              const Spacer(),
              Text(
                '$entered / ${ingredientState.items.length} 입력 완료',
                style: GoogleFonts.notoSansKr(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView.builder(
              itemCount: ingredientState.items.length,
              itemBuilder: (context, index) {
                final item = ingredientState.items[index];
                final id = item['id'].toString();
                final theoretical =
                    (item['current_stock'] as num?)?.toDouble() ?? 0.0;
                final controller = _actualControllers[id]!;

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.surface1,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.surface2),
                  ),
                  child: Row(
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
                            Text(
                              '이론재고: ${theoretical.toStringAsFixed(3)} ${item['unit'] ?? 'g'}',
                              style: GoogleFonts.notoSansKr(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 140,
                        child: TextField(
                          controller: controller,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          style: GoogleFonts.notoSansKr(
                            color: AppColors.textPrimary,
                          ),
                          decoration: const InputDecoration(labelText: '실측재고'),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: restaurantId == null || countState.isSaving
                  ? null
                  : () => _submitAllCounts(restaurantId),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              child: countState.isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('전체 저장'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReportTab(String? restaurantId) {
    final report = ref.watch(inventoryReportProvider);
    final ingredients = ref.watch(ingredientProvider).items;

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
    final adjustLoss = report.transactions
        .where((t) => t['transaction_type'] == 'adjust')
        .fold<double>(0, (s, t) {
          final q = (t['quantity_g'] as num?)?.toDouble() ?? 0;
          return q < 0 ? s + q.abs() : s;
        });

    final reorderList = ingredients.where((item) {
      final stock = (item['current_stock'] as num?)?.toDouble() ?? 0;
      final reorder = (item['reorder_point'] as num?)?.toDouble() ?? 0;
      return stock <= reorder;
    }).toList();

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
                onPressed: restaurantId == null
                    ? null
                    : () => ref
                          .read(inventoryReportProvider.notifier)
                          .load(
                            restaurantId: restaurantId,
                            from: _reportFrom,
                            to: _reportTo,
                          ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                child: const Text('적용'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _summaryCard('총 차감량', deduct),
              const SizedBox(width: 8),
              _summaryCard('총 입고량', restock),
              const SizedBox(width: 8),
              _summaryCard('총 손실량', adjustLoss),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: report.isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.amber500),
                  )
                : ListView.builder(
                    itemCount: report.transactions.length,
                    itemBuilder: (context, index) {
                      final row = report.transactions[index];
                      final ingredient =
                          row['inventory_items'] as Map<String, dynamic>?;
                      final qty = (row['quantity_g'] as num?)?.toDouble() ?? 0;
                      return ListTile(
                        title: Text(
                          ingredient?['name']?.toString() ?? '-',
                          style: GoogleFonts.notoSansKr(
                            color: AppColors.textPrimary,
                          ),
                        ),
                        subtitle: Text(
                          '${row['transaction_type']}  ${qty.toStringAsFixed(3)}',
                          style: GoogleFonts.notoSansKr(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
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
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '발주 필요',
              style: GoogleFonts.notoSansKr(
                color: AppColors.statusOccupied,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: reorderList
                .map(
                  (item) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.statusOccupied.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.statusOccupied),
                    ),
                    child: Text(
                      '${item['name']} (${item['current_stock']})',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

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

  Future<void> _submitAllCounts(String restaurantId) async {
    final auth = ref.read(authProvider);
    final ingredients = ref.read(ingredientProvider).items;
    final notifier = ref.read(physicalCountProvider.notifier);

    int saved = 0;
    int loss = 0;
    int surplus = 0;
    for (final item in ingredients) {
      final id = item['id'].toString();
      final txt = _actualControllers[id]?.text.trim() ?? '';
      if (txt.isEmpty) continue;
      final actual = double.tryParse(txt);
      if (actual == null) continue;

      final theoretical = (item['current_stock'] as num?)?.toDouble() ?? 0;
      final variance = actual - theoretical;
      if (variance < 0) {
        loss += 1;
      } else if (variance > 0) {
        surplus += 1;
      }

      await notifier.submit(
        restaurantId: restaurantId,
        ingredientId: id,
        countDate: DateFormat('yyyy-MM-dd').format(_countDate),
        actualQty: actual,
        theoreticalQty: theoretical,
        userId: auth.user?.id,
      );
      saved += 1;
    }

    if (!mounted) return;
    showSuccessToast(context, '저장 완료: $saved개, 손실 $loss개, 잉여 $surplus개');
    await ref.read(ingredientProvider.notifier).load(restaurantId);
  }

  Future<void> _showIngredientDialog(
    BuildContext context,
    String restaurantId,
    IngredientNotifier notifier, {
    Map<String, dynamic>? initial,
  }) async {
    final isEdit = initial != null;
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
                isEdit ? '원재료 수정' : '원재료 추가',
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
                        decoration: const InputDecoration(labelText: '이름'),
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
                        decoration: const InputDecoration(labelText: '단위'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: stockController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(labelText: '현재고'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: reorderController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(labelText: '발주기준'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: costController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(labelText: '단가(VND)'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: supplierController,
                        decoration: const InputDecoration(labelText: '공급처'),
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
                FilledButton(
                  onPressed: () async {
                    final name = nameController.text.trim();
                    if (name.isEmpty) return;

                    if (isEdit) {
                      await notifier.update(
                        initial['id'].toString(),
                        restaurantId,
                        {
                          'name': name,
                          'unit': unit,
                          'current_stock': double.tryParse(
                            stockController.text,
                          ),
                          'reorder_point': double.tryParse(
                            reorderController.text,
                          ),
                          'cost_per_unit': double.tryParse(costController.text),
                          'supplier_name': supplierController.text.trim(),
                        },
                      );
                    } else {
                      await notifier.add(
                        restaurantId: restaurantId,
                        name: name,
                        unit: unit,
                        currentStock: double.tryParse(stockController.text),
                        reorderPoint: double.tryParse(reorderController.text),
                        costPerUnit: double.tryParse(costController.text),
                        supplierName: supplierController.text.trim().isEmpty
                            ? null
                            : supplierController.text.trim(),
                      );
                    }

                    if (!context.mounted) return;
                    Navigator.of(context).pop();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.amber500,
                    foregroundColor: AppColors.surface0,
                  ),
                  child: const Text('저장'),
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

  Future<void> _showRestockDialog(
    BuildContext context,
    String restaurantId,
    Map<String, dynamic> ingredient,
  ) async {
    final qtyController = TextEditingController();
    final noteController = TextEditingController();
    final notifier = ref.read(ingredientProvider.notifier);
    final userId = ref.read(authProvider).user?.id;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface1,
          title: Text(
            '입고 - ${ingredient['name']}',
            style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: qtyController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: '입고량'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: noteController,
                decoration: const InputDecoration(labelText: '메모'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () async {
                final qty = double.tryParse(qtyController.text.trim());
                if (qty == null || qty <= 0) return;
                await notifier.restock(
                  restaurantId,
                  ingredient['id'].toString(),
                  qty,
                  noteController.text.trim(),
                  userId,
                );
                if (!context.mounted) return;
                Navigator.of(context).pop();
              },
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              child: const Text('저장'),
            ),
          ],
        );
      },
    );

    qtyController.dispose();
    noteController.dispose();
  }

  Future<void> _showAddRecipeDialog(
    BuildContext context,
    String restaurantId,
    String menuItemId,
    List<Map<String, dynamic>> ingredients,
    RecipeNotifier notifier,
  ) async {
    String? ingredientId;
    final qtyController = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              backgroundColor: AppColors.surface1,
              title: Text(
                '원재료 추가',
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: ingredientId,
                    items: ingredients
                        .map(
                          (i) => DropdownMenuItem<String>(
                            value: i['id'].toString(),
                            child: Text(i['name']?.toString() ?? '-'),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setModalState(() => ingredientId = v),
                    decoration: const InputDecoration(labelText: '원재료'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: qtyController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: '사용량(g)'),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: () async {
                    final qty = double.tryParse(qtyController.text.trim());
                    if (ingredientId == null || qty == null || qty <= 0) return;
                    await notifier.upsert(
                      restaurantId: restaurantId,
                      menuItemId: menuItemId,
                      ingredientId: ingredientId!,
                      quantityG: qty,
                    );
                    if (!context.mounted) return;
                    Navigator.of(context).pop();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.amber500,
                    foregroundColor: AppColors.surface0,
                  ),
                  child: const Text('저장'),
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
