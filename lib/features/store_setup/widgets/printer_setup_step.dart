import 'package:flutter/material.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../store_setup_models.dart';
import '../store_setup_localization.dart';
import 'physical_printer_form.dart';

class StoreSetupPrinterStep extends StatelessWidget {
  const StoreSetupPrinterStep({
    super.key,
    required this.draft,
    required this.onPrinterChanged,
    required this.onFloor1Changed,
    required this.onOperationChanged,
    this.onServiceWorkflowChanged,
    required this.enabled,
  });

  final StoreOpeningDraft draft;
  final ValueChanged<PhysicalPrinterDraft> onPrinterChanged;
  final ValueChanged<PhysicalPrinterSlot> onFloor1Changed;
  final ValueChanged<StorePrinterOperation> onOperationChanged;
  final bool enabled;
  final ValueChanged<StoreServiceWorkflow>? onServiceWorkflowChanged;

  @override
  Widget build(BuildContext context) {
    String title(PhysicalPrinterSlot slot) =>
        localizePhysicalPrinterSlot(context.l10n, slot);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.l10n.storeSetupOperationTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              key: const Key('store_setup_mode_paperless'),
              label: Text(context.l10n.storeSetupPaperless),
              selected: draft.operation == StorePrinterOperation.paperless,
              onSelected: enabled
                  ? (_) => onOperationChanged(StorePrinterOperation.paperless)
                  : null,
            ),
            ChoiceChip(
              key: const Key('store_setup_mode_pos_print'),
              label: Text(context.l10n.storeSetupPhysical),
              selected: draft.operation == StorePrinterOperation.posPrint,
              onSelected: enabled
                  ? (_) => onOperationChanged(StorePrinterOperation.posPrint)
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          draft.operation == StorePrinterOperation.paperless
              ? context.l10n.storeSetupPaperlessDescription
              : context.l10n.storeSetupPhysicalDescription,
        ),
        const SizedBox(height: 16),
        Text(
          context.l10n.storeSetupServiceWorkflowTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final workflow in StoreServiceWorkflow.values)
              ChoiceChip(
                key: Key('store_setup_workflow_${workflow.code}'),
                label: Text(
                  workflow == StoreServiceWorkflow.kitchenFloor
                      ? context.l10n.storeSetupKitchenFloor
                      : context.l10n.storeSetupKitchenTrayFloor,
                ),
                selected: draft.serviceWorkflow == workflow,
                onSelected: enabled && onServiceWorkflowChanged != null
                    ? (_) => onServiceWorkflowChanged!(workflow)
                    : null,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(context.l10n.storeSetupServiceWorkflowHelp),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns =
                constraints.maxWidth >= 760 &&
                    draft.requiredPrinterSlots.length > 1
                ? 2
                : 1;
            final width = columns == 2
                ? (constraints.maxWidth - 12) / 2
                : constraints.maxWidth;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final slot in draft.requiredPrinterSlots)
                  SizedBox(
                    width: width,
                    child: PhysicalPrinterForm(
                      key: ValueKey(slot),
                      title: title(slot),
                      printer: draft.printers[slot]!,
                      onChanged: onPrinterChanged,
                      enabled: enabled,
                    ),
                  ),
              ],
            );
          },
        ),
        if (draft.operation == StorePrinterOperation.posPrint) ...[
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
            onChanged: !enabled
                ? null
                : (value) {
                    if (value != null) onFloor1Changed(value);
                  },
          ),
        ],
      ],
    );
  }
}
