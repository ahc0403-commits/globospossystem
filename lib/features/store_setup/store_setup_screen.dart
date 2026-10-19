import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/hardware/print_agent_coordinator_provider.dart';
import '../../core/i18n/locale_extensions.dart';
import '../auth/auth_provider.dart';
import 'store_setup_localization.dart';
import 'store_setup_models.dart';
import 'store_setup_provider.dart';
import 'widgets/printer_setup_step.dart';
import 'widgets/print_test_checklist.dart';
import 'widgets/readiness_summary.dart';
import 'widgets/route_preview.dart';
import 'widgets/table_bulk_editor.dart';
import 'widgets/workforce_setup_card.dart';

class StoreSetupScreen extends ConsumerStatefulWidget {
  const StoreSetupScreen({super.key, required this.storeId});

  final String storeId;

  @override
  ConsumerState<StoreSetupScreen> createState() => _StoreSetupScreenState();
}

class _StoreSetupScreenState extends ConsumerState<StoreSetupScreen> {
  bool _storeSelectionInFlight = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual(
      authProvider,
      (_, next) => _scheduleStoreSelection(),
      fireImmediately: true,
    );
  }

  @override
  void didUpdateWidget(StoreSetupScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storeId != widget.storeId) _scheduleStoreSelection();
  }

  void _scheduleStoreSelection() {
    // Follow the same authorized active-store selection as Enter Store. The
    // app-root print agent consumes that scope; the route ID alone does not.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final auth = ref.read(authProvider);
      if (!_storeSelectionInFlight &&
          auth.user != null &&
          auth.storeId != widget.storeId) {
        unawaited(_selectStore(widget.storeId));
      }
    });
  }

  Future<void> _selectStore(String storeId) async {
    _storeSelectionInFlight = true;
    try {
      await ref.read(authProvider.notifier).setActiveStoreForSetup(storeId);
    } finally {
      _storeSelectionInFlight = false;
      if (mounted && widget.storeId != storeId) _scheduleStoreSelection();
    }
  }

  @override
  Widget build(BuildContext context) {
    final storeId = widget.storeId;
    final state = ref.watch(storeSetupProvider(storeId));
    final notifier = ref.read(storeSetupProvider(storeId).notifier);
    final auth = ref.watch(authProvider);
    final compactAppBar =
        MediaQuery.sizeOf(context).width < 600 ||
        MediaQuery.textScalerOf(context).scale(1) > 1.5;
    void openAdvancedDestinations() => context.go(
      auth.role == 'super_admin'
          ? '/admin/$storeId?tab=settings'
          : '/admin?tab=settings',
    );

    return Scaffold(
      key: const Key('store_setup_root'),
      appBar: AppBar(
        title: Text(context.l10n.storeSetupTitle),
        leading: IconButton(
          onPressed: () => context.go(
            auth.role == 'super_admin' ? '/super-admin' : '/admin',
          ),
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          if (compactAppBar)
            IconButton(
              key: const Key('store_setup_advanced'),
              onPressed: openAdvancedDestinations,
              tooltip: context.l10n.storeSetupAdvancedDestinations,
              icon: const Icon(Icons.tune),
            )
          else
            TextButton.icon(
              key: const Key('store_setup_advanced'),
              onPressed: openAdvancedDestinations,
              icon: const Icon(Icons.tune),
              label: Text(context.l10n.storeSetupAdvancedDestinations),
            ),
        ],
      ),
      body: state.phase == StoreSetupPhase.loadingExisting
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (state.errorCode != null)
                  MaterialBanner(
                    content: Text(_localizedError(context, state.errorCode!)),
                    actions: [
                      TextButton(
                        onPressed: notifier.loadExisting,
                        child: Text(context.l10n.retry),
                      ),
                    ],
                  ),
                Expanded(
                  child: Stepper(
                    key: const Key('store_setup_six_step_wizard'),
                    type:
                        MediaQuery.sizeOf(context).width >= 1800 &&
                            MediaQuery.textScalerOf(context).scale(1) <= 1.2
                        ? StepperType.horizontal
                        : StepperType.vertical,
                    currentStep: state.step,
                    onStepTapped: notifier.goToStep,
                    controlsBuilder: (context, details) => Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (state.step > 0)
                            OutlinedButton(
                              key: ValueKey(
                                'store_setup_previous_${details.stepIndex}',
                              ),
                              onPressed: state.isBusy
                                  ? null
                                  : () => notifier.goToStep(state.step - 1),
                              child: Text(context.l10n.storeSetupPrevious),
                            ),
                          if (state.step < 5)
                            FilledButton(
                              key: ValueKey(
                                'store_setup_next_${details.stepIndex}',
                              ),
                              onPressed: state.isBusy
                                  ? null
                                  : () => notifier.goToStep(state.step + 1),
                              child: Text(context.l10n.storeSetupNext),
                            ),
                        ],
                      ),
                    ),
                    steps: [
                      Step(
                        title: Text(context.l10n.storeSetupStepStore),
                        isActive: state.step >= 0,
                        content: _StoreTemplateStep(
                          store: state.store,
                          storeId: storeId,
                          workforceReadiness: state.workforceReadiness,
                          isSavingWorkforce: state.isSavingWorkforce,
                          onSaveWorkforce: notifier.configureWorkforce,
                          onRefreshWorkforce: () =>
                              notifier.refreshWorkforceReadiness(silent: false),
                          onProvisionAccount: notifier.provisionFixedAccount,
                        ),
                      ),
                      Step(
                        title: Text(context.l10n.storeSetupStepTables),
                        isActive: state.step >= 1,
                        content: TableBulkEditor(
                          tables: state.draft.tables,
                          onAdd: notifier.addTables,
                          onRemove: notifier.removeTableAt,
                          onReassign: notifier.reassignTables,
                        ),
                      ),
                      Step(
                        title: Text(context.l10n.storeSetupStepPrinters),
                        isActive: state.step >= 2,
                        content: StoreSetupPrinterStep(
                          draft: state.draft,
                          onPrinterChanged: notifier.updatePrinter,
                          onFloor1Changed: notifier.setFloor1Slot,
                          onOperationChanged: notifier.setOperation,
                          enabled: !state.isBusy,
                        ),
                      ),
                      Step(
                        title: Text(context.l10n.storeSetupStepRoutes),
                        isActive: state.step >= 3,
                        content: _PreviewApplyStep(
                          state: state,
                          onValidate: notifier.validate,
                          onApply: notifier.apply,
                        ),
                      ),
                      Step(
                        title: Text(context.l10n.storeSetupStepAgent),
                        isActive: state.step >= 4,
                        content: _PrintAgentStep(storeId: storeId),
                      ),
                      Step(
                        title: Text(context.l10n.storeSetupStepTests),
                        isActive: state.step >= 5,
                        content: _TestsStep(
                          state: state,
                          onRun: notifier.runAllTests,
                          onRetry: notifier.retryTest,
                          onConfirm: notifier.confirmPhysicalOutput,
                          onRefresh: notifier.refreshReadiness,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

String _localizedError(BuildContext context, String code) {
  return localizeStoreSetupFlowError(context.l10n, code);
}

class _StoreTemplateStep extends StatelessWidget {
  const _StoreTemplateStep({
    required this.store,
    required this.storeId,
    required this.workforceReadiness,
    required this.isSavingWorkforce,
    required this.onSaveWorkforce,
    required this.onRefreshWorkforce,
    required this.onProvisionAccount,
  });

  final Map<String, dynamic> store;
  final String storeId;
  final Map<String, dynamic>? workforceReadiness;
  final bool isSavingWorkforce;
  final Future<bool> Function({
    required String shortCode,
    required String managementModel,
    required int brandManagerSlots,
    required List<WorkforceAccountTemplate> accountTemplates,
  })
  onSaveWorkforce;
  final Future<void> Function() onRefreshWorkforce;
  final Future<bool> Function({
    required String requirementId,
    required String password,
  })
  onProvisionAccount;

  @override
  Widget build(BuildContext context) {
    final brand = store['brands'] is Map
        ? (store['brands'] as Map)['name']?.toString()
        : null;
    final entity = store['tax_entity'] is Map
        ? (store['tax_entity'] as Map)['name']?.toString()
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  context.l10n.storeSetupSubtitle,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 16),
                Text(
                  '${context.l10n.storeSetupSelectedStore}: '
                  '${store['name'] ?? storeId}',
                ),
                Text('${context.l10n.storeSetupStoreId}: $storeId'),
                Text('${context.l10n.superAdminBrand}: ${brand ?? '-'}'),
                Text('${context.l10n.superAdminLegalEntity}: ${entity ?? '-'}'),
                Text(
                  '${context.l10n.settingsPrintDestinationActive}: '
                  '${store['is_active'] == true ? context.l10n.yes : context.l10n.no}',
                ),
                const Divider(height: 28),
                Text(
                  context.l10n.storeSetupTemplateName,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Text(context.l10n.storeSetupTemplateDescription),
                Text(context.l10n.storeSetupFloors),
              ],
            ),
          ),
        ),
        WorkforceSetupCard(
          store: store,
          readiness: workforceReadiness,
          isSaving: isSavingWorkforce,
          onSave: onSaveWorkforce,
          onRefresh: onRefreshWorkforce,
          onProvision: onProvisionAccount,
        ),
      ],
    );
  }
}

class _PreviewApplyStep extends StatelessWidget {
  const _PreviewApplyStep({
    required this.state,
    required this.onValidate,
    required this.onApply,
  });

  final StoreSetupState state;
  final Future<bool> Function() onValidate;
  final Future<bool> Function() onApply;

  @override
  Widget build(BuildContext context) {
    final validation = state.validation;
    final plan = validation?.plan ?? const <String, int>{};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StoreSetupRoutePreview(destinations: state.draft.destinations),
        const SizedBox(height: 16),
        if (validation != null) ...[
          Text(
            validation.valid
                ? context.l10n.storeSetupValidationReady
                : context.l10n.storeSetupValidationBlocked,
          ),
          Text(
            context.l10n.storeSetupPlanCounts(
              plan['tables_create'] ?? 0,
              plan['tables_update'] ?? 0,
              plan['destinations_create'] ?? 0,
              plan['destinations_update'] ?? 0,
            ),
          ),
          for (final error in validation.errors)
            ListTile(
              leading: const Icon(Icons.error_outline),
              title: Text(context.l10n.storeSetupErrorInvalid),
              subtitle: Text(localizeStoreSetupValidation(context.l10n, error)),
            ),
          for (final warning in validation.warnings)
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(context.l10n.storeSetupRowsUntouched),
              subtitle: Text(
                localizeStoreSetupValidation(context.l10n, warning),
              ),
            ),
        ],
        if (state.applyResult != null) Text(context.l10n.storeSetupApplied),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              key: const Key('store_setup_validate'),
              onPressed: state.isBusy ? null : () => unawaited(onValidate()),
              icon: const Icon(Icons.fact_check_outlined),
              label: Text(context.l10n.storeSetupValidate),
            ),
            FilledButton.icon(
              key: const Key('store_setup_apply'),
              onPressed: state.isBusy || validation?.valid != true
                  ? null
                  : () => unawaited(onApply()),
              icon: const Icon(Icons.save_outlined),
              label: Text(context.l10n.storeSetupApplyAtomically),
            ),
          ],
        ),
      ],
    );
  }
}

class _PrintAgentStep extends ConsumerWidget {
  const _PrintAgentStep({required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(printAgentCoordinatorProvider);
    final coordinator = ref.read(printAgentCoordinatorProvider.notifier);
    final runningForStore = state.isRunning && state.activeStoreId == storeId;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              key: const Key('store_setup_print_agent_toggle'),
              contentPadding: EdgeInsets.zero,
              value: state.enabled,
              onChanged: !state.preferenceLoaded || !coordinator.isSupported
                  ? null
                  : (enabled) => unawaited(coordinator.setEnabled(enabled)),
              title: Text(context.l10n.storeSetupPrintAgentToggle),
              subtitle: Text(context.l10n.storeSetupPrintAgentHelp),
            ),
            ListTile(
              leading: Icon(
                runningForStore ? Icons.check_circle : Icons.warning_amber,
              ),
              title: Text(
                runningForStore
                    ? context.l10n.storeSetupPrintAgentRunning
                    : context.l10n.storeSetupPrintAgentStopped,
              ),
              subtitle: state.lastError == null
                  ? null
                  : Text(_localizedError(context, state.lastError!)),
            ),
          ],
        ),
      ),
    );
  }
}

class _TestsStep extends ConsumerWidget {
  const _TestsStep({
    required this.state,
    required this.onRun,
    required this.onRetry,
    required this.onConfirm,
    required this.onRefresh,
  });

  final StoreSetupState state;
  final Future<void> Function() onRun;
  final Future<void> Function(String label) onRetry;
  final void Function(String label, bool confirmed) onConfirm;
  final Future<void> Function({bool silent}) onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agent = ref.watch(printAgentCoordinatorProvider);
    final runningForStore =
        agent.isRunning && agent.activeStoreId == state.draft.storeId;
    // Web setup can queue tests for a separate Windows station. On a supported
    // native station, require this device's agent to consume the selected store.
    final localAgentRequired = ref
        .read(printAgentCoordinatorProvider.notifier)
        .isSupported;
    final agentReady = !localAgentRequired || runningForStore;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!agentReady)
          Text(
            '${context.l10n.storeSetupStepAgent}: '
            '${context.l10n.storeSetupPrintAgentStopped}',
          ),
        FilledButton.icon(
          key: const Key('store_setup_run_five_tests'),
          onPressed: state.applyResult == null || state.isBusy || !agentReady
              ? null
              : () => unawaited(onRun()),
          icon: const Icon(Icons.print_outlined),
          label: Text(context.l10n.storeSetupRunFiveTests),
        ),
        const SizedBox(height: 12),
        PrintTestChecklist(
          jobs: state.testJobs,
          enabled: agentReady && !state.isBusy,
          onConfirm: onConfirm,
          onRetry: (label) => unawaited(onRetry(label)),
        ),
        OutlinedButton.icon(
          onPressed: () => unawaited(onRefresh(silent: false)),
          icon: const Icon(Icons.refresh),
          label: Text(context.l10n.storeSetupRefreshReadiness),
        ),
        ReadinessSummary(
          readiness: state.readiness,
          operationallyReady: state.operationallyReady,
        ),
      ],
    );
  }
}
