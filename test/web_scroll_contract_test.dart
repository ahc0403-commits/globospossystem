import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/toast/toast_primitives_extended.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

Future<void> pumpToastResponsiveBodyAt(
  WidgetTester tester,
  Size viewport,
) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(
        body: ToastResponsiveBody(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Compact scroll top'),
              Spacer(),
              Text('Compact scroll bottom', key: Key('compact_scroll_bottom')),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  test('app enables desktop web drag scrolling devices', () {
    final main = readRepoFile('lib/main.dart');

    expect(main, contains('scrollBehavior: const GlobosScrollBehavior()'));
    expect(main, contains('class GlobosScrollBehavior'));
    expect(main, contains('PointerDeviceKind.mouse'));
    expect(main, contains('PointerDeviceKind.trackpad'));
    expect(main, contains('PointerDeviceKind.touch'));
  });

  test('toast responsive pages can scroll when viewport height is short', () {
    final primitives = readRepoFile(
      'lib/core/ui/toast/toast_primitives_extended.dart',
    );

    expect(primitives, contains('this.minHeight = 720'));
    expect(primitives, contains('final preferredHeight = narrowLayout'));
    expect(primitives, contains('_toastCompactPageMinHeight'));
    expect(
      primitives,
      contains('ToastViewportScroll(padding: resolvedPadding'),
    );
    expect(primitives, contains('controller: _scrollController'));
    expect(primitives, contains('thumbVisibility: true'));
    expect(primitives, contains('AlwaysScrollableScrollPhysics'));
    expect(
      primitives,
      contains(
        'keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag',
      ),
    );
  });

  test('web host document does not steal Flutter touch scrolling', () {
    final index = readRepoFile('web/index.html');
    final bootstrap = readRepoFile('web/flutter_bootstrap.js');

    expect(
      index,
      contains(
        '<meta name="viewport" content="width=device-width, initial-scale=1.0">',
      ),
    );

    for (final source in [index, bootstrap]) {
      expect(source, contains('height: 100%'));
      expect(source, contains('height: 100dvh'));
      expect(source, contains('overflow: hidden'));
      expect(source, contains('position: fixed'));
      expect(source, contains('overscroll-behavior: none'));
    }
  });

  test(
    'toast responsive bodies keep page scrolling available on narrow layouts',
    () {
      final primitives = readRepoFile(
        'lib/core/ui/toast/toast_primitives_extended.dart',
      );

      expect(primitives, contains('_toastSingleScrollOwnerBreakpoint = 1120'));
      expect(primitives, contains('_toastCompactPageMinHeight = 1600'));
      expect(primitives, contains('this.fitToViewportWhenNarrow = false'));
      expect(primitives, contains('final useSingleScrollOwner'));
      expect(primitives, contains('final narrowLayout'));
      expect(primitives, contains('narrowLayout && !fitToViewportWhenNarrow'));
      expect(primitives, contains('!narrowLayout && effectiveHeight'));
    },
  );

  for (final viewport in <String, Size>{
    'phone portrait': Size(390, 640),
    'tablet portrait': Size(820, 900),
  }.entries) {
    testWidgets(
      'toast responsive body scrolls with a drag on ${viewport.key}',
      (tester) async {
        await pumpToastResponsiveBodyAt(tester, viewport.value);

        final bottom = find.byKey(const Key('compact_scroll_bottom'));
        final initialBottomTop = tester.getTopLeft(bottom).dy;

        expect(initialBottomTop, greaterThan(viewport.value.height * 1.5));

        await tester.drag(find.byType(ListView), const Offset(0, -520));
        await tester.pumpAndSettle();

        final draggedBottomTop = tester.getTopLeft(bottom).dy;

        expect(draggedBottomTop, lessThan(initialBottomTop - 300));
      },
    );
  }

  test(
    'sidebar and admin shells do not force desktop chrome on phone landscape',
    () {
      final sidebar = readRepoFile('lib/core/ui/toast/toast_sidebar.dart');
      final admin = readRepoFile('lib/features/admin/admin_screen.dart');

      expect(sidebar, contains('final useCompactShell'));
      expect(sidebar, contains('viewport.shortestSide < 600'));
      expect(sidebar, contains('class _ToastSidebarCompactNav'));
      expect(sidebar, contains('class _ToastSidebarCompactSelectNav'));
      expect(sidebar, contains("Key('toast_compact_section_selector')"));
      expect(sidebar, contains('DropdownButton<int>'));
      expect(sidebar, contains('scrollDirection: Axis.horizontal'));

      expect(admin, contains('final useDesktopShell'));
      expect(admin, contains('viewport.shortestSide >= 600'));
      expect(admin, contains('Widget _buildMobileLayout'));
      expect(admin, contains('return ToastSidebar('));
      expect(admin, isNot(contains('BottomNavigationBar(')));
    },
  );

  test('all routed operational surfaces have a compact scroll contract', () {
    final surfaces = <String, List<String>>{
      'lib/features/auth/login_screen.dart': ['SingleChildScrollView('],
      'lib/features/auth/privacy_consent_screen.dart': [
        'SingleChildScrollView(',
      ],
      'lib/features/onboarding/onboarding_screen.dart': [
        'SingleChildScrollView(',
      ],
      'lib/features/waiter/waiter_screen.dart': ['ToastResponsiveBody('],
      'lib/features/kitchen/kitchen_screen.dart': ['ToastResponsiveBody('],
      'lib/features/cashier/cashier_screen.dart': ['ToastResponsiveBody('],
      'lib/features/attendance/attendance_kiosk_screen.dart': [
        'ToastResponsiveBody(',
      ],
      'lib/features/qc/qc_check_screen.dart': ['ToastResponsiveScrollBody('],
      'lib/features/qc/qc_review_screen.dart': ['ToastResponsiveScrollBody('],
      'lib/features/photo_ops/photo_ops_screen.dart': [
        'ToastResponsiveScrollBody(',
        'constraints.maxWidth < 1120',
      ],
      'lib/features/payment/payment_detail_screen.dart': [
        'ToastResponsiveScrollBody(',
      ],
      'lib/features/super_admin/super_admin_screen.dart': [
        '_superAdminScrollPhysics',
      ],
      'lib/features/admin/tabs/tables_tab.dart': ['ToastResponsiveBody('],
      'lib/features/admin/tabs/menu_tab.dart': ['ToastResponsiveScrollBody('],
      'lib/features/admin/tabs/staff_tab.dart': ['ToastResponsiveScrollBody('],
      'lib/features/admin/tabs/reports_tab.dart': [
        'ToastResponsiveScrollBody(',
      ],
      'lib/features/admin/tabs/attendance_tab.dart': [
        'ToastResponsiveScrollBody(',
      ],
      'lib/features/inventory_purchase/inventory_purchase_screen.dart': [
        'ToastResponsiveScrollBody(',
      ],
      'lib/features/admin/tabs/qc_tab.dart': ['ToastResponsiveBody('],
      'lib/features/admin/tabs/settings_tab.dart': [
        'ToastResponsiveScrollBody(',
      ],
      'lib/features/delivery/screens/delivery_settlement_tab.dart': [
        'ToastResponsiveScrollBody(',
      ],
      'lib/features/admin/tabs/einvoice_tab.dart': [
        'ToastResponsiveScrollBody(',
      ],
    };

    for (final entry in surfaces.entries) {
      final source = readRepoFile(entry.key);
      for (final marker in entry.value) {
        expect(source, contains(marker), reason: '${entry.key}: $marker');
      }
    }
  });

  test(
    'cashier mobile empty states fit the viewport instead of overscrolling',
    () {
      final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');

      expect(cashier, contains('fitToViewportWhenNarrow: true'));
      expect(
        cashier,
        contains("Key('cashier_no_payable_orders_operational_empty')"),
      );
    },
  );

  test('toast action buttons clamp labels in tight rows', () {
    final primitives = readRepoFile('lib/core/ui/toast/toast_primitives.dart');

    expect(primitives, contains('class PosActionButton'));
    expect(primitives, contains('final boundedLabel'));
    expect(primitives, contains('final labelMaxWidth'));
    expect(primitives, contains('ConstrainedBox('));
    expect(primitives, contains('maxLines: 1'));
    expect(primitives, contains('overflow: TextOverflow.ellipsis'));
    expect(primitives, contains('softWrap: false'));
  });

  test('topbar navigation clamps trailing controls to available width', () {
    final topbar = readRepoFile(
      'lib/core/ui/toast/toast_primitives_extended.dart',
    );
    final appNav = readRepoFile('lib/widgets/app_nav_bar.dart');

    expect(topbar, contains('Flexible('));
    expect(topbar, contains('fit: FlexFit.loose'));
    expect(topbar, contains('alignment: Alignment.centerRight'));
    expect(appNav, contains('LayoutBuilder('));
    expect(appNav, contains('final availableWidth'));
    expect(appNav, contains('final phoneChrome = viewportWidth < 560'));
    expect(appNav, contains('final showStore'));
    expect(appNav, contains('!phoneChrome && availableWidth >= 290'));
    expect(appNav, contains('final showLanguage'));
    expect(appNav, contains('width: 170'));
    expect(appNav, contains('maxWidth: 170'));
    expect(appNav, contains('overflow: TextOverflow.ellipsis'));
  });

  test('split content allows taller compact secondary panes when needed', () {
    final primitives = readRepoFile(
      'lib/core/ui/toast/toast_primitives_extended.dart',
    );

    expect(primitives, contains('this.compactPrimaryHeight = 520'));
    expect(primitives, contains('this.compactSecondaryHeight = 320'));
    expect(
      primitives,
      contains('compactPrimaryHeight + spacing + compactSecondaryHeight'),
    );
    expect(primitives, contains('height: compactSecondaryHeight'));
  });
}
