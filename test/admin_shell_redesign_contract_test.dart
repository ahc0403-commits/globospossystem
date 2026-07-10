import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('toast sidebar renders the grouped admin shell directly', () {
    final sidebar = readRepoFile('lib/core/ui/toast/toast_sidebar.dart');

    expect(sidebar, contains('class _ToastSidebarRail'));
    expect(sidebar, contains('class _ToastSidebarNavItem'));
    expect(sidebar, contains('item.helperLabel ?? item.helper'));
    expect(sidebar, contains('if (item.badge != null)'));
    expect(sidebar, contains('statusColor: highlight'));
    expect(sidebar, contains('Queue-first operational navigation'));

    expect(sidebar, isNot(contains('WebSidebarLayout(')));
    expect(sidebar, isNot(contains('_flatten()')));
    expect(sidebar, isNot(contains('renders identically')));
  });

  test(
    'admin screen supplies grouped operational navigation without legacy theme aliases',
    () {
      final admin = readRepoFile('lib/features/admin/admin_screen.dart');

      expect(
        admin,
        contains('helperLabel: l10n.adminNavTablesHelper'),
      );
      expect(admin, contains('helperLabel: l10n.adminNavEinvoiceHelper'));
      expect(admin, contains('context.l10n.adminViewTitle'));
      expect(admin, contains('ToastStatusBadge('));
      expect(admin, contains('ToastSidebar('));

      expect(admin, isNot(contains('AppColors.')));
      expect(admin, isNot(contains('GoogleFonts.notoSansKr')));
    },
  );
}
