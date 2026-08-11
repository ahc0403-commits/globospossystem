import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/hardware/print_agent_coordinator.dart';
import '../../core/hardware/print_agent_coordinator_provider.dart';
import '../../core/hardware/network_capability_service.dart';
import '../../core/hardware/printer_service.dart';
import '../../core/i18n/locale_extensions.dart';
import '../../core/services/printer_destination_service.dart';
import '../../core/services/live_refresh_service.dart';
import '../../core/ui/app_fonts.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../core/utils/floor_label.dart';
import '../../core/utils/number_input_utils.dart';
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
  const PrintStationScreen({super.key, this.isSupportedOverride});

  /// Allows widget tests to exercise supported queue states on non-printer
  /// hosts. Production continues to use the coordinator capability probe.
  final bool? isSupportedOverride;

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
        showErrorToast(
          context,
          '${context.l10n.printStationTestFailed} (${result.name})',
        );
      }
    } finally {
      if (!mounted) {
        _testingDestinationIds.remove(destination.id);
      } else {
        setState(() => _testingDestinationIds.remove(destination.id));
      }
    }
  }

  Future<void> _deleteDestination(
    String storeId,
    PrinterDestinationConfig destination,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('print_station_destination_delete_dialog'),
        backgroundColor: AppColors.surface1,
        title: Text(
          context.l10n.settingsPrintDestinationDeleteTitle,
          style: AppFonts.system(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          context.l10n.settingsPrintDestinationDeleteMessage(destination.name),
          style: AppFonts.system(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            key: const Key('print_station_destination_delete_confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: PosColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(context.l10n.settingsPrintDestinationDeleteAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final success = await ref
        .read(printerDestinationsProvider(storeId).notifier)
        .deleteDestination(destination.id);
    if (!mounted || !success) return;
    showSuccessToast(
      context,
      context.l10n.settingsPrintDestinationDeletedToast,
    );
  }

  Future<void> _showPrinterDestinationDialog({
    required String storeId,
    PrinterDestinationConfig? destination,
  }) async {
    final pageContext = context;
    final l10n = context.l10n;
    final nameController = TextEditingController(text: destination?.name ?? '');

    PrinterEndpointConfig? endpointOf(String type) {
      for (final endpoint
          in destination?.endpoints ?? const <PrinterEndpointConfig>[]) {
        if (endpoint.type == type) return endpoint;
      }
      return null;
    }

    final wiredEndpoint = endpointOf('wired');
    final wirelessEndpoint = endpointOf('wireless');
    final usbEndpoint = endpointOf('usb');
    final wiredIpController = TextEditingController(
      text: wiredEndpoint?.ip ?? '',
    );
    final wiredPortController = TextEditingController(
      text: (wiredEndpoint?.port ?? 9100).toString(),
    );
    final wirelessIpController = TextEditingController(
      text:
          wirelessEndpoint?.ip ??
          (destination?.endpoints.isEmpty == true ? destination?.ip : null) ??
          '',
    );
    final wirelessPortController = TextEditingController(
      text:
          (wirelessEndpoint?.port ??
                  (destination?.endpoints.isEmpty == true
                      ? destination?.port
                      : null) ??
                  9100)
              .toString(),
    );
    final usbPrinterNameController = TextEditingController(
      text: usbEndpoint?.deviceName ?? '',
    );
    final floorController = TextEditingController(
      text: destination == null
          ? 'G'
          : displayFloorLabel(destination.floorLabel ?? '1F'),
    );
    var purpose = destination?.purpose ?? 'kitchen';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          key: const Key('print_station_destination_dialog'),
          backgroundColor: AppColors.surface1,
          title: Text(
            destination == null
                ? l10n.settingsPrintDestinationAdd
                : l10n.settingsPrintDestinationEdit,
            style: AppFonts.system(color: AppColors.textPrimary),
          ),
          content: SizedBox(
            width: (MediaQuery.sizeOf(dialogContext).width - 80).clamp(
              240,
              460,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const Key('print_station_destination_name'),
                    controller: nameController,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.settingsPrintDestinationName,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('print_station_destination_wired_ip'),
                    controller: wiredIpController,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.settingsPrinterWiredIp,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('print_station_destination_wired_port'),
                    controller: wiredPortController,
                    keyboardType: TextInputType.number,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.settingsPrinterWiredPort,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('print_station_destination_wireless_ip'),
                    controller: wirelessIpController,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.settingsPrinterWirelessIp,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('print_station_destination_wireless_port'),
                    controller: wirelessPortController,
                    keyboardType: TextInputType.number,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.settingsPrinterWirelessPort,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('print_station_destination_usb_name'),
                    controller: usbPrinterNameController,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.settingsPrinterUsbName,
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: const Key('print_station_destination_purpose'),
                    initialValue: purpose,
                    dropdownColor: AppColors.surface1,
                    style: AppFonts.system(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.settingsPrintDestinationPurpose,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'kitchen',
                        child: Text(l10n.settingsPrintDestinationKitchen),
                      ),
                      DropdownMenuItem(
                        value: 'floor',
                        child: Text(l10n.settingsPrintDestinationFloor),
                      ),
                      DropdownMenuItem(
                        value: 'tray',
                        child: Text(l10n.settingsPrintDestinationTray),
                      ),
                      DropdownMenuItem(
                        value: 'receipt',
                        child: Text(l10n.settingsPrintDestinationReceipt),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => purpose = value);
                      }
                    },
                  ),
                  if (purpose == 'floor') ...[
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('print_station_destination_floor_label'),
                      controller: floorController,
                      textCapitalization: TextCapitalization.characters,
                      style: AppFonts.system(color: AppColors.textPrimary),
                      decoration: InputDecoration(
                        labelText: l10n.tablesFloorLabel,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              key: const Key('print_station_destination_save'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.amber500,
                foregroundColor: AppColors.surface0,
              ),
              onPressed: () async {
                final name = nameController.text.trim();
                final wiredIp = wiredIpController.text.trim();
                final wiredPort = parseIntInput(wiredPortController.text);
                final wirelessIp = wirelessIpController.text.trim();
                final wirelessPort = parseIntInput(wirelessPortController.text);
                final usbPrinterName = usbPrinterNameController.text.trim();
                final floorLabel = storedFloorLabel(floorController.text);
                if (name.isEmpty ||
                    (wiredIp.isEmpty &&
                        wirelessIp.isEmpty &&
                        usbPrinterName.isEmpty) ||
                    (wiredIp.isNotEmpty &&
                        (!isValidPrinterIpv4Address(wiredIp) ||
                            wiredPort == null ||
                            wiredPort <= 0 ||
                            wiredPort > 65535)) ||
                    (wirelessIp.isNotEmpty &&
                        (!isValidPrinterIpv4Address(wirelessIp) ||
                            wirelessPort == null ||
                            wirelessPort <= 0 ||
                            wirelessPort > 65535)) ||
                    (purpose == 'floor' && floorLabel.isEmpty)) {
                  showErrorToast(
                    dialogContext,
                    l10n.settingsPrintDestinationInputError,
                  );
                  return;
                }

                final success = await ref
                    .read(printerDestinationsProvider(storeId).notifier)
                    .upsertDestination(
                      PrinterDestinationDraft(
                        id: destination?.id,
                        name: name,
                        wiredIp: wiredIp,
                        wiredPort: wiredPort ?? 9100,
                        wirelessIp: wirelessIp,
                        wirelessPort: wirelessPort ?? 9100,
                        usbPrinterName: usbPrinterName,
                        purpose: purpose,
                        floorLabel: purpose == 'floor' ? floorLabel : null,
                        isActive: true,
                      ),
                    );
                if (!dialogContext.mounted || !success) return;
                Navigator.of(dialogContext).pop();
                if (mounted) {
                  showSuccessToast(
                    pageContext,
                    l10n.settingsPrintDestinationSavedToast,
                  );
                }
              },
              child: Text(l10n.save),
            ),
          ],
        ),
      ),
    );

    await Future<void>.delayed(kThemeAnimationDuration);
    nameController.dispose();
    wiredIpController.dispose();
    wiredPortController.dispose();
    wirelessIpController.dispose();
    wirelessPortController.dispose();
    usbPrinterNameController.dispose();
    floorController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final storeId = ref.watch(authProvider).storeId;
    if (storeId != null) {
      ref.listen<AsyncValue<PosLiveEvent>>(posLiveEventsProvider(storeId), (
        _,
        next,
      ) {
        next.whenData((event) {
          if (!event.affects({'print', 'settings', 'orders'})) return;
          ref.invalidate(printerDestinationsProvider(storeId));
          ref.invalidate(printStationJobsProvider(storeId));
          ref.invalidate(failedPrintJobsProvider(storeId));
        });
      });
    }
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
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: const AppNavBar(),
                ),
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
    final networkCapabilities = ref.watch(networkCapabilitiesProvider);
    if (!(widget.isSupportedOverride ?? coordinator.isSupported)) {
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
                        ref.invalidate(networkCapabilitiesProvider);
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
                      label: l10n.printStationNetwork,
                      value: networkCapabilities.when(
                        data: (capabilities) => capabilities.wiredConnected
                            ? l10n.settingsPrinterWired
                            : capabilities.wirelessConnected
                            ? l10n.settingsPrinterWireless
                            : l10n.printStationNoNetwork,
                        loading: () => '-',
                        error: (_, __) => l10n.printStationNoNetwork,
                      ),
                      tone: networkCapabilities.maybeWhen(
                        data: (capabilities) => capabilities.hasNetwork
                            ? PosColors.success
                            : PosColors.warning,
                        orElse: () => PosColors.textSecondary,
                      ),
                    ),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    key: const Key('print_station_destination_add'),
                    onPressed: destinationState.isSaving
                        ? null
                        : () => _showPrinterDestinationDialog(storeId: storeId),
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(l10n.settingsPrintDestinationAdd),
                  ),
                ),
                const SizedBox(height: 10),
                _buildDestinations(storeId, destinationState),
              ],
            ),
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

  Widget _buildDestinations(String storeId, PrinterDestinationsState state) {
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
      key: const Key('print_station_destination_test'),
      children: [
        for (final destination in state.destinations)
          _DestinationTile(
            destination: destination,
            isSaving: state.isSaving,
            isTesting: _testingDestinationIds.contains(destination.id),
            onTest: () => _testDestination(destination),
            onEdit: () => _showPrinterDestinationDialog(
              storeId: storeId,
              destination: destination,
            ),
            onDelete: () => _deleteDestination(storeId, destination),
          ),
      ],
    );
  }

  String _printerDestinationErrorDetail(String code) {
    final l10n = context.l10n;
    return switch (code) {
      PrinterDestinationErrorCodes.nameRequired =>
        l10n.settingsPrintDestinationNameRequired,
      PrinterDestinationErrorCodes.endpointRequired =>
        l10n.settingsPrintDestinationInputError,
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
    required this.isSaving,
    required this.isTesting,
    required this.onTest,
    required this.onEdit,
    required this.onDelete,
  });

  final PrinterDestinationConfig destination;
  final bool isSaving;
  final bool isTesting;
  final VoidCallback onTest;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final details = Row(
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
                    for (final endpoint in destination.endpoints)
                      Text(
                        '${switch (endpoint.type) {
                          'usb' => l10n.settingsPrinterUsb,
                          'wired' => l10n.settingsPrinterWired,
                          _ => l10n.settingsPrinterWireless,
                        }}: '
                        '${endpoint.type == 'usb' ? endpoint.deviceName : '${endpoint.ip}:${endpoint.port}'}',
                        style: AppFonts.system(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    if (destination.endpoints.isEmpty)
                      Text(
                        '${l10n.settingsPrinterWireless}: '
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
                              displayFloorLabel(destination.floorLabel!),
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
            ],
          );
          final actions = Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              OutlinedButton.icon(
                key: ValueKey(
                  'print_station_destination_test_${destination.id}',
                ),
                onPressed: isSaving || isTesting ? null : onTest,
                icon: isTesting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.receipt_long_outlined, size: 16),
                label: Text(l10n.printStationTestPrint),
              ),
              IconButton.outlined(
                key: ValueKey(
                  'print_station_destination_edit_${destination.id}',
                ),
                onPressed: isSaving ? null : onEdit,
                icon: const Icon(Icons.edit_outlined, size: 18),
                tooltip: l10n.settingsPrintDestinationEditTooltip,
              ),
              IconButton.outlined(
                key: ValueKey(
                  'print_station_destination_remove_${destination.id}',
                ),
                onPressed: isSaving ? null : onDelete,
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: l10n.settingsPrintDestinationDeleteTooltip,
              ),
            ],
          );
          if (constraints.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                details,
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: details),
              const SizedBox(width: 8),
              actions,
            ],
          );
        },
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
                  '${displayFloorLabel(job.floorLabel)} / ${job.tableNumber} / '
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
