import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/super_admin/super_admin_provider.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

SuperRestaurant store({
  required String id,
  required String ownerType,
  required String taxEntityId,
  required String brandId,
}) {
  return SuperRestaurant(
    id: id,
    name: id,
    slug: id,
    address: '',
    operationMode: 'standard',
    perPersonCharge: null,
    isActive: true,
    createdAt: DateTime(2026),
    ownerType: ownerType,
    taxEntityId: taxEntityId,
    taxEntityName: taxEntityId,
    brandId: brandId,
    brandName: brandId,
  );
}

void main() {
  test('store filters follow owner type then legal entity then brand', () {
    final state = SuperAdminState(
      reportStart: DateTime(2026),
      reportEnd: DateTime(2026, 1, 2),
      restaurants: [
        store(
          id: 'akj-photo',
          ownerType: 'internal',
          taxEntityId: 'akj',
          brandId: 'photo',
        ),
        store(
          id: 'akj-other',
          ownerType: 'internal',
          taxEntityId: 'akj',
          brandId: 'other',
        ),
        store(
          id: 'client-photo',
          ownerType: 'external',
          taxEntityId: 'client',
          brandId: 'photo',
        ),
      ],
      selectedOwnerType: 'internal',
      selectedTaxEntityId: 'akj',
      selectedBrandId: 'photo',
    );

    expect(state.filteredRestaurants.map((item) => item.id), ['akj-photo']);
  });

  test('brands are limited to active legal entity relationships', () {
    final state = SuperAdminState(
      reportStart: DateTime(2026),
      reportEnd: DateTime(2026, 1, 2),
      brands: const [
        {'id': 'photo', 'name': 'PHOTO OBJET'},
        {'id': 'other', 'name': 'Other'},
      ],
      taxEntityBrands: const [
        SuperTaxEntityBrand(taxEntityId: 'akj', brandId: 'photo'),
      ],
      selectedTaxEntityId: 'akj',
    );

    expect(state.filteredBrands.map((brand) => brand['id']), ['photo']);
  });

  test('Super Admin uses v2 RPC and derives Office integration', () {
    final service = readRepoFile('lib/core/services/store_service.dart');
    final provider = readRepoFile(
      'lib/features/super_admin/super_admin_provider.dart',
    );
    final screen = readRepoFile(
      'lib/features/super_admin/super_admin_screen.dart',
    );

    expect(service, contains("'admin_create_restaurant_v2'"));
    expect(service, contains("'admin_update_restaurant_v2'"));
    expect(service, contains("'p_tax_entity_id': taxEntityId"));
    expect(provider, contains(".from('tax_entity_brands')"));
    expect(provider, contains('brand is not allowed for this legal entity'));
    expect(
      provider,
      contains("bool get isOfficeLinked => ownerType == 'internal'"),
    );
    expect(screen, contains('superAdminGroupByLegalEntityBrand'));
    expect(screen, contains('_legalEntityBrandRows'));
    expect(
      screen,
      isNot(
        contains(
          'onChanged: (value) {\n                      if (value != null) {\n                        setModalState(() => storeType = value)',
        ),
      ),
    );
  });

  test('legal entity workflow is localized in all supported locales', () {
    for (final locale in ['en', 'ko', 'vi']) {
      final arb = readRepoFile('lib/l10n/app_$locale.arb');
      expect(arb, contains('"superAdminLegalEntity"'));
      expect(arb, contains('"superAdminOfficeLinkedDerived"'));
      expect(arb, contains('"superAdminGroupByLegalEntityBrand"'));
    }
  });
}
