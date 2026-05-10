import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:globos_pos_system/features/admin/providers/admin_scope_provider.dart';

void main() {
  test('admin scope can be overridden for super admin store views', () {
    final container = ProviderContainer(
      overrides: [
        adminScopedStoreIdProvider.overrideWithValue('store-from-url'),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(adminScopedStoreIdProvider), 'store-from-url');
  });
}
