import 'package:flutter/material.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../store_setup_localization.dart';

class ReadinessSummary extends StatelessWidget {
  const ReadinessSummary({
    super.key,
    required this.readiness,
    required this.operationallyReady,
  });

  final Map<String, dynamic>? readiness;
  final bool operationallyReady;

  @override
  Widget build(BuildContext context) {
    final checks = (readiness?['checks'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row));
    final recovery = (readiness?['recovery'] as List? ?? const []).map(
      (value) => value.toString(),
    );
    return Card(
      color: operationallyReady
          ? Theme.of(context).colorScheme.primaryContainer
          : Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              operationallyReady
                  ? context.l10n.storeSetupReady
                  : context.l10n.storeSetupNotReady,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            for (final check in checks)
              ListTile(
                dense: true,
                leading: Icon(
                  check['ok'] == true ? Icons.check_circle : Icons.warning,
                ),
                title: Text(
                  localizeReadinessCheck(
                    context.l10n,
                    check['code']?.toString() ?? '',
                  ),
                ),
              ),
            for (final code in recovery)
              Text(localizeStoreSetupRecovery(context.l10n, code)),
          ],
        ),
      ),
    );
  }
}
