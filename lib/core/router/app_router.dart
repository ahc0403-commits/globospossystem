import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/admin/admin_screen.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/auth/login_screen.dart';
import '../../features/cashier/cashier_screen.dart';
import '../../features/kitchen/kitchen_screen.dart';
import '../../features/waiter/waiter_screen.dart';

final appRouter = GoRouter(
  initialLocation: '/login',
  redirect: (context, state) {
    final container = ProviderScope.containerOf(context, listen: false);
    final authState = container.read(authProvider);
    final role = authState.role;
    final isLoggedIn = authState.user != null && role != null;
    final isOnLogin = state.matchedLocation == '/login';

    if (!isLoggedIn && !isOnLogin) return '/login';
    if (isLoggedIn && isOnLogin) {
      switch (role) {
        case 'waiter':
          return '/waiter';
        case 'kitchen':
          return '/kitchen';
        case 'cashier':
          return '/cashier';
        case 'admin':
        case 'super_admin':
          return '/admin';
        default:
          return '/waiter';
      }
    }
    return null;
  },
  routes: [
    GoRoute(
      path: '/login',
      builder: (context, state) => const LoginScreen(),
    ),
    GoRoute(
      path: '/waiter',
      builder: (context, state) => const WaiterScreen(),
    ),
    GoRoute(
      path: '/kitchen',
      builder: (context, state) => const KitchenScreen(),
    ),
    GoRoute(
      path: '/cashier',
      builder: (context, state) => const CashierScreen(),
    ),
    GoRoute(
      path: '/admin',
      builder: (context, state) => const AdminScreen(),
    ),
  ],
);
