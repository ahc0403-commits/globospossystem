import 'dart:async';

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
    final connectivity = ref.watch(serviceConnectivityProvider);
    final connectivityState = connectivity.maybeWhen(
      data: (value) => value,
      orElse: () => const ServiceConnectivityState(),
    );
    final content = switch (connectivityState.kind) {
      ServiceConnectivityKind.networkUnavailable => (
        label: l10n.offline,
        message: l10n.offlineConnectionMessage,
        icon: Icons.wifi_off,
        color: AppColors.statusCancelled,
      ),
      ServiceConnectivityKind.serverDegraded => (
        label: l10n.connectivityServerDelayed,
        message: l10n.connectivityServerDelayedMessage,
        icon: Icons.cloud_off_outlined,
        color: AppColors.statusOccupied,
      ),
      ServiceConnectivityKind.authRequired => (
        label: l10n.connectivitySignInRequired,
        message: l10n.connectivitySignInRequiredMessage,
        icon: Icons.lock_clock_outlined,
        color: AppColors.statusCancelled,
      ),
      ServiceConnectivityKind.realtimeDegraded => (
        label: l10n.connectivityRealtimeDelayed,
        message: l10n.connectivityRealtimeDelayedMessage,
        icon: Icons.sync_problem_outlined,
        color: AppColors.statusOccupied,
      ),
      ServiceConnectivityKind.unknown || ServiceConnectivityKind.online => null,
    };
    final lastSuccessAt = connectivityState.lastSuccessAt?.toLocal();
    final lastSuccess = lastSuccessAt == null
        ? null
        : l10n.connectivityLastSuccess(
            MaterialLocalizations.of(
              context,
            ).formatTimeOfDay(TimeOfDay.fromDateTime(lastSuccessAt)),
          );
    if (content == null) return const SizedBox.shrink();
    final semanticMessage = [
      content.label,
      content.message,
      if (lastSuccess != null) lastSuccess,
    ].join('. ');

    return Semantics(
      liveRegion: true,
      label: semanticMessage,
      child: SizedBox(
        height: 56,
        child: ClipRect(
          child: Container(
            color: AppColors.surface0,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AppStatusBadge(
                  label: content.label.toUpperCase(),
                  color: content.color,
                  foregroundColor: content.color,
                ),
                const SizedBox(width: AppSpacing.sm),
                Icon(content.icon, color: content.color, size: 18),
                const SizedBox(width: 6),
                Flexible(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        content.message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (lastSuccess != null)
                        Text(
                          lastSuccess,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 10,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: l10n.retry,
                  onPressed: () => unawaited(
                    ref.read(connectivityServiceProvider).refresh(),
                  ),
                  icon: const Icon(Icons.refresh, size: 18),
                  color: content.color,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
