import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../ui/app_theme.dart';

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
  /// above this item. Stored but not rendered today.
  final String? sectionLabel;

  /// Wave 1.5 shell migration: secondary helper string under the label.
  /// Stored but not rendered today.
  final String? helperLabel;

  /// Wave 1.5 shell migration: optional provider-backed badge widget
  /// (e.g. a count chip). Stored but not rendered today.
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
    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: Row(
        children: [
          Container(
            width: 240,
            color: AppColors.surface1,
            child: Column(
              children: [
                Container(
                  height: 72,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  alignment: Alignment.centerLeft,
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: AppColors.surface3),
                    ),
                  ),
                  child: Row(
                    children: [
                      if (topBarLeading != null) ...[
                        topBarLeading!,
                        const SizedBox(width: 8),
                      ],
                      Text(
                        title,
                        style: AppTextStyles.operationalTitle(size: 24),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final isSelected = selectedIndex == index;
                      final header = groupHeaders?[index];
                      final nav = _SidebarNavItem(
                        key: item.itemKey,
                        icon: item.icon,
                        label: item.label,
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
                              style: GoogleFonts.notoSansKr(
                                color: AppColors.textMuted,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
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
                  const Divider(color: AppColors.surface2, height: 1),
                  ...bottomItems!.map(
                    (item) => _SidebarNavItem(
                      icon: item.icon,
                      label: item.label,
                      isSelected: false,
                      onTap: item.onTap ?? () {},
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ),
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 72,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: const BoxDecoration(
                    color: AppColors.surface0,
                    border: Border(
                      bottom: BorderSide(color: AppColors.surface3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        items.isNotEmpty && selectedIndex < items.length
                            ? items[selectedIndex].label.toUpperCase()
                            : '',
                        style: AppTextStyles.operationalTitle(
                          color: AppColors.textSecondary,
                          size: 18,
                          letterSpacing: 2,
                        ),
                      ),
                      const Spacer(),
                      if (topBarTrailing != null) topBarTrailing!,
                    ],
                  ),
                ),
                Expanded(child: body),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarNavItem extends StatelessWidget {
  const _SidebarNavItem({
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
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 48,
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.surface2 : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? AppColors.amber500.withValues(alpha: 0.35)
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: isSelected ? AppColors.amber500 : AppColors.textSecondary,
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: GoogleFonts.notoSansKr(
                color: isSelected
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
                fontSize: 14,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
