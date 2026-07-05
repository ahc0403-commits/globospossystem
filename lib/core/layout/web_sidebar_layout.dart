import 'package:flutter/material.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';

import '../ui/app_theme.dart';
import '../ui/pos_design_tokens.dart';
import '../ui/toast/toast_primitives_extended.dart';
import '../../widgets/language_switcher.dart';

class SidebarItem {
  const SidebarItem({
    required this.icon,
    required this.label,
    this.onTap,
    this.itemKey,
    this.targetIndex = 0,
    this.workflowKey = '',
    this.sectionLabel,
    this.helperLabel,
    this.badge,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Key? itemKey;

  /// Wave 1.5 shell migration: target index this item resolves to in the
  /// host workflow grid. Stored but not rendered by the current
  /// `WebSidebarLayout` build; callers that need it (e.g. the upcoming
  /// shell-wave web sidebar) read it directly.
  final int targetIndex;

  /// Wave 1.5 shell migration: workflow grouping key (e.g. "service",
  /// "back_office"). Stored but not rendered today.
  final String workflowKey;

  /// Wave 1.5 shell migration: optional section header label inlined
  /// above this item.
  final String? sectionLabel;

  /// Wave 1.5 shell migration: secondary helper string under the label.
  final String? helperLabel;

  /// Wave 1.5 shell migration: optional provider-backed badge widget
  /// (e.g. a count chip).
  final Widget? badge;
}

class WebSidebarLayout extends StatelessWidget {
  const WebSidebarLayout({
    super.key,
    required this.title,
    required this.items,
    required this.selectedIndex,
    required this.onItemSelected,
    required this.body,
    this.topBarTrailing,
    this.topBarLeading,
    this.bottomItems,
    this.groupHeaders,
  });

  final String title;
  final List<SidebarItem> items;
  final int selectedIndex;
  final ValueChanged<int> onItemSelected;
  final Widget body;
  final Widget? topBarTrailing;
  final Widget? topBarLeading;
  final List<SidebarItem>? bottomItems;

  /// Optional map from item index to a group-header label that should be
  /// rendered immediately above that item. Non-interactive. Indices that
  /// are not keys render no header. Selection / [onItemSelected] indexing
  /// is unaffected.
  final Map<int, String>? groupHeaders;

  @override
  Widget build(BuildContext context) {
    final selectedLabel = items.isNotEmpty && selectedIndex < items.length
        ? items[selectedIndex].label
        : '';
    final trailing = topBarTrailing ?? const LanguageSwitcher(compact: true);

    return Scaffold(
      backgroundColor: PosColors.canvas,
      body: ToastShell(
        safeArea: false,
        contentPadding: EdgeInsets.zero,
        sidebar: _SidebarRail(
          title: title,
          leading: topBarLeading,
          items: items,
          selectedIndex: selectedIndex,
          onItemSelected: onItemSelected,
          bottomItems: bottomItems,
          groupHeaders: groupHeaders,
        ),
        topbar: ToastTopbar(title: selectedLabel, trailing: trailing),
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

class _SidebarRail extends StatelessWidget {
  const _SidebarRail({
    required this.title,
    required this.leading,
    required this.items,
    required this.selectedIndex,
    required this.onItemSelected,
    required this.bottomItems,
    required this.groupHeaders,
  });

  final String title;
  final Widget? leading;
  final List<SidebarItem> items;
  final int selectedIndex;
  final ValueChanged<int> onItemSelected;
  final List<SidebarItem>? bottomItems;
  final Map<int, String>? groupHeaders;

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
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: PosColors.sidebarSurface,
              border: const Border(bottom: BorderSide(color: PosColors.border)),
            ),
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 8)],
                Expanded(
                  child: Text(
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
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 10),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final isSelected = selectedIndex == index;
                final header = groupHeaders?[index];
                final nav = _SidebarRailItem(
                  key: item.itemKey,
                  icon: item.icon,
                  label: item.label,
                  helperLabel: item.helperLabel,
                  badge: item.badge,
                  isSelected: isSelected,
                  onTap: item.onTap ?? () => onItemSelected(index),
                );
                if (header == null) return nav;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        16,
                        index == 0 ? 4 : 14,
                        16,
                        6,
                      ),
                      child: Text(
                        header.toUpperCase(),
                        style: AppFonts.system(
                          color: PosColors.textMuted,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.45,
                        ),
                      ),
                    ),
                    nav,
                  ],
                );
              },
            ),
          ),
          if (bottomItems != null && bottomItems!.isNotEmpty) ...[
            Container(height: 1, color: PosColors.border),
            ...bottomItems!.map(
              (item) => _SidebarRailItem(
                icon: item.icon,
                label: item.label,
                helperLabel: item.helperLabel,
                badge: item.badge,
                isSelected: false,
                onTap: item.onTap ?? () {},
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _SidebarRailItem extends StatelessWidget {
  const _SidebarRailItem({
    super.key,
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.helperLabel,
    this.badge,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final String? helperLabel;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      child: PosListRow(
        selected: isSelected,
        minHeight: ToastShellTokens.navItemHeight,
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: isSelected ? PosColors.accent : PosColors.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.system(
                  color: isSelected ? PosColors.text : PosColors.textSecondary,
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ),
            if (badge != null) ...[
              const SizedBox(width: AppSpacing.xs),
              badge!,
            ],
          ],
        ),
      ),
    );
  }
}

@Deprecated('Use ToastSidebar through WebSidebarLayout instead.')
class LegacySidebarNavItem extends StatelessWidget {
  const LegacySidebarNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PosListRow(
      selected: isSelected,
      minHeight: ToastShellTokens.navItemHeight,
      onTap: onTap,
      child: Row(
        children: [
          Icon(
            icon,
            size: 17,
            color: isSelected ? PosColors.accent : PosColors.textMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: isSelected ? PosColors.text : PosColors.textSecondary,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
