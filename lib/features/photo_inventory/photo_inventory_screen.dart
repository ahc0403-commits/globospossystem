import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/services/inventory_service.dart';
import '../../core/ui/app_theme.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/inventory/inventory_provider.dart';

class PhotoInventoryScreen extends ConsumerStatefulWidget {
  const PhotoInventoryScreen({super.key, this.autoLoad = true});

  final bool autoLoad;

  @override
  ConsumerState<PhotoInventoryScreen> createState() =>
      _PhotoInventoryScreenState();
}

class _PhotoInventoryScreenState extends ConsumerState<PhotoInventoryScreen> {
  String? _loadedStoreId;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final storeId = auth.storeId;
    final state = ref.watch(ingredientProvider);

    if (widget.autoLoad && storeId != null && storeId != _loadedStoreId) {
      _loadedStoreId = storeId;
      Future.microtask(
        () => ref.read(ingredientProvider.notifier).load(storeId),
      );
    }

    return Scaffold(
      key: const Key('photo_inventory_root'),
      backgroundColor: AppColors.surface0,
      body: ToastResponsiveBody(
        maxWidth: 1180,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PhotoInventoryHeader(
              itemCount: state.items.length,
              canAdd: storeId != null && !state.isLoading,
              onAdd: storeId == null
                  ? null
                  : () => _showItemDialog(storeId: storeId),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ToastWorkSurface(
                padding: const EdgeInsets.all(12),
                child: _buildInventoryList(state: state, storeId: storeId),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInventoryList({
    required IngredientState state,
    required String? storeId,
  }) {
    if (storeId == null) {
      return Center(child: Text(context.l10n.photoOpsNoActiveStore));
    }

    if (state.isLoading && state.items.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: PosColors.accent),
      );
    }

    if (state.error != null && state.items.isEmpty) {
      return _PhotoInventoryEmptyState(
        icon: Icons.error_outline,
        title: context.l10n.inventoryFailedLoadIngredientCatalog,
        message: state.error!,
        actionLabel: context.l10n.retry,
        onAction: () => ref.read(ingredientProvider.notifier).load(storeId),
      );
    }

    if (state.items.isEmpty) {
      return _PhotoInventoryEmptyState(
        icon: Icons.inventory_2_outlined,
        title: context.l10n.inventoryNoIngredientsRegistered,
        message: context.l10n.inventoryStartCatalogByAddingIngredient,
        actionLabel: context.l10n.inventoryAddIngredientAction,
        onAction: () => _showItemDialog(storeId: storeId),
      );
    }

    return RefreshIndicator(
      color: PosColors.accent,
      onRefresh: () => ref.read(ingredientProvider.notifier).load(storeId),
      child: ListView.separated(
        key: const Key('photo_inventory_item_list'),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: state.items.length + (state.error == null ? 0 : 1),
        separatorBuilder: (_, __) =>
            const Divider(height: 1, color: AppColors.surface3),
        itemBuilder: (context, index) {
          if (state.error != null && index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _InlineError(message: state.error!),
            );
          }
          final itemIndex = index - (state.error == null ? 0 : 1);
          final item = state.items[itemIndex];
          return _PhotoInventoryItemRow(
            item: item,
            onEdit: () => _showItemDialog(storeId: storeId, initial: item),
          );
        },
      ),
    );
  }

  Future<void> _showItemDialog({
    required String storeId,
    Map<String, dynamic>? initial,
  }) async {
    final editing = initial != null;
    final nameController = TextEditingController(
      text: initial?['name']?.toString() ?? '',
    );
    final stockController = TextEditingController(
      text: editing ? _formatQuantity(_number(initial['current_stock'])) : '',
    );
    String? validationMessage;
    bool isSaving = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: !isSaving,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> save() async {
            final name = nameController.text.trim();
            final stock = double.tryParse(
              stockController.text.trim().replaceAll(',', ''),
            );
            if (name.isEmpty) {
              setDialogState(
                () => validationMessage =
                    context.l10n.inventoryPurchaseProductNameRequired,
              );
              return;
            }
            if (stock == null || stock < 0) {
              setDialogState(
                () => validationMessage =
                    context.l10n.inventoryActualStockNonNegative,
              );
              return;
            }

            setDialogState(() {
              validationMessage = null;
              isSaving = true;
            });
            try {
              await inventoryService.upsertPhotoObjetInventoryItem(
                storeId: storeId,
                itemId: initial?['id']?.toString(),
                name: name,
                currentStock: stock,
              );
              await ref.read(ingredientProvider.notifier).load(storeId);
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    editing
                        ? context.l10n.inventoryIngredientSaved
                        : context.l10n.inventoryIngredientAdded,
                  ),
                ),
              );
            } catch (error) {
              if (!dialogContext.mounted) return;
              setDialogState(() {
                isSaving = false;
                validationMessage = _saveErrorMessage(error);
              });
            }
          }

          return AlertDialog(
            key: const Key('photo_inventory_item_dialog'),
            backgroundColor: AppColors.surface1,
            title: Text(
              editing
                  ? context.l10n.inventoryEditIngredient
                  : context.l10n.inventoryAddIngredient,
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const Key('photo_inventory_item_name'),
                      controller: nameController,
                      enabled: !isSaving,
                      autofocus: true,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: context.l10n.inventoryPurchaseProductName,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('photo_inventory_current_stock'),
                      controller: stockController,
                      enabled: !isSaving,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => isSaving ? null : save(),
                      decoration: InputDecoration(
                        labelText: context.l10n.inventoryCurrentStock,
                      ),
                    ),
                    if (validationMessage != null) ...[
                      const SizedBox(height: 10),
                      _InlineError(message: validationMessage!),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSaving
                    ? null
                    : () => Navigator.of(dialogContext).pop(),
                child: Text(context.l10n.cancel),
              ),
              FilledButton(
                key: const Key('photo_inventory_save'),
                onPressed: isSaving ? null : save,
                child: isSaving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(context.l10n.save),
              ),
            ],
          );
        },
      ),
    );

    // The dialog route keeps painting its outgoing transition briefly after
    // `showDialog` resolves. Dispose after that transition so TextFields never
    // rebuild against an already-disposed controller.
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      nameController.dispose();
      stockController.dispose();
    });
  }

  String _saveErrorMessage(Object error) {
    final message = error.toString();
    if (message.contains('PHOTO_INVENTORY_NAME_DUPLICATE')) {
      return context.l10n.inventoryAddIngredientFailed;
    }
    if (message.contains('PHOTO_INVENTORY_WRITE_FORBIDDEN') ||
        message.contains('PHOTO_INVENTORY_STORE_FORBIDDEN') ||
        message.contains('ADMIN_MUTATION_FORBIDDEN')) {
      return context.l10n.inventoryAddIngredientFailed;
    }
    return context.l10n.inventoryAddIngredientFailed;
  }
}

class _PhotoInventoryHeader extends StatelessWidget {
  const _PhotoInventoryHeader({
    required this.itemCount,
    required this.canAdd,
    required this.onAdd,
  });

  final int itemCount;
  final bool canAdd;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return ToastWorkSurface(
      key: const Key('photo_inventory_header'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      backgroundColor: AppColors.surface1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxWidth < 600 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.5;
          return Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.inventoryPurchaseStockStatusTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              ToastStatusBadge(
                label: context.l10n.inventoryPurchaseCountItems(itemCount),
                color: PosColors.info,
                compact: true,
              ),
              const SizedBox(width: 8),
              if (compact)
                IconButton.filled(
                  key: const Key('photo_inventory_add_item'),
                  onPressed: canAdd ? onAdd : null,
                  tooltip: context.l10n.inventoryAddIngredientAction,
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(36),
                    maximumSize: const Size.square(36),
                    padding: const EdgeInsets.all(6),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.add, size: 20),
                )
              else
                FilledButton.icon(
                  key: const Key('photo_inventory_add_item'),
                  onPressed: canAdd ? onAdd : null,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(context.l10n.inventoryAddIngredientAction),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _PhotoInventoryItemRow extends StatelessWidget {
  const _PhotoInventoryItemRow({required this.item, required this.onEdit});

  final Map<String, dynamic> item;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final stock = _number(item['current_stock']);
    final unit = item['unit']?.toString() ?? 'ea';
    return ListTile(
      key: ValueKey('photo_inventory_item_${item['id']}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      leading: const CircleAvatar(
        backgroundColor: AppColors.surface2,
        foregroundColor: PosColors.accent,
        child: Icon(Icons.inventory_2_outlined),
      ),
      title: Text(
        item['name']?.toString() ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        context.l10n.inventoryStockWithUnit(_formatQuantity(stock), unit),
      ),
      trailing: IconButton(
        key: ValueKey('photo_inventory_edit_${item['id']}'),
        onPressed: onEdit,
        tooltip: context.l10n.inventoryEditIngredient,
        icon: const Icon(Icons.edit_outlined),
      ),
    );
  }
}

class _PhotoInventoryEmptyState extends StatelessWidget {
  const _PhotoInventoryEmptyState({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: PosColors.textSecondary),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: PosColors.textSecondary),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.add),
              label: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: PosColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PosColors.danger.withValues(alpha: 0.35)),
      ),
      child: Text(
        message,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: PosColors.danger),
      ),
    );
  }
}

double _number(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

String _formatQuantity(double value) => NumberFormat('#,##0.###').format(value);
