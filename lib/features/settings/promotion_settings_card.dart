import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../widgets/error_toast.dart';
import 'promotion_service.dart';

class PromotionSettingsCard extends StatefulWidget {
  const PromotionSettingsCard({super.key, required this.storeId});

  final String storeId;

  @override
  State<PromotionSettingsCard> createState() => _PromotionSettingsCardState();
}

class _PromotionSettingsCardState extends State<PromotionSettingsCard> {
  late Future<List<StorePromotion>> _future = _load();

  Future<List<StorePromotion>> _load() => promotionService.list(widget.storeId);

  void _reload() => setState(() => _future = _load());

  Future<void> _edit([StorePromotion? existing]) async {
    late final List<PromotionMenuItem> menuItems;
    try {
      menuItems = await promotionService.listMenuItems(widget.storeId);
    } catch (error) {
      if (mounted) {
        showErrorToast(
          context,
          '${context.l10n.settingsPromotionSaveFailed}: $error',
        );
      }
      return;
    }
    if (!mounted) return;

    final name = TextEditingController(text: existing?.name ?? '');
    final percent = TextEditingController(
      text: existing?.discountPercent.toStringAsFixed(0) ?? '30',
    );
    final menuSearch = TextEditingController();
    var start = existing?.startsAt ?? DateTime.now();
    var end = existing?.endsAt ?? DateTime.now().add(const Duration(days: 3));
    var scope = existing?.scope ?? promotionScopeAllMenu;
    var menuQuery = '';
    final selectedMenuIds = <String>{...?existing?.menuItemIds};
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          key: const Key('promotion_settings_dialog'),
          title: Text(context.l10n.settingsPromotionTitle),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: InputDecoration(
                      labelText: context.l10n.settingsPromotionName,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: percent,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: context.l10n.settingsPromotionPercent,
                      suffixText: '%',
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: scope,
                    decoration: InputDecoration(
                      labelText: context.l10n.settingsPromotionScope,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: promotionScopeAllMenu,
                        child: Text(context.l10n.settingsPromotionAllMenus),
                      ),
                      DropdownMenuItem(
                        value: promotionScopeSelectedItems,
                        child: Text(
                          context.l10n.settingsPromotionSelectedMenus,
                        ),
                      ),
                    ],
                    onChanged: (value) {
                      setModalState(
                        () => scope = value ?? promotionScopeAllMenu,
                      );
                    },
                  ),
                  if (scope == promotionScopeSelectedItems) ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: menuSearch,
                      onChanged: (value) => setModalState(
                        () => menuQuery = value.trim().toLowerCase(),
                      ),
                      decoration: InputDecoration(
                        labelText: context.l10n.settingsPromotionMenuSearch,
                        prefixIcon: const Icon(Icons.search),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 240,
                      decoration: BoxDecoration(
                        border: Border.all(color: PosColors.border),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Builder(
                        builder: (context) {
                          final languageCode = Localizations.localeOf(
                            context,
                          ).languageCode;
                          final visibleItems = menuItems
                              .where((item) {
                                if (menuQuery.isEmpty) return true;
                                return item
                                        .localizedName(languageCode)
                                        .toLowerCase()
                                        .contains(menuQuery) ||
                                    item.name.toLowerCase().contains(menuQuery);
                              })
                              .toList(growable: false);
                          return ListView.builder(
                            itemCount: visibleItems.length,
                            itemBuilder: (context, index) {
                              final item = visibleItems[index];
                              final selected = selectedMenuIds.contains(
                                item.id,
                              );
                              return CheckboxListTile(
                                key: Key('promotion_menu_${item.id}'),
                                dense: true,
                                value: selected,
                                title: Text(item.localizedName(languageCode)),
                                subtitle: item.isAvailable
                                    ? null
                                    : Text(context.l10n.menuSoldOut),
                                onChanged: (checked) => setModalState(() {
                                  if (checked == true) {
                                    selectedMenuIds.add(item.id);
                                  } else {
                                    selectedMenuIds.remove(item.id);
                                  }
                                }),
                              );
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        context.l10n.settingsPromotionMenuCount(
                          selectedMenuIds.length,
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final date = await showDatePicker(
                              context: context,
                              initialDate: start,
                              firstDate: DateTime.now().subtract(
                                const Duration(days: 365),
                              ),
                              lastDate: DateTime.now().add(
                                const Duration(days: 3650),
                              ),
                            );
                            if (date != null) {
                              setModalState(
                                () => start = DateTime(
                                  date.year,
                                  date.month,
                                  date.day,
                                ),
                              );
                            }
                          },
                          child: Text(
                            '${context.l10n.settingsPromotionStart} ${DateFormat('dd/MM/yyyy').format(start)}',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final date = await showDatePicker(
                              context: context,
                              initialDate: end,
                              firstDate: start,
                              lastDate: DateTime.now().add(
                                const Duration(days: 3650),
                              ),
                            );
                            if (date != null) {
                              setModalState(
                                () => end = DateTime(
                                  date.year,
                                  date.month,
                                  date.day,
                                  23,
                                  59,
                                  59,
                                ),
                              );
                            }
                          },
                          child: Text(
                            '${context.l10n.settingsPromotionEnd} ${DateFormat('dd/MM/yyyy').format(end)}',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () async {
                final value = double.tryParse(percent.text.trim());
                if (name.text.trim().isEmpty ||
                    value == null ||
                    value <= 0 ||
                    value > 100 ||
                    (scope == promotionScopeSelectedItems &&
                        selectedMenuIds.isEmpty) ||
                    !end.isAfter(start)) {
                  if (scope == promotionScopeSelectedItems &&
                      selectedMenuIds.isEmpty) {
                    showErrorToast(
                      dialogContext,
                      dialogContext.l10n.settingsPromotionMenuRequired,
                    );
                  }
                  return;
                }
                try {
                  await promotionService.save(
                    storeId: widget.storeId,
                    id: existing?.id,
                    name: name.text.trim(),
                    discountPercent: value,
                    startsAt: start,
                    endsAt: end,
                    isActive: true,
                    scope: scope,
                    menuItemIds: selectedMenuIds.toList(growable: false),
                  );
                  if (dialogContext.mounted) {
                    Navigator.pop(dialogContext, true);
                  }
                } catch (error) {
                  if (dialogContext.mounted) {
                    showErrorToast(
                      dialogContext,
                      '${dialogContext.l10n.settingsPromotionSaveFailed}: $error',
                    );
                  }
                }
              },
              child: Text(context.l10n.save),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    percent.dispose();
    menuSearch.dispose();
    if (saved == true && mounted) {
      showSuccessToast(context, context.l10n.settingsPromotionSaved);
      _reload();
    }
  }

  Future<void> _deactivate(StorePromotion promotion) async {
    try {
      await promotionService.save(
        storeId: widget.storeId,
        id: promotion.id,
        name: promotion.name,
        discountPercent: promotion.discountPercent,
        startsAt: promotion.startsAt,
        endsAt: promotion.endsAt,
        isActive: false,
        scope: promotion.scope,
        menuItemIds: promotion.menuItemIds,
      );
      _reload();
    } catch (error) {
      if (mounted) {
        showErrorToast(
          context,
          '${context.l10n.settingsPromotionSaveFailed}: $error',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('settings_promotions_section'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: PosColors.panelMuted,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PosColors.border),
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
                      context.l10n.settingsPromotionTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      context.l10n.settingsPromotionSummary,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                key: const Key('settings_promotion_add_action'),
                onPressed: _edit,
                icon: const Icon(Icons.add),
                label: Text(context.l10n.settingsPromotionAdd),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<StorePromotion>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final promotions = snapshot.data ?? const <StorePromotion>[];
              if (promotions.isEmpty) {
                return Text(context.l10n.settingsPromotionEmpty);
              }
              return Column(
                children: [
                  for (final promotion in promotions)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${promotion.name} · '
                        '${promotion.discountPercent.toStringAsFixed(0)}%',
                      ),
                      subtitle: Text(
                        '${DateFormat('dd/MM/yyyy').format(promotion.startsAt)}'
                        ' – '
                        '${DateFormat('dd/MM/yyyy').format(promotion.endsAt)}'
                        ' · '
                        '${promotion.targetsAllMenus ? context.l10n.settingsPromotionAllMenus : context.l10n.settingsPromotionMenuCount(promotion.menuItemIds.length)}',
                      ),
                      trailing: promotion.isActive
                          ? TextButton(
                              onPressed: () => _deactivate(promotion),
                              child: Text(
                                context.l10n.settingsPromotionDeactivate,
                              ),
                            )
                          : ToastStatusBadge(
                              label: context.l10n.settingsPromotionInactive,
                              color: PosColors.textSecondary,
                              compact: true,
                            ),
                      onTap: promotion.isActive ? () => _edit(promotion) : null,
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
