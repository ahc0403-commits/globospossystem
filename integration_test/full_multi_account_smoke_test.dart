import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:globos_pos_system/main.dart' as app;

const _sharedPassword = '1234!@#\$';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('full multi-account smoke test', (tester) async {
    final report = SmokeRunReport();

    try {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 8));

      final accounts = <AccountSpec>[
        AccountSpec(email: 'waiter@globos.test',           expectedSurface: AccountSurface.waiterPos),
        AccountSpec(email: 'kitchen@globos.test',          expectedSurface: AccountSurface.kitchenPos),
        AccountSpec(email: 'cashier@globos.test',          expectedSurface: AccountSurface.cashierPos),
        AccountSpec(email: 'admin@globos.test',            expectedSurface: AccountSurface.adminPos),
        AccountSpec(email: 'superadmin@globos.test',       expectedSurface: AccountSurface.superAdminPos),
        // Office accounts live in a separate office app/Supabase project.
        // They exist in auth.users but have no public.users POS profile,
        // so _fetchUserProfile throws. skipIfLoginFails records the outcome
        // as EXPECTED_OUT_OF_SCOPE without stopping the run.
        AccountSpec(email: 'office.store@globos.vn',     expectedSurface: AccountSurface.officeStore,  skipIfLoginFails: true),
        AccountSpec(email: 'office.brand.kn@globos.vn', expectedSurface: AccountSurface.officeBrand, skipIfLoginFails: true),
        AccountSpec(email: 'office.brand.mk@globos.vn', expectedSurface: AccountSurface.officeBrand, skipIfLoginFails: true),
        AccountSpec(email: 'office.staff@globos.vn',    expectedSurface: AccountSurface.officeStaff, skipIfLoginFails: true),
        AccountSpec(email: 'office.super@globos.vn',    expectedSurface: AccountSurface.officeSuper, skipIfLoginFails: true),
        AccountSpec(email: 'pos.validation.codex@globos.test', expectedSurface: AccountSurface.validation),
      ];

      final ctx = SmokeContext(tester: tester, report: report);

      for (final account in accounts) {
        ctx.currentAccount = account.email;
        await _runAccount(ctx, account);
      }

      report.finalVerdict = 'PASS';
      report.stopCondition = 'All listed accounts completed without failure.';
      report.printToConsole();
    } catch (e, st) {
      report.finalVerdict =
          report.finalVerdict == 'PASS' ? 'FAIL' : report.finalVerdict;
      report.firstFailure ??= 'Unhandled failure';
      report.stackTrace ??= st.toString();
      report.printToConsole();
      fail(report.firstFailure ?? e.toString());
    }
  });
}

// ---------------------------------------------------------------------------
// Account runner
// ---------------------------------------------------------------------------

Future<void> _runAccount(SmokeContext ctx, AccountSpec account) async {
  final tester = ctx.tester;
  final accountResult = AccountResult(email: account.email);
  ctx.report.accounts.add(accountResult);

  // Step 1: force clean unauthenticated state, then ensure login screen
  await _safeStep(ctx, 'bootstrap_to_login', () async {
    await _forceSignOut(tester);
    await _ensureLoginScreen(tester);
  });

  // Step 2: login once (1 pass per account — validates login contract).
  // If skipIfLoginFails is true, a login failure is treated as
  // EXPECTED_OUT_OF_SCOPE: the account is skipped and the run continues.
  if (account.skipIfLoginFails) {
    try {
      ctx.report.commandsRun.add('login_pass_1');
      await _performLogin(tester, email: account.email, password: _sharedPassword);
      final landing = _captureLandingSurface(tester);
      accountResult.loginResult = 'PASS';
      accountResult.landingSurface = landing;
      accountResult.effectiveScope = landing;
    } catch (e) {
      accountResult.loginResult = 'EXPECTED_OUT_OF_SCOPE';
      ctx.report.linkArtifacts.add(
        '${account.email}: login skipped (out of POS scope) — $e',
      );
      await _forceSignOut(tester);
      return; // skip all features for this account; do not fail the run
    }
  } else {
    await _safeStep(ctx, 'login_pass_1', () async {
      await _performLogin(tester, email: account.email, password: _sharedPassword);
      final landing = _captureLandingSurface(tester);
      accountResult.loginResult = 'PASS';
      accountResult.landingSurface = landing;
      accountResult.effectiveScope = landing;
    });
  }

  // Step 3: discover which features are visible for this account
  final visible = await _safeStepReturn<List<FeatureSpec>>(
    ctx,
    'surface_inventory',
    () async => _discoverVisibleFeatures(tester, account.expectedSurface),
  );

  accountResult.visibleFeatures = visible.map((e) => e.name).toList();

  // Step 4: run each visible feature exactly feature.maxPasses times (default 1).
  // Non-repeatable operations override maxPasses to 1 explicitly.
  for (final feature in visible) {
    for (var pass = 1; pass <= feature.maxPasses; pass++) {
      await _safeStep(ctx, '${feature.name}_pass_$pass[${account.email}]', () async {
        await feature.run(ctx, account);
      });
    }
  }

  // Record blocked features
  final blocked = _blockedFeatures(account.expectedSurface, visible);
  accountResult.hiddenOrBlockedFeatures = blocked.map((e) => e.name).toList();

  // Step 5: logout
  await _safeStep(ctx, 'logout_after_account[${account.email}]', () async {
    await _logoutIfPossible(tester);
  });
}

// ---------------------------------------------------------------------------
// Login helpers
// ---------------------------------------------------------------------------

Future<void> _ensureLoginScreen(WidgetTester tester) async {
  await tester.pumpAndSettle(const Duration(seconds: 2));

  final emailFinder    = find.byKey(const Key(UiKeys.loginEmailField));
  final passwordFinder = find.byKey(const Key(UiKeys.loginPasswordField));
  final buttonFinder   = find.byKey(const Key(UiKeys.loginSubmitButton));

  if (emailFinder.evaluate().isEmpty ||
      passwordFinder.evaluate().isEmpty ||
      buttonFinder.evaluate().isEmpty) {
    throw TestFailure(
      'Login screen contract missing. '
      'Required: ${UiKeys.loginEmailField}, ${UiKeys.loginPasswordField}, '
      '${UiKeys.loginSubmitButton}',
    );
  }
}

Future<void> _performLogin(
  WidgetTester tester, {
  required String email,
  required String password,
}) async {
  final emailField  = find.byKey(const Key(UiKeys.loginEmailField));
  final passField   = find.byKey(const Key(UiKeys.loginPasswordField));
  final loginButton = find.byKey(const Key(UiKeys.loginSubmitButton));

  await tester.tap(emailField);
  await tester.pumpAndSettle();
  await tester.enterText(emailField, email);

  await tester.tap(passField);
  await tester.pumpAndSettle();
  await tester.enterText(passField, password);

  await tester.tap(loginButton);
  await tester.pumpAndSettle(const Duration(seconds: 6));

  final errorText = find.byKey(const Key(UiKeys.authErrorText));
  if (errorText.evaluate().isNotEmpty) {
    final widget = tester.widget<Text>(errorText);
    throw TestFailure('Login failed for $email: ${widget.data}');
  }
}

// ---------------------------------------------------------------------------
// Landing surface detection — uses root screen keys (nav_* keys not available
// for role-scoped screens; root keys are set on every role's main Scaffold).
// ---------------------------------------------------------------------------

String _captureLandingSurface(WidgetTester tester) {
  // Priority: role-scoped root screens first, then admin nav presence
  for (final candidate in [
    UiKeys.kitchenRoot,
    UiKeys.cashierRoot,
    UiKeys.dashboardRoot,   // waiterPos
    UiKeys.adminRoot,       // adminPos / officePos / superAdminPos
  ]) {
    if (find.byKey(Key(candidate)).evaluate().isNotEmpty) {
      return 'root:$candidate';
    }
  }
  // Fallback: admin sidebar nav items confirm admin surface even if
  // Scaffold key landed on a different variant
  for (final nav in [UiKeys.navTables, UiKeys.navMenu, UiKeys.navReports]) {
    if (find.byKey(Key(nav)).evaluate().isNotEmpty) {
      return 'nav:$nav';
    }
  }
  throw TestFailure(
    'Could not determine landing surface. '
    'None of the root screen keys or admin nav keys were found.',
  );
}

/// Programmatic sign-out — bypasses UI so it works even when the app booted
/// into an authenticated role screen (e.g., persisted session from a prior run).
///
/// Uses a bounded pump loop instead of pumpAndSettle to avoid hanging forever
/// when realtime subscriptions or animations keep scheduling frames.
Future<void> _forceSignOut(WidgetTester tester) async {
  try {
    await app.supabase.auth.signOut();
  } catch (_) {
    // Already signed out or no session — safe to ignore.
  }
  // Pump in 100 ms increments for up to 6 s, breaking early once the login
  // screen's email field appears (router has redirected to /login).
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (find.byKey(const Key(UiKeys.loginEmailField)).evaluate().isNotEmpty) {
      break;
    }
  }
}

Future<void> _logoutIfPossible(WidgetTester tester) async {
  final logoutButton = find.byKey(const Key(UiKeys.logoutButton));
  if (logoutButton.evaluate().isNotEmpty) {
    await tester.tap(logoutButton.first);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  }
}

// ---------------------------------------------------------------------------
// Feature discovery — finds which features are currently reachable
// ---------------------------------------------------------------------------

List<FeatureSpec> _discoverVisibleFeatures(
  WidgetTester tester,
  AccountSurface surface,
) {
  final all = _featureMatrix(surface);
  return all.where((feature) {
    return find.byKey(Key(feature.entryKey)).evaluate().isNotEmpty;
  }).toList();
}

List<FeatureSpec> _blockedFeatures(
  AccountSurface surface,
  List<FeatureSpec> visible,
) {
  final visibleNames = visible.map((e) => e.name).toSet();
  return _featureMatrix(surface)
      .where((e) => !visibleNames.contains(e.name))
      .toList();
}

// ---------------------------------------------------------------------------
// Feature matrix — ordered E2E flow where applicable
// ---------------------------------------------------------------------------

List<FeatureSpec> _featureMatrix(AccountSurface surface) {
  switch (surface) {
    case AccountSurface.adminPos:
      return [
        _adminLandingFeature(),
        _adminTablesNavFeature(),
        _adminMenuNavFeature(),
        _reportsFeature(),
        _dailyClosingFeature(),
      ];
    case AccountSurface.superAdminPos:
      // super_admin routes to /super-admin with its own sidebar.
      // admin_root key is present on SuperAdminScreen Scaffold.
      return [
        _superAdminLandingFeature(),
        _superAdminStoresTabFeature(),
        _superAdminReportsTabFeature(),
      ];
    case AccountSurface.cashierPos:
      return [
        _cashierFeature(),
      ];
    case AccountSurface.waiterPos:
      return [
        _waiterDashboardFeature(),
        _waiterTablesFeature(),
        _waiterOrderFeature(),
      ];
    case AccountSurface.kitchenPos:
      return [
        _kitchenFeature(),
      ];
    case AccountSurface.officeStore:
      // office accounts route to /admin → admin_root visible
      return [
        _adminLandingFeature(),
        _reportsFeature(),
        _dailyClosingFeature(),
      ];
    case AccountSurface.officeBrand:
      return [
        _adminLandingFeature(),
        _reportsFeature(),
      ];
    case AccountSurface.officeStaff:
      return [
        _adminLandingFeature(),
      ];
    case AccountSurface.officeSuper:
      return [
        _adminLandingFeature(),
        _adminTablesNavFeature(),
        _adminMenuNavFeature(),
        _reportsFeature(),
      ];
    case AccountSurface.validation:
      // Include all possible features; discovery filters to those visible
      return [
        _adminLandingFeature(),
        _adminTablesNavFeature(),
        _adminMenuNavFeature(),
        _reportsFeature(),
        _dailyClosingFeature(),
        _kitchenFeature(),
        _cashierFeature(),
        _waiterDashboardFeature(),
        _waiterTablesFeature(),
        _waiterOrderFeature(),
      ];
  }
}

// ---------------------------------------------------------------------------
// Feature implementations
// ---------------------------------------------------------------------------

/// Admin screens: verify admin_root is present (landing verification).
/// Office-role accounts also land on admin_root — no separate office_root exists.
FeatureSpec _adminLandingFeature() {
  return FeatureSpec(
    name: 'admin_landing',
    entryKey: UiKeys.adminRoot,
    run: (ctx, account) async {
      _expectVisible(ctx.tester, UiKeys.adminRoot, 'admin_root not visible');
    },
  );
}

/// Admin sidebar → Tables tab.
FeatureSpec _adminTablesNavFeature() {
  return FeatureSpec(
    name: 'admin_tables_nav',
    entryKey: UiKeys.navTables,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(find.byKey(const Key(UiKeys.navTables)));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      // TablesTab in admin has no dedicated root key; verify we stayed on admin
      _expectVisible(tester, UiKeys.adminRoot, 'admin_root lost after Tables nav');
    },
  );
}

/// Admin sidebar → Menu tab.
FeatureSpec _adminMenuNavFeature() {
  return FeatureSpec(
    name: 'admin_menu_nav',
    entryKey: UiKeys.navMenu,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(find.byKey(const Key(UiKeys.navMenu)));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      _expectVisible(tester, UiKeys.adminRoot, 'admin_root lost after Menu nav');
    },
  );
}

/// Admin sidebar → Reports tab (verifies reports_root).
FeatureSpec _reportsFeature() {
  return FeatureSpec(
    name: 'reports',
    entryKey: UiKeys.navReports,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(find.byKey(const Key(UiKeys.navReports)));
      await tester.pumpAndSettle(const Duration(seconds: 3));
      _expectVisible(tester, UiKeys.reportsRoot, 'reports_root not visible');
    },
  );
}

/// Daily closing — uses nav_reports as entryKey because daily_closing_root is
/// only present in the widget tree when the Reports tab is active.
///
/// Non-repeatable boundary: if daily closing for today already exists, the
/// app shows daily_closing_already_closed_banner. The test stops immediately
/// on that boundary as required.
FeatureSpec _dailyClosingFeature() {
  return FeatureSpec(
    name: 'daily_closing',
    entryKey: UiKeys.navReports,   // daily_closing_root only appears after this nav
    maxPasses: 1,                  // non-repeatable: pass 1 consumes today's closing slot
    run: (ctx, account) async {
      final tester = ctx.tester;

      // Navigate to Reports to make daily_closing_root appear
      await tester.tap(find.byKey(const Key(UiKeys.navReports)));
      await tester.pumpAndSettle(const Duration(seconds: 3));
      _expectVisible(tester, UiKeys.reportsRoot, 'reports_root not visible');

      // Pre-flight: if today is already closed, stop immediately (non-repeatable boundary).
      final alreadyClosed =
          find.byKey(const Key(UiKeys.dailyClosingAlreadyClosedBanner));
      if (alreadyClosed.evaluate().isNotEmpty) {
        throw TestFailure(
          'Daily closing is destructive/non-repeatable for current state. '
          'Stop condition triggered as requested.',
        );
      }

      final closeButton =
          find.byKey(const Key(UiKeys.dailyClosingSubmitButton));
      if (closeButton.evaluate().isEmpty) {
        // daily_closing_submit_button not present for this role → skip
        return;
      }

      // Scroll close button into view (it may be below the fold)
      await tester.ensureVisible(closeButton);
      await tester.pumpAndSettle();

      await tester.tap(closeButton);
      // Let the confirmation dialog open (short entrance animation).
      await tester.pumpAndSettle(const Duration(milliseconds: 500));

      // Confirm the AlertDialog that _createClosing() shows before running.
      final dialogConfirm = find.widgetWithText(FilledButton, 'Close');
      if (dialogConfirm.evaluate().isNotEmpty) {
        await tester.tap(dialogConfirm);
      }
      await tester.pumpAndSettle(const Duration(seconds: 4));

      final successBanner =
          find.byKey(const Key(UiKeys.dailyClosingSuccessBanner));
      final nowAlreadyClosed =
          find.byKey(const Key(UiKeys.dailyClosingAlreadyClosedBanner));
      final closeButtonAfter =
          find.byKey(const Key(UiKeys.dailyClosingSubmitButton));

      final successDetected =
          successBanner.evaluate().isNotEmpty ||
          nowAlreadyClosed.evaluate().isNotEmpty ||
          closeButtonAfter.evaluate().isEmpty;

      if (!successDetected) {
        throw TestFailure(
          'Daily closing success state not detectable after close',
        );
      }
    },
  );
}

/// Kitchen screen — role-scoped, no nav tap needed; kitchen_root is the landing.
/// Advances the first order item status if an active order is present.
/// Gracefully skips if kitchen is empty.
FeatureSpec _kitchenFeature() {
  return FeatureSpec(
    name: 'kitchen',
    entryKey: UiKeys.kitchenRoot,
    run: (ctx, account) async {
      final tester = ctx.tester;
      _expectVisible(tester, UiKeys.kitchenRoot, 'kitchen_root not visible');

      final firstOrder =
          find.byKey(const Key(UiKeys.kitchenFirstOrderCard));
      final advanceButton =
          find.byKey(const Key(UiKeys.kitchenAdvanceStatusButton));

      if (firstOrder.evaluate().isNotEmpty) {
        _expectVisible(
          tester, UiKeys.kitchenFirstOrderCard,
          'kitchen_first_order_card disappeared',
        );
      } else {
        // No active orders — record and skip gracefully
        ctx.report.linkArtifacts.add(
          'kitchen[${account.email}]: no active orders (kitchen_first_order_card absent)',
        );
      }

      if (advanceButton.evaluate().isNotEmpty) {
        await tester.tap(advanceButton);
        await tester.pumpAndSettle(const Duration(seconds: 2));
      }
    },
  );
}

/// Cashier screen — role-scoped, cashier_root is the landing.
/// Processes payment for the first payable order if present.
/// Gracefully skips if no payable orders exist.
FeatureSpec _cashierFeature() {
  return FeatureSpec(
    name: 'cashier',
    entryKey: UiKeys.cashierRoot,
    run: (ctx, account) async {
      final tester = ctx.tester;
      _expectVisible(tester, UiKeys.cashierRoot, 'cashier_root not visible');

      final paymentCandidate =
          find.byKey(const Key(UiKeys.paymentFirstCandidate));
      if (paymentCandidate.evaluate().isEmpty) {
        // No payable orders; record and skip payment flow
        ctx.report.linkArtifacts.add(
          'cashier[${account.email}]: no payment_first_candidate present',
        );
        return;
      }

      await tester.tap(paymentCandidate);
      await tester.pumpAndSettle(const Duration(seconds: 2));

      final payButton = find.byKey(const Key(UiKeys.paymentSubmitButton));
      if (payButton.evaluate().isEmpty) {
        ctx.report.linkArtifacts.add(
          'cashier[${account.email}]: payment_submit_button not visible after candidate selection',
        );
        return;
      }

      await tester.tap(payButton);
      await tester.pumpAndSettle(const Duration(seconds: 4));

      _expectVisible(
        tester,
        UiKeys.paymentSuccessBanner,
        'payment_success_banner not visible after payment',
      );
    },
  );
}

/// Waiter screen — dashboard_root (the WaiterScreen Scaffold) is the landing.
FeatureSpec _waiterDashboardFeature() {
  return FeatureSpec(
    name: 'waiter_dashboard',
    entryKey: UiKeys.dashboardRoot,
    run: (ctx, account) async {
      final tester = ctx.tester;
      _expectVisible(tester, UiKeys.dashboardRoot, 'dashboard_root not visible');
      _expectVisible(tester, UiKeys.tablesRoot, 'tables_root not visible on waiter dashboard');
    },
  );
}

/// Waiter tables grid — tables_root is the _TableGridView, visible on waiter landing.
FeatureSpec _waiterTablesFeature() {
  return FeatureSpec(
    name: 'waiter_tables',
    entryKey: UiKeys.tablesRoot,
    run: (ctx, account) async {
      final tester = ctx.tester;
      _expectVisible(tester, UiKeys.tablesRoot, 'tables_root not visible');

      final firstTable = find.byKey(const Key(UiKeys.tableFirstCard));
      if (firstTable.evaluate().isEmpty) {
        ctx.report.linkArtifacts
            .add('waiter_tables[${account.email}]: no table_first_card visible');
        return;
      }

      await tester.tap(firstTable);
      await tester.pumpAndSettle(const Duration(seconds: 2));

      // Handle buffet-mode guest count dialog if it appeared
      await _dismissGuestCountDialogIfPresent(tester);

      // If order workspace opened, verify presence then close it
      final ordersVisible =
          find.byKey(const Key(UiKeys.ordersRoot)).evaluate().isNotEmpty;
      if (ordersVisible) {
        _expectVisible(tester, UiKeys.ordersRoot, 'orders_root not visible in workspace');
        // Cancel back to table grid without creating an order
        final cancelButton = find.text('CANCEL');
        if (cancelButton.evaluate().isNotEmpty) {
          await tester.tap(cancelButton.first);
          await tester.pumpAndSettle(const Duration(seconds: 2));
        }
      }
    },
  );
}

/// Waiter order creation flow — entryKey is table_first_card.
/// Creates a bounded order and verifies success banner + order number text.
/// Gracefully skips if no tables are present or workspace does not open.
FeatureSpec _waiterOrderFeature() {
  return FeatureSpec(
    name: 'waiter_order',
    entryKey: UiKeys.tableFirstCard,
    run: (ctx, account) async {
      final tester = ctx.tester;

      final firstTable = find.byKey(const Key(UiKeys.tableFirstCard));
      if (firstTable.evaluate().isEmpty) return;

      await tester.tap(firstTable);
      await tester.pumpAndSettle(const Duration(seconds: 2));

      await _dismissGuestCountDialogIfPresent(tester);

      final menuItem   = find.byKey(const Key(UiKeys.menuFirstItem));
      final submitBtn  = find.byKey(const Key(UiKeys.cartSubmitOrder));

      if (menuItem.evaluate().isEmpty || submitBtn.evaluate().isEmpty) {
        // Workspace not open or menu empty → cancel and skip gracefully
        ctx.report.linkArtifacts.add(
          'waiter_order[${account.email}]: workspace or menu not available — skipping order creation',
        );
        final cancelButton = find.text('CANCEL');
        if (cancelButton.evaluate().isNotEmpty) {
          await tester.tap(cancelButton.first);
          await tester.pumpAndSettle();
        }
        return;
      }

      await tester.tap(menuItem);
      await tester.pumpAndSettle();

      await tester.tap(submitBtn);
      await tester.pumpAndSettle(const Duration(seconds: 4));

      _expectVisible(
        tester,
        UiKeys.orderCreateSuccessBanner,
        'order_create_success_banner not visible after order submission',
      );

      final artifactFinder =
          find.byKey(const Key(UiKeys.latestOrderNumberText));
      if (artifactFinder.evaluate().isNotEmpty) {
        final widget = tester.widget<Text>(artifactFinder);
        final artifact = (widget.data ?? '').trim();
        if (artifact.isNotEmpty) {
          ctx.report.linkArtifacts.add(
            'Order created by ${account.email}: id_prefix=$artifact',
          );
        }
      }
      // Leave the table occupied; bounded — intentional test artifact
    },
  );
}

/// SuperAdmin: verify admin_root is present (SuperAdminScreen has Scaffold key admin_root).
FeatureSpec _superAdminLandingFeature() {
  return FeatureSpec(
    name: 'super_admin_landing',
    entryKey: UiKeys.adminRoot,
    run: (ctx, account) async {
      _expectVisible(ctx.tester, UiKeys.adminRoot, 'admin_root (SuperAdminScreen) not visible');
      // Stores tab is the default; verify its nav item is present
      _expectVisible(
        ctx.tester,
        UiKeys.superAdminNavStores,
        'super_admin_nav_stores not visible on landing',
      );
    },
  );
}

/// SuperAdmin sidebar → Stores tab (index 0).
FeatureSpec _superAdminStoresTabFeature() {
  return FeatureSpec(
    name: 'super_admin_stores_tab',
    entryKey: UiKeys.superAdminNavStores,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(find.byKey(const Key(UiKeys.superAdminNavStores)));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      // After tapping Stores, admin_root must still be present (same Scaffold)
      _expectVisible(tester, UiKeys.adminRoot, 'admin_root lost after super_admin Stores tab nav');
    },
  );
}

/// SuperAdmin sidebar → All Reports tab (index 1).
FeatureSpec _superAdminReportsTabFeature() {
  return FeatureSpec(
    name: 'super_admin_reports_tab',
    entryKey: UiKeys.superAdminNavReports,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(find.byKey(const Key(UiKeys.superAdminNavReports)));
      await tester.pumpAndSettle(const Duration(seconds: 3));
      // After tapping All Reports, admin_root must still be present
      _expectVisible(tester, UiKeys.adminRoot, 'admin_root lost after super_admin Reports tab nav');
    },
  );
}

// ---------------------------------------------------------------------------
// Dialog helper
// ---------------------------------------------------------------------------

/// Dismisses the buffet-mode guest count dialog by entering "2" and confirming.
Future<void> _dismissGuestCountDialogIfPresent(WidgetTester tester) async {
  final guestDialogTitle = find.text('How many guests?');
  if (guestDialogTitle.evaluate().isEmpty) return;

  final textFields = find.byType(TextField);
  if (textFields.evaluate().isNotEmpty) {
    await tester.enterText(textFields.last, '2');
  }
  final confirmButton = find.text('Confirm');
  if (confirmButton.evaluate().isNotEmpty) {
    await tester.tap(confirmButton);
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }
}

// ---------------------------------------------------------------------------
// Assertion helpers
// ---------------------------------------------------------------------------

void _expectVisible(WidgetTester tester, String keyName, String message) {
  if (find.byKey(Key(keyName)).evaluate().isEmpty) {
    throw TestFailure(message);
  }
}

// ---------------------------------------------------------------------------
// Safe step wrappers — stop immediately on first failure
// ---------------------------------------------------------------------------

Future<void> _safeStep(
  SmokeContext ctx,
  String stepName,
  Future<void> Function() body,
) async {
  ctx.report.commandsRun.add(stepName);
  try {
    await body();
  } catch (e) {
    ctx.report.finalVerdict = 'FAIL';
    ctx.report.firstFailure ??= '[${ctx.currentAccount}] $stepName -> $e';
    ctx.report.stopCondition =
        'Stopped immediately at first failure: [${ctx.currentAccount}] $stepName';
    rethrow;
  }
}

Future<T> _safeStepReturn<T>(
  SmokeContext ctx,
  String stepName,
  Future<T> Function() body,
) async {
  ctx.report.commandsRun.add(stepName);
  try {
    return await body();
  } catch (e) {
    ctx.report.finalVerdict = 'FAIL';
    ctx.report.firstFailure ??= '[${ctx.currentAccount}] $stepName -> $e';
    ctx.report.stopCondition =
        'Stopped immediately at first failure: [${ctx.currentAccount}] $stepName';
    rethrow;
  }
}

// ---------------------------------------------------------------------------
// UiKeys — reflects the implemented widget key contract.
// Keys listed as "NOT IMPLEMENTED" are absent from the app and must not be
// used in find.byKey() calls; they are retained here for documentation only.
// ---------------------------------------------------------------------------

class UiKeys {
  // Login
  static const loginEmailField    = 'login_email_field';
  static const loginPasswordField = 'login_password_field';
  static const loginSubmitButton  = 'login_submit_button';
  static const authErrorText      = 'auth_error_text';
  static const logoutButton       = 'logout_button';

  // Navigation (admin sidebar — implemented)
  static const navMenu         = 'nav_menu';
  static const navTables       = 'nav_tables';
  static const navReports      = 'nav_reports';
  // nav_daily_closing is the header Row key inside the DailyClosingSection
  // (only present when Reports tab is active). Used via ensureVisible, not
  // as an entryKey for discovery.
  static const navDailyClosing = 'nav_daily_closing';

  // NOT IMPLEMENTED in app — retained for documentation:
  // nav_dashboard, nav_orders, nav_kitchen, nav_cashier, nav_admin, nav_office

  // Root screens
  static const dashboardRoot    = 'dashboard_root';   // WaiterScreen Scaffold
  static const tablesRoot       = 'tables_root';      // _TableGridView in waiter
  static const kitchenRoot      = 'kitchen_root';     // KitchenScreen Scaffold
  static const cashierRoot      = 'cashier_root';     // CashierScreen Scaffold
  static const adminRoot        = 'admin_root';       // AdminScreen & SuperAdminScreen Scaffold
  static const reportsRoot      = 'reports_root';     // ReportsTab Scaffold
  static const dailyClosingRoot = 'daily_closing_root'; // DailyClosingSection Column
  static const menuRoot         = 'menu_root';        // _MenuBrowser Container
  static const ordersRoot       = 'orders_root';      // _CurrentOrderPanel Container

  // NOT IMPLEMENTED — office accounts route to admin_root, no separate office_root.
  // office_root

  // SuperAdmin sidebar navigation (implemented in SuperAdminScreen._navItem)
  static const superAdminNavStores        = 'super_admin_nav_stores';
  static const superAdminNavReports       = 'super_admin_nav_reports';
  static const superAdminNavQcStatus      = 'super_admin_nav_qc_status';
  static const superAdminNavQcTemplate    = 'super_admin_nav_qc_template';
  static const superAdminNavSystemSettings = 'super_admin_nav_system_settings';

  // Transactional — order workspace
  static const menuFirstItem           = 'menu_first_item';
  static const cartSubmitOrder         = 'cart_submit_order';
  static const orderCreateSuccessBanner = 'order_create_success_banner';
  static const latestOrderNumberText   = 'latest_order_number_text';

  // Transactional — tables
  static const tableFirstCard = 'table_first_card';

  // Transactional — payment
  static const paymentFirstCandidate = 'payment_first_candidate';
  static const paymentSubmitButton   = 'payment_submit_button';
  static const paymentSuccessBanner  = 'payment_success_banner';

  // Transactional — kitchen
  static const kitchenFirstOrderCard      = 'kitchen_first_order_card';
  static const kitchenAdvanceStatusButton = 'kitchen_advance_status_button';

  // Transactional — daily closing
  static const dailyClosingSubmitButton       = 'daily_closing_submit_button';
  static const dailyClosingSuccessBanner      = 'daily_closing_success_banner';
  static const dailyClosingAlreadyClosedBanner = 'daily_closing_already_closed_banner';
}

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

enum AccountSurface {
  adminPos,
  superAdminPos,
  cashierPos,
  waiterPos,
  kitchenPos,
  officeStore,
  officeBrand,
  officeStaff,
  officeSuper,
  validation,
}

class AccountSpec {
  const AccountSpec({
    required this.email,
    required this.expectedSurface,
    this.skipIfLoginFails = false,
  });
  final String email;
  final AccountSurface expectedSurface;
  /// When true, a login failure is recorded as EXPECTED_OUT_OF_SCOPE and the
  /// account is skipped without failing the entire run.  Use for accounts that
  /// legitimately cannot authenticate in this app (e.g. office-system accounts
  /// whose profiles live in a separate Supabase project).
  final bool skipIfLoginFails;
}

class FeatureSpec {
  const FeatureSpec({
    required this.name,
    required this.entryKey,
    required this.run,
    this.maxPasses = 1,
  });
  final String name;
  final String entryKey;
  final Future<void> Function(SmokeContext ctx, AccountSpec account) run;
  /// How many times this feature is executed per account.
  /// Default is 1. Non-repeatable operations (e.g. daily_closing) must
  /// always remain at 1 and are explicitly annotated below.
  final int maxPasses;
}

class SmokeContext {
  SmokeContext({required this.tester, required this.report});
  final WidgetTester tester;
  final SmokeRunReport report;
  String currentAccount = '';
}

class SmokeRunReport {
  String finalVerdict = 'PARTIAL';
  String stopCondition = '';
  String? firstFailure;
  String? stackTrace;
  final List<String> commandsRun   = [];
  final List<AccountResult> accounts = [];
  final List<String> linkArtifacts = [];

  void printToConsole() {
    debugPrint('================ SMOKE REPORT ================');
    debugPrint('1. Final Verdict: $finalVerdict');
    debugPrint('2. Stop Condition: $stopCondition');
    if (firstFailure != null) debugPrint('3. First Failure: $firstFailure');
    debugPrint('4. Accounts Tested: ${accounts.length}');
    for (final a in accounts) {
      debugPrint('   - ${a.email}');
      debugPrint('     loginResult:           ${a.loginResult}');
      debugPrint('     landingSurface:        ${a.landingSurface}');
      debugPrint('     effectiveScope:        ${a.effectiveScope}');
      debugPrint('     visibleFeatures:       ${a.visibleFeatures}');
      debugPrint('     hiddenOrBlocked:       ${a.hiddenOrBlockedFeatures}');
    }
    debugPrint('5. Link Artifacts:');
    for (final item in linkArtifacts) { debugPrint('   - $item'); }
    debugPrint('6. Steps Run:');
    for (final item in commandsRun) { debugPrint('   - $item'); }
    if (stackTrace != null) {
      debugPrint('7. Stack Trace:');
      debugPrint(stackTrace);
    }
    debugPrint('==============================================');
  }
}

class AccountResult {
  AccountResult({required this.email});
  final String email;
  String loginResult = 'NOT RUN';
  String landingSurface = '';
  String effectiveScope = '';
  List<String> visibleFeatures = [];
  List<String> hiddenOrBlockedFeatures = [];
}
