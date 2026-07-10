import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/i18n/locale_controller.dart';
import 'package:globos_pos_system/core/i18n/locale_state.dart';
import 'package:globos_pos_system/features/super_admin/super_admin_provider.dart';
import 'package:globos_pos_system/main.dart' as app;
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sharedPassword = String.fromEnvironment(
  'SMOKE_SHARED_PASSWORD',
  defaultValue: '',
);
const _dryRun = bool.fromEnvironment('BUTTON_SWEEP_DRY_RUN');
const _onlyAccount = String.fromEnvironment('BUTTON_SWEEP_ONLY_ACCOUNT');
const _onlyRoute = String.fromEnvironment('BUTTON_SWEEP_ONLY_ROUTE');
String _currentSweepScope = 'bootstrap';
int _routeResetNonce = 0;

const _accounts = <_AccountRoutes>[
  _AccountRoutes(
    email: 'gate3.waiter@globos.test',
    rootKey: 'dashboard_root',
    routes: ['/waiter'],
  ),
  _AccountRoutes(
    email: 'gate3.kitchen@globos.test',
    rootKey: 'kitchen_root',
    routes: ['/kitchen'],
  ),
  _AccountRoutes(
    email: 'gate3.cashier@globos.test',
    rootKey: 'cashier_root',
    routes: ['/cashier', '/payments/90000000-0000-4000-8000-000000000363'],
  ),
  _AccountRoutes(
    email: 'gate3.admin@globos.test',
    rootKey: 'admin_root',
    routes: [
      '/admin?tab=overview',
      '/admin?tab=tables',
      '/admin?tab=menu',
      '/admin?tab=staff',
      '/admin?tab=reports',
      '/admin?tab=attendance',
      '/admin?tab=inventory',
      '/admin?tab=qc',
      '/admin?tab=settings',
      '/admin?tab=delivery',
      '/admin?tab=einvoice',
      '/qc-check',
      '/qc-review',
    ],
  ),
  _AccountRoutes(
    email: 'gate3.superadmin@globos.test',
    rootKey: 'admin_root',
    routes: ['/super-admin', '/photo-ops'],
  ),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('system-wide reachable button sweep', (tester) async {
    if (_sharedPassword.isEmpty) {
      throw TestFailure('SMOKE_SHARED_PASSWORD is required.');
    }

    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      debugPrint('BUTTON_SWEEP_FLUTTER_ERROR scope=$_currentSweepScope');
      previousOnError?.call(details);
    };
    app.main();
    await _pumpFor(tester, const Duration(seconds: 8));

    final report = _SweepReport();
    await _exerciseLoginUtilities(tester, report);
    await _exerciseQrOrder(tester, report);
    await _resetRoute(tester, '/login');

    for (final account in _accounts) {
      if (_onlyAccount.isNotEmpty && account.email != _onlyAccount) continue;
      await _signIn(tester, account);
      final routes = _onlyRoute.isEmpty
          ? account.routes
          : account.routes.where((route) => route == _onlyRoute).toList();
      if (routes.isEmpty) {
        throw TestFailure(
          'No matching route $_onlyRoute for ${account.email}.',
        );
      }
      for (final route in routes) {
        await _sweepRoute(tester, account.email, route, report);
      }
      if (_onlyRoute.isEmpty && account.email == 'gate3.admin@globos.test') {
        await _exerciseGlobalNavigation(tester, report);
      }
      await _clickLogout(
        tester,
        account,
        report,
        homeRoute: account.routes.first,
      );
    }

    report.printSummary();

    if (report.failures.isNotEmpty) {
      fail(report.failures.join('\n'));
    }
    if (report.clicked == 0 && !_dryRun) {
      fail('Button sweep did not click any controls.');
    }
  });
}

Future<void> _exerciseLoginUtilities(
  WidgetTester tester,
  _SweepReport report,
) async {
  await _waitForKey(tester, 'login_submit_button');

  final passwordVisibility = find.byIcon(Icons.visibility_outlined);
  if (passwordVisibility.evaluate().isNotEmpty) {
    await tester.tap(passwordVisibility.first);
    await _pumpFor(tester, const Duration(milliseconds: 250));
    _recordException(tester, report, 'login', 'password_visibility');
    report.clicked++;
  }

  final languageButton = find.byType(PopupMenuButton<dynamic>).hitTestable();
  if (languageButton.evaluate().isNotEmpty) {
    report.discovered += 4;
    for (var index = 0; index < 3; index++) {
      await tester.tap(languageButton.first);
      await _pumpFor(tester, const Duration(milliseconds: 250));
      final options = find.byType(PopupMenuItem<dynamic>);
      if (options.evaluate().length <= index) {
        report.failures.add('login: language option $index is not reachable');
        break;
      }
      await tester.tap(options.at(index));
      await _pumpFor(tester, const Duration(milliseconds: 250));
      report.clicked += 2;
    }
    _recordException(tester, report, 'login', 'language_switcher_all');
  }

  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  await container
      .read(localeControllerProvider.notifier)
      .setLocale(AppLanguage.korean);
  await _pumpFor(tester, const Duration(milliseconds: 500));
}

Future<void> _sweepRoute(
  WidgetTester tester,
  String account,
  String route,
  _SweepReport report,
) async {
  await _resetRoute(tester, route);
  final initial = _collectActions(tester);
  report.discovered += initial.length;
  report.routeCounts['$account $route'] = initial.length;

  for (final action in initial) {
    if (_isGlobalUtility(action.id, route)) {
      report.globalUtilities.add(action.id);
      continue;
    }
    if (_isEnvironmentBlocked(action.id)) {
      report.environmentBlocked.add('$account $route ${action.id}');
      continue;
    }
    if (_isNonFixtureSuperAdminRow(action.id)) {
      report.fixtureDuplicatesSkipped.add('$account $route ${action.id}');
      continue;
    }
    if (_dryRun) {
      debugPrint('BUTTON_SWEEP_DISCOVERED $account $route ${action.id}');
      continue;
    }

    await _resetRoute(tester, route);
    final current = await _waitForAction(tester, action.id);
    if (current.isEmpty) {
      report.failures.add(
        '$account $route ${action.id}: action disappeared after route reset',
      );
      continue;
    }

    await tester.tapAt(current.first.rect.center);
    debugPrint(
      'BUTTON_SWEEP_CLICK account=$account route=$route id=${action.id}',
    );
    await _pumpFor(tester, const Duration(milliseconds: 650));
    report.clicked++;
    _recordException(tester, report, '$account $route', action.id);
    if (app.supabase.auth.currentUser == null) {
      report.failures.add(
        '$account $route ${action.id}: click unexpectedly signed out the session',
      );
      return;
    }

    final transientActions = _collectActions(
      tester,
    ).where((item) => item.isTransient).toList();
    report.discovered += transientActions.length;
    for (final transient in transientActions) {
      if (_isFrameworkGenerated(transient.id)) {
        report.frameworkGenerated.add('$route ${transient.id}');
        continue;
      }
      if (_isEnvironmentBlocked(transient.id)) {
        report.environmentBlocked.add(
          '$account $route ${action.id} -> ${transient.id}',
        );
        continue;
      }

      await _resetRoute(tester, route);
      final openers = await _waitForAction(tester, action.id);
      if (openers.isEmpty) {
        report.failures.add(
          '$account $route ${action.id}: opener disappeared before ${transient.id}',
        );
        break;
      }
      await tester.tapAt(openers.first.rect.center);
      await _pumpFor(tester, const Duration(milliseconds: 400));
      final overlayTargets = await _waitForAction(
        tester,
        transient.id,
        transientOnly: true,
      );
      if (overlayTargets.isEmpty) {
        report.failures.add(
          '$account $route ${action.id} -> ${transient.id}: transient action disappeared',
        );
        continue;
      }
      await tester.tapAt(overlayTargets.first.rect.center);
      await _pumpFor(tester, const Duration(milliseconds: 500));
      report.clicked++;
      _recordException(
        tester,
        report,
        '$account $route ${action.id}',
        transient.id,
      );
    }

    if (find.byType(MaterialApp).evaluate().isEmpty ||
        find.byType(Overlay).evaluate().isEmpty) {
      report.failures.add(
        '$account $route ${action.id}: app surface disappeared after click',
      );
    }
  }
  debugPrint(
    'BUTTON_SWEEP_ROUTE_DONE account=$account route=$route '
    'controls=${initial.length}',
  );
}

Future<void> _exerciseQrOrder(WidgetTester tester, _SweepReport report) async {
  await _resetRoute(tester, '/qr/gate3-1f-token-20260709');
  await _waitForKey(tester, 'qr_order_screen');

  final addButton = find.byIcon(Icons.add).hitTestable();
  if (addButton.evaluate().isEmpty) {
    report.failures.add('qr: add button is not reachable');
    return;
  }
  report.discovered++;
  if (_dryRun) return;

  await tester.tap(addButton.first);
  await _pumpFor(tester, const Duration(milliseconds: 300));
  report.clicked++;
  _recordException(tester, report, 'qr', 'add_item');

  final removeButton = find.byIcon(Icons.remove).hitTestable();
  if (removeButton.evaluate().isNotEmpty) {
    report.discovered++;
    await tester.tap(removeButton.first);
    await _pumpFor(tester, const Duration(milliseconds: 250));
    await tester.tap(addButton.first);
    await _pumpFor(tester, const Duration(milliseconds: 250));
    report.clicked += 2;
    _recordException(tester, report, 'qr', 'remove_and_restore_item');
  }

  final submit = find.byKey(const Key('qr_cart_submit'));
  if (submit.evaluate().isEmpty) {
    report.failures.add('qr: cart submit button is not reachable after add');
    return;
  }
  report.discovered += 3;
  await tester.tap(submit);
  await _pumpFor(tester, const Duration(milliseconds: 250));
  report.clicked++;

  final dialog = find.byKey(const Key('qr_confirm_dialog'));
  final cancel = find.descendant(of: dialog, matching: find.byType(TextButton));
  if (cancel.evaluate().isNotEmpty) {
    await tester.tap(cancel);
    await _pumpFor(tester, const Duration(milliseconds: 250));
    report.clicked++;
  }

  await tester.tap(submit);
  await _pumpFor(tester, const Duration(milliseconds: 250));
  final confirm = find.byKey(const Key('qr_confirm_submit'));
  if (confirm.evaluate().isEmpty) {
    report.failures.add('qr: confirmation button is not reachable');
    return;
  }
  await tester.tap(confirm);
  await _pumpFor(tester, const Duration(seconds: 4));
  report.clicked += 2;
  _recordException(tester, report, 'qr', 'submit_confirm');

  if (find.byKey(const Key('qr_order_screen')).evaluate().isNotEmpty) {
    report.failures.add('qr: order did not transition to success state');
  }
}

List<_ActionTarget> _collectActions(WidgetTester tester) {
  final candidates = <_ActionTarget>[];
  final finder = find.byWidgetPredicate(_isInteractiveWidget).hitTestable();

  for (final element in finder.evaluate()) {
    if (!_isEnabled(element.widget)) continue;
    Rect rect;
    try {
      rect = tester.getRect(find.byWidget(element.widget));
    } catch (_) {
      continue;
    }
    if (rect.isEmpty || !rect.center.dx.isFinite || !rect.center.dy.isFinite) {
      continue;
    }
    candidates.add(
      _ActionTarget(
        id: _actionId(element, rect),
        rect: rect,
        priority: _widgetPriority(element.widget),
        isTransient: _hasTransientAncestor(element),
      ),
    );
  }

  final byBounds = <String, _ActionTarget>{};
  for (final candidate in candidates) {
    final bounds = [
      candidate.rect.left.round(),
      candidate.rect.top.round(),
      candidate.rect.width.round(),
      candidate.rect.height.round(),
    ].join(':');
    final existing = byBounds[bounds];
    if (existing == null || candidate.priority > existing.priority) {
      byBounds[bounds] = candidate;
    }
  }

  final idCounts = <String, int>{};
  final result = <_ActionTarget>[];
  for (final candidate in byBounds.values) {
    final ordinal = idCounts.update(
      candidate.id,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    result.add(
      _ActionTarget(
        id: ordinal == 1 ? candidate.id : '${candidate.id}#$ordinal',
        rect: candidate.rect,
        priority: candidate.priority,
        isTransient: candidate.isTransient,
      ),
    );
  }
  result.sort((a, b) {
    final vertical = a.rect.top.compareTo(b.rect.top);
    return vertical != 0 ? vertical : a.rect.left.compareTo(b.rect.left);
  });
  return result;
}

bool _isInteractiveWidget(Widget widget) {
  return widget is ButtonStyleButton ||
      widget is IconButton ||
      widget is InkWell ||
      widget is GestureDetector ||
      widget is PopupMenuButton<dynamic> ||
      widget is DropdownButton<dynamic> ||
      widget is FilterChip ||
      widget is ChoiceChip ||
      widget is ActionChip ||
      widget is Switch ||
      widget is Checkbox ||
      widget is SegmentedButton<dynamic>;
}

bool _isEnabled(Widget widget) {
  if (widget is ButtonStyleButton) return widget.onPressed != null;
  if (widget is IconButton) return widget.onPressed != null;
  if (widget is InkWell) return widget.onTap != null;
  if (widget is GestureDetector) return widget.onTap != null;
  if (widget is PopupMenuButton<dynamic>) return widget.enabled;
  if (widget is DropdownButton) {
    final dynamic dropdown = widget;
    return dropdown.onChanged != null;
  }
  if (widget is FilterChip) return widget.onSelected != null;
  if (widget is ChoiceChip) return widget.onSelected != null;
  if (widget is ActionChip) return widget.onPressed != null;
  if (widget is Switch) return widget.onChanged != null;
  if (widget is Checkbox) return widget.onChanged != null;
  if (widget is SegmentedButton) {
    final dynamic segmented = widget;
    return segmented.onSelectionChanged != null;
  }
  return false;
}

int _widgetPriority(Widget widget) {
  if (widget is ButtonStyleButton || widget is IconButton) return 5;
  if (widget is PopupMenuButton<dynamic> ||
      widget is DropdownButton<dynamic> ||
      widget is SegmentedButton<dynamic>) {
    return 4;
  }
  if (widget is FilterChip ||
      widget is ChoiceChip ||
      widget is ActionChip ||
      widget is Switch ||
      widget is Checkbox) {
    return 3;
  }
  if (widget is InkWell) return 2;
  return 1;
}

String _actionId(Element element, Rect rect) {
  Key? key = element.widget.key;
  if (key == null) {
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget.key != null) {
        key = ancestor.widget.key;
        return false;
      }
      return true;
    });
  }
  final resolvedKey = key;
  if (resolvedKey is ValueKey<Object>) return 'key:${resolvedKey.value}';

  String? tooltip;
  String? semantics;
  final texts = <String>[];

  void read(Element current) {
    final widget = current.widget;
    final tooltipMessage = widget is Tooltip ? widget.message : null;
    if (tooltipMessage?.isNotEmpty == true) {
      tooltip ??= tooltipMessage;
    } else if (widget is Semantics && widget.properties.label != null) {
      semantics ??= widget.properties.label;
    } else if (widget is Text) {
      final value = widget.data ?? widget.textSpan?.toPlainText();
      if (value != null && value.trim().isNotEmpty) texts.add(value.trim());
    }
    current.visitChildElements(read);
  }

  read(element);
  final widget = element.widget;
  if (widget is IconButton && widget.tooltip?.isNotEmpty == true) {
    tooltip ??= widget.tooltip;
  }
  if (widget is PopupMenuButton<dynamic> &&
      widget.tooltip?.isNotEmpty == true) {
    tooltip ??= widget.tooltip;
  }

  final label = tooltip ?? semantics ?? texts.take(2).join(' / ');
  if (label.isNotEmpty) return '${widget.runtimeType}:$label';
  return '${widget.runtimeType}@${rect.left.round()},${rect.top.round()}';
}

bool _isGlobalUtility(String id, String route) {
  final normalized = id.toLowerCase();
  final adminNavigation =
      route.startsWith('/admin') &&
      const {
        'inkwell:테이블',
        'inkwell:메뉴',
        'inkwell:직원',
        'inkwell:리포트',
        'inkwell:근태',
        'inkwell:재고',
        'inkwell:품질',
        'inkwell:설정',
        'inkwell:딜리베리 정산',
        'inkwell:전자세금계산서',
      }.contains(normalized);
  final superAdminNavigation =
      route == '/super-admin' &&
      const {
        'inkwell:매장',
        'inkwell:전체 리포트',
        'inkwell:qc 상태',
        'inkwell:qc 템플릿',
        'inkwell:시스템 설정',
      }.contains(normalized);
  return adminNavigation ||
      superAdminNavigation ||
      normalized.contains('로그아웃') ||
      normalized.contains('logout') ||
      normalized.contains('log out') ||
      normalized.contains('đăng xuất') ||
      normalized.contains('language') ||
      normalized == 'inkwell:en' ||
      normalized == 'inkwell:ko' ||
      normalized == 'inkwell:vi' ||
      normalized.contains('key:app_nav_') ||
      normalized.contains('key:nav_') ||
      normalized.contains('key:super_admin_nav_') ||
      normalized.endsWith(':back') ||
      normalized.endsWith(':home') ||
      normalized.endsWith(':forward');
}

bool _isEnvironmentBlocked(String id) {
  final normalized = id.toLowerCase();
  return normalized.contains('오피스 시스템으로 이동') ||
      normalized.contains('office system') ||
      normalized.contains('hệ thống office') ||
      normalized.contains('사진 첨부') ||
      normalized.contains('attach photo') ||
      normalized.contains('đính kèm ảnh') ||
      normalized.contains('출력/pdf') ||
      normalized.contains('print/pdf') ||
      normalized.contains('in/pdf');
}

bool _isNonFixtureSuperAdminRow(String id) {
  const fixtureStoreId = '90000000-0000-4000-8000-000000000301';
  final isStoreRowAction =
      id.startsWith('key:super_admin_manage_') ||
      id.startsWith('key:super_admin_go_to_admin_');
  return isStoreRowAction && !id.endsWith(fixtureStoreId);
}

bool _isFrameworkGenerated(String id) {
  final normalized = id.toLowerCase();
  return RegExp(
    r'^(inkwell|gesturedetector):\d{1,2}(#\d+)?$',
  ).hasMatch(normalized);
}

bool _hasTransientAncestor(Element element) {
  var transient = false;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is Dialog ||
        widget is BottomSheet ||
        widget is PopupMenuItem<dynamic>) {
      transient = true;
      return false;
    }
    return true;
  });
  return transient;
}

Future<void> _resetRoute(WidgetTester tester, String route) async {
  _currentSweepScope = route;
  await _dismissTransientRoutes(tester);
  final context = tester.element(find.byType(Overlay).first);
  final uri = Uri.parse(route);
  if (uri.path == '/super-admin') {
    final container = ProviderScope.containerOf(context);
    final notifier = container.read(superAdminProvider.notifier);
    notifier.setBrandFilter(null);
    notifier.setStoreTypeFilter(null);
  }
  final query = <String, String>{
    ...uri.queryParameters,
    'button_sweep_nonce': '${++_routeResetNonce}',
  };
  GoRouter.of(context).go(uri.replace(queryParameters: query).toString());
  await _pumpFor(tester, const Duration(seconds: 2));
}

Future<void> _dismissTransientRoutes(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    final dialogs = find.byType(Dialog);
    final menus = find.byType(PopupMenuItem<dynamic>);
    final sheets = find.byType(BottomSheet);
    if (dialogs.evaluate().isEmpty &&
        menus.evaluate().isEmpty &&
        sheets.evaluate().isEmpty) {
      return;
    }
    final context = tester.element(find.byType(Overlay).first);
    final navigator = Navigator.of(context, rootNavigator: true);
    if (!navigator.canPop()) return;
    navigator.pop();
    await _pumpFor(tester, const Duration(milliseconds: 150));
  }
}

Future<void> _signIn(WidgetTester tester, _AccountRoutes account) async {
  if (find.byKey(const Key('login_submit_button')).evaluate().isEmpty) {
    await app.supabase.auth.signOut();
    await _pumpFor(tester, const Duration(seconds: 2));
  }

  await tester.enterText(
    find.byKey(const Key('login_email_field')),
    account.email,
  );
  await tester.enterText(
    find.byKey(const Key('login_password_field')),
    _sharedPassword,
  );
  await tester.tap(find.byKey(const Key('login_submit_button')));
  await _waitForKey(
    tester,
    account.rootKey,
    timeout: const Duration(seconds: 20),
  );

  final consent = find.byKey(const Key('privacy_consent_checkbox'));
  if (consent.evaluate().isNotEmpty) {
    await tester.tap(consent);
    await tester.tap(find.byKey(const Key('privacy_consent_accept_button')));
    await _waitForKey(
      tester,
      account.rootKey,
      timeout: const Duration(seconds: 20),
    );
  }
}

Future<void> _signOut(WidgetTester tester) async {
  await app.supabase.auth.signOut();
  await _waitForKey(tester, 'login_submit_button');
}

Future<void> _clickLogout(
  WidgetTester tester,
  _AccountRoutes account,
  _SweepReport report, {
  required String homeRoute,
}) async {
  await _resetRoute(tester, homeRoute);
  final logout = find.byKey(const Key('logout_button'));
  if (logout.evaluate().isEmpty) {
    report.failures.add('${account.email}: logout button is not reachable');
    await _signOut(tester);
    return;
  }
  report.discovered++;
  if (_dryRun) {
    await _signOut(tester);
    return;
  }
  final targetCenter = await _waitForLogoutTarget(tester, logout);
  if (targetCenter == null) {
    report.failures.add('${account.email}: logout button is not hit-testable');
    await _signOut(tester);
    return;
  }
  await tester.tapAt(targetCenter);
  await _waitForKey(tester, 'login_submit_button');
  report.clicked++;
  _recordException(tester, report, account.email, 'logout_button');
}

Future<Offset?> _waitForLogoutTarget(WidgetTester tester, Finder logout) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    final logoutElements = logout.evaluate().toList();
    if (logoutElements.isNotEmpty) {
      await tester.ensureVisible(find.byWidget(logoutElements.first.widget));
      final inkWellElements = find
          .descendant(of: logout, matching: find.byType(InkWell))
          .hitTestable()
          .evaluate()
          .toList();
      final hitTestableLogout = logout.hitTestable().evaluate().toList();
      final targetElement = inkWellElements.isNotEmpty
          ? inkWellElements.first
          : hitTestableLogout.firstOrNull;
      final renderObject = targetElement?.renderObject;
      if (renderObject is RenderBox && renderObject.hasSize) {
        return renderObject.localToGlobal(
          renderObject.size.center(Offset.zero),
        );
      }
    }
    await _pumpFor(tester, const Duration(milliseconds: 250));
  }
  return null;
}

Future<void> _exerciseGlobalNavigation(
  WidgetTester tester,
  _SweepReport report,
) async {
  await _resetRoute(tester, '/qc-check');
  for (final key in const ['app_nav_back', 'app_nav_forward', 'app_nav_home']) {
    final button = find.byKey(Key(key));
    report.discovered++;
    if (button.evaluate().isEmpty) {
      report.failures.add('admin navigation: $key is not reachable');
      continue;
    }
    if (_dryRun) continue;
    await tester.tap(button.first, warnIfMissed: false);
    await _pumpFor(tester, const Duration(milliseconds: 500));
    report.clicked++;
    _recordException(tester, report, 'admin navigation', key);
  }
}

Future<void> _waitForKey(
  WidgetTester tester,
  String key, {
  Duration timeout = const Duration(seconds: 12),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (find.byKey(Key(key)).evaluate().isNotEmpty) return;
    await _pumpFor(tester, const Duration(milliseconds: 250));
  }
  throw TestFailure('Timed out waiting for $key.');
}

Future<List<_ActionTarget>> _waitForAction(
  WidgetTester tester,
  String id, {
  bool transientOnly = false,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await _revealKeyedAction(tester, id);
    final matches = _collectActions(tester).where((item) {
      return item.id == id && (!transientOnly || item.isTransient);
    }).toList();
    if (matches.isNotEmpty) return matches;
    await _pumpFor(tester, const Duration(milliseconds: 250));
  }
  return const [];
}

Future<void> _revealKeyedAction(WidgetTester tester, String id) async {
  if (!id.startsWith('key:') || id.contains('#')) return;
  final keyValue = id.substring('key:'.length);
  final finder = find.byKey(ValueKey<String>(keyValue), skipOffstage: false);
  if (finder.evaluate().isEmpty) return;
  try {
    await tester.ensureVisible(finder.first);
    await _pumpFor(tester, const Duration(milliseconds: 250));
  } catch (_) {
    // Some keyed controls live outside a scrollable and need no reveal step.
  }
}

Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void _recordException(
  WidgetTester tester,
  _SweepReport report,
  String scope,
  String action,
) {
  Object? exception;
  while ((exception = tester.takeException()) != null) {
    report.failures.add('$scope $action: $exception');
  }
}

class _AccountRoutes {
  const _AccountRoutes({
    required this.email,
    required this.rootKey,
    required this.routes,
  });

  final String email;
  final String rootKey;
  final List<String> routes;
}

class _ActionTarget {
  const _ActionTarget({
    required this.id,
    required this.rect,
    required this.priority,
    required this.isTransient,
  });

  final String id;
  final Rect rect;
  final int priority;
  final bool isTransient;
}

class _SweepReport {
  int discovered = 0;
  int clicked = 0;
  final List<String> failures = [];
  final Set<String> globalUtilities = {};
  final List<String> environmentBlocked = [];
  final List<String> fixtureDuplicatesSkipped = [];
  final List<String> frameworkGenerated = [];
  final Map<String, int> routeCounts = {};

  void printSummary() {
    debugPrint('SYSTEM_BUTTON_SWEEP_START');
    debugPrint('mode=${_dryRun ? 'DRY_RUN' : 'CLICK'}');
    debugPrint(
      'discovered=$discovered clicked=$clicked failures=${failures.length}',
    );
    for (final entry in routeCounts.entries) {
      debugPrint('route=${entry.key} controls=${entry.value}');
    }
    debugPrint('globalUtilities=${globalUtilities.toList()..sort()}');
    debugPrint('environmentBlocked=$environmentBlocked');
    debugPrint('fixtureDuplicatesSkipped=$fixtureDuplicatesSkipped');
    debugPrint('frameworkGeneratedSkipped=${frameworkGenerated.length}');
    for (final failure in failures) {
      debugPrint('FAIL $failure');
    }
    debugPrint('SYSTEM_BUTTON_SWEEP_END');
  }
}
