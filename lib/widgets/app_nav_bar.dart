import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/services/navigation_history_service.dart';
import '../features/auth/auth_provider.dart';
import '../main.dart';

class AppNavBar extends ConsumerWidget {
  const AppNavBar({super.key});

  static String homeRouteForRole(String? role) {
    return switch (role) {
      'super_admin' => '/super-admin',
      'admin' => '/admin',
      'waiter' => '/waiter',
      'kitchen' => '/kitchen',
      'cashier' => '/cashier',
      _ => '/login',
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(authProvider).role;
    final nav = NavigationHistoryService.instance;
    final homeRoute = homeRouteForRole(role);
    final currentLocation = GoRouterState.of(context).uri.toString();
    final isHome =
        currentLocation == homeRoute ||
        currentLocation.startsWith('$homeRoute?') ||
        currentLocation.startsWith('$homeRoute/');

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _NavButton(
          icon: Icons.arrow_back_ios_new_rounded,
          tooltip: '뒤로',
          enabled: nav.canGoBack,
          onTap: () {
            final prev = nav.goBack();
            if (prev != null) {
              context.go(prev);
            }
          },
        ),
        const SizedBox(width: 4),
        _NavButton(
          icon: Icons.arrow_forward_ios_rounded,
          tooltip: '앞으로',
          enabled: nav.canGoForward,
          onTap: () {
            final next = nav.goForward();
            if (next != null) {
              context.go(next);
            }
          },
        ),
        const SizedBox(width: 4),
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
                : AppColors.surface2.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 18,
            color: enabled
                ? AppColors.textPrimary
                : AppColors.textSecondary.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}
