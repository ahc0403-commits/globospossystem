Project: /Users/andreahn/globos_pos_system
Task: Implement responsive web layout for Admin and Super Admin screens.

## Context
- AdaptiveLayout widget already exists: lib/core/layout/adaptive_layout.dart
- isWebOrDesktop getter: returns true for kIsWeb, macOS, Windows, Linux
- Admin screen uses AppBar + BottomNavigationBar (mobile style)
- Super Admin screen already has sidebar layout
- Target: Web/macOS → Sidebar layout. Android → BottomNav layout (unchanged)

## Design Spec (from UI_UX.md)
Web layout:
  ┌─────────────────────────────────┐
  │  TopBar (64px, no AppBar)       │
  ├──────────┬──────────────────────┤
  │ Sidebar  │   Main Content       │
  │  220px   │   flex 1             │
  │          │                      │
  └──────────┴──────────────────────┘

Colors:
  Sidebar bg: AppColors.surface1 (#1C1D1A)
  Content bg: AppColors.surface0 (#111210)
  Selected item: amber500 left border 4px + surface2 bg
  Unselected: textSecondary color

Android layout (UNCHANGED):
  AppBar + BottomNavigationBar (keep exactly as is)

---

## Task 1: Create WebSidebarLayout widget

Create: lib/core/layout/web_sidebar_layout.dart

This is a reusable sidebar layout for web/desktop screens.

```dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../main.dart';

class SidebarItem {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const SidebarItem({
    required this.icon,
    required this.label,
    this.onTap,
  });
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
  final List<SidebarItem>? bottomItems;  // items at bottom of sidebar (e.g. logout)

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: Row(
        children: [
          // Sidebar
          Container(
            width: 220,
            color: AppColors.surface1,
            child: Column(
              children: [
                // Sidebar header
                Container(
                  height: 64,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  alignment: Alignment.centerLeft,
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: AppColors.surface2)),
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

                // Nav items
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final isSelected = selectedIndex == index;
                      return _SidebarNavItem(
                        icon: item.icon,
                        label: item.label,
                        isSelected: isSelected,
                        onTap: item.onTap ?? () => onItemSelected(index),
                      );
                    },
                  ),
                ),

                // Bottom items (logout etc)
                if (bottomItems != null && bottomItems!.isNotEmpty) ...[
                  const Divider(color: AppColors.surface2, height: 1),
                  ...bottomItems!.map((item) => _SidebarNavItem(
                    icon: item.icon,
                    label: item.label,
                    isSelected: false,
                    onTap: item.onTap ?? () {},
                  )),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ),

          // Main content
          Expanded(
            child: Column(
              children: [
                // Top bar
                Container(
                  height: 64,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: const BoxDecoration(
                    color: AppColors.surface0,
                    border: Border(bottom: BorderSide(color: AppColors.surface2)),
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

                // Content
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
              ? const Border(left: BorderSide(color: AppColors.amber500, width: 3))
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
                color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
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
```

---

## Task 2: Refactor AdminScreen to use adaptive layout

In lib/features/admin/admin_screen.dart:

Add import for adaptive_layout.dart and web_sidebar_layout.dart.

The build method should return different layouts based on isWebOrDesktop:

```
if (isWebOrDesktop) → WebSidebarLayout
else → existing Scaffold with AppBar + BottomNavigationBar (UNCHANGED)
```

For the WebSidebarLayout:
- title: isSuperAdminView ? 'ADMIN VIEW' : 'GLOBOS POS'
- topBarLeading: if isSuperAdminView → back button (arrow_back, goes to /super-admin)
- items: Tables, Menu, Staff, Reports, Attendance, Settings (same 6 tabs)
  Icons: table_restaurant, restaurant_menu, people, bar_chart, access_time, settings
- body: the currently selected tab widget (same IndexedStack or direct widget)
- topBarTrailing: if isSuperAdminView → "SUPER ADMIN MODE" badge
- bottomItems: if !isSuperAdminView → logout button

The tab content widgets (TablesTab, MenuTab, etc.) stay EXACTLY the same.
Only the navigation shell changes.

Keep existing BottomNavigationBar layout for Android (isWebOrDesktop == false).

---

## Task 3: Verify SuperAdminScreen already works on Web

The SuperAdminScreen already has a sidebar layout.
Just verify it looks correct with the same WebSidebarLayout style.

If the super_admin_screen has its own custom sidebar, consider refactoring it
to use WebSidebarLayout for consistency. But only if it's straightforward.
If complex, leave as-is and just note it.

---

## Task 4: Responsive Login Screen

In lib/features/auth/login_screen.dart:

The login card is already constrained to 400px max width.
On Web, center it vertically and horizontally with some extra polish:

- Add a left panel on wide screens (width > 900px):
  Left panel (50%): Dark panel with GLOBOS branding
    - Large "GLOBOS" logo in BebasNeue 80px amber
    - "POS SYSTEM" subtitle
    - Tagline: "Powered by GLOBOSVN" in small grey text
  Right panel (50%): Login form (existing)

- On narrow screens (width <= 900px): existing centered form (unchanged)

Use LayoutBuilder to detect width:
```dart
LayoutBuilder(builder: (context, constraints) {
  if (constraints.maxWidth > 900) {
    return Row(children: [leftBrandPanel, Expanded(child: loginForm)]);
  }
  return loginForm;
})
```

---

## Task 5: Web-specific polish

Add to web/index.html (if needed):
- Set page title to "GLOBOS POS"
- Set background color to #111210 to prevent white flash on load

In web/index.html, find <title> and change to:
  <title>GLOBOS POS</title>

Find or add to <style>:
  body { background-color: #111210; margin: 0; }

---

## Validation

1. flutter analyze → no errors
2. flutter build web --release → must pass
3. flutter build macos → must pass  
4. flutter build apk --release → must pass (Android layout UNCHANGED)

## Git

git add -A && git commit -m "feat: responsive web layout - sidebar for admin/super_admin on web, branded login split panel" && git push
