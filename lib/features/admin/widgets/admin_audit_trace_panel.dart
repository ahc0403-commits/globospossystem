import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../../main.dart';
import '../providers/admin_audit_provider.dart';

class AdminAuditTracePanel extends ConsumerWidget {
  const AdminAuditTracePanel({
    super.key,
    required this.auditTraceAsync,
    this.storeId,
    this.allowedEntityTypes,
    this.maxItems = 5,
    this.emptyMessage = 'No recent changes to display.',
    this.showRetry = false,
    this.compact = false,
  });

  final AsyncValue<List<Map<String, dynamic>>> auditTraceAsync;
  final String? storeId;
  final Set<String>? allowedEntityTypes;
  final int maxItems;
  final String emptyMessage;
  final bool showRetry;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return auditTraceAsync.when(
      data: (rows) {
        final filteredRows = rows
            .where((row) {
              if (allowedEntityTypes == null) {
                return true;
              }

              final entityType = row['entity_type']?.toString() ?? '';
              return allowedEntityTypes!.contains(entityType);
            })
            .take(maxItems)
            .toList();

        if (filteredRows.isEmpty) {
          return _panelContainer(
            child: Text(
              emptyMessage,
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: compact ? 12 : 13,
              ),
            ),
          );
        }

        return _panelContainer(
          child: Column(
            children: [
              for (var index = 0; index < filteredRows.length; index++) ...[
                _AuditTraceRow(row: filteredRows[index], compact: compact),
                if (index < filteredRows.length - 1)
                  const Divider(height: 1, color: AppColors.surface2),
              ],
            ],
          ),
        );
      },
      loading: () => _panelContainer(
        child: SizedBox(
          height: compact ? 28 : 40,
          child: const Center(
            child: CircularProgressIndicator(
              color: AppColors.amber500,
              strokeWidth: 2,
            ),
          ),
        ),
      ),
      error: (error, _) => _panelContainer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              mapAdminAuditError(error),
              style: GoogleFonts.notoSansKr(
                color: AppColors.statusCancelled,
                fontSize: compact ? 12 : 13,
              ),
            ),
            if (showRetry && storeId != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: () =>
                      ref.refresh(adminAuditTraceProvider(storeId!)),
                  child: const Text('Retry'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _panelContainer({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 12 : 14),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surface2),
      ),
      child: child,
    );
  }
}

class _AuditTraceRow extends StatelessWidget {
  const _AuditTraceRow({required this.row, required this.compact});

  final Map<String, dynamic> row;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final createdAtRaw = row['created_at']?.toString();
    final createdAt = createdAtRaw == null
        ? null
        : DateTime.tryParse(createdAtRaw)?.toLocal();
    final timestamp = createdAt == null
        ? '-'
        : DateFormat('dd/MM HH:mm').format(createdAt);
    final actorName = row['actor_name']?.toString() ?? 'Unknown';
    final entityType = row['entity_type']?.toString() ?? '';
    final action = row['action']?.toString() ?? '';
    final changedFields = _extractChangedFields(row['changed_fields']);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 8 : 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '${_entityLabel(entityType)} · ${_actionLabel(action)}',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textPrimary,
                    fontSize: compact ? 12 : 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                timestamp,
                style: GoogleFonts.notoSansKr(
                  color: AppColors.textSecondary,
                  fontSize: compact ? 11 : 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Actor: $actorName',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: compact ? 11 : 12,
            ),
          ),
          if (changedFields.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Changed fields: ${changedFields.join(', ')}',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: compact ? 11 : 12,
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<String> _extractChangedFields(dynamic raw) {
    if (raw is! List) {
      return const [];
    }

    return raw.map((field) => _fieldLabel(field.toString())).toList();
  }

  String _entityLabel(String entityType) {
    return switch (entityType) {
      'restaurants' => 'Store',
      'tables' => 'Table',
      'menu_categories' => 'Category',
      'menu_items' => 'Menu',
      'orders' => 'Order',
      'order_items' => 'Order Items',
      'payments' => 'Payment',
      _ => entityType,
    };
  }

  String _actionLabel(String action) {
    return switch (action) {
      'admin_create_restaurant' => 'Created',
      'admin_update_restaurant' => 'Edit',
      'admin_update_restaurant_settings' => 'Settings Updated',
      'admin_deactivate_restaurant' => 'Deactivated',
      'admin_create_table' => 'Add',
      'admin_update_table' => 'Edit',
      'admin_delete_table' => 'Delete',
      'admin_create_menu_category' => 'Add',
      'admin_update_menu_category' => 'Edit',
      'admin_delete_menu_category' => 'Delete',
      'admin_create_menu_item' => 'Add',
      'admin_update_menu_item' => 'Edit',
      'admin_delete_menu_item' => 'Delete',
      'create_order' => 'Order Created',
      'create_buffet_order' => 'Buffet Order',
      'add_items_to_order' => 'Add Item',
      'cancel_order' => 'Cancel Order',
      'cancel_order_item' => 'Cancel Item',
      'edit_order_item_quantity' => 'Change Quantity',
      'transfer_order_table' => 'Move Table',
      'process_payment' => 'Process Payment',
      'update_order_item_status' => 'Status Changed',
      _ => action,
    };
  }

  String _fieldLabel(String field) {
    return switch (field) {
      'name' => 'Name',
      'address' => 'Address',
      'slug' => 'Slug',
      'operation_mode' => 'Operation Mode',
      'per_person_charge' => 'Per-person Charge',
      'brand_id' => 'Brand',
      'store_type' => 'Store Type',
      'is_active' => 'Active Status',
      'table_number' => 'Table Number',
      'seat_count' => 'Seat Count',
      'status' => 'Status',
      'sort_order' => 'Sort Order',
      'category_id' => 'Category',
      'description' => 'Description',
      'price' => 'Price',
      'is_available' => 'Available',
      'is_visible_public' => 'Public',
      _ => field,
    };
  }
}
