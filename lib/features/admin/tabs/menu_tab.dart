import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:intl/intl.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../core/ui/pos_design_tokens.dart';
import '../../../core/ui/toast/toast.dart';
import '../../../core/utils/number_input_utils.dart';
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
    final l10n = context.l10n;
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
        key: Key('admin_menu_root'),
        backgroundColor: AppColors.surface0,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.amber500),
        ),
      );
    }

    if (categoriesError || itemsError) {
      return Scaffold(
        key: const Key('admin_menu_root'),
        backgroundColor: AppColors.surface0,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.menuLoadFailed,
                style: AppFonts.system(
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
                child: Text(l10n.retry),
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

    final header = _buildMenuCommandHeader(
      categoryCount: categories.length,
      itemCount: allItems.length,
      availableItems: availableItems,
      selectedItemCount: selectedItems.length,
      selectedCategoryName: _categoryNameForId(categories, selectedCategoryId),
      onAddCategory: () => _showAddCategoryDialog(context, menuNotifier),
      onAddItem: selectedCategoryId == null
          ? null
          : () => _showAddItemDialog(context, selectedCategoryId, menuNotifier),
    );

    Widget categoryPane({required bool scrollable}) => _CategoryPanel(
      categories: categories,
      selectedCategoryId: selectedCategoryId,
      auditTraceAsync: auditTraceAsync,
      scrollable: scrollable,
      onSelect: menuNotifier.selectCategory,
    );

    Widget itemsPane({required bool scrollable}) => _ItemsPanel(
      selectedItems: selectedItems,
      selectedCategoryId: selectedCategoryId,
      numberFormat: numberFormat,
      scrollable: scrollable,
      onToggleAvailability: menuNotifier.toggleAvailability,
      onEditItem: (item) => _showEditItemDialog(context, item, menuNotifier),
    );

    return Scaffold(
      key: const Key('admin_menu_root'),
      backgroundColor: AppColors.surface0,
      body: LayoutBuilder(
        builder: (context, viewport) {
          if (viewport.maxWidth < 960) {
            return ToastResponsiveScrollBody(
              maxWidth: 1420,
              padding: const EdgeInsets.all(16),
              children: [
                header,
                const SizedBox(height: 16),
                categoryPane(scrollable: false),
                const SizedBox(height: 16),
                itemsPane(scrollable: false),
              ],
            );
          }

          return ToastResponsiveBody(
            maxWidth: 1420,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                const SizedBox(height: 16),
                Expanded(
                  child: ToastSplitPane(
                    queueWidth: 360,
                    queue: categoryPane(scrollable: true),
                    detail: itemsPane(scrollable: true),
                    divider: false,
                  ),
                ),
              ],
            ),
          );
        },
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
                      context.l10n.menuManagementTitle,
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.l10n.menuManagementSubtitle,
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
                    label: Text(context.l10n.menuAddCategory),
                  ),
                  FilledButton.icon(
                    onPressed: onAddItem,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(context.l10n.menuAddMenu),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          ToastMetricStrip(
            metrics: [
              ToastMetric(
                label: context.l10n.menuCategoriesMetric,
                value: '$categoryCount',
              ),
              ToastMetric(
                label: context.l10n.menuItemsMetric,
                value: '$itemCount',
              ),
              ToastMetric(
                label: context.l10n.menuAvailableItemsMetric,
                value: '$availableItems',
                tone: PosColors.success,
              ),
              ToastMetric(
                label: context.l10n.menuSelectedCategoryMetric,
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
                label: context.l10n.menuConfiguration,
                color: PosColors.accent,
                compact: true,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  selectedCategoryName == null
                      ? context.l10n.menuSelectCategoryEditHint
                      : context.l10n.menuEditingCategory(selectedCategoryName),
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
    final l10n = context.l10n;
    final nameController = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface1,
          title: Text(
            l10n.menuAddCategory,
            style: AppFonts.system(color: AppColors.textPrimary),
          ),
          content: TextField(
            controller: nameController,
            style: AppFonts.system(color: AppColors.textPrimary),
            decoration: InputDecoration(labelText: l10n.menuCategoryName),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              onPressed: () async {
                final name = nameController.text.trim();
                if (name.isEmpty) {
                  showErrorToast(context, l10n.menuEnterCategoryName);
                  return;
                }

                final success = await menuNotifier.addCategory(name);
                if (context.mounted) {
                  if (success) {
                    Navigator.of(context).pop();
                    showSuccessToast(context, l10n.menuCategoryAdded(name));
                  }
                }
              },
              child: Text(l10n.add),
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

    final l10n = context.l10n;
    final nameController = TextEditingController();
    final priceController = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface1,
          title: Text(
            l10n.menuAddMenu,
            style: AppFonts.system(color: AppColors.textPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                style: AppFonts.system(color: AppColors.textPrimary),
                decoration: InputDecoration(labelText: l10n.menuMenuName),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: priceController,
                keyboardType: TextInputType.number,
                style: AppFonts.system(color: AppColors.textPrimary),
                decoration: InputDecoration(labelText: l10n.menuPrice),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              onPressed: () async {
                final name = nameController.text.trim();
                final price = parseDecimalInput(priceController.text);
                if (name.isEmpty || price == null || price <= 0) {
                  showErrorToast(context, l10n.menuEnterValidNameAndPrice);
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
                    showSuccessToast(context, l10n.menuAdded(name));
                  }
                }
              },
              child: Text(l10n.add),
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
    final l10n = context.l10n;
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
      String value => parseDecimalInput(value) ?? 0,
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
            l10n.menuEditMenu,
            style: AppFonts.system(color: AppColors.textPrimary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                style: AppFonts.system(color: AppColors.textPrimary),
                decoration: InputDecoration(labelText: l10n.menuMenuName),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: priceController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: AppFonts.system(color: AppColors.textPrimary),
                decoration: InputDecoration(labelText: l10n.menuPrice),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              onPressed: () async {
                final name = nameController.text.trim();
                final price = parseDecimalInput(priceController.text);
                if (name.isEmpty || price == null || price <= 0) {
                  showErrorToast(context, l10n.menuEnterValidNameAndPrice);
                  return;
                }

                if (name == (item['name']?.toString() ?? '') &&
                    price == initialPrice) {
                  showErrorToast(context, l10n.noChanges);
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
                    showSuccessToast(context, l10n.menuSaved(name));
                  }
                }
              },
              child: Text(l10n.save),
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
    this.scrollable = true,
  });

  final List<Map<String, dynamic>> categories;
  final String? selectedCategoryId;
  final AsyncValue<List<Map<String, dynamic>>> auditTraceAsync;
  final ValueChanged<String> onSelect;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final categoryBody = categories.isEmpty
        ? PosEmptyState(
            title: l10n.menuNoCategories,
            subtitle: l10n.menuCreateRailFirst,
          )
        : ListView.separated(
            shrinkWrap: !scrollable,
            physics: scrollable ? null : const NeverScrollableScrollPhysics(),
            itemCount: categories.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final category = categories[index];
              final categoryId = category['id']?.toString() ?? '';
              final isSelected = categoryId == selectedCategoryId;

              return PosListRow(
                selected: isSelected,
                statusColor: AppColors.amber500,
                onTap: categoryId.isEmpty ? null : () => onSelect(categoryId),
                child: Text(
                  category['name']?.toString() ?? '-',
                  style: AppFonts.system(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              );
            },
          );

    return PosDataPanel(
      title: l10n.menuCategoriesMetric,
      subtitle: l10n.menuCategoryPanelSubtitle,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (scrollable) Expanded(child: categoryBody) else categoryBody,
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
    this.scrollable = true,
  });

  final List<Map<String, dynamic>> selectedItems;
  final String? selectedCategoryId;
  final NumberFormat numberFormat;
  final Future<bool> Function(String itemId, bool isAvailable)
  onToggleAvailability;
  final ValueChanged<Map<String, dynamic>> onEditItem;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    Widget panelBody(Widget child) =>
        scrollable ? Expanded(child: child) : child;

    return PosDataPanel(
      title: l10n.menuItemsPanelTitle,
      subtitle: selectedCategoryId == null
          ? l10n.menuItemsSelectCategorySubtitle
          : l10n.menuItemsReadySubtitle,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (selectedCategoryId == null)
            panelBody(
              PosEmptyState(
                title: l10n.menuSelectCategoryTitle,
                subtitle: l10n.menuSelectCategoryMessage,
                icon: Icons.restaurant_menu_outlined,
              ),
            )
          else if (selectedItems.isEmpty)
            panelBody(
              PosEmptyState(
                title: l10n.menuNoItemsTitle,
                subtitle: l10n.menuNoItemsMessage,
                icon: Icons.fastfood_outlined,
              ),
            )
          else
            panelBody(
              ListView.separated(
                shrinkWrap: !scrollable,
                physics: scrollable
                    ? null
                    : const NeverScrollableScrollPhysics(),
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
                                style: AppFonts.system(
                                  color: AppColors.textPrimary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '₫${numberFormat.format(priceValue)}',
                                style: AppFonts.system(
                                  color: AppColors.textSecondary,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        ToastStatusBadge(
                          label: isAvailable
                              ? l10n.menuAvailable
                              : l10n.menuSoldOut,
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
                                        ? l10n.menuMarkedAvailable(name)
                                        : l10n.menuMarkedSoldOut(name),
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
                          tooltip: l10n.menuEditMenu,
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
    final l10n = context.l10n;
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
          l10n.changeHistory,
          style: AppFonts.system(
            color: AppColors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          l10n.menuRecentChangesHint,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppFonts.system(
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
            emptyMessage: l10n.menuNoRecentChanges,
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
          context.l10n.menuNoLinkedStoreMessage,
          style: AppFonts.system(
            color: AppColors.statusCancelled,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
