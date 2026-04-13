import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../main.dart';

class SidebarItem {
  const SidebarItem({required this.icon, required this.label, this.onTap, this.itemKey});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Key? itemKey;
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
  });

  final String title;
  final List<SidebarItem> items;
  final int selectedIndex;
  final ValueChanged<int> onItemSelected;
  final Widget body;
  final Widget? topBarTrailing;
  final Widget? topBarLeading;
  final List<SidebarItem>? bottomItems;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: Row(
        children: [
          Container(
            width: 220,
            color: AppColors.surface1,
            child: Column(
              children: [
                Container(
                  height: 64,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  alignment: Alignment.centerLeft,
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: AppColors.surface2),
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
                        style: GoogleFonts.bebasNeue(
                          color: AppColors.amber500,
                          fontSize: 22,
                          letterSpacing: 1.5,
                        ),
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
                      return _SidebarNavItem(
                        key: item.itemKey,
                        icon: item.icon,
                        label: item.label,
                        isSelected: isSelected,
                        onTap: item.onTap ?? () => onItemSelected(index),
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
                  height: 64,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: const BoxDecoration(
                    color: AppColors.surface0,
                    border: Border(
                      bottom: BorderSide(color: AppColors.surface2),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        items.isNotEmpty && selectedIndex < items.length
                            ? items[selectedIndex].label.toUpperCase()
                            : '',
                        style: GoogleFonts.bebasNeue(
                          color: AppColors.textSecondary,
                          fontSize: 18,
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
          borderRadius: BorderRadius.circular(8),
          border: isSelected
              ? const Border(
                  left: BorderSide(color: AppColors.amber500, width: 4),
                )
              : null,
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
