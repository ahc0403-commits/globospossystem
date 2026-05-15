import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../../core/ui/pos_design_tokens.dart';
import '../../../core/ui/toast/toast.dart';
import '../../../main.dart';
import '../../../widgets/error_toast.dart';
import '../../auth/auth_provider.dart';
import '../providers/admin_audit_provider.dart';
import '../providers/menu_provider.dart';
import '../widgets/admin_audit_trace_panel.dart';

class MenuTab extends ConsumerStatefulWidget {
  const MenuTab({super.key});

  @override
  ConsumerState<MenuTab> createState() => _MenuTabState();
}

class _MenuTabState extends ConsumerState<MenuTab> {
  String? _lastError;

  @override
  Widget build(BuildContext context) {
    final storeId = ref.watch(authProvider).storeId;
    if (storeId == null) {
      return const _RestaurantMissingView();
    }

    final menuState = ref.watch(menuProvider(storeId));
    final menuNotifier = ref.read(menuProvider(storeId).notifier);
    final auditTraceAsync = ref.watch(adminAuditTraceProvider(storeId));
    final numberFormat = NumberFormat('#,###', 'vi_VN');

    final categoriesAsync = menuState.categories;
    final itemsAsync = menuState.items;

    if (menuState.error != null &&
        menuState.error!.isNotEmpty &&
        menuState.error != _lastError) {
      _lastError = menuState.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showErrorToast(context, menuState.error!);
        }
      });
    }

    final isLoading = categoriesAsync.isLoading || itemsAsync.isLoading;
    final categoriesError = categoriesAsync.hasError;
    final itemsError = itemsAsync.hasError;

    if (isLoading) {
      return const Scaffold(
        backgroundColor: AppColors.surface0,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.amber500),
        ),
      );
    }

    if (categoriesError || itemsError) {
      return Scaffold(
        backgroundColor: AppColors.surface0,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Failed to load menu info.',
                style: GoogleFonts.notoSansKr(
                  color: AppColors.statusCancelled,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: menuNotifier.fetchAll,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final categories = categoriesAsync.valueOrNull ?? [];
    final allItems = itemsAsync.valueOrNull ?? [];
    final selectedCategoryId = menuState.selectedCategoryId;

    final selectedItems = selectedCategoryId == null
        ? <Map<String, dynamic>>[]
        : allItems
              .where(
                (item) => item['category_id']?.toString() == selectedCategoryId,
              )
              .toList();
    final availableItems = allItems
        .where((item) => item['is_available'] == true)
        .length;

    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: ToastResponsiveBody(
        maxWidth: 1420,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildMenuCommandHeader(
              categoryCount: categories.length,
              itemCount: allItems.length,
              availableItems: availableItems,
              selectedItemCount: selectedItems.length,
              selectedCategoryName: _categoryNameForId(
                categories,
                selectedCategoryId,
              ),
              onAddCategory: () =>
                  _showAddCategoryDialog(context, menuNotifier),
              onAddItem: selectedCategoryId == null
                  ? null
                  : () => _showAddItemDialog(
                      context,
                      selectedCategoryId,
                      menuNotifier,
                    ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 960) {
                    return ToastViewportScroll(
                      child: Column(
                        children: [
                          SizedBox(
                            height: 420,
                            child: _CategoryPanel(
                              categories: categories,
                              selectedCategoryId: selectedCategoryId,
                              auditTraceAsync: auditTraceAsync,
                              onSelect: menuNotifier.selectCategory,
                            ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            height: 620,
                            child: _ItemsPanel(
                              selectedItems: selectedItems,
                              selectedCategoryId: selectedCategoryId,
                              numberFormat: numberFormat,
                              onToggleAvailability:
                                  menuNotifier.toggleAvailability,
                              onEditItem: (item) => _showEditItemDialog(
                                context,
                                item,
                                menuNotifier,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  return ToastSplitPane(
                    queueWidth: 360,
                    queue: _CategoryPanel(
                      categories: categories,
                      selectedCategoryId: selectedCategoryId,
                      auditTraceAsync: auditTraceAsync,
                      onSelect: menuNotifier.selectCategory,
                    ),
                    detail: _ItemsPanel(
                      selectedItems: selectedItems,
                      selectedCategoryId: selectedCategoryId,
                      numberFormat: numberFormat,
                      onToggleAvailability: menuNotifier.toggleAvailability,
                      onEditItem: (item) =>
                          _showEditItemDialog(context, item, menuNotifier),
                    ),
                    divider: false,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuCommandHeader({
    required int categoryCount,
    required int itemCount,
    required int availableItems,
    required int selectedItemCount,
    required String? selectedCategoryName,
    required VoidCallback onAddCategory,
    required VoidCallback? onAddItem,
  }) {
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
                      '메뉴 관리',
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '카테고리를 선택하고 메뉴명, 가격, 판매 상태만 빠르게 관리합니다.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PosColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  OutlinedButton.icon(
                    onPressed: onAddCategory,
                    icon: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 18,
                    ),
                    label: const Text('카테고리 추가'),
                  ),
                  FilledButton.icon(
                    onPressed: onAddItem,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('메뉴 추가'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          ToastMetricStrip(
            metrics: [
              ToastMetric(label: '카테고리', value: '$categoryCount'),
              ToastMetric(label: '메뉴', value: '$itemCount'),
              ToastMetric(
                label: '판매 가능',
                value: '$availableItems',
                tone: PosColors.success,
              ),
              ToastMetric(
                label: '선택 카테고리',
                value: '$selectedItemCount',
                tone: selectedCategoryName == null
                    ? PosColors.textSecondary
                    : PosColors.accent,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              ToastStatusBadge(
                label: '메뉴 구성',
                color: PosColors.accent,
                compact: true,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  selectedCategoryName == null
                      ? '카테고리를 선택하면 오른쪽에서 메뉴를 편집할 수 있습니다.'
                      : '$selectedCategoryName 카테고리의 판매 메뉴를 편집 중입니다.',
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

  String? _categoryNameForId(
    List<Map<String, dynamic>> categories,
    String? categoryId,
  ) {
    if (categoryId == null) {
      return null;
    }

    for (final category in categories) {
      if (category['id']?.toString() == categoryId) {
        return category['name']?.toString() ?? '-';
      }
    }

    return null;
  }

  Future<void> _showAddCategoryDialog(
    BuildContext context,
    MenuNotifier menuNotifier,
  ) async {
    final nameController = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface1,
          title: Text(
            'Add Category',
            style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
          ),
          content: TextField(
            controller: nameController,
            style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
            decoration: const InputDecoration(labelText: 'Category Name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              onPressed: () async {
                final name = nameController.text.trim();
                if (name.isEmpty) {
                  showErrorToast(context, 'Enter a category name.');
                  return;
                }

                final success = await menuNotifier.addCategory(name);
                if (context.mounted) {
                  if (success) {
                    Navigator.of(context).pop();
                    showSuccessToast(context, 'Category "$name" added.');
                  }
                }
              },
              child: const Text('Add'),
            ),
          ],
        );
      },
    );

    nameController.dispose();
  }

  Future<void> _showAddItemDialog(
    BuildContext context,
    String? categoryId,
    MenuNotifier menuNotifier,
  ) async {
    if (categoryId == null) {
      return;
    }

    final nameController = TextEditingController();
    final priceController = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface1,
          title: Text(
            'Add Menu',
            style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                decoration: const InputDecoration(labelText: 'Menu Name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: priceController,
                keyboardType: TextInputType.number,
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                decoration: const InputDecoration(labelText: 'Price'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              onPressed: () async {
                final name = nameController.text.trim();
                final price = double.tryParse(priceController.text.trim());
                if (name.isEmpty || price == null || price <= 0) {
                  showErrorToast(context, 'Enter a valid menu name and price.');
                  return;
                }

                final success = await menuNotifier.addMenuItem(
                  categoryId,
                  name,
                  price,
                );
                if (context.mounted) {
                  if (success) {
                    Navigator.of(context).pop();
                    showSuccessToast(context, 'Menu "$name" added.');
                  }
                }
              },
              child: const Text('Add'),
            ),
          ],
        );
      },
    );

    nameController.dispose();
    priceController.dispose();
  }

  Future<void> _showEditItemDialog(
    BuildContext context,
    Map<String, dynamic> item,
    MenuNotifier menuNotifier,
  ) async {
    final itemId = item['id']?.toString() ?? '';
    if (itemId.isEmpty) {
      return;
    }
    final nameController = TextEditingController(
      text: item['name']?.toString() ?? '',
    );
    final rawPrice = item['price'];
    final initialPrice = switch (rawPrice) {
      num value => value.toDouble(),
      String value => double.tryParse(value) ?? 0,
      _ => 0.0,
    };
    final priceController = TextEditingController(
      text: initialPrice <= 0 ? '' : initialPrice.toStringAsFixed(0),
    );

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface1,
          title: Text(
            'Edit Menu',
            style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                decoration: const InputDecoration(labelText: 'Menu Name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: priceController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: GoogleFonts.notoSansKr(color: AppColors.textPrimary),
                decoration: const InputDecoration(labelText: 'Price'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              onPressed: () async {
                final name = nameController.text.trim();
                final price = double.tryParse(priceController.text.trim());
                if (name.isEmpty || price == null || price <= 0) {
                  showErrorToast(context, 'Enter a valid menu name and price.');
                  return;
                }

                if (name == (item['name']?.toString() ?? '') &&
                    price == initialPrice) {
                  showErrorToast(context, 'No menu changes.');
                  return;
                }

                final success = await menuNotifier.updateMenuItem(
                  itemId: itemId,
                  name: name,
                  price: price,
                );
                if (context.mounted) {
                  if (success) {
                    Navigator.of(context).pop();
                    showSuccessToast(context, 'Menu "$name" saved.');
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    nameController.dispose();
    priceController.dispose();
  }
}

class _CategoryPanel extends StatelessWidget {
  const _CategoryPanel({
    required this.categories,
    required this.selectedCategoryId,
    required this.auditTraceAsync,
    required this.onSelect,
  });

  final List<Map<String, dynamic>> categories;
  final String? selectedCategoryId;
  final AsyncValue<List<Map<String, dynamic>>> auditTraceAsync;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return PosDataPanel(
      title: '카테고리',
      subtitle: '메뉴를 편집할 카테고리를 선택합니다.',
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (categories.isEmpty)
            const Expanded(
              child: PosEmptyState(
                title: '카테고리가 없습니다.',
                subtitle: '첫 카테고리를 추가하면 판매 구성을 시작할 수 있습니다.',
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: categories.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  final category = categories[index];
                  final categoryId = category['id']?.toString() ?? '';
                  final isSelected = categoryId == selectedCategoryId;

                  return PosListRow(
                    selected: isSelected,
                    statusColor: AppColors.amber500,
                    onTap: categoryId.isEmpty
                        ? null
                        : () => onSelect(categoryId),
                    child: Text(
                      category['name']?.toString() ?? '-',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                        fontWeight: isSelected
                            ? FontWeight.w700
                            : FontWeight.w600,
                      ),
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 12),
          _MenuAuditDisclosure(auditTraceAsync: auditTraceAsync),
        ],
      ),
    );
  }
}

class _ItemsPanel extends StatelessWidget {
  const _ItemsPanel({
    required this.selectedItems,
    required this.selectedCategoryId,
    required this.numberFormat,
    required this.onToggleAvailability,
    required this.onEditItem,
  });

  final List<Map<String, dynamic>> selectedItems;
  final String? selectedCategoryId;
  final NumberFormat numberFormat;
  final Future<bool> Function(String itemId, bool isAvailable)
  onToggleAvailability;
  final ValueChanged<Map<String, dynamic>> onEditItem;

  @override
  Widget build(BuildContext context) {
    return PosDataPanel(
      title: '메뉴 목록',
      subtitle: selectedCategoryId == null
          ? '카테고리를 선택하면 메뉴 목록이 표시됩니다.'
          : '메뉴명, 가격, 판매 상태를 한 줄에서 확인합니다.',
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (selectedCategoryId == null)
            const Expanded(
              child: PosEmptyState(
                title: '카테고리를 선택해 주세요.',
                subtitle: '좌측 목록에서 카테고리를 선택하면 메뉴가 표시됩니다.',
                icon: Icons.restaurant_menu_outlined,
              ),
            )
          else if (selectedItems.isEmpty)
            const Expanded(
              child: PosEmptyState(
                title: '등록된 메뉴가 없습니다.',
                subtitle: '첫 메뉴를 추가해 판매 구성을 완성해 주세요.',
                icon: Icons.fastfood_outlined,
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: selectedItems.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final item = selectedItems[index];
                  final itemId = item['id']?.toString() ?? '';
                  final name = item['name']?.toString() ?? '-';
                  final priceRaw = item['price'];
                  final isAvailable = item['is_available'] == true;
                  final priceValue = switch (priceRaw) {
                    num value => value.toDouble(),
                    _ => 0.0,
                  };

                  return Container(
                    decoration: BoxDecoration(
                      color: AppColors.surface1,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.surface3),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.notoSansKr(
                                  color: AppColors.textPrimary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '₫${numberFormat.format(priceValue)}',
                                style: GoogleFonts.notoSansKr(
                                  color: AppColors.textSecondary,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        ToastStatusBadge(
                          label: isAvailable ? '사용' : '중지',
                          color: isAvailable
                              ? PosColors.success
                              : PosColors.textSecondary,
                          compact: true,
                        ),
                        const SizedBox(width: 8),
                        Switch(
                          value: isAvailable,
                          activeThumbColor: AppColors.amber500,
                          onChanged: itemId.isEmpty
                              ? null
                              : (value) async {
                                  final success = await onToggleAvailability(
                                    itemId,
                                    value,
                                  );
                                  if (!context.mounted || !success) return;
                                  showSuccessToast(
                                    context,
                                    value
                                        ? 'Menu "$name" marked as available.'
                                        : 'Menu "$name" marked as sold out.',
                                  );
                                },
                        ),
                        IconButton(
                          onPressed: itemId.isEmpty
                              ? null
                              : () => onEditItem(item),
                          icon: const Icon(
                            Icons.edit_outlined,
                            color: AppColors.textSecondary,
                          ),
                          tooltip: 'Edit Menu',
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

class _MenuAuditDisclosure extends StatelessWidget {
  const _MenuAuditDisclosure({required this.auditTraceAsync});

  final AsyncValue<List<Map<String, dynamic>>> auditTraceAsync;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: ExpansionTile(
        key: const Key('menu_audit_secondary_detail'),
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        iconColor: AppColors.textSecondary,
        collapsedIconColor: AppColors.textSecondary,
        title: Text(
          '최근 변경',
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          '필요할 때만 메뉴 변경 이력을 확인합니다.',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.notoSansKr(
            color: AppColors.textSecondary,
            fontSize: 11,
          ),
        ),
        children: [
          AdminAuditTracePanel(
            auditTraceAsync: auditTraceAsync,
            allowedEntityTypes: const {'menu_categories', 'menu_items'},
            maxItems: 3,
            compact: true,
            emptyMessage: '최근 메뉴 변경 내역이 없습니다.',
          ),
        ],
      ),
    );
  }
}

class _RestaurantMissingView extends StatelessWidget {
  const _RestaurantMissingView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: Center(
        child: Text(
          'Store not found for this account.',
          style: GoogleFonts.notoSansKr(
            color: AppColors.statusCancelled,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
