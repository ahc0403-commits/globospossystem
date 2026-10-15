import 'package:flutter/material.dart';
import 'procurement_presentation.dart';
import 'procurement_process_labels.dart';

class ProcurementRequestCard extends StatelessWidget {
  const ProcurementRequestCard({
    super.key,
    required this.request,
    required this.selected,
    required this.onOpen,
  });
  final Map<String, dynamic> request;
  final bool selected;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final language = Localizations.localeOf(context).languageCode;
    String copy(String key) => procurementProcessLabel(key, language);
    final colors = Theme.of(context).colorScheme;
    final count = request['line_count'] ?? 0;
    final name = request['requester_name']?.toString().trim();
    final role = request['requester_role']?.toString();
    final requester = name == null || name.isEmpty
        ? copy('unavailableRequester')
        : name;
    final roleName = switch (role) {
      'inventory_orderer' => copy('requesterRole'),
      'store_admin' => copy('storeManagerRole'),
      'super_admin' => copy('administratorRole'),
      _ => '',
    };
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${request['request_no']}',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        Text(
          '${copy('requestDate')} ${procurementDate(request['created_at'])}  |  ${copy('requiredDate')} ${procurementDate(request['requested_delivery_date'])}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_2_outlined, size: 17, color: colors.primary),
            const SizedBox(width: 6),
            Text('$count ${copy('itemCount')}'),
          ],
        ),
        if (request['approval_group'] == 'approved') ...[
          const SizedBox(height: 6),
          Text(
            request['status'] == 'office_review'
                ? copy('storeApprovedAwaitingBuyer')
                : copy(request['status']?.toString() ?? 'approved'),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.primary),
          ),
        ],
      ],
    );
    final author = Text(
      '${copy('requester')}: $requester${roleName.isEmpty ? '' : ' ($roleName)'}',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    final reason = Text(
      '${copy('requestReason')}: ${request['reason'] ?? '—'}',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    final button = OutlinedButton.icon(
      onPressed: onOpen,
      label: Text(copy('viewDetails')),
      icon: const Icon(Icons.chevron_right, size: 18),
      iconAlignment: IconAlignment.end,
    );
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
        ),
      ),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 850 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.4) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    identity,
                    const SizedBox(height: 12),
                    author,
                    const SizedBox(height: 6),
                    reason,
                    const SizedBox(height: 10),
                    Align(alignment: Alignment.centerRight, child: button),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(flex: 5, child: identity),
                  const SizedBox(width: 20),
                  Expanded(flex: 3, child: author),
                  const SizedBox(width: 20),
                  Expanded(flex: 4, child: reason),
                  const SizedBox(width: 20),
                  button,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
