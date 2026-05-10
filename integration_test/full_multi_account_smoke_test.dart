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

      // Account order is load-bearing: waiter creates an order, kitchen
      // advances that order, cashier pays that order, then admin/super
      // navigate the rest. Validation runs last with a full feature set.
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

  await _safeStep(ctx, 'bootstrap_to_login', () async {
    await _forceSignOut(tester);
    await _ensureLoginScreen(tester);
  });

  // Login once per account. skipIfLoginFails: log+skip on auth failure.
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
      return;
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

  // Discover features that are visibly reachable for this account
  final visible = await _safeStepReturn<List<FeatureSpec>>(
    ctx,
    'surface_inventory',
    () async => _discoverVisibleFeatures(tester, account.expectedSurface),
  );

  accountResult.visibleFeatures = visible.map((e) => e.name).toList();

  // Run each visible feature exactly maxPasses times (default 1).
  for (final feature in visible) {
    for (var pass = 1; pass <= feature.maxPasses; pass++) {
      await _safeStep(ctx, '${feature.name}_pass_$pass[${account.email}]', () async {
        await feature.run(ctx, account);
      });
    }
  }

  final blocked = _blockedFeatures(account.expectedSurface, visible);
  accountResult.hiddenOrBlockedFeatures = blocked.map((e) => e.name).toList();

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

String _captureLandingSurface(WidgetTester tester) {
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

/// Programmatic sign-out. Bypasses UI to work even when the app boots into
/// an authenticated screen. Bounded pump loop avoids hangs on realtime/anim.
Future<void> _forceSignOut(WidgetTester tester) async {
  try {
    await app.supabase.auth.signOut();
  } catch (_) {
    // Already signed out — safe to ignore.
  }
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
// Feature discovery
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
// Feature matrix — visible navs/screens per role, ordered for E2E flow
// ---------------------------------------------------------------------------

List<FeatureSpec> _featureMatrix(AccountSurface surface) {
  switch (surface) {
    case AccountSurface.adminPos:
      return [
        _adminLandingFeature(),
        _adminTablesNavFeature(),
        _adminMenuNavFeature(),
        _adminStaffNavFeature(),
        _adminAttendanceNavFeature(),
        _adminInventoryNavFeature(),
        _adminQcNavFeature(),
        _adminSettingsNavFeature(),
        _adminEinvoiceNavFeature(),
        _adminDeliveryNavFeature(),
        _reportsFeature(),
        _dailyClosingFeature(),
      ];
    case AccountSurface.superAdminPos:
      return [
        _superAdminLandingFeature(),
        _superAdminStoresTabFeature(),
        _superAdminReportsTabFeature(),
        _superAdminQcStatusTabFeature(),
        _superAdminQcTemplateTabFeature(),
        _superAdminSystemSettingsTabFeature(),
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
      // All possible features; discovery filters to those visible.
      return [
        _adminLandingFeature(),
        _adminTablesNavFeature(),
        _adminMenuNavFeature(),
        _adminStaffNavFeature(),
        _adminAttendanceNavFeature(),
        _adminInventoryNavFeature(),
        _adminQcNavFeature(),
        _adminSettingsNavFeature(),
        _adminEinvoiceNavFeature(),
        _adminDeliveryNavFeature(),
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
// Admin landing + sidebar nav features
// ---------------------------------------------------------------------------

FeatureSpec _adminLandingFeature() {
  return FeatureSpec(
    name: 'admin_landing',
    entryKey: UiKeys.adminRoot,
    run: (ctx, account) async {
      _expectVisible(ctx.tester, UiKeys.adminRoot, 'admin_root not visible');
    },
  );
}

FeatureSpec _adminTablesNavFeature() {
  return FeatureSpec(
    name: 'admin_tables_nav',
    entryKey: UiKeys.navTables,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(find.byKey(const Key(UiKeys.navTables)));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      // TablesTab body has no dedicated key; verify shell stayed mounted.
      _expectVisible(tester, UiKeys.adminRoot, 'admin_root lost after Tables nav');
    },
  );
}

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

FeatureSpec _adminStaffNavFeature() {
  return FeatureSpec(
    name: 'admin_staff_nav',
    entryKey: UiKeys.navStaff,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(find.byKey(const Key(UiKeys.navStaff)));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      _expectVisible(tester, UiKeys.staffRoot, 'staff_root not visible after Staff nav');
    },
  );
}

FeatureSpec _adminAttendanceNavFeature() {
  return FeatureSpec(
    name: 'admin_attendance_nav',
    entryKey: UiKeys.navAttendance,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(find.byKey(const Key(UiKeys.navAttendance)));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      _expectVisible(tester, UiKeys.attendanceRoot, 'attendance_root not visible after Attendance nav');
    },
  );
}

FeatureSpec _adminInventoryNavFeature() {
  return FeatureSpec(
    name: 'admin_inventory_nav',
    entryKey: UiKeys.navInventory,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(find.byKey(const Key(UiKeys.navInventory)));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      _expectVisible(tester, UiKeys.inventoryRoot, 'inventory_root not visible after Inventory nav');
    },
  );
}

FeatureSpec _adminQcNavFeature() {
  return FeatureSpec(
    name: 'admin_qc_nav',
    entryKey: UiKeys.navQc,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(find.byKey(const Key(UiKeys.navQc)));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      _expectVisible(tester, UiKeys.qcRoot, 'qc_root not visible after QC nav');
    },
  );
}

FeatureSpec _adminSettingsNavFeature() {
  return FeatureSpec(
    name: 'admin_settings_nav',
    entryKey: UiKeys.navSettings,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(find.byKey(const Key(UiKeys.navSettings)));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      _expectVisible(tester, UiKeys.settingsRoot, 'settings_root not visible after Settings nav');
    },
  );
}

FeatureSpec _adminEinvoiceNavFeature() {
  return FeatureSpec(
    name: 'admin_einvoice_nav',
    entryKey: UiKeys.navEinvoice,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(find.byKey(const Key(UiKeys.navEinvoice)));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      _expectVisible(tester, UiKeys.einvoiceRoot, 'einvoice_root not visible after E-Invoice nav');
    },
  );
}

FeatureSpec _adminDeliveryNavFeature() {
  return FeatureSpec(
    name: 'admin_delivery_settlement_nav',
    entryKey: UiKeys.navDeliverySettlement,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(find.byKey(const Key(UiKeys.navDeliverySettlement)));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      _expectVisible(tester, UiKeys.adminRoot,
          'admin_root lost after Delivery Settlement nav');
    },
  );
}

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

/// Daily closing — uses nav_reports as entryKey because daily_closing_root only
/// renders inside the Reports tab. Non-repeatable: only the first account to
/// reach it actually executes; subsequent accounts observe already-closed and
/// log without failing.
FeatureSpec _dailyClosingFeature() {
  return FeatureSpec(
    name: 'daily_closing',
    entryKey: UiKeys.navReports,
    maxPasses: 1,
    run: (ctx, account) async {
      final tester = ctx.tester;

      await tester.tap(find.byKey(const Key(UiKeys.navReports)));
      await tester.pumpAndSettle(const Duration(seconds: 3));
      _expectVisible(tester, UiKeys.reportsRoot, 'reports_root not visible');

      // Already-closed → record artifact and skip without failing the run.
      final alreadyClosed =
          find.byKey(const Key(UiKeys.dailyClosingAlreadyClosedBanner));
      if (alreadyClosed.evaluate().isNotEmpty) {
        ctx.report.linkArtifacts.add(
          'daily_closing[${account.email}]: already closed for today (non-repeatable boundary observed)',
        );
        return;
      }

      final closeButton =
          find.byKey(const Key(UiKeys.dailyClosingSubmitButton));
      if (closeButton.evaluate().isEmpty) {
        // Role lacks button — record and skip.
        ctx.report.linkArtifacts.add(
          'daily_closing[${account.email}]: daily_closing_submit_button not present for this role',
        );
        return;
      }

      await tester.ensureVisible(closeButton);
      await tester.pumpAndSettle();

      await tester.tap(closeButton);
      await tester.pumpAndSettle(const Duration(milliseconds: 500));

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

// ---------------------------------------------------------------------------
// Kitchen / Cashier — cross-account flow targets the order created by waiter
// ---------------------------------------------------------------------------

/// Kitchen advances item status. If the waiter previously captured an order
/// id, prefer that exact card so the flow is verifiable end-to-end.
FeatureSpec _kitchenFeature() {
  return FeatureSpec(
    name: 'kitchen',
    entryKey: UiKeys.kitchenRoot,
    run: (ctx, account) async {
      final tester = ctx.tester;
      _expectVisible(tester, UiKeys.kitchenRoot, 'kitchen_root not visible');

      final capturedId = ctx.capturedOrderId;
      if (capturedId != null) {
        final perOrderCard =
            find.byKey(Key('kitchen_order_$capturedId'));
        if (perOrderCard.evaluate().isEmpty) {
          throw TestFailure(
            'Cross-account flow broken: waiter created order $capturedId '
            'but kitchen does not see kitchen_order_$capturedId. '
            'Order routing or realtime subscription failure.',
          );
        }
        ctx.report.linkArtifacts.add(
          'kitchen[${account.email}]: confirmed waiter-created order $capturedId visible',
        );
      }

      final firstOrder =
          find.byKey(const Key(UiKeys.kitchenFirstOrderCard));
      final advanceButton =
          find.byKey(const Key(UiKeys.kitchenAdvanceStatusButton));

      if (firstOrder.evaluate().isEmpty) {
        // Even waiter's order would manifest as the first card; absence here
        // means the cross-account flow is broken.
        if (capturedId != null) {
          throw TestFailure(
            'kitchen_first_order_card absent despite waiter having created '
            'order $capturedId',
          );
        }
        ctx.report.linkArtifacts.add(
          'kitchen[${account.email}]: no active orders (kitchen_first_order_card absent)',
        );
        return;
      }

      _expectVisible(
        tester, UiKeys.kitchenFirstOrderCard,
        'kitchen_first_order_card disappeared',
      );

      if (advanceButton.evaluate().isNotEmpty) {
        await tester.tap(advanceButton);
        await tester.pumpAndSettle(const Duration(seconds: 2));
      }
    },
  );
}

/// Cashier pays the order created by waiter (if captured). Otherwise pays
/// the first available candidate.
FeatureSpec _cashierFeature() {
  return FeatureSpec(
    name: 'cashier',
    entryKey: UiKeys.cashierRoot,
    run: (ctx, account) async {
      final tester = ctx.tester;
      _expectVisible(tester, UiKeys.cashierRoot, 'cashier_root not visible');

      final capturedId = ctx.capturedOrderId;
      Finder targetCandidate;
      if (capturedId != null) {
        targetCandidate = find.byKey(Key('cashier_order_$capturedId'));
        if (targetCandidate.evaluate().isEmpty) {
          throw TestFailure(
            'Cross-account flow broken: waiter created order $capturedId '
            'but cashier does not see cashier_order_$capturedId. '
            'Realtime subscription or status-routing failure.',
          );
        }
        ctx.report.linkArtifacts.add(
          'cashier[${account.email}]: targeting waiter-created order $capturedId',
        );
      } else {
        targetCandidate = find.byKey(const Key(UiKeys.paymentFirstCandidate));
        if (targetCandidate.evaluate().isEmpty) {
          ctx.report.linkArtifacts.add(
            'cashier[${account.email}]: no payment_first_candidate present',
          );
          return;
        }
      }

      await tester.tap(targetCandidate);
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

      // Order has been paid; clear captured id so subsequent accounts
      // (validation) don't try to pay an already-paid order.
      ctx.capturedOrderId = null;
    },
  );
}

// ---------------------------------------------------------------------------
// Waiter features — landing, table grid, order creation (captures order id)
// ---------------------------------------------------------------------------

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

      await _dismissGuestCountDialogIfPresent(tester);

      final ordersVisible =
          find.byKey(const Key(UiKeys.ordersRoot)).evaluate().isNotEmpty;
      if (ordersVisible) {
        _expectVisible(tester, UiKeys.ordersRoot, 'orders_root not visible in workspace');
        // Cancel back to grid without creating an order — waiter_order
        // is the dedicated feature that performs the create.
        final cancelButton = find.text('CANCEL');
        if (cancelButton.evaluate().isNotEmpty) {
          await tester.tap(cancelButton.first);
          await tester.pumpAndSettle(const Duration(seconds: 2));
        }
      }
    },
  );
}

/// Creates a real order and captures its full id into SmokeContext so the
/// kitchen and cashier accounts can target it specifically.
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

      // Capture FULL order id from offstage debug widget for cross-account
      // routing. The visible latest_order_number_text only shows 8 chars.
      final fullIdFinder = find.byKey(const Key(UiKeys.latestOrderIdFullText));
      if (fullIdFinder.evaluate().isNotEmpty) {
        final widget = tester.widget<Text>(fullIdFinder);
        final fullId = (widget.data ?? '').trim();
        if (fullId.isNotEmpty) {
          ctx.capturedOrderId = fullId;
          ctx.report.linkArtifacts.add(
            'Order created by ${account.email}: id=$fullId (captured for kitchen/cashier flow)',
          );
        }
      }
    },
  );
}

// ---------------------------------------------------------------------------
// SuperAdmin features — full nav coverage
// ---------------------------------------------------------------------------

FeatureSpec _superAdminLandingFeature() {
  return FeatureSpec(
    name: 'super_admin_landing',
    entryKey: UiKeys.adminRoot,
    run: (ctx, account) async {
      _expectVisible(ctx.tester, UiKeys.adminRoot, 'admin_root (SuperAdminScreen) not visible');
      _expectVisible(
        ctx.tester,
        UiKeys.superAdminNavStores,
        'super_admin_nav_stores not visible on landing',
      );
    },
  );
}

FeatureSpec _superAdminStoresTabFeature() {
  return FeatureSpec(
    name: 'super_admin_stores_tab',
    entryKey: UiKeys.superAdminNavStores,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(find.byKey(const Key(UiKeys.superAdminNavStores)));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      _expectVisible(tester, UiKeys.adminRoot, 'admin_root lost after super_admin Stores tab nav');
    },
  );
}

FeatureSpec _superAdminReportsTabFeature() {
  return FeatureSpec(
    name: 'super_admin_reports_tab',
    entryKey: UiKeys.superAdminNavReports,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(find.byKey(const Key(UiKeys.superAdminNavReports)));
      await tester.pumpAndSettle(const Duration(seconds: 3));
      _expectVisible(tester, UiKeys.adminRoot, 'admin_root lost after super_admin Reports tab nav');
    },
  );
}

FeatureSpec _superAdminQcStatusTabFeature() {
  return FeatureSpec(
    name: 'super_admin_qc_status_tab',
    entryKey: UiKeys.superAdminNavQcStatus,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(find.byKey(const Key(UiKeys.superAdminNavQcStatus)));
      await tester.pumpAndSettle(const Duration(seconds: 3));
      _expectVisible(tester, UiKeys.adminRoot, 'admin_root lost after super_admin QC Status tab nav');
    },
  );
}

FeatureSpec _superAdminQcTemplateTabFeature() {
  return FeatureSpec(
    name: 'super_admin_qc_template_tab',
    entryKey: UiKeys.superAdminNavQcTemplate,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(find.byKey(const Key(UiKeys.superAdminNavQcTemplate)));
      await tester.pumpAndSettle(const Duration(seconds: 3));
      _expectVisible(tester, UiKeys.adminRoot, 'admin_root lost after super_admin QC Template tab nav');
    },
  );
}

FeatureSpec _superAdminSystemSettingsTabFeature() {
  return FeatureSpec(
    name: 'super_admin_system_settings_tab',
    entryKey: UiKeys.superAdminNavSystemSettings,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(find.byKey(const Key(UiKeys.superAdminNavSystemSettings)));
      await tester.pumpAndSettle(const Duration(seconds: 3));
      _expectVisible(tester, UiKeys.adminRoot, 'admin_root lost after super_admin System Settings tab nav');
    },
  );
}

// ---------------------------------------------------------------------------
// Dialog helper
// ---------------------------------------------------------------------------

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
// Assertion + safe-step helpers
// ---------------------------------------------------------------------------

void _expectVisible(WidgetTester tester, String keyName, String message) {
  if (find.byKey(Key(keyName)).evaluate().isEmpty) {
    throw TestFailure(message);
  }
}

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
// UiKeys — reflects implemented widget key contract.
// ---------------------------------------------------------------------------

class UiKeys {
  // Login
  static const loginEmailField    = 'login_email_field';
  static const loginPasswordField = 'login_password_field';
  static const loginSubmitButton  = 'login_submit_button';
  static const authErrorText      = 'auth_error_text';
  static const logoutButton       = 'logout_button';

  // Admin sidebar nav (all entries now keyed)
  static const navTables             = 'nav_tables';
  static const navMenu               = 'nav_menu';
  static const navStaff              = 'nav_staff';
  static const navReports            = 'nav_reports';
  static const navAttendance         = 'nav_attendance';
  static const navInventory          = 'nav_inventory';
  static const navQc                 = 'nav_qc';
  static const navSettings           = 'nav_settings';
  static const navEinvoice           = 'nav_einvoice';
  static const navDeliverySettlement = 'nav_delivery_settlement';
  // nav_daily_closing is the section header inside Reports tab; not a sidebar
  // entry. Used via ensureVisible elsewhere.
  static const navDailyClosing = 'nav_daily_closing';

  // Root screens
  static const dashboardRoot    = 'dashboard_root';
  static const tablesRoot       = 'tables_root';
  static const kitchenRoot      = 'kitchen_root';
  static const cashierRoot      = 'cashier_root';
  static const adminRoot        = 'admin_root';
  static const reportsRoot      = 'reports_root';
  static const dailyClosingRoot = 'daily_closing_root';
  static const menuRoot         = 'menu_root';
  static const ordersRoot       = 'orders_root';

  // Admin tab body roots
  static const staffRoot        = 'staff_root';
  static const attendanceRoot   = 'attendance_root';
  static const inventoryRoot    = 'inventory_root';
  static const qcRoot           = 'qc_root';
  static const settingsRoot     = 'settings_root';
  static const einvoiceRoot     = 'einvoice_root';

  // SuperAdmin sidebar
  static const superAdminNavStores         = 'super_admin_nav_stores';
  static const superAdminNavReports        = 'super_admin_nav_reports';
  static const superAdminNavQcStatus       = 'super_admin_nav_qc_status';
  static const superAdminNavQcTemplate     = 'super_admin_nav_qc_template';
  static const superAdminNavSystemSettings = 'super_admin_nav_system_settings';

  // Order workspace
  static const menuFirstItem            = 'menu_first_item';
  static const cartSubmitOrder          = 'cart_submit_order';
  static const orderCreateSuccessBanner = 'order_create_success_banner';
  static const latestOrderNumberText    = 'latest_order_number_text';
  static const latestOrderIdFullText    = 'latest_order_id_full_text';

  // Tables
  static const tableFirstCard = 'table_first_card';

  // Payment
  static const paymentFirstCandidate = 'payment_first_candidate';
  static const paymentSubmitButton   = 'payment_submit_button';
  static const paymentSuccessBanner  = 'payment_success_banner';

  // Kitchen
  static const kitchenFirstOrderCard      = 'kitchen_first_order_card';
  static const kitchenAdvanceStatusButton = 'kitchen_advance_status_button';

  // Daily closing
  static const dailyClosingSubmitButton        = 'daily_closing_submit_button';
  static const dailyClosingSuccessBanner       = 'daily_closing_success_banner';
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
  /// When true, login failure is recorded as EXPECTED_OUT_OF_SCOPE without
  /// failing the run. Used for office-system accounts whose profiles live in
  /// a separate Supabase project.
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
  /// Per-account execution count. Default 1; non-repeatable operations
  /// (daily_closing) must remain at 1.
  final int maxPasses;
}

class SmokeContext {
  SmokeContext({required this.tester, required this.report});
  final WidgetTester tester;
  final SmokeRunReport report;
  String currentAccount = '';
  /// Full uuid of the order created by the waiter, captured for kitchen and
  /// cashier accounts to target. Cleared once the cashier pays it.
  String? capturedOrderId;
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
