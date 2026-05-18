import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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
                        style: GoogleFonts.notoSansKr(
                          color: PosColors.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.1,
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
                          style: GoogleFonts.notoSansKr(
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
              style: GoogleFonts.notoSansKr(
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
        style: GoogleFonts.notoSansKr(
          color: selected ? color : PosColors.textSecondary,
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
