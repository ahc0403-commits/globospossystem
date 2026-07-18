import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/hardware/print_agent_coordinator.dart';
import '../../core/hardware/print_agent_coordinator_provider.dart';
import '../../core/i18n/locale_extensions.dart';
import '../auth/auth_provider.dart';
import 'store_setup_localization.dart';
import 'store_setup_models.dart';
import 'store_setup_provider.dart';
import 'widgets/physical_printer_form.dart';
import 'widgets/print_test_checklist.dart';
import 'widgets/readiness_summary.dart';
import 'widgets/route_preview.dart';
import 'widgets/table_bulk_editor.dart';
import 'widgets/workforce_setup_card.dart';

class StoreSetupScreen extends ConsumerWidget {
  const StoreSetupScreen({super.key, required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                      child: Row(
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
                          const SizedBox(width: 8),
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
                        content: _PrinterStep(
                          draft: state.draft,
                          onPrinterChanged: notifier.updatePrinter,
                          onFloor1Changed: notifier.setFloor1Slot,
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
                        content: const _PrintAgentStep(),
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

class _PrinterStep extends StatelessWidget {
  const _PrinterStep({
    required this.draft,
    required this.onPrinterChanged,
    required this.onFloor1Changed,
  });

  final StoreOpeningDraft draft;
  final ValueChanged<PhysicalPrinterDraft> onPrinterChanged;
  final ValueChanged<PhysicalPrinterSlot> onFloor1Changed;

  @override
  Widget build(BuildContext context) {
    String title(PhysicalPrinterSlot slot) =>
        localizePhysicalPrinterSlot(context.l10n, slot);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 760 ? 2 : 1;
            final width = columns == 2
                ? (constraints.maxWidth - 12) / 2
                : constraints.maxWidth;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final slot in PhysicalPrinterSlot.values)
                  SizedBox(
                    width: width,
                    child: PhysicalPrinterForm(
                      key: ValueKey(slot),
                      title: title(slot),
                      printer: draft.printers[slot]!,
                      onChanged: onPrinterChanged,
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        Text(context.l10n.storeSetupFloor1Share),
        DropdownButton<PhysicalPrinterSlot>(
          key: const Key('store_setup_floor1_physical_slot'),
          value: draft.floor1Slot,
          isExpanded: true,
          items: [
            for (final slot in PhysicalPrinterSlot.values)
              DropdownMenuItem(value: slot, child: Text(title(slot))),
          ],
          onChanged: (value) {
            if (value != null) onFloor1Changed(value);
          },
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
  const _PrintAgentStep();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(printAgentCoordinatorProvider);
    final coordinator = ref.read(printAgentCoordinatorProvider.notifier);
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
                state.status == PrintAgentStatus.running
                    ? Icons.check_circle
                    : Icons.warning_amber,
              ),
              title: Text(
                state.status == PrintAgentStatus.running
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

class _TestsStep extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          key: const Key('store_setup_run_five_tests'),
          onPressed: state.applyResult == null
              ? null
              : () => unawaited(onRun()),
          icon: const Icon(Icons.print_outlined),
          label: Text(context.l10n.storeSetupRunFiveTests),
        ),
        const SizedBox(height: 12),
        PrintTestChecklist(
          jobs: state.testJobs,
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
