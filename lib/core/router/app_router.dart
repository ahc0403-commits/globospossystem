import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/admin/admin_screen.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/auth/auth_state.dart';
import '../../features/auth/login_screen.dart';
import '../../features/cashier/cashier_screen.dart';
import '../../features/kitchen/kitchen_screen.dart';
import '../../features/onboarding/onboarding_screen.dart';
import '../../features/waiter/waiter_screen.dart';

/// authProvider 변경을 GoRouter가 감지하도록 ChangeNotifier 브릿지
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
      final authState = listenable.authState;
      final role = authState.role;
      final restaurantId = authState.restaurantId;
      final isLoggedIn = authState.user != null && role != null;
      final location = state.matchedLocation;

      // 로그아웃 → 로그인
      if (!isLoggedIn) {
        return location == '/login' ? null : '/login';
      }

      // super_admin + 레스토랑 없음 → 온보딩
      if (role == 'super_admin' && restaurantId == null) {
        return location == '/onboarding' ? null : '/onboarding';
      }

      // 로그인 상태에서 /login 또는 /onboarding → 역할별 화면
      if (location == '/login' || location == '/onboarding') {
        switch (role) {
          case 'waiter':    return '/waiter';
          case 'kitchen':   return '/kitchen';
          case 'cashier':   return '/cashier';
          case 'admin':
          case 'super_admin':
          default:          return '/admin';
        }
      }

      return null;
    },
    routes: [
      GoRoute(path: '/login',      builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingScreen()),
      GoRoute(path: '/waiter',     builder: (_, __) => const WaiterScreen()),
      GoRoute(path: '/kitchen',    builder: (_, __) => const KitchenScreen()),
      GoRoute(path: '/cashier',    builder: (_, __) => const CashierScreen()),
      GoRoute(path: '/admin',      builder: (_, __) => const AdminScreen()),
    ],
  );
}
