import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

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

    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 900) {
            return Column(
              children: [
                Expanded(
                  flex: 2,
                  child: _CategoryPanel(
                    categories: categories,
                    selectedCategoryId: selectedCategoryId,
                    auditTraceAsync: auditTraceAsync,
                    onSelect: menuNotifier.selectCategory,
                    onAddCategory: () =>
                        _showAddCategoryDialog(context, menuNotifier),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: _ItemsPanel(
                    selectedItems: selectedItems,
                    selectedCategoryId: selectedCategoryId,
                    numberFormat: numberFormat,
                    onToggleAvailability: menuNotifier.toggleAvailability,
                    onEditItem: (item) =>
                        _showEditItemDialog(context, item, menuNotifier),
                    onAddItem: () => _showAddItemDialog(
                      context,
                      selectedCategoryId,
                      menuNotifier,
                    ),
                  ),
                ),
              ],
            );
          }

          return Row(
            children: [
              Expanded(
                flex: 1,
                child: _CategoryPanel(
                  categories: categories,
                  selectedCategoryId: selectedCategoryId,
                  auditTraceAsync: auditTraceAsync,
                  onSelect: menuNotifier.selectCategory,
                  onAddCategory: () =>
                      _showAddCategoryDialog(context, menuNotifier),
                ),
              ),
              Expanded(
                flex: 2,
                child: _ItemsPanel(
                  selectedItems: selectedItems,
                  selectedCategoryId: selectedCategoryId,
                  numberFormat: numberFormat,
                  onToggleAvailability: menuNotifier.toggleAvailability,
                  onEditItem: (item) =>
                      _showEditItemDialog(context, item, menuNotifier),
                  onAddItem: () => _showAddItemDialog(
                    context,
                    selectedCategoryId,
                    menuNotifier,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
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
    required this.onAddCategory,
  });

  final List<Map<String, dynamic>> categories;
  final String? selectedCategoryId;
  final AsyncValue<List<Map<String, dynamic>>> auditTraceAsync;
  final ValueChanged<String> onSelect;
  final VoidCallback onAddCategory;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface0,
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Expanded(
            child: categories.isEmpty
                ? Center(
                    child: Text(
                      'No categories.',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: categories.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final category = categories[index];
                      final categoryId = category['id']?.toString() ?? '';
                      final isSelected = categoryId == selectedCategoryId;

                      return InkWell(
                        onTap: categoryId.isEmpty
                            ? null
                            : () => onSelect(categoryId),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          decoration: BoxDecoration(
                            color: AppColors.surface1,
                            borderRadius: BorderRadius.circular(12),
                            border: Border(
                              left: BorderSide(
                                color: isSelected
                                    ? AppColors.amber500
                                    : Colors.transparent,
                                width: 3,
                              ),
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 14,
                          ),
                          child: Text(
                            category['name']?.toString() ?? '-',
                            style: GoogleFonts.notoSansKr(
                              color: AppColors.textPrimary,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 12),
          Text(
            'Recent Menu Changes',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          AdminAuditTracePanel(
            auditTraceAsync: auditTraceAsync,
            allowedEntityTypes: const {'menu_categories', 'menu_items'},
            maxItems: 3,
            compact: true,
            emptyMessage: 'No recent menu changes.',
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onAddCategory,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              icon: const Icon(Icons.add),
              label: const Text('Add Category'),
            ),
          ),
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
    required this.onAddItem,
  });

  final List<Map<String, dynamic>> selectedItems;
  final String? selectedCategoryId;
  final NumberFormat numberFormat;
  final Future<bool> Function(String itemId, bool isAvailable)
  onToggleAvailability;
  final ValueChanged<Map<String, dynamic>> onEditItem;
  final VoidCallback onAddItem;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface0,
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.amber500,
        onPressed: onAddItem,
        child: const Icon(Icons.add, color: AppColors.surface0),
      ),
      body: Container(
        color: AppColors.surface0,
        padding: const EdgeInsets.all(16),
        child: selectedCategoryId == null
            ? Center(
                child: Text(
                  'Select a category to view menus.',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              )
            : selectedItems.isEmpty
            ? Center(
                child: Text(
                  'No menus. Add your first menu.',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              )
            : ListView.separated(
                itemCount: selectedItems.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
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
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                style: GoogleFonts.notoSansKr(
                                  color: AppColors.textPrimary,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '₫${numberFormat.format(priceValue)}',
                                style: GoogleFonts.notoSansKr(
                                  color: AppColors.textSecondary,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
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
