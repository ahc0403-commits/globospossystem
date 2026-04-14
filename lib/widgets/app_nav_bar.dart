import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/ui/app_theme.dart';
import '../core/services/navigation_history_service.dart';
import '../features/auth/auth_provider.dart';
import '../features/auth/auth_state.dart';

class AppNavBar extends ConsumerWidget {
  const AppNavBar({super.key});

  static String homeRouteForRole(String? role) {
    return switch (role) {
      'super_admin' => '/super-admin',
      'photo_objet_master' || 'photo_objet_store_admin' => '/photo-ops',
      'brand_admin' || 'store_admin' => '/admin',
      'admin' => '/admin',
      'waiter' => '/waiter',
      'kitchen' => '/kitchen',
      'cashier' => '/cashier',
      _ => '/login',
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);
    final role = authState.role;
    final nav = NavigationHistoryService.instance;
    final homeRoute = homeRouteForRole(role);
    final currentLocation = GoRouterState.of(context).uri.toString();
    final isHome =
        currentLocation == homeRoute ||
        currentLocation.startsWith('$homeRoute?') ||
        currentLocation.startsWith('$homeRoute/');
    AccessibleStore? activeStore;
    for (final store in authState.accessibleStores) {
      if (store.id == authState.storeId) {
        activeStore = store;
        break;
      }
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _NavButton(
          icon: Icons.arrow_back_ios_new_rounded,
          tooltip: 'Back',
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
          tooltip: 'Forward',
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
          tooltip: 'Home',
          enabled: !isHome,
          onTap: () {
            nav.push(homeRoute);
            context.go(homeRoute);
          },
        ),
        if (authState.accessibleStores.length > 1) ...[
          const SizedBox(width: 8),
          _StoreSwitcher(
            value: authState.storeId,
            stores: authState.accessibleStores,
            onChanged: (storeId) =>
                ref.read(authProvider.notifier).setActiveStore(storeId),
          ),
        ] else if (activeStore != null) ...[
          const SizedBox(width: 8),
          _StorePill(store: activeStore),
        ],
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
            color: enabled ? AppColors.surface2 : AppColors.surface1,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: enabled
                  ? AppColors.surface3
                  : AppColors.surface3.withValues(alpha: 0.45),
            ),
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

class _StoreSwitcher extends StatelessWidget {
  const _StoreSwitcher({
    required this.value,
    required this.stores,
    required this.onChanged,
  });

  final String? value;
  final List<AccessibleStore> stores;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.surface3),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value != null && stores.any((store) => store.id == value)
              ? value
              : stores.first.id,
          dropdownColor: AppColors.surface1,
          iconEnabledColor: AppColors.amber500,
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
          items: stores
              .map(
                (store) => DropdownMenuItem<String>(
                  value: store.id,
                  child: Text(
                    store.brandName == null || store.brandName!.isEmpty
                        ? store.name
                        : '${store.brandName} / ${store.name}',
                  ),
                ),
              )
              .toList(),
          onChanged: (next) {
            if (next != null) onChanged(next);
          },
        ),
      ),
    );
  }
}

class _StorePill extends StatelessWidget {
  const _StorePill({required this.store});

  final AccessibleStore store;

  @override
  Widget build(BuildContext context) {
    final label = store.brandName == null || store.brandName!.isEmpty
        ? store.name
        : '${store.brandName} / ${store.name}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.surface3),
      ),
      child: Text(
        label,
        style: GoogleFonts.notoSansKr(
          color: AppColors.textPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
