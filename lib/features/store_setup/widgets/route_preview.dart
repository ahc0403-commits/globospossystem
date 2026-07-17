import 'package:flutter/material.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../store_setup_localization.dart';
import '../store_setup_models.dart';

class StoreSetupRoutePreview extends StatelessWidget {
  const StoreSetupRoutePreview({super.key, required this.destinations});

  final List<LogicalDestinationDraft> destinations;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.l10n.storeSetupRoutePreview,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        for (final destination in destinations)
          Card(
            child: ListTile(
              key: Key('store_setup_route_${destination.label}'),
              leading: const Icon(Icons.route_outlined),
              title: Text(
                localizeStoreSetupTestLabel(context.l10n, destination.label),
              ),
              subtitle: Text(
                '${context.l10n.storeSetupRoutePurpose}: '
                '${localizeStoreSetupRoutePurpose(context.l10n, destination.purpose)}'
                '${destination.floorLabel == null ? '' : '/${destination.floorLabel}'}\n'
                '${destination.ip}:${destination.port}',
              ),
              trailing: Text(
                '${context.l10n.storeSetupRoutePhysical}\n'
                '${localizePhysicalPrinterSlot(context.l10n, destination.physicalSlot)}',
                textAlign: TextAlign.end,
              ),
            ),
          ),
        Text(context.l10n.storeSetupRowsUntouched),
      ],
    );
  }
}
