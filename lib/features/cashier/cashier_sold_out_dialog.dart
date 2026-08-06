import 'package:flutter/material.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/services/menu_service.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../widgets/error_toast.dart';

class CashierSoldOutDialog extends StatefulWidget {
  const CashierSoldOutDialog({
    super.key,
    required this.storeId,
    this.menuServiceOverride,
  });

  final String storeId;
  final MenuService? menuServiceOverride;

  @override
  State<CashierSoldOutDialog> createState() => _CashierSoldOutDialogState();
}

class _CashierSoldOutDialogState extends State<CashierSoldOutDialog> {
  List<Map<String, dynamic>> _items = const [];
  final Set<String> _updatingItemIds = <String>{};
  bool _isLoading = true;
  String? _error;

  MenuService get _menuService => widget.menuServiceOverride ?? menuService;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final items = await _menuService.fetchItems(widget.storeId);
      if (!mounted) return;
      setState(() {
        _items = items;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _setAvailability(
    Map<String, dynamic> item,
    bool isAvailable,
  ) async {
    final itemId = item['id']?.toString() ?? '';
    if (itemId.isEmpty || _updatingItemIds.contains(itemId)) return;

    setState(() => _updatingItemIds.add(itemId));
    try {
      await _menuService.toggleAvailability(itemId, isAvailable);
      if (!mounted) return;
      setState(() {
        _items = [
          for (final current in _items)
            if (current['id']?.toString() == itemId)
              {...current, 'is_available': isAvailable}
            else
              current,
        ];
      });
      final name = item['name']?.toString() ?? '-';
      showSuccessToast(
        context,
        isAvailable
            ? context.l10n.menuMarkedAvailable(name)
            : context.l10n.menuMarkedSoldOut(name),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() => _updatingItemIds.remove(itemId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return AlertDialog(
      key: const Key('cashier_sold_out_dialog'),
      title: Text(l10n.menuManagementTitle),
      content: SizedBox(
        width: 620,
        height: 520,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _error != null && _items.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      color: PosColors.danger,
                      size: 36,
                    ),
                    const SizedBox(height: 8),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _loadItems,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(l10n.retry),
                    ),
                  ],
                ),
              )
            : _items.isEmpty
            ? PosEmptyState(
                title: l10n.menuNoItemsTitle,
                subtitle: l10n.menuNoItemsMessage,
                icon: Icons.fastfood_outlined,
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: PosColors.danger),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Expanded(
                    child: ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        final itemId = item['id']?.toString() ?? '';
                        final isAvailable = item['is_available'] == true;
                        final isUpdating = _updatingItemIds.contains(itemId);
                        return ListTile(
                          title: Text(item['name']?.toString() ?? '-'),
                          subtitle: Text(
                            isAvailable ? l10n.menuAvailable : l10n.menuSoldOut,
                          ),
                          trailing: isUpdating
                              ? const SizedBox.square(
                                  dimension: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Switch(
                                  key: Key('cashier_menu_availability_$itemId'),
                                  value: isAvailable,
                                  onChanged: itemId.isEmpty
                                      ? null
                                      : (value) =>
                                            _setAvailability(item, value),
                                ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.close),
        ),
      ],
    );
  }
}
