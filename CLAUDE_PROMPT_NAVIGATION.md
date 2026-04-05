Project: /Users/andreahn/globos_pos_system
Task: Add back / forward / home navigation buttons to all screens

---

## Background

All screens use custom TopBar widgets (not Flutter AppBar).
GoRouter is used for navigation.
This task adds 3 navigation buttons to every screen's TopBar:
  ← 뒤로   →  앞으로   🏠 홈

---

## PART 1: NavigationHistoryService (NEW)

Create: lib/core/services/navigation_history_service.dart

GoRouter doesn't support forward navigation natively.
We maintain a simple history stack manually.

```dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Global navigation history stack for back/forward support
class NavigationHistoryService {
  NavigationHistoryService._();
  static final NavigationHistoryService instance = NavigationHistoryService._();

  final List<String> _history = [];
  int _currentIndex = -1;

  void push(String location) {
    // Drop any forward history when navigating to a new location
    if (_currentIndex < _history.length - 1) {
      _history.removeRange(_currentIndex + 1, _history.length);
    }
    // Avoid duplicate consecutive entries
    if (_history.isEmpty || _history.last != location) {
      _history.add(location);
      _currentIndex = _history.length - 1;
    }
  }

  bool get canGoBack => _currentIndex > 0;
  bool get canGoForward => _currentIndex < _history.length - 1;

  String? goBack() {
    if (!canGoBack) return null;
    _currentIndex--;
    return _history[_currentIndex];
  }

  String? goForward() {
    if (!canGoForward) return null;
    _currentIndex++;
    return _history[_currentIndex];
  }

  String? get currentLocation =>
      _currentIndex >= 0 ? _history[_currentIndex] : null;

  void clear() {
    _history.clear();
    _currentIndex = -1;
  }
}
```

---

## PART 2: AppNavBar Widget (NEW)

Create: lib/widgets/app_nav_bar.dart

This is the shared navigation button row added to every TopBar.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/services/navigation_history_service.dart';
import '../features/auth/auth_provider.dart';
import '../main.dart'; // AppColors

class AppNavBar extends ConsumerWidget {
  const AppNavBar({super.key});

  /// Returns the home route for the given role
  static String homeRouteForRole(String? role) {
    return switch (role) {
      'super_admin' => '/super-admin',
      'admin'       => '/admin',
      'waiter'      => '/waiter',
      'kitchen'     => '/kitchen',
      'cashier'     => '/cashier',
      _             => '/login',
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(authProvider).role;
    final nav = NavigationHistoryService.instance;
    final homeRoute = homeRouteForRole(role);
    final currentLocation = GoRouterState.of(context).uri.toString();
    final isHome = currentLocation == homeRoute ||
        currentLocation.startsWith(homeRoute);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ← 뒤로
        _NavButton(
          icon: Icons.arrow_back_ios_new_rounded,
          tooltip: '뒤로',
          enabled: nav.canGoBack,
          onTap: () {
            final prev = nav.goBack();
            if (prev != null) context.go(prev);
          },
        ),
        const SizedBox(width: 4),
        // → 앞으로
        _NavButton(
          icon: Icons.arrow_forward_ios_rounded,
          tooltip: '앞으로',
          enabled: nav.canGoForward,
          onTap: () {
            final next = nav.goForward();
            if (next != null) context.go(next);
          },
        ),
        const SizedBox(width: 4),
        // 🏠 홈
        _NavButton(
          icon: Icons.home_rounded,
          tooltip: '홈',
          enabled: !isHome,
          onTap: () {
            nav.push(homeRoute);
            context.go(homeRoute);
          },
        ),
      ],
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: enabled
                ? AppColors.surface2
                : AppColors.surface2.withOpacity(0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 18,
            color: enabled
                ? AppColors.textPrimary
                : AppColors.textSecondary.withOpacity(0.4),
          ),
        ),
      ),
    );
  }
}
```

---

## PART 3: Track navigation history in router

In lib/core/router/app_router.dart:

Add a `redirect` listener or use GoRouter's `observers` to push each navigation
event to NavigationHistoryService.

The cleanest way is to add a NavigatorObserver:

```dart
// Add at top of buildAppRouter or as a top-level class:
class _NavHistoryObserver extends NavigatorObserver {
  @override
  void didPush(Route route, Route? previousRoute) {
    final location = route.settings.name;
    if (location != null) {
      NavigationHistoryService.instance.push(location);
    }
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    final location = newRoute?.settings.name;
    if (location != null) {
      NavigationHistoryService.instance.push(location);
    }
  }
}
```

In the GoRouter constructor, add:
```dart
GoRouter(
  observers: [_NavHistoryObserver()],
  ...
)
```

Also push location manually via redirect in GoRouter is an alternative.
Choose whichever approach compiles cleanly.

---

## PART 4: Add AppNavBar to every TopBar

### 4-A: WaiterScreen (_WaiterTopBar)
File: lib/features/waiter/waiter_screen.dart

In _WaiterTopBar.build(), find the Row that contains the restaurant name and logout button.
Add `const AppNavBar()` at the LEFT side of the Row, before the restaurant name.

Import: `import '../../widgets/app_nav_bar.dart';`

```dart
// Existing structure approximation:
Row(
  children: [
    Text(restaurantName),   // center/expanded
    IconButton(logout),
  ],
)

// New structure:
Row(
  children: [
    const AppNavBar(),          // ← ADD HERE (left side)
    const SizedBox(width: 12),
    Expanded(child: Text(restaurantName)),
    IconButton(logout),
  ],
)
```

### 4-B: KitchenScreen (_KitchenTopBar)
File: lib/features/kitchen/kitchen_screen.dart

Same pattern — add `const AppNavBar()` to the left of the existing top bar Row.

Import: `import '../../widgets/app_nav_bar.dart';`

### 4-C: CashierScreen
File: lib/features/cashier/cashier_screen.dart

The cashier screen uses an inline top section (not a separate TopBar widget).
Find the Container/Row at the top of the screen body.
Add `const AppNavBar()` on the left side.

Import: `import '../../widgets/app_nav_bar.dart';`

### 4-D: AdminScreen
File: lib/features/admin/admin_screen.dart

Admin has both Web sidebar layout and Android BottomNav layout.

For Web layout: Add AppNavBar to the top of the sidebar or the top app bar area.
For Android layout: Add AppNavBar to the AppBar's leading area or actions.

```dart
// If AppBar exists:
AppBar(
  leading: const AppNavBar(),  // or put in title Row
  ...
)

// If no AppBar (custom header):
// Add to the header Row similarly to other screens
```

Import: `import '../../widgets/app_nav_bar.dart';`

### 4-E: SuperAdminScreen
File: lib/features/super_admin/super_admin_screen.dart

Find the top bar / header Row. Add `const AppNavBar()` to the left.

Import: `import '../../widgets/app_nav_bar.dart';`

### 4-F: AttendanceKioskScreen
File: lib/features/attendance/attendance_kiosk_screen.dart

Add `const AppNavBar()` to the top-right corner of the idle state scaffold.
Position: in a Positioned widget if using Stack, or in the AppBar.

Import: `import '../../widgets/app_nav_bar.dart';`

### 4-G: QcCheckScreen
File: lib/features/qc/qc_check_screen.dart

This screen likely has an AppBar. Add AppNavBar to the leading or actions:
```dart
AppBar(
  leading: const AppNavBar(),
  title: Text('오늘의 품질 점검'),
  ...
)
```

Import: `import '../../widgets/app_nav_bar.dart';`

---

## PART 5: Push initial route to history on login

In lib/features/auth/auth_provider.dart or in the router redirect:

After successful login, push the initial role-based route to NavigationHistoryService:

```dart
// After determining homeRoute for the user:
NavigationHistoryService.instance.push(homeRoute);
```

Also clear history on logout:
```dart
// In logout():
NavigationHistoryService.instance.clear();
```

---

## Rules
- AppNavBar must work on ALL platforms (Web, Android, macOS)
- 뒤로 button: grey/disabled when no history to go back to
- 앞으로 button: grey/disabled when at the latest history item
- 홈 button: grey/disabled when already on home screen for current role
- Login screen: NO AppNavBar (excluded)
- Onboarding screen: NO AppNavBar (excluded)
- Button size: 36x36px, rounded corners, AppColors.surface2 background
- flutter analyze → 0 errors
- flutter build macos → pass
- flutter build web --release → pass
- flutter build apk --release → pass
- vercel deploy build/web --prod --yes
- git add -A && git commit -m "feat: add back/forward/home navigation buttons to all screens" && git push
