Project: /Users/andreahn/globos_pos_system
Flutter app. Currently works on macOS. Need to add Web + Android support.

## Platform Decision (ADR-006)
- super_admin / admin → Flutter Web (browser) + macOS
- waiter / kitchen / cashier → Flutter Android (tablet)
- admin → also works on Android (for on-site management)

## Current State
- Flutter web platform is already available (Chrome detected)
- Android folder already exists (created with --platforms android)
- All screens: LoginScreen, AdminScreen, SuperAdminScreen, WaiterScreen, KitchenScreen, CashierScreen
- go_router routing working
- Supabase connected
- google_fonts used for fonts
- drift (SQLite) used for menu cache

## Problems to Solve

### Problem 1: drift (SQLite) breaks on Web
drift and sqlite3_flutter_libs do not work on Flutter Web.
On Web, replace drift cache with an in-memory Map cache.

### Problem 2: blue_thermal_printer breaks on Web/Android build
Already removed from pubspec.yaml. Confirm it's gone.

### Problem 3: Adaptive layout needed
Web needs sidebar layout (already implemented for admin/super_admin).
Android needs to be verified working.
The current macOS layout should work on Android too since it uses BottomNavigationBar.

### Problem 4: Web needs flutter web enabled
Add web to pubspec if needed and enable it.

### Problem 5: .env file loading on Web
flutter_dotenv works on web but .env must be in assets.
It's already in assets. Should work.

---

## Tasks

### Task 1: Fix drift for Web compatibility

In lib/features/admin/providers/menu_provider.dart (or wherever drift is used for menu cache):
- Check if drift/sqlite is directly imported and used for caching
- If used: wrap with `kIsWeb` check
- On Web: use a simple `Map<String, List<MenuCategory>>` in-memory cache instead
- On Native: keep existing drift cache

Check all files that import drift:
```bash
grep -r "drift\|sqlite\|database" lib/ --include="*.dart" -l
```

For each file using drift on Web-incompatible way:
- Add `import 'package:flutter/foundation.dart' show kIsWeb;`
- Wrap drift operations: `if (!kIsWeb) { /* drift code */ } else { /* memory cache */ }`

### Task 2: Add Web platform to Flutter project

Run:
```bash
flutter create --platforms web .
```

This adds the web/ directory without affecting existing platforms.

### Task 3: Verify Android build

Run:
```bash
flutter build apk --release --target-platform android-arm64
```

Fix any Android-specific build errors.

### Task 4: Responsive layout for Web vs Mobile

Create lib/core/layout/adaptive_layout.dart:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:io' show Platform;

bool get isWebOrDesktop {
  if (kIsWeb) return true;
  try {
    return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  } catch (_) {
    return false;
  }
}

class AdaptiveLayout extends StatelessWidget {
  const AdaptiveLayout({
    super.key,
    required this.mobileLayout,
    required this.desktopLayout,
    this.breakpoint = 768,
  });

  final Widget mobileLayout;
  final Widget desktopLayout;
  final double breakpoint;

  @override
  Widget build(BuildContext context) {
    if (isWebOrDesktop) return desktopLayout;
    return mobileLayout;
  }
}
```

### Task 5: Web-specific entitlements / CORS

In Supabase dashboard, the web app will call from localhost during dev.
No code change needed - Supabase handles CORS automatically.

For the .env on web, verify it loads correctly.

### Task 6: Test Web build

```bash
flutter build web --release
```

Fix any errors. Common issues:
- dart:io imports (use kIsWeb checks)
- Platform.isAndroid etc. (wrap with !kIsWeb)
- sqlite3 / drift (replace with memory cache on web)

### Task 7: Create build scripts

Create scripts/build_web.sh:
```bash
#!/bin/bash
flutter build web --release --web-renderer canvaskit
echo "Web build complete: build/web/"
```

Create scripts/build_android.sh:
```bash
#!/bin/bash
flutter build apk --release --target-platform android-arm64
echo "Android APK: build/app/outputs/flutter-apk/app-release.apk"
```

Make executable: chmod +x scripts/*.sh

---

## Important constraints

- DO NOT change any business logic, providers, or screens
- DO NOT change Supabase queries
- ONLY fix platform compatibility issues
- Keep existing macOS functionality working
- Use kIsWeb from flutter/foundation.dart for Web checks
- Use Platform.isAndroid etc. only inside non-web guards

## Validation

Run in this order:
1. flutter analyze → must pass with no errors
2. flutter build macos → must still work
3. flutter build web --release → must succeed
4. flutter build apk --release → must succeed

## Git

git add -A && git commit -m "feat: add Web + Android platform support - adaptive layout, drift web compat" && git push
