import 'package:flutter/material.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';

import '../app_theme.dart';
import '../pos_design_tokens.dart';
import 'toast_primitives_extended.dart';

enum ToastSidebarUrgency { live, exception, backOffice }

class ToastSidebarItem {
  const ToastSidebarItem({
    required this.icon,
    required this.label,
    this.urgency = ToastSidebarUrgency.backOffice,
    this.helper,
    this.helperLabel,
    this.badge,
    this.sectionLabel,
    this.onTap,
    this.itemKey,
  });

  final IconData icon;
  final String label;
  final ToastSidebarUrgency urgency;
  final String? helper;
  final String? helperLabel;
  final int? badge;
  final String? sectionLabel;
  final VoidCallback? onTap;
  final Key? itemKey;
}

class ToastSidebarGroup {
  const ToastSidebarGroup({required this.title, required this.items});

  final String title;
  final List<ToastSidebarItem> items;
}

class ToastSidebar extends StatelessWidget {
  const ToastSidebar({
    super.key,
    required this.title,
    required this.groups,
    required this.selectedIndex,
    required this.onItemSelected,
    required this.body,
    this.topBarTrailing,
    this.topBarLeading,
    this.bottomItems,
  });

  final String title;
  final List<ToastSidebarGroup> groups;
  final int selectedIndex;
  final ValueChanged<int> onItemSelected;
  final Widget body;
  final Widget? topBarTrailing;
  final Widget? topBarLeading;
  final List<ToastSidebarItem>? bottomItems;

  List<_ToastSidebarEntry> _entries() {
    final entries = <_ToastSidebarEntry>[];
    var index = 0;
    for (final group in groups) {
      if (group.items.isEmpty) {
        continue;
      }
      for (var groupIndex = 0; groupIndex < group.items.length; groupIndex++) {
        entries.add(
          _ToastSidebarEntry(
            item: group.items[groupIndex],
            flatIndex: index,
            sectionTitle: groupIndex == 0 ? group.title : null,
          ),
        );
        index += 1;
      }
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries();
    final safeIndex = entries.isEmpty
        ? 0
        : selectedIndex.clamp(0, entries.length - 1).toInt();
    final selected = entries.isEmpty ? null : entries[safeIndex];
    final viewport = MediaQuery.sizeOf(context);
    final useCompactShell = viewport.width < 900 || viewport.shortestSide < 600;

    if (useCompactShell) {
      return Scaffold(
        backgroundColor: PosColors.canvas,
        body: SafeArea(
          child: Column(
            children: [
              ToastTopbar(
                title: selected?.item.label ?? title,
                leading: topBarLeading,
                trailing: topBarTrailing,
              ),
              _ToastSidebarCompactNav(
                entries: entries,
                selectedIndex: safeIndex,
                onItemSelected: onItemSelected,
                bottomItems: bottomItems ?? const <ToastSidebarItem>[],
              ),
              Expanded(
                child: ToastWorkSurface(
                  padding: EdgeInsets.zero,
                  backgroundColor: PosColors.canvas,
                  borderColor: Colors.transparent,
                  clip: false,
                  child: body,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: PosColors.canvas,
      body: ToastShell(
        safeArea: false,
        contentPadding: EdgeInsets.zero,
        sidebar: _ToastSidebarRail(
          title: title,
          leading: topBarLeading,
          entries: entries,
          selectedIndex: safeIndex,
          onItemSelected: onItemSelected,
          bottomItems: bottomItems ?? const <ToastSidebarItem>[],
        ),
        topbar: ToastTopbar(
          title: selected?.item.label ?? title,
          trailing: topBarTrailing,
        ),
        child: ToastWorkSurface(
          padding: EdgeInsets.zero,
          backgroundColor: PosColors.canvas,
          borderColor: Colors.transparent,
          clip: false,
          child: body,
        ),
      ),
    );
  }
}

class _ToastSidebarCompactNav extends StatelessWidget {
  const _ToastSidebarCompactNav({
    required this.entries,
    required this.selectedIndex,
    required this.onItemSelected,
    required this.bottomItems,
  });

  final List<_ToastSidebarEntry> entries;
  final int selectedIndex;
  final ValueChanged<int> onItemSelected;
  final List<ToastSidebarItem> bottomItems;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    if (viewport.width < 560 && entries.length > 5) {
      return _ToastSidebarCompactSelectNav(
        entries: entries,
        selectedIndex: selectedIndex,
        onItemSelected: onItemSelected,
        bottomItems: bottomItems,
      );
    }

    final items = <Widget>[
      for (final entry in entries)
        _ToastSidebarCompactNavItem(
          key: entry.item.itemKey,
          icon: entry.item.icon,
          label: entry.item.label,
          selected: entry.flatIndex == selectedIndex,
          onTap: entry.item.onTap ?? () => onItemSelected(entry.flatIndex),
        ),
      for (final item in bottomItems)
        _ToastSidebarCompactNavItem(
          key: item.itemKey,
          icon: item.icon,
          label: item.label,
          selected: false,
          onTap: item.onTap ?? () {},
        ),
    ];

    return SizedBox(
      height: 68,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: PosColors.surface,
          border: Border(bottom: BorderSide(color: PosColors.border)),
        ),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const AlwaysScrollableScrollPhysics(
            parent: ClampingScrollPhysics(),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) => items[index],
        ),
      ),
    );
  }
}

class _ToastSidebarCompactSelectNav extends StatelessWidget {
  const _ToastSidebarCompactSelectNav({
    required this.entries,
    required this.selectedIndex,
    required this.onItemSelected,
    required this.bottomItems,
  });

  final List<_ToastSidebarEntry> entries;
  final int selectedIndex;
  final ValueChanged<int> onItemSelected;
  final List<ToastSidebarItem> bottomItems;

  @override
  Widget build(BuildContext context) {
    final safeValue = entries.any((entry) => entry.flatIndex == selectedIndex)
        ? selectedIndex
        : entries.isEmpty
        ? null
        : entries.first.flatIndex;

    return SizedBox(
      height: 68,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: PosColors.surface,
          border: Border(bottom: BorderSide(color: PosColors.border)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  key: const Key('toast_compact_section_semantics'),
                  container: true,
                  button: true,
                  enabled: entries.isNotEmpty,
                  selected: true,
                  label: safeValue == null
                      ? null
                      : entries
                            .firstWhere((entry) => entry.flatIndex == safeValue)
                            .item
                            .label,
                  child: Container(
                    height: 52,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: PosColors.accentMuted,
                      borderRadius: AppRadius.md,
                      border: Border.all(color: PosColors.accent),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        key: const Key('toast_compact_section_selector'),
                        value: safeValue,
                        isExpanded: true,
                        borderRadius: AppRadius.md,
                        dropdownColor: PosColors.surface,
                        icon: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: PosColors.accent,
                        ),
                        style: AppFonts.system(
                          color: PosColors.textPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                        ),
                        selectedItemBuilder: (context) => [
                          for (final entry in entries)
                            _ToastSidebarCompactSelectLabel(
                              icon: entry.item.icon,
                              label: entry.item.label,
                              selected: true,
                            ),
                        ],
                        items: [
                          for (final entry in entries)
                            DropdownMenuItem<int>(
                              value: entry.flatIndex,
                              child: _ToastSidebarCompactSelectLabel(
                                icon: entry.item.icon,
                                label: entry.item.label,
                                selected: entry.flatIndex == selectedIndex,
                              ),
                            ),
                        ],
                        onChanged: (index) {
                          if (index != null) {
                            onItemSelected(index);
                          }
                        },
                      ),
                    ),
                  ),
                ),
              ),
              for (final item in bottomItems) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: item.label,
                  child: IconButton.filledTonal(
                    key: item.itemKey,
                    onPressed: item.onTap ?? () {},
                    icon: Icon(item.icon),
                    color: PosColors.textSecondary,
                    style: IconButton.styleFrom(
                      fixedSize: const Size(48, 48),
                      backgroundColor: PosColors.mutedSurface,
                      shape: RoundedRectangleBorder(borderRadius: AppRadius.md),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ToastSidebarCompactSelectLabel extends StatelessWidget {
  const _ToastSidebarCompactSelectLabel({
    required this.icon,
    required this.label,
    required this.selected,
  });

  final IconData icon;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = selected ? PosColors.accent : PosColors.textSecondary;
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.system(
              color: selected ? PosColors.text : PosColors.textSecondary,
              fontSize: 13.5,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _ToastSidebarCompactNavItem extends StatelessWidget {
  const _ToastSidebarCompactNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: true,
      selected: selected,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: PosDensity.touchTargetMin,
            ),
            child: Ink(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: selected
                    ? PosColors.accentMuted
                    : PosColors.mutedSurface,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: selected ? PosColors.accent : PosColors.border,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 17,
                    color: selected
                        ? PosColors.accent
                        : PosColors.textSecondary,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.system(
                      color: selected
                          ? PosColors.accent
                          : PosColors.textSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastSidebarEntry {
  const _ToastSidebarEntry({
    required this.item,
    required this.flatIndex,
    this.sectionTitle,
  });

  final ToastSidebarItem item;
  final int flatIndex;
  final String? sectionTitle;
}

class _ToastSidebarRail extends StatelessWidget {
  const _ToastSidebarRail({
    required this.title,
    required this.leading,
    required this.entries,
    required this.selectedIndex,
    required this.onItemSelected,
    required this.bottomItems,
  });

  final String title;
  final Widget? leading;
  final List<_ToastSidebarEntry> entries;
  final int selectedIndex;
  final ValueChanged<int> onItemSelected;
  final List<ToastSidebarItem> bottomItems;

  // Queue-first operational navigation

  @override
  Widget build(BuildContext context) {
    return Container(
      width: ToastShellTokens.sidebarWidth,
      decoration: BoxDecoration(
        color: PosColors.sidebarSurface,
        border: Border(
          right: BorderSide(
            color: PosColors.border,
            width: ToastShellTokens.borderWidth,
          ),
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            decoration: BoxDecoration(
              color: PosColors.sidebarSurface,
              border: const Border(bottom: BorderSide(color: PosColors.border)),
            ),
            child: Row(
              children: [
                if (leading != null) ...[
                  leading!,
                  const SizedBox(width: AppSpacing.sm),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.system(
                          color: PosColors.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              key: const Key('toast_sidebar_rail_list'),
              padding: const EdgeInsets.symmetric(vertical: 10),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                final isSelected = index == selectedIndex;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (entry.sectionTitle != null)
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          16,
                          index == 0 ? 4 : 14,
                          16,
                          6,
                        ),
                        child: Text(
                          entry.sectionTitle!.toUpperCase(),
                          style: AppFonts.system(
                            color: PosColors.textMuted,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.45,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: 2,
                      ),
                      child: _ToastSidebarNavItem(
                        key: entry.item.itemKey,
                        item: entry.item,
                        selected: isSelected,
                        onTap: entry.item.onTap ?? () => onItemSelected(index),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          if (bottomItems.isNotEmpty) ...[
            Container(height: 1, color: PosColors.border),
            const SizedBox(height: AppSpacing.xs),
            for (final item in bottomItems)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: 2,
                ),
                child: _ToastSidebarNavItem(
                  item: item,
                  selected: false,
                  onTap: item.onTap ?? () {},
                ),
              ),
            const SizedBox(height: AppSpacing.xs),
          ],
        ],
      ),
    );
  }
}

class _ToastSidebarNavItem extends StatelessWidget {
  const _ToastSidebarNavItem({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final ToastSidebarItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final highlight = PosColors.accent;
    final helper = item.helperLabel ?? item.helper;

    final row = PosListRow(
      selected: selected,
      minHeight: ToastShellTokens.navItemHeight,
      statusColor: highlight,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            item.icon,
            size: 18,
            color: selected ? highlight : PosColors.textSecondary,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.system(
                color: selected ? PosColors.text : PosColors.textSecondary,
                fontSize: 14,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              ),
            ),
          ),
          if (item.badge != null) ...[
            const SizedBox(width: AppSpacing.xs),
            _ToastSidebarBadge(
              value: item.badge!,
              color: highlight,
              selected: selected,
            ),
          ],
        ],
      ),
    );

    if (helper == null || helper.isEmpty) {
      return row;
    }

    return Tooltip(message: helper, child: row);
  }
}

class _ToastSidebarBadge extends StatelessWidget {
  const _ToastSidebarBadge({
    required this.value,
    required this.color,
    required this.selected,
  });

  final int value;
  final Color color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: selected ? color.withValues(alpha: 0.12) : PosColors.panelMuted,
        borderRadius: ToastRadiusTokens.pill,
        border: Border.all(
          color: selected ? color.withValues(alpha: 0.3) : PosColors.border,
        ),
      ),
      child: Text(
        '$value',
        textAlign: TextAlign.center,
        style: AppFonts.system(
          color: selected ? color : PosColors.textSecondary,
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
