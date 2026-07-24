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
  const PhotoInventoryScreen({super.key, this.autoLoad = true, this.service});

  final bool autoLoad;
  final InventoryService? service;

  @override
  ConsumerState<PhotoInventoryScreen> createState() =>
      _PhotoInventoryScreenState();
}

class _PhotoInventoryScreenState extends ConsumerState<PhotoInventoryScreen> {
  String? _loadedStoreId;
  InventoryService get _inventoryService => widget.service ?? inventoryService;

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
              canViewHistory: storeId != null,
              onAdd: storeId == null
                  ? null
                  : () => _showItemDialog(storeId: storeId),
              onHistory: storeId == null
                  ? null
                  : () => _showAdjustmentHistory(storeId),
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
    final noteController = TextEditingController();
    var countDate = DateTime.now();
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
              await _inventoryService.upsertPhotoObjetInventoryItem(
                storeId: storeId,
                itemId: initial?['id']?.toString(),
                name: name,
                currentStock: stock,
                countDate: countDate,
                note: noteController.text,
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
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: const Key('photo_inventory_count_date'),
                      onPressed: isSaving
                          ? null
                          : () async {
                              final picked = await showDatePicker(
                                context: dialogContext,
                                initialDate: countDate,
                                firstDate: DateTime(2020),
                                lastDate: DateTime.now(),
                              );
                              if (picked == null) return;
                              setDialogState(
                                () => countDate = DateTime(
                                  picked.year,
                                  picked.month,
                                  picked.day,
                                ),
                              );
                            },
                      icon: const Icon(Icons.event_outlined),
                      label: Text(
                        context.l10n.inventoryCountDate(
                          DateFormat('yyyy-MM-dd').format(countDate),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('photo_inventory_adjustment_note'),
                      controller: noteController,
                      enabled: !isSaving,
                      maxLength: 200,
                      decoration: InputDecoration(
                        labelText: context.l10n.inventoryMemoOptional,
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
      noteController.dispose();
    });
  }

  Future<void> _showAdjustmentHistory(String storeId) async {
    var range = DateTimeRange(
      start: DateTime.now().subtract(const Duration(days: 29)),
      end: DateTime.now(),
    );
    late Future<List<Map<String, dynamic>>> history;

    Future<List<Map<String, dynamic>>> load() =>
        _inventoryService.fetchInventoryAdjustmentHistory(
          storeId: storeId,
          from: range.start,
          to: range.end,
        );

    history = load();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          key: const Key('photo_inventory_history_dialog'),
          backgroundColor: AppColors.surface1,
          title: Text(context.l10n.inventoryAdjustmentHistory),
          content: SizedBox(
            width: 620,
            height: 520,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const Key('photo_inventory_history_date_range'),
                    onPressed: () async {
                      final picked = await showDateRangePicker(
                        context: dialogContext,
                        initialDateRange: range,
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now(),
                      );
                      if (picked == null) return;
                      setDialogState(() {
                        range = picked;
                        history = load();
                      });
                    },
                    icon: const Icon(Icons.date_range_outlined),
                    label: Text(
                      '${DateFormat('yyyy-MM-dd').format(range.start)}'
                      ' – ${DateFormat('yyyy-MM-dd').format(range.end)}',
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: FutureBuilder<List<Map<String, dynamic>>>(
                    future: history,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(
                          child: CircularProgressIndicator(
                            color: PosColors.accent,
                          ),
                        );
                      }
                      if (snapshot.hasError) {
                        return _PhotoInventoryEmptyState(
                          icon: Icons.error_outline,
                          title: context.l10n.inventoryHistoryLoadFailed,
                          message: snapshot.error.toString(),
                          actionLabel: context.l10n.retry,
                          onAction: () =>
                              setDialogState(() => history = load()),
                        );
                      }
                      final rows = snapshot.data ?? const [];
                      if (rows.isEmpty) {
                        return Center(
                          child: Text(
                            context.l10n.inventoryHistoryEmpty,
                            textAlign: TextAlign.center,
                          ),
                        );
                      }
                      return ListView.separated(
                        key: const Key('photo_inventory_history_list'),
                        itemCount: rows.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) =>
                            _PhotoInventoryHistoryRow(row: rows[index]),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(context.l10n.close),
            ),
          ],
        ),
      ),
    );
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
    required this.canViewHistory,
    required this.onAdd,
    required this.onHistory,
  });

  final int itemCount;
  final bool canAdd;
  final bool canViewHistory;
  final VoidCallback? onAdd;
  final VoidCallback? onHistory;

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
                IconButton(
                  key: const Key('photo_inventory_history'),
                  onPressed: canViewHistory ? onHistory : null,
                  tooltip: context.l10n.inventoryAdjustmentHistory,
                  icon: const Icon(Icons.history, size: 20),
                )
              else
                OutlinedButton.icon(
                  key: const Key('photo_inventory_history'),
                  onPressed: canViewHistory ? onHistory : null,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.history, size: 18),
                  label: Text(context.l10n.inventoryAdjustmentHistory),
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

class _PhotoInventoryHistoryRow extends StatelessWidget {
  const _PhotoInventoryHistoryRow({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final unit = row['ingredient_unit']?.toString() ?? 'ea';
    final before = _nullableNumber(row['stock_before']);
    final after = _nullableNumber(row['stock_after']);
    final change = _number(row['quantity_change']);
    final date = row['effective_date']?.toString() ?? '-';
    final actor = row['recorded_by_name']?.toString() ?? '-';
    final recordedAt = DateTime.tryParse(
      row['recorded_at']?.toString() ?? '',
    )?.toLocal();
    final note = row['note']?.toString().trim() ?? '';

    return ListTile(
      key: ValueKey('photo_inventory_history_${row['transaction_id']}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      title: Row(
        children: [
          Expanded(
            child: Text(
              row['ingredient_name']?.toString() ?? '-',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Text(date, style: Theme.of(context).textTheme.labelMedium),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(
            before == null || after == null
                ? context.l10n.inventoryHistoryChangeOnly(
                    _signedQuantity(change),
                    unit,
                  )
                : context.l10n.inventoryHistoryQuantityChange(
                    _formatQuantity(before),
                    _formatQuantity(after),
                    _signedQuantity(change),
                    unit,
                  ),
          ),
          Text(
            context.l10n.inventoryHistoryRecordedBy(
              actor,
              recordedAt == null
                  ? date
                  : DateFormat('yyyy-MM-dd HH:mm').format(recordedAt),
            ),
          ),
          if (note.isNotEmpty) Text(note),
        ],
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

double? _nullableNumber(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

String _signedQuantity(double value) {
  final formatted = _formatQuantity(value.abs());
  if (value > 0) return '+$formatted';
  if (value < 0) return '-$formatted';
  return formatted;
}

String _formatQuantity(double value) => NumberFormat('#,##0.###').format(value);
