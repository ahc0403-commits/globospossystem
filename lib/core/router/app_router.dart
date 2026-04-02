import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/auth/login_screen.dart';
import '../../main.dart';

// 플레이스홀더 화면
class _PlaceholderScreen extends StatelessWidget {
  final String title;
  const _PlaceholderScreen(this.title);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: Center(
        child: Text(
          title,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 24,
          ),
        ),
      ),
    );
  }
}

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
      builder: (context, state) => const _PlaceholderScreen('Waiter Screen'),
    ),
    GoRoute(
      path: '/kitchen',
      builder: (context, state) => const _PlaceholderScreen('Kitchen Screen'),
    ),
    GoRoute(
      path: '/cashier',
      builder: (context, state) => const _PlaceholderScreen('Cashier Screen'),
    ),
    GoRoute(
      path: '/admin',
      builder: (context, state) => const _PlaceholderScreen('Admin Screen'),
    ),
  ],
);
