import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/hardware/print_agent_coordinator.dart';
import '../../core/hardware/print_agent_coordinator_provider.dart';
import '../../core/hardware/printer_service.dart';
import '../../core/i18n/locale_extensions.dart';
import '../../core/services/printer_destination_service.dart';
import '../../core/ui/app_fonts.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../core/utils/time_utils.dart';
import '../../main.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/error_toast.dart';
import '../../widgets/offline_banner.dart';
import '../admin/providers/printer_destinations_provider.dart';
import '../auth/auth_provider.dart';
import '../kitchen/kitchen_provider.dart';
import '../store_setup/store_setup_localization.dart';

class PrintStationScreen extends ConsumerStatefulWidget {
  const PrintStationScreen({super.key});

  @override
  ConsumerState<PrintStationScreen> createState() => _PrintStationScreenState();
}

class _PrintStationScreenState extends ConsumerState<PrintStationScreen> {
  final Set<String> _testingDestinationIds = <String>{};
  bool _isProcessingOnce = false;

  Future<void> _togglePolling() async {
    final coordinator = ref.read(printAgentCoordinatorProvider.notifier);
    final enabled = ref.read(printAgentCoordinatorProvider).enabled;
    await coordinator.setEnabled(!enabled);
  }

  Future<void> _processOnce(String storeId) async {
    if (_isProcessingOnce) {
      return;
    }
    setState(() => _isProcessingOnce = true);
    try {
      await ref.read(printAgentCoordinatorProvider.notifier).processOnce();
      if (!mounted) {
        return;
      }
      ref.invalidate(printStationJobsProvider(storeId));
      ref.invalidate(failedPrintJobsProvider(storeId));
    } finally {
      if (mounted) {
        setState(() => _isProcessingOnce = false);
      }
    }
  }

  Future<void> _reprintJob(String storeId, FailedPrintJob job) async {
    await ref.read(kitchenProvider.notifier).reprintPrintJob(job.id);
    ref.invalidate(printStationJobsProvider(storeId));
    ref.invalidate(failedPrintJobsProvider(storeId));
    if (mounted) {
      showSuccessToast(context, context.l10n.kitchenReprintQueued);
    }
  }

  Future<void> _testDestination(PrinterDestinationConfig destination) async {
    if (_testingDestinationIds.contains(destination.id)) {
      return;
    }
    setState(() => _testingDestinationIds.add(destination.id));
    try {
      final result = await ref
          .read(printAgentCoordinatorProvider.notifier)
          .testDestination(destination.id);
      if (!mounted) {
        return;
      }
      if (result == PrintResult.success) {
        showSuccessToast(context, context.l10n.printStationTestComplete);
      } else {
        showErrorToast(context, context.l10n.printStationTestFailed);
      }
    } finally {
      if (!mounted) {
        _testingDestinationIds.remove(destination.id);
      } else {
        setState(() => _testingDestinationIds.remove(destination.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final storeId = ref.watch(authProvider).storeId;
    final agentState = ref.watch(printAgentCoordinatorProvider);
    final isRunning = agentState.status == PrintAgentStatus.running;

    return Scaffold(
      key: const Key('print_station_root'),
      backgroundColor: PosSurfaceRole.background.fill,
      body: Column(
        children: [
          const OfflineBanner(),
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              color: AppColors.surfaceTopbar,
              border: Border(bottom: BorderSide(color: AppColors.surface3)),
            ),
            child: Row(
              children: [
                const AppNavBar(),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.printStationTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.system(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                ToastStatusBadge(
                  label: isRunning
                      ? l10n.printStationRunning
                      : l10n.printStationStopped,
                  color: isRunning ? PosColors.success : PosColors.warning,
                  compact: true,
                ),
              ],
            ),
          ),
          Expanded(
            child: ToastResponsiveBody(
              maxWidth: 1120,
              padding: const EdgeInsets.all(16),
              child: _buildBody(storeId),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(String? storeId) {
    final l10n = context.l10n;
    final coordinator = ref.read(printAgentCoordinatorProvider.notifier);
    final agentState = ref.watch(printAgentCoordinatorProvider);
    if (!coordinator.isSupported) {
      return Center(
        child: PosExceptionAlert(
          label: l10n.printStationTitle,
          detail: l10n.printStationUnsupported,
          color: PosColors.warning,
          icon: Icons.print_disabled_outlined,
        ),
      );
    }

    if (storeId == null) {
      return Center(
        child: PosExceptionAlert(
          label: l10n.printStationTitle,
          detail: l10n.printStationNoStore,
          color: PosColors.warning,
          icon: Icons.store_outlined,
        ),
      );
    }

    final destinationState = ref.watch(printerDestinationsProvider(storeId));
    final printJobs = ref.watch(printStationJobsProvider(storeId));
    final failedJobs = ref.watch(failedPrintJobsProvider(storeId));

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ToastWorkSurface(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.printStationSubtitle,
                  style: AppFonts.system(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      key: const Key('print_station_start'),
                      onPressed: _togglePolling,
                      icon: Icon(
                        agentState.enabled
                            ? Icons.stop_circle_outlined
                            : Icons.play_circle_outline,
                        size: 18,
                      ),
                      label: Text(
                        agentState.enabled
                            ? l10n.printStationStop
                            : l10n.printStationStart,
                      ),
                    ),
                    OutlinedButton.icon(
                      key: const Key('print_station_process_once'),
                      onPressed: _isProcessingOnce
                          ? null
                          : () => unawaited(_processOnce(storeId)),
                      icon: _isProcessingOnce
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh_outlined, size: 18),
                      label: Text(l10n.printStationProcessOnce),
                    ),
                    OutlinedButton.icon(
                      key: const Key('print_station_refresh'),
                      onPressed: () {
                        ref.invalidate(printerDestinationsProvider(storeId));
                        ref.invalidate(printStationJobsProvider(storeId));
                        ref.invalidate(failedPrintJobsProvider(storeId));
                      },
                      icon: const Icon(Icons.sync_outlined, size: 18),
                      label: Text(l10n.printStationRefresh),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                ToastMetricStrip(
                  metrics: [
                    ToastMetric(
                      label: l10n.printStationDestinations,
                      value: '${destinationState.destinations.length}',
                      tone: PosColors.info,
                    ),
                    ToastMetric(
                      label: l10n.printStationFailedJobs,
                      value: failedJobs.maybeWhen(
                        data: (jobs) => '${jobs.length}',
                        orElse: () => '-',
                      ),
                      tone: PosColors.warning,
                    ),
                    ToastMetric(
                      label: l10n.printStationLastRun,
                      value: agentState.lastProcessed == 0
                          ? l10n.printStationNoLastRun
                          : l10n.printStationLastRunSummary(
                              agentState.lastProcessed,
                              agentState.lastSuccessful,
                            ),
                      tone: PosColors.textPrimary,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _PrintStationSection(
            key: const Key('print_station_job_feed'),
            title: l10n.printStationJobFeed,
            child: printJobs.when(
              loading: () => const Center(
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: CircularProgressIndicator(color: AppColors.amber500),
                ),
              ),
              error: (_, __) => PosExceptionAlert(
                label: l10n.kitchenPrintQueueUnavailable,
                detail: l10n.storeSetupErrorTestPoll,
                color: PosColors.warning,
                icon: Icons.warning_amber_outlined,
              ),
              data: (jobs) {
                if (jobs.isEmpty) {
                  return PosExceptionAlert(
                    label: l10n.kitchenNoFailedPrintJobs,
                    detail: l10n.kitchenNoFailedPrintJobsDetail,
                    color: PosColors.success,
                    icon: Icons.check_circle_outline,
                  );
                }
                return Column(
                  children: [for (final job in jobs) _PrintJobTile(job: job)],
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          _PrintStationSection(
            title: l10n.printStationDestinations,
            child: _buildDestinations(destinationState),
          ),
          const SizedBox(height: 14),
          _PrintStationSection(
            key: const Key('print_station_failed_jobs'),
            title: l10n.printStationFailedJobs,
            child: failedJobs.when(
              loading: () => const Center(
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: CircularProgressIndicator(color: AppColors.amber500),
                ),
              ),
              error: (_, __) => PosExceptionAlert(
                label: l10n.kitchenPrintQueueUnavailable,
                detail: l10n.storeSetupErrorTestPoll,
                color: PosColors.warning,
                icon: Icons.warning_amber_outlined,
              ),
              data: (jobs) {
                if (jobs.isEmpty) {
                  return PosExceptionAlert(
                    label: l10n.kitchenNoFailedPrintJobs,
                    detail: l10n.kitchenNoFailedPrintJobsDetail,
                    color: PosColors.success,
                    icon: Icons.check_circle_outline,
                  );
                }
                return Column(
                  children: [
                    for (final job in jobs)
                      _FailedPrintJobTile(
                        job: job,
                        onReprint: () => _reprintJob(storeId, job),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDestinations(PrinterDestinationsState state) {
    final l10n = context.l10n;
    if (state.isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(18),
          child: CircularProgressIndicator(color: AppColors.amber500),
        ),
      );
    }

    if (state.error != null) {
      return PosExceptionAlert(
        label: l10n.settingsPrintRoutingNeedsReview,
        detail: _printerDestinationErrorDetail(state.error!),
        color: PosColors.warning,
        icon: Icons.warning_amber_outlined,
      );
    }

    if (state.destinations.isEmpty) {
      return PosExceptionAlert(
        label: l10n.settingsPrintRoutingEmptyTitle,
        detail: l10n.settingsPrintRoutingEmptyDetail,
        color: PosColors.info,
        icon: Icons.print_outlined,
      );
    }

    return Column(
      children: [
        for (final destination in state.destinations)
          _DestinationTile(
            destination: destination,
            isTesting: _testingDestinationIds.contains(destination.id),
            onTest: () => _testDestination(destination),
          ),
      ],
    );
  }

  String _printerDestinationErrorDetail(String code) {
    final l10n = context.l10n;
    return switch (code) {
      PrinterDestinationErrorCodes.nameRequired =>
        l10n.settingsPrintDestinationNameRequired,
      PrinterDestinationErrorCodes.ipRequired =>
        l10n.settingsPrintDestinationIpRequired,
      PrinterDestinationErrorCodes.portInvalid =>
        l10n.settingsPrintDestinationPortInvalid,
      PrinterDestinationErrorCodes.purposeInvalid =>
        l10n.settingsPrintDestinationPurposeInvalid,
      PrinterDestinationErrorCodes.floorRequired =>
        l10n.settingsPrintDestinationFloorRequired,
      PrinterDestinationErrorCodes.permissionDenied =>
        l10n.settingsPrintDestinationPermissionDenied,
      PrinterDestinationErrorCodes.saveFailed =>
        l10n.settingsPrintRoutingSaveFailed,
      PrinterDestinationErrorCodes.removeFailed =>
        l10n.settingsPrintRoutingRemoveFailed,
      PrinterDestinationErrorCodes.loadFailed =>
        l10n.settingsPrintRoutingLoadFailed,
      _ => l10n.settingsPrintRoutingNeedsReview,
    };
  }
}

class _PrintStationSection extends StatelessWidget {
  const _PrintStationSection({
    super.key,
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ToastWorkSurface(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _DestinationTile extends StatelessWidget {
  const _DestinationTile({
    required this.destination,
    required this.isTesting,
    required this.onTest,
  });

  final PrinterDestinationConfig destination;
  final bool isTesting;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final purpose = localizeStoreSetupRoutePurpose(l10n, destination.purpose);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Row(
        children: [
          Icon(
            destination.isFloorDestination
                ? Icons.layers_outlined
                : Icons.print_outlined,
            color: destination.isActive
                ? AppColors.textPrimary
                : AppColors.textSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  destination.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.system(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${destination.ip}:${destination.port}',
                  style: AppFonts.system(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ToastStatusBadge(
                      label: [
                        purpose,
                        if (destination.floorLabel != null &&
                            destination.floorLabel!.isNotEmpty)
                          destination.floorLabel!,
                      ].join(' / '),
                      color: PosColors.info,
                      compact: true,
                    ),
                    ToastStatusBadge(
                      label: destination.isActive
                          ? l10n.settingsPrintDestinationActiveStatus
                          : l10n.settingsPrintDestinationInactiveStatus,
                      color: destination.isActive
                          ? PosColors.success
                          : PosColors.textSecondary,
                      compact: true,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: const Key('print_station_destination_test'),
            onPressed: isTesting ? null : onTest,
            icon: isTesting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.receipt_long_outlined, size: 16),
            label: Text(l10n.printStationTestPrint),
          ),
        ],
      ),
    );
  }
}

class _PrintJobTile extends StatelessWidget {
  const _PrintJobTile({required this.job});

  final FailedPrintJob job;

  @override
  Widget build(BuildContext context) {
    final updatedAt = TimeUtils.toVietnam(job.updatedAt);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface0,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${job.floorLabel} / ${job.tableNumber} / '
                  '${localizePrintCopyType(context.l10n, job.copyType)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.system(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  context.l10n.kitchenPrintJobBatch(
                    job.batchNo,
                    DateFormat('HH:mm').format(updatedAt),
                  ),
                  style: AppFonts.system(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                if (job.lastError != null && job.lastError!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    localizePrintJobError(context.l10n, job.lastError!),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.system(
                      color: PosColors.warning,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          ToastStatusBadge(
            label: localizePrintJobStatus(context.l10n, job.status),
            color: switch (job.status) {
              'printing' => PosColors.info,
              'pending' => PosColors.warning,
              _ => PosColors.danger,
            },
            compact: true,
          ),
        ],
      ),
    );
  }
}

class _FailedPrintJobTile extends StatelessWidget {
  const _FailedPrintJobTile({required this.job, required this.onReprint});

  final FailedPrintJob job;
  final VoidCallback onReprint;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _PrintJobTile(job: job)),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          key: const Key('print_station_reprint_job_button'),
          onPressed: onReprint,
          icon: const Icon(Icons.refresh_outlined, size: 16),
          label: Text(context.l10n.printStationReprint),
        ),
      ],
    );
  }
}
