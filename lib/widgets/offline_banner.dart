import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/i18n/locale_extensions.dart';
import '../core/services/connectivity_service.dart';
import '../core/ui/app_primitives.dart';
import '../main.dart';

class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final connectivity = ref.watch(connectivityProvider);
    final isOffline = connectivity.maybeWhen(
      data: (connected) => !connected,
      orElse: () => false,
    );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      height: isOffline ? 44 : 0,
      child: ClipRect(
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          offset: isOffline ? Offset.zero : const Offset(0, -1),
          child: Container(
            color: AppColors.surface0,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AppStatusBadge(
                  label: l10n.offline.toUpperCase(),
                  color: AppColors.statusOccupied,
                  foregroundColor: AppColors.statusOccupied,
                ),
                const SizedBox(width: AppSpacing.sm),
                const Icon(
                  Icons.wifi_off,
                  color: AppColors.statusOccupied,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    l10n.offlineConnectionMessage,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
