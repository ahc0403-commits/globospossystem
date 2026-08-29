import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/permission_utils.dart';
import 'package:globos_pos_system/core/utils/role_routes.dart';
import 'package:globos_pos_system/features/inventory_purchase/inventory_purchase_document_service.dart';
import 'package:globos_pos_system/features/inventory_purchase/supplier_price_excel_import.dart';
import 'package:globos_pos_system/l10n/app_localizations_ko.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('inventory orderer has only the shared purchase workflow home', () {
    expect(kKnownPosRoles, contains('inventory_orderer'));
    expect(homeRouteForRole('inventory_orderer'), '/inventory-orders');
    expect(
      canAccessRouteForRole('inventory_orderer', '/inventory-orders/order-1'),
      isTrue,
    );
    expect(canAccessRouteForRole('inventory_orderer', '/admin'), isFalse);
    expect(canAccessRouteForRole('kitchen', '/inventory-orders'), isFalse);
    expect(canAccessRouteForRole('store_admin', '/inventory-orders'), isTrue);
    expect(canAccessRouteForRole('brand_admin', '/inventory-orders'), isTrue);
    expect(kKnownPosRoles, contains('inventory_accounting'));
    expect(homeRouteForRole('inventory_accounting'), '/inventory-orders');
    expect(
      canAccessRouteForRole('inventory_accounting', '/inventory-orders'),
      isTrue,
    );
    expect(canAccessRouteForRole('inventory_accounting', '/admin'), isFalse);
    expect(
      PermissionUtils.canVerifyInventoryReceipt(
        'inventory_accounting',
        const [],
      ),
      isTrue,
    );
    expect(
      PermissionUtils.canVerifyInventoryReceipt('store_admin', const []),
      isFalse,
    );
  });

  test('supplier price workbook round-trips required audit fields', () {
    final bytes = Uint8List.fromList(
      buildSupplierPriceImportTemplate([
        {
          'id': 'supplier-item-1',
          'supplier_id': 'supplier-1',
          'product_id': 'product-1',
          'order_unit': 'kg',
          'unit_price': 16000,
          'tax_rate': 8,
          'is_active': true,
          'supplier': {'supplier_name': '우리푸드'},
          'product': {'name': '당근'},
        },
      ]),
    );
    final parsed = parseSupplierPriceImportWorkbook(bytes);
    expect(parsed.rows, hasLength(1));
    expect(parsed.rows.single['supplier_item_id'], 'supplier-item-1');
    expect(parsed.rows.single['new_unit_price'], 16000);
    expect(parsed.rows.single['tax_rate'], 8);
    expect(
      parsed.rows.single['effective_date'],
      matches(r'^\d{4}-\d{2}-\d{2}$'),
    );
  });

  test('database contract gates stock behind independent verification', () {
    final migration = readRepoFile(
      'supabase/migrations/20260827150000_inventory_purchase_approval_receiving_prices.sql',
    );
    expect(migration, contains("'inventory_orderer'"));
    expect(migration, contains("'inventory_accounting'"));
    expect(migration, contains('public.user_tax_entity_access'));
    expect(
      migration,
      contains('public.legal_entity_fixed_account_requirements'),
    );
    expect(
      migration,
      contains('admin_configure_legal_entity_inventory_accounting'),
    );
    expect(migration, contains("scope = 'legal_entity'"));
    expect(
      migration,
      contains('JOIN public.restaurants r\n      ON r.tax_entity_id'),
    );
    expect(migration, contains("THEN 'store_approved'"));
    expect(migration, contains("status = 'ordered', brand_approved_by"));
    expect(migration, contains('INVENTORY_PURCHASE_SELF_APPROVAL_FORBIDDEN'));
    expect(migration, contains('INVENTORY_RECEIPT_MAKER_CHECKER_REQUIRED'));
    expect(migration, contains('upsert_inventory_receipt_draft_line'));
    expect(migration, contains('verify_inventory_receipt'));
    expect(migration, contains('UPDATE public.inventory_items'));
    expect(migration, contains('bulk_update_inventory_supplier_prices'));
    expect(migration, isNot(contains('inventory_purchase_dispatches')));
  });

  test('Flutter workflow exposes draft approval receiving PDF and Excel', () {
    final screen = readRepoFile(
      'lib/features/inventory_purchase/inventory_order_workflow_screen.dart',
    );
    final service = readRepoFile('lib/core/services/inventory_service.dart');
    final document = readRepoFile(
      'lib/features/inventory_purchase/inventory_purchase_document_service.dart',
    );

    expect(screen, contains('createManualInventoryPurchaseOrder'));
    expect(screen, contains('saveInventoryPurchaseOrderDraft'));
    expect(screen, contains('deleteInventoryPurchaseOrderDraft'));
    expect(screen, contains('storeDecideInventoryPurchaseOrder'));
    expect(screen, contains('brandDecideInventoryPurchaseOrder'));
    expect(screen, contains('_queueReceiptAutosave'));
    expect(screen, contains('verifyInventoryReceipt'));
    expect(screen, contains('parseSupplierPriceImportWorkbook'));
    expect(screen, contains('inventory_order_create_draft_dialog'));
    expect(screen, contains('inventory_order_edit_draft_dialog'));
    expect(screen, contains('inventory_order_confirmation_dialog'));
    expect(screen, contains('inventory_order_text_input_dialog'));
    expect(screen, contains('inventory_receipt_statement_dialog'));
    expect(service, contains("'upsert_inventory_receipt_draft_line'"));
    expect(service, contains("'bulk_update_inventory_supplier_prices'"));
    expect(
      service,
      contains('fetchLegalEntityInventoryPurchaseWorkflowOrders'),
    );
    expect(screen, contains('inventory_accounting_store_filter'));
    expect(screen, contains('전체 브랜드·전체 매장'));
    expect(screen, contains('constraints.maxWidth < 720'));
    expect(screen, contains('Align(alignment: Alignment.centerRight'));
    expect(document, contains("from('inventory-purchase-documents')"));
    expect(screen, isNot(contains('requestInventoryPurchaseDispatch')));
    expect(
      File(
        'supabase/functions/inventory-purchase-dispatcher/index.ts',
      ).existsSync(),
      isFalse,
    );
  });

  test('legal entity accounting account is configured outside store setup', () {
    final storePreset = readRepoFile(
      'lib/features/store_setup/store_setup_models.dart',
    );
    final superAdmin = readRepoFile(
      'lib/features/super_admin/super_admin_screen.dart',
    );
    final superProvider = readRepoFile(
      'lib/features/super_admin/super_admin_provider.dart',
    );
    final provisioner = readRepoFile(
      'supabase/functions/provision-fixed-pos-account/index.ts',
    );

    expect(storePreset, isNot(contains('bunsik_acc1')));
    expect(superAdmin, contains('legal_entity_accounting_dialog'));
    expect(superAdmin, contains('법인 공용 회계 계정'));
    expect(
      superProvider,
      contains('admin_configure_legal_entity_inventory_accounting'),
    );
    expect(provisioner, contains('legal_entity_requirement_id'));
    expect(provisioner, contains('user_tax_entity_access'));
  });

  test('approved purchase order renders as a real PDF', () async {
    final bytes = await inventoryPurchaseDocumentService.buildPurchaseOrderPdf(
      order: {
        'id': 'order-1',
        'purchase_order_no': 'PO-20260829-001',
        'status': 'ordered',
        'requested_delivery_date': '2026-08-30',
        'total_supply_amount': 132000,
        'tax_amount': 10560,
        'total_amount': 142560,
        'created_by_name': 'Kitchen Orderer',
        'submitted_at': '2026-08-29T08:00:00Z',
        'store_approved_by_name': 'Store Manager',
        'store_approved_at': '2026-08-29T08:30:00Z',
        'brand_approved_by_name': 'Brand Manager',
        'brand_approved_at': '2026-08-29T09:00:00Z',
        'store': {'name': 'BunsikClub Binh Thanh'},
        'supplier': {'supplier_name': '우리푸드'},
      },
      lines: [
        {
          'product': {'name': '당근'},
          'ordered_quantity_unit': 5,
          'order_unit': 'KG',
          'unit_price': 16000,
          'supply_amount': 80000,
          'tax_amount': 6400,
        },
        {
          'product': {'name': '양파'},
          'ordered_quantity_unit': 4,
          'order_unit': 'KG',
          'unit_price': 13000,
          'supply_amount': 52000,
          'tax_amount': 4160,
        },
      ],
      l10n: AppLocalizationsKo(),
    );

    expect(bytes.length, greaterThan(5000));
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });
}
