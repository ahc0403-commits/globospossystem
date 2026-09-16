import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../widgets/error_toast.dart';
import 'promotion_service.dart';

class PromotionSettingsCard extends StatefulWidget {
  const PromotionSettingsCard({super.key, required this.storeId, this.service});

  final String storeId;
  final PromotionService? service;

  @override
  State<PromotionSettingsCard> createState() => _PromotionSettingsCardState();
}

class _PromotionSettingsCardState extends State<PromotionSettingsCard> {
  late Future<List<StorePromotion>> _future = _load();
  late Future<QrTakeoutAvailability> _takeoutFuture = _loadTakeout();
  bool _isSavingTakeout = false;

  PromotionService get _service => widget.service ?? promotionService;

  Future<List<StorePromotion>> _load() => _service.list(widget.storeId);

  Future<QrTakeoutAvailability> _loadTakeout() =>
      _service.getQrTakeoutAvailability(widget.storeId);

  void _reload() => setState(() {
    _future = _load();
    _takeoutFuture = _loadTakeout();
  });

  Future<void> _setTakeoutAvailability(
    bool enabled, {
    DateTime? resumeAt,
  }) async {
    if (_isSavingTakeout) return;
    setState(() => _isSavingTakeout = true);
    try {
      final setting = await _service.setQrTakeoutAvailability(
        storeId: widget.storeId,
        enabled: enabled,
        resumeAt: resumeAt,
      );
      if (!mounted) return;
      setState(() => _takeoutFuture = Future.value(setting));
      showSuccessToast(context, context.l10n.settingsQrTakeoutSaved);
    } catch (error) {
      if (mounted) {
        showErrorToast(
          context,
          '${context.l10n.settingsQrTakeoutSaveFailed}: $error',
        );
      }
    } finally {
      if (mounted) setState(() => _isSavingTakeout = false);
    }
  }

  Future<void> _scheduleTakeoutResume(QrTakeoutAvailability setting) async {
    final now = DateTime.now();
    var selected = setting.resumeAt?.isAfter(now) == true
        ? setting.resumeAt!
        : DateTime(now.year, now.month, now.day + 1);
    String? validationMessage;
    final resumeAt = await showDialog<DateTime>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          key: const Key('settings_qr_takeout_resume_dialog'),
          title: Text(context.l10n.settingsQrTakeoutScheduleDialogTitle),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('settings_qr_takeout_resume_date'),
                        onPressed: () async {
                          final date = await showDatePicker(
                            context: context,
                            initialDate: selected,
                            firstDate: DateTime(now.year, now.month, now.day),
                            lastDate: DateTime(now.year + 10),
                          );
                          if (date == null) return;
                          setModalState(() {
                            selected = DateTime(
                              date.year,
                              date.month,
                              date.day,
                              selected.hour,
                              selected.minute,
                            );
                            validationMessage = null;
                          });
                        },
                        icon: const Icon(Icons.calendar_today_outlined),
                        label: Text(
                          '${context.l10n.settingsQrTakeoutResumeDate}\n'
                          '${DateFormat('dd/MM/yyyy').format(selected)}',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('settings_qr_takeout_resume_time'),
                        onPressed: () async {
                          final time = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay.fromDateTime(selected),
                          );
                          if (time == null) return;
                          setModalState(() {
                            selected = DateTime(
                              selected.year,
                              selected.month,
                              selected.day,
                              time.hour,
                              time.minute,
                            );
                            validationMessage = null;
                          });
                        },
                        icon: const Icon(Icons.schedule_outlined),
                        label: Text(
                          '${context.l10n.settingsQrTakeoutResumeTime}\n'
                          '${DateFormat('HH:mm').format(selected)}',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ],
                ),
                if (validationMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    validationMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              key: const Key('settings_qr_takeout_resume_save'),
              onPressed: () {
                if (!selected.isAfter(DateTime.now())) {
                  setModalState(
                    () => validationMessage =
                        context.l10n.settingsQrTakeoutFutureRequired,
                  );
                  return;
                }
                Navigator.pop(dialogContext, selected);
              },
              child: Text(context.l10n.save),
            ),
          ],
        ),
      ),
    );
    if (resumeAt != null && mounted) {
      await _setTakeoutAvailability(false, resumeAt: resumeAt);
    }
  }

  Future<void> _edit([StorePromotion? existing]) async {
    late final List<PromotionMenuItem> menuItems;
    try {
      menuItems = await _service.listMenuItems(widget.storeId);
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
                  await _service.save(
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
      await _service.save(
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
          FutureBuilder<QrTakeoutAvailability>(
            future: _takeoutFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final setting = snapshot.data;
              if (setting == null) {
                return Row(
                  children: [
                    Expanded(
                      child: Text(context.l10n.settingsQrTakeoutSaveFailed),
                    ),
                    IconButton(
                      key: const Key('settings_qr_takeout_retry'),
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh_outlined),
                    ),
                  ],
                );
              }
              final resumeLabel = setting.resumeAt == null
                  ? context.l10n.settingsQrTakeoutNoAutoResume
                  : context.l10n.settingsQrTakeoutResumeAt(
                      DateFormat('dd/MM/yyyy HH:mm').format(setting.resumeAt!),
                    );
              return Container(
                key: const Key('settings_qr_takeout_control'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: PosColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: PosColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile(
                      key: const Key('settings_qr_takeout_toggle'),
                      contentPadding: EdgeInsets.zero,
                      value: setting.effectiveEnabled,
                      onChanged: _isSavingTakeout
                          ? null
                          : (enabled) => _setTakeoutAvailability(enabled),
                      title: Text(context.l10n.settingsQrTakeoutTitle),
                      subtitle: Text(context.l10n.settingsQrTakeoutSummary),
                      secondary: _isSavingTakeout
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              setting.effectiveEnabled
                                  ? Icons.takeout_dining_outlined
                                  : Icons.hide_source_outlined,
                            ),
                    ),
                    Row(
                      children: [
                        ToastStatusBadge(
                          key: const Key('settings_qr_takeout_status'),
                          label: setting.effectiveEnabled
                              ? context.l10n.settingsQrTakeoutEnabled
                              : context.l10n.settingsQrTakeoutDisabled,
                          color: setting.effectiveEnabled
                              ? PosColors.success
                              : PosColors.warning,
                          compact: true,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            setting.effectiveEnabled ? '' : resumeLabel,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                    if (!setting.effectiveEnabled) ...[
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          key: const Key('settings_qr_takeout_schedule_resume'),
                          onPressed: _isSavingTakeout
                              ? null
                              : () => _scheduleTakeoutResume(setting),
                          icon: const Icon(Icons.event_repeat_outlined),
                          label: Text(
                            context.l10n.settingsQrTakeoutScheduleResume,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
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
