import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:intl/intl.dart';

import '../../../core/i18n/locale_extensions.dart';
import '../../../main.dart';
import '../providers/admin_audit_provider.dart';

class AdminAuditTracePanel extends ConsumerWidget {
  const AdminAuditTracePanel({
    super.key,
    required this.auditTraceAsync,
    this.storeId,
    this.allowedEntityTypes,
    this.maxItems = 5,
    this.emptyMessage,
    this.showRetry = false,
    this.compact = false,
  });

  final AsyncValue<List<Map<String, dynamic>>> auditTraceAsync;
  final String? storeId;
  final Set<String>? allowedEntityTypes;
  final int maxItems;
  final String? emptyMessage;
  final bool showRetry;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
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
              emptyMessage ?? l10n.adminAuditNoRecentChanges,
              style: AppFonts.system(
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
              _errorMessage(context, classifyAdminAuditError(error)),
              style: AppFonts.system(
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
                  child: Text(l10n.retry),
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
    final languageCode = Localizations.localeOf(context).languageCode;
    final l10n = context.l10n;
    final timestamp = createdAt == null
        ? '-'
        : DateFormat.yMd(languageCode).add_Hm().format(createdAt);
    final actorName = row['actor_name']?.toString().trim();
    final entityType = row['entity_type']?.toString() ?? '';
    final action = row['action']?.toString() ?? '';
    final changedFields = _extractChangedFields(context, row['changed_fields']);

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
                  '${_entityLabel(context, entityType)} · ${_actionLabel(context, action)}',
                  style: AppFonts.system(
                    color: AppColors.textPrimary,
                    fontSize: compact ? 12 : 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                timestamp,
                style: AppFonts.system(
                  color: AppColors.textSecondary,
                  fontSize: compact ? 11 : 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.adminAuditActor(
              actorName == null || actorName.isEmpty
                  ? l10n.adminAuditUnknownActor
                  : actorName,
            ),
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontSize: compact ? 11 : 12,
            ),
          ),
          if (changedFields.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              l10n.adminAuditChangedFields(changedFields.join(', ')),
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: compact ? 11 : 12,
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<String> _extractChangedFields(BuildContext context, dynamic raw) {
    if (raw is! List) {
      return const [];
    }

    return raw.map((field) => _fieldLabel(context, field.toString())).toList();
  }

  String _entityLabel(BuildContext context, String entityType) {
    final l10n = context.l10n;
    return switch (entityType) {
      'restaurants' => l10n.adminAuditEntityStore,
      'tables' => l10n.adminAuditEntityTable,
      'menu_categories' => l10n.adminAuditEntityCategory,
      'menu_items' => l10n.adminAuditEntityMenu,
      'orders' => l10n.adminAuditEntityOrder,
      'order_items' => l10n.adminAuditEntityOrderItems,
      'payments' => l10n.adminAuditEntityPayment,
      _ => l10n.adminAuditUnknownValue,
    };
  }

  String _actionLabel(BuildContext context, String action) {
    final l10n = context.l10n;
    return switch (action) {
      'admin_create_restaurant' => l10n.adminAuditActionCreated,
      'admin_update_restaurant' => l10n.edit,
      'admin_update_restaurant_settings' =>
        l10n.adminAuditActionSettingsUpdated,
      'admin_deactivate_restaurant' => l10n.adminAuditActionDeactivated,
      'admin_create_table' ||
      'admin_create_menu_category' ||
      'admin_create_menu_item' => l10n.add,
      'admin_update_table' ||
      'admin_update_menu_category' ||
      'admin_update_menu_item' => l10n.edit,
      'admin_delete_table' ||
      'admin_delete_menu_category' ||
      'admin_delete_menu_item' => l10n.adminAuditActionDeleted,
      'create_order' => l10n.adminAuditActionOrderCreated,
      'create_buffet_order' => l10n.adminAuditActionBuffetOrder,
      'add_items_to_order' => l10n.adminAuditActionItemAdded,
      'cancel_order' => l10n.adminAuditActionOrderCancelled,
      'cancel_order_item' => l10n.adminAuditActionItemCancelled,
      'edit_order_item_quantity' => l10n.adminAuditActionQuantityChanged,
      'transfer_order_table' => l10n.adminAuditActionTableMoved,
      'process_payment' => l10n.adminAuditActionPaymentProcessed,
      'update_order_item_status' => l10n.statusChanged,
      _ => l10n.adminAuditUnknownValue,
    };
  }

  String _fieldLabel(BuildContext context, String field) {
    final l10n = context.l10n;
    return switch (field) {
      'name' => l10n.name,
      'address' => l10n.address,
      'slug' => l10n.adminAuditFieldSlug,
      'operation_mode' => l10n.adminAuditFieldOperationMode,
      'per_person_charge' => l10n.adminAuditFieldPerPersonCharge,
      'brand_id' => l10n.adminAuditFieldBrand,
      'store_type' => l10n.adminAuditFieldStoreType,
      'is_active' => l10n.adminAuditFieldActiveStatus,
      'table_number' => l10n.adminAuditFieldTableNumber,
      'seat_count' => l10n.adminAuditFieldSeatCount,
      'floor_label' => l10n.adminAuditFieldFloorLabel,
      'status' => l10n.status,
      'layout_x' => l10n.adminAuditFieldLayoutX,
      'layout_y' => l10n.adminAuditFieldLayoutY,
      'layout_w' => l10n.adminAuditFieldLayoutWidth,
      'layout_h' => l10n.adminAuditFieldLayoutHeight,
      'layout_rotation' => l10n.adminAuditFieldLayoutRotation,
      'layout_shape' => l10n.adminAuditFieldLayoutShape,
      'layout_sort_order' => l10n.adminAuditFieldLayoutOrder,
      'sort_order' => l10n.adminAuditFieldSortOrder,
      'category_id' => l10n.adminAuditFieldCategory,
      'description' => l10n.adminAuditFieldDescription,
      'price' => l10n.adminAuditFieldPrice,
      'is_available' => l10n.adminAuditFieldAvailable,
      'is_visible_public' => l10n.adminAuditFieldPublic,
      _ => l10n.adminAuditUnknownValue,
    };
  }
}

String _errorMessage(BuildContext context, AdminAuditErrorKind kind) {
  final l10n = context.l10n;
  return switch (kind) {
    AdminAuditErrorKind.loadFailed => l10n.adminAuditLoadFailed,
    AdminAuditErrorKind.storeRequired => l10n.adminAuditStoreRequired,
    AdminAuditErrorKind.forbidden => l10n.adminAuditForbidden,
  };
}
