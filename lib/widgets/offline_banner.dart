import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/connectivity_service.dart';
import '../core/ui/app_primitives.dart';
import '../main.dart';

class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              children: const [
                AppStatusBadge(
                  label: 'OFFLINE',
                  color: AppColors.statusOccupied,
                  foregroundColor: AppColors.statusOccupied,
                ),
                SizedBox(width: AppSpacing.sm),
                Icon(Icons.wifi_off, color: AppColors.statusOccupied, size: 16),
                SizedBox(width: 6),
                Text(
                  'Internet connection lost. Online-only actions may be unavailable.',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
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
