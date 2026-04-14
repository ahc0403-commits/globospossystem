import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/services/navigation_history_service.dart';
import '../../core/utils/permission_utils.dart';
import '../../features/admin/admin_screen.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/auth/auth_state.dart';
import '../../features/auth/login_screen.dart';
import '../../features/cashier/cashier_screen.dart';
import '../../features/kitchen/kitchen_screen.dart';
import '../../features/onboarding/onboarding_screen.dart';
import '../../features/photo_ops/photo_ops_screen.dart';
import '../../features/attendance/attendance_kiosk_screen.dart';
import '../../features/qc/qc_check_screen.dart';
import '../../features/super_admin/super_admin_screen.dart';
import '../../features/waiter/waiter_screen.dart';

class _AuthListenable extends ChangeNotifier {
  _AuthListenable(ProviderContainer container) {
    container.listen<PosAuthState>(authProvider, (_, __) {
      notifyListeners();
    });
    _container = container;
  }
  late final ProviderContainer _container;
  PosAuthState get authState => _container.read(authProvider);
}

GoRouter buildAppRouter(ProviderContainer container) {
  final listenable = _AuthListenable(container);

  return GoRouter(
    initialLocation: '/login',
    refreshListenable: listenable,
    redirect: (context, state) {
      final auth = listenable.authState;
      final role = auth.role;
      final storeId = auth.storeId;
      final isLoggedIn = auth.user != null && role != null;
      final location = state.matchedLocation;
      final fullLocation = state.uri.toString();
      String? redirectTo;

      // 1. 비로그인 → 로그인 화면
      if (!isLoggedIn) {
        redirectTo = location == '/login' ? null : '/login';
        NavigationHistoryService.instance.push(redirectTo ?? fullLocation);
        return redirectTo;
      }

      // 2. super_admin + 레스토랑 없음 → 온보딩
      if (role == 'super_admin' && storeId == null) {
        redirectTo = location == '/onboarding' ? null : '/onboarding';
        NavigationHistoryService.instance.push(redirectTo ?? fullLocation);
        return redirectTo;
      }

      // 3. 역할별 허용 경로 정의
      final String homeRoute = switch (role) {
        'waiter' => '/waiter',
        'kitchen' => '/kitchen',
        'cashier' => '/cashier',
        'super_admin' => '/super-admin',
        'photo_objet_master' || 'photo_objet_store_admin' => '/photo-ops',
        'brand_admin' || 'store_admin' => '/admin',
        _ => '/admin',
      };

      const publicRoutes = ['/login', '/onboarding'];

      // 4. 공개 경로에 있으면 → 홈으로
      if (publicRoutes.contains(location)) {
        redirectTo = homeRoute;
        NavigationHistoryService.instance.push(redirectTo);
        return redirectTo;
      }

      // 5. super_admin이 /admin에 있으면 → /super-admin으로 강제
      // 단, /admin/:id 형태(특정 레스토랑 뷰)는 허용
      if (role == 'super_admin' && location == '/admin') {
        redirectTo = '/super-admin';
        NavigationHistoryService.instance.push(redirectTo);
        return redirectTo;
      }

      // super_admin이 /admin/:restaurantId에 접근하는 건 허용
      if (role == 'super_admin' && location.startsWith('/admin/')) {
        NavigationHistoryService.instance.push(fullLocation);
        return null;
      }

      // 6. admin이 /super-admin에 있으면 → /admin으로 강제
      if ((role == 'admin' || role == 'brand_admin' || role == 'store_admin') &&
          location == '/super-admin') {
        redirectTo = '/admin';
        NavigationHistoryService.instance.push(redirectTo);
        return redirectTo;
      }

      // 6-B. /super-admin 은 super_admin 전용
      if (location == '/super-admin' && role != 'super_admin') {
        redirectTo = homeRoute;
        NavigationHistoryService.instance.push(redirectTo);
        return redirectTo;
      }

      // 6-C. /admin 은 admin / super_admin 전용
      if (location == '/admin' &&
          role != 'admin' &&
          role != 'brand_admin' &&
          role != 'store_admin' &&
          role != 'super_admin') {
        redirectTo = homeRoute;
        NavigationHistoryService.instance.push(redirectTo);
        return redirectTo;
      }

      if (location == '/photo-ops' && !PermissionUtils.canAccessPhotoOps(role)) {
        redirectTo = homeRoute;
        NavigationHistoryService.instance.push(redirectTo);
        return redirectTo;
      }

      // 6-D. /admin/:storeId 는 super_admin 전용
      if (location.startsWith('/admin/') && role != 'super_admin') {
        redirectTo = homeRoute;
        NavigationHistoryService.instance.push(redirectTo);
        return redirectTo;
      }

      // 6-E. attendance kiosk / fingerprint flow is dormant and disabled
      if (location == '/attendance-kiosk') {
        redirectTo = homeRoute;
        NavigationHistoryService.instance.push(redirectTo);
        return redirectTo;
      }

      // 7. /qc-check 접근 제한
      if (location == '/qc-check' &&
          !PermissionUtils.canDoQcCheck(role, auth.extraPermissions)) {
        redirectTo = homeRoute;
        NavigationHistoryService.instance.push(redirectTo);
        return redirectTo;
      }

      NavigationHistoryService.instance.push(fullLocation);
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(
        path: '/onboarding',
        builder: (_, __) => const OnboardingScreen(),
      ),
      GoRoute(path: '/waiter', builder: (_, __) => const WaiterScreen()),
      GoRoute(path: '/kitchen', builder: (_, __) => const KitchenScreen()),
      GoRoute(path: '/cashier', builder: (_, __) => const CashierScreen()),
      GoRoute(
        path: '/attendance-kiosk',
        builder: (_, __) => const AttendanceKioskScreen(),
      ),
      GoRoute(path: '/qc-check', builder: (_, __) => const QcCheckScreen()),
      GoRoute(path: '/photo-ops', builder: (_, __) => const PhotoOpsScreen()),
      GoRoute(
        path: '/super-admin',
        builder: (_, __) => const SuperAdminScreen(),
      ),
      GoRoute(
        path: '/admin',
        builder: (_, state) => AdminScreen(
          initialTabIndex: _tabIndexFromQuery(state.uri.queryParameters['tab']),
        ),
      ),
      // super_admin이 특정 레스토랑 admin 화면으로 진입하는 경로
      GoRoute(
        path: '/admin/:storeId',
        builder: (_, state) => AdminScreen(
          overrideRestaurantId: state.pathParameters['storeId'],
          initialTabIndex: _tabIndexFromQuery(state.uri.queryParameters['tab']),
        ),
      ),
    ],
  );
}

int _tabIndexFromQuery(String? value) {
  if (value == null) return 0;
  return switch (value.toLowerCase()) {
    'tables' => 0,
    'menu' => 1,
    'staff' => 2,
    'reports' => 3,
    'attendance' => 4,
    'inventory' => 5,
    'qc' => 6,
    'settings' => 7,
    'delivery' || 'settlement' => 8,
    _ => 0,
  };
}
