import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/layout/platform_info.dart';
import '../../core/services/navigation_history_service.dart';
import '../../core/utils/permission_utils.dart';
import '../../core/utils/role_routes.dart';
import '../../features/admin/admin_screen.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/auth/auth_state.dart';
import '../../features/auth/login_screen.dart';
import '../../features/auth/privacy_consent_screen.dart';
import '../../features/cashier/cashier_screen.dart';
import '../../features/kitchen/kitchen_screen.dart';
import '../../features/onboarding/onboarding_screen.dart';
import '../../features/photo_ops/photo_ops_screen.dart';
import '../../features/payment/payment_detail_screen.dart';
import '../../features/print_station/print_station_screen.dart';
import '../../features/qr_order/qr_order_screen.dart';
import '../../features/attendance/attendance_kiosk_screen.dart';
import '../../features/qc/qc_check_screen.dart';
import '../../features/qc/qc_review_screen.dart';
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
      final path = state.uri.path;
      String? redirectTo;

      if (path.startsWith('/qr/')) {
        NavigationHistoryService.instance.push(fullLocation);
        return null;
      }

      // 1. 비로그인 → 로그인 화면
      if (!isLoggedIn) {
        redirectTo = location == '/login' ? null : '/login';
        NavigationHistoryService.instance.push(redirectTo ?? fullLocation);
        return redirectTo;
      }

      if (auth.privacyConsentRequired) {
        redirectTo = location == '/privacy-consent' ? null : '/privacy-consent';
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
      final homeRoute = homeRouteForRole(role);

      const publicRoutes = ['/login', '/onboarding', '/privacy-consent'];

      // 4. 공개 경로에 있으면 → 홈으로
      if (publicRoutes.contains(location)) {
        if (homeRoute == '/login') {
          NavigationHistoryService.instance.push(fullLocation);
          return null;
        }
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

      if (location == '/photo-ops' &&
          !PermissionUtils.canAccessPhotoOps(role)) {
        redirectTo = homeRoute;
        NavigationHistoryService.instance.push(redirectTo);
        return redirectTo;
      }

      if (path.startsWith('/payments/') &&
          !canAccessRouteForRole(
            role,
            fullLocation,
            extraPermissions: auth.extraPermissions,
          )) {
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

      // 6-E. Attendance capture requires the native Android camera flow.
      if (location == '/attendance-kiosk' && !PlatformInfo.isKioskSupported) {
        redirectTo = homeRoute;
        NavigationHistoryService.instance.push(redirectTo);
        return redirectTo;
      }

      if (location == '/print-station' && !PlatformInfo.isPrinterSupported) {
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

      if (location == '/qc-review' &&
          !PermissionUtils.canDoQcVisitReview(role, auth.extraPermissions)) {
        redirectTo = homeRoute;
        NavigationHistoryService.instance.push(redirectTo);
        return redirectTo;
      }

      // Fall-through: enforce role matrix on any route not handled above
      if (!canAccessRouteForRole(
        role,
        fullLocation,
        extraPermissions: auth.extraPermissions,
      )) {
        redirectTo = homeRoute;
        NavigationHistoryService.instance.push(redirectTo);
        return redirectTo;
      }

      NavigationHistoryService.instance.push(fullLocation);
      return null;
    },
    routes: [
      GoRoute(
        path: '/qr/:token',
        builder: (_, state) => QrOrderScreen(
          key: ValueKey(state.uri.toString()),
          token: state.pathParameters['token'] ?? '',
        ),
      ),
      GoRoute(
        path: '/login',
        builder: (_, state) => LoginScreen(key: ValueKey(state.uri.toString())),
      ),
      GoRoute(
        path: '/privacy-consent',
        builder: (_, state) =>
            PrivacyConsentScreen(key: ValueKey(state.uri.toString())),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (_, state) =>
            OnboardingScreen(key: ValueKey(state.uri.toString())),
      ),
      GoRoute(
        path: '/waiter',
        builder: (_, state) =>
            WaiterScreen(key: ValueKey(state.uri.toString())),
      ),
      GoRoute(
        path: '/kitchen',
        builder: (_, state) =>
            KitchenScreen(key: ValueKey(state.uri.toString())),
      ),
      GoRoute(
        path: '/print-station',
        builder: (_, state) =>
            PrintStationScreen(key: ValueKey(state.uri.toString())),
      ),
      GoRoute(
        path: '/cashier',
        builder: (_, state) =>
            CashierScreen(key: ValueKey(state.uri.toString())),
      ),
      GoRoute(
        path: '/attendance-kiosk',
        builder: (_, state) =>
            AttendanceKioskScreen(key: ValueKey(state.uri.toString())),
      ),
      GoRoute(
        path: '/qc-check',
        builder: (_, state) =>
            QcCheckScreen(key: ValueKey(state.uri.toString())),
      ),
      GoRoute(
        path: '/qc-review',
        builder: (_, state) =>
            QcReviewScreen(key: ValueKey(state.uri.toString())),
      ),
      GoRoute(
        path: '/photo-ops',
        builder: (_, state) =>
            PhotoOpsScreen(key: ValueKey(state.uri.toString())),
      ),
      GoRoute(
        path: '/payments/:paymentId',
        builder: (_, state) => PaymentDetailScreen(
          key: ValueKey(state.uri.toString()),
          paymentId: state.pathParameters['paymentId'] ?? '',
        ),
      ),
      GoRoute(
        path: '/super-admin',
        builder: (_, state) =>
            SuperAdminScreen(key: ValueKey(state.uri.toString())),
      ),
      GoRoute(
        path: '/admin',
        builder: (_, state) => AdminScreen(
          key: ValueKey(state.uri.toString()),
          initialTabIndex: _tabIndexFromQuery(state.uri.queryParameters['tab']),
        ),
      ),
      // super_admin이 특정 레스토랑 admin 화면으로 진입하는 경로
      GoRoute(
        path: '/admin/:storeId',
        builder: (_, state) => AdminScreen(
          key: ValueKey(state.uri.toString()),
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
    'einvoice' || 'e-invoice' || 'invoice' => 9,
    _ => 0,
  };
}
