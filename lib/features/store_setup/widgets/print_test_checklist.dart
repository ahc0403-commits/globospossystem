import 'package:flutter/material.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../store_setup_localization.dart';
import '../store_setup_models.dart';

class PrintTestChecklist extends StatelessWidget {
  const PrintTestChecklist({
    super.key,
    required this.jobs,
    required this.onConfirm,
    required this.onRetry,
  });

  final Map<String, StoreSetupTestJob> jobs;
  final void Function(String label, bool confirmed) onConfirm;
  final ValueChanged<String> onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final entry in jobs.entries)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    entry.key,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    context.l10n.storeSetupTestJobStatus(
                      localizePrintJobStatus(context.l10n, entry.value.status),
                    ),
                  ),
                  Text('Job ID: ${entry.value.jobId}'),
                  if (entry.value.error != null)
                    Text(
                      localizePrintJobError(context.l10n, entry.value.error!),
                    ),
                  CheckboxListTile(
                    key: Key('store_setup_confirm_${entry.key}'),
                    contentPadding: EdgeInsets.zero,
                    value: entry.value.physicallyConfirmed,
                    onChanged: entry.value.status == 'done'
                        ? (value) => onConfirm(entry.key, value == true)
                        : null,
                    title: Text(context.l10n.storeSetupConfirmPhysicalOutput),
                  ),
                  if (entry.value.status == 'failed')
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                        onPressed: () => onRetry(entry.key),
                        child: Text(context.l10n.storeSetupRetryTest),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
