import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

Set<String> filesContaining(String rootPath, Pattern pattern) {
  final matches = <String>{};
  for (final entity in Directory(rootPath).listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) {
      continue;
    }
    final content = entity.readAsStringSync();
    if (content.contains(pattern)) {
      matches.add(entity.path.replaceAll('\\', '/'));
    }
  }
  return matches;
}

void main() {
  test(
    'legacy AppPanel usage stays inside the tracked compatibility allowlist',
    () {
      final files = filesContaining('lib', 'AppPanel(');

      expect(files, {'lib/core/ui/app_primitives.dart'});
    },
  );

  test(
    'WebSidebarLayout stays isolated from the migrated Toast admin shell',
    () {
      final files = filesContaining('lib', 'WebSidebarLayout(');

      expect(files, {'lib/core/layout/web_sidebar_layout.dart'});
      expect(
        readRepoFile('lib/core/ui/toast/toast_sidebar.dart'),
        isNot(contains('WebSidebarLayout(')),
      );
    },
  );

  test(
    'migrated admin shell files do not reintroduce legacy theme aliases',
    () {
      final admin = readRepoFile('lib/features/admin/admin_screen.dart');
      final sidebar = readRepoFile('lib/core/ui/toast/toast_sidebar.dart');

      expect(admin, isNot(contains('AppColors.')));
      expect(admin, isNot(contains('AppPanel(')));
      expect(admin, isNot(contains('GoogleFonts.notoSansKr')));
      expect(sidebar, isNot(contains('AppColors.')));
      expect(sidebar, isNot(contains('AppPanel(')));
    },
  );

  test('migrated cashier and order workspace surfaces stay off AppPanel', () {
    final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');
    final orderWorkspace = readRepoFile('lib/widgets/order_workspace.dart');

    expect(cashier, contains("key: const Key('cashier_payment_surface')"));
    expect(cashier, contains('ToastWorkSurface('));
    expect(cashier, isNot(contains('AppPanel(')));
    expect(cashier, isNot(contains('AppColors.')));
    expect(cashier, isNot(contains('GoogleFonts.notoSansKr')));

    expect(orderWorkspace, contains("key: const Key('menu_root')"));
    expect(orderWorkspace, contains("key: const Key('orders_root')"));
    expect(orderWorkspace, contains('ToastWorkSurface('));
    expect(orderWorkspace, isNot(contains('AppPanel(')));
    expect(orderWorkspace, isNot(contains('AppColors.')));
    expect(orderWorkspace, isNot(contains('GoogleFonts.notoSansKr')));
  });
}
