import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';

import '../core/i18n/locale_extensions.dart';
import '../core/ui/app_theme.dart';
import '../core/ui/pos_design_tokens.dart';
import '../core/services/navigation_history_service.dart';
import '../core/utils/role_routes.dart' as role_routes;
import '../features/auth/auth_provider.dart';
import '../features/auth/auth_state.dart';
import 'language_switcher.dart';

class AppNavBar extends ConsumerWidget {
  const AppNavBar({
    super.key,
    this.forceBackEnabled = false,
    this.forceHomeEnabled = false,
    this.showLogout = true,
    this.onBackPressed,
    this.onHomePressed,
  });

  final bool forceBackEnabled;
  final bool forceHomeEnabled;
  final bool showLogout;
  final VoidCallback? onBackPressed;
  final VoidCallback? onHomePressed;

  static String homeRouteForRole(String? role) =>
      role_routes.homeRouteForRole(role);

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
    final canGoBack = forceBackEnabled || nav.canGoBack;
    final canGoHome = forceHomeEnabled || !isHome;
    AccessibleStore? activeStore;
    for (final store in authState.accessibleStores) {
      if (store.id == authState.storeId) {
        activeStore = store;
        break;
      }
    }
    final l10n = context.l10n;
    final viewportWidth = MediaQuery.sizeOf(context).width;

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth =
            constraints.hasBoundedWidth && constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : viewportWidth;
        final phoneChrome = viewportWidth < 560;
        final veryCompact = availableWidth < 132 || viewportWidth < 420;
        final showForward = !veryCompact && availableWidth >= 132;
        final showStore = !veryCompact && !phoneChrome && availableWidth >= 290;
        final showLanguage =
            !veryCompact && !phoneChrome && availableWidth >= 460;
        final logoutOnly = showLogout && veryCompact;
        final compactLanguageSwitcher =
            availableWidth < 640 || viewportWidth < 1180;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!logoutOnly) ...[
              _NavButton(
                icon: Icons.arrow_back_ios_new_rounded,
                tooltip: l10n.back,
                enabled: canGoBack,
                onTap: () {
                  if (forceBackEnabled && onBackPressed != null) {
                    onBackPressed!();
                    return;
                  }
                  final prev = nav.goBack();
                  if (prev != null) {
                    context.go(prev);
                  }
                },
              ),
              const SizedBox(width: 6),
              _NavButton(
                key: const Key('app_nav_home_button'),
                icon: Icons.home_rounded,
                tooltip: l10n.home,
                enabled: canGoHome,
                onTap: () {
                  if (forceHomeEnabled && onHomePressed != null) {
                    onHomePressed!();
                    return;
                  }
                  nav.push(homeRoute);
                  context.go(homeRoute);
                },
              ),
            ],
            if (!logoutOnly && showForward) ...[
              const SizedBox(width: 6),
              _NavButton(
                icon: Icons.arrow_forward_ios_rounded,
                tooltip: l10n.forward,
                enabled: nav.canGoForward,
                onTap: () {
                  final next = nav.goForward();
                  if (next != null) {
                    context.go(next);
                  }
                },
              ),
            ],
            if (showStore && authState.accessibleStores.length > 1) ...[
              const SizedBox(width: 10),
              _StoreSwitcher(
                value: authState.storeId,
                stores: authState.accessibleStores,
                onChanged: (storeId) =>
                    ref.read(authProvider.notifier).setActiveStore(storeId),
              ),
            ] else if (showStore && activeStore != null) ...[
              const SizedBox(width: 10),
              _StorePill(store: activeStore),
            ],
            if (showLanguage) ...[
              const SizedBox(width: 10),
              LanguageSwitcher(compact: compactLanguageSwitcher),
            ],
            if (showLogout) ...[
              const SizedBox(width: 6),
              _NavButton(
                key: const Key('app_nav_logout_button'),
                icon: Icons.logout_rounded,
                tooltip: l10n.logout,
                enabled: true,
                onTap: () async {
                  await ref.read(authProvider.notifier).logout();
                },
              ),
            ],
          ],
        );
      },
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    super.key,
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
    return Semantics(
      button: true,
      enabled: enabled,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: AppRadius.sm,
          child: Container(
            width: PosDensity.touchTargetMin,
            height: PosDensity.touchTargetMin,
            decoration: BoxDecoration(
              color: enabled ? PosColors.surface : PosColors.canvasAlt,
              borderRadius: AppRadius.sm,
              border: Border.all(
                color: enabled
                    ? PosColors.border
                    : PosColors.border.withValues(alpha: 0.7),
              ),
            ),
            child: Icon(
              icon,
              size: 18,
              color: enabled
                  ? PosColors.textPrimary
                  : PosColors.textMuted.withValues(alpha: 0.72),
            ),
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
      width: 170,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: AppRadius.lg,
        border: Border.all(color: PosColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: value != null && stores.any((store) => store.id == value)
              ? value
              : stores.first.id,
          dropdownColor: PosColors.surface,
          iconEnabledColor: PosColors.accent,
          style: AppFonts.system(
            color: PosColors.textPrimary,
            fontSize: 13,
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
      constraints: const BoxConstraints(maxWidth: 170),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: AppRadius.lg,
        border: Border.all(color: PosColors.border),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppFonts.system(
          color: PosColors.textPrimary,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
