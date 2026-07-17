import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    show AsyncValueX, ProviderScope;
import 'package:globos_pos_system/core/ui/app_primitives.dart'
    show AppErrorState;
import 'package:globos_pos_system/features/admin/providers/menu_provider.dart'
    show menuProvider;
import 'package:globos_pos_system/features/auth/auth_provider.dart'
    show authProvider;
import 'package:globos_pos_system/features/kitchen/kitchen_provider.dart'
    show kitchenProvider;
import 'package:globos_pos_system/features/payment/payment_provider.dart'
    show paymentProvider;
import 'package:globos_pos_system/core/ui/toast/toast_primitives.dart'
    show ToastFilterChip, ToastOperationalEmptyState;
import 'package:globos_pos_system/main.dart' as app;
import 'package:shared_preferences/shared_preferences.dart';

const _sharedPassword = String.fromEnvironment(
  'SMOKE_SHARED_PASSWORD',
  defaultValue: '',
);
const _noStoreScopeEmail = String.fromEnvironment(
  'SMOKE_NOSTORE_EMAIL',
  defaultValue: '',
);
const _waiterEmail = String.fromEnvironment(
  'SMOKE_WAITER_EMAIL',
  defaultValue: 'waiter@globos.test',
);
const _kitchenEmail = String.fromEnvironment(
  'SMOKE_KITCHEN_EMAIL',
  defaultValue: 'kitchen@globos.test',
);
const _cashierEmail = String.fromEnvironment(
  'SMOKE_CASHIER_EMAIL',
  defaultValue: 'cashier@globos.test',
);
const _adminEmail = String.fromEnvironment(
  'SMOKE_ADMIN_EMAIL',
  defaultValue: 'admin@globos.test',
);
const _superAdminEmail = String.fromEnvironment(
  'SMOKE_SUPERADMIN_EMAIL',
  defaultValue: 'superadmin@globos.test',
);
const _validationEmail = String.fromEnvironment(
  'SMOKE_VALIDATION_EMAIL',
  defaultValue: 'pos.validation.codex@globos.test',
);
const _includeOfficeAccounts = bool.fromEnvironment(
  'SMOKE_INCLUDE_OFFICE_ACCOUNTS',
  defaultValue: true,
);
const _maxTestDataInputsPerActivatableButton = 3;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('full multi-account smoke test', (tester) async {
    final report = SmokeRunReport();
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('RenderFlex overflowed')) {
        debugPrint('SMOKE_RENDER_OVERFLOW_DIAGNOSTIC_START');
        debugPrint(details.toString());
        debugPrint('SMOKE_RENDER_OVERFLOW_DIAGNOSTIC_END');
      }
      previousOnError?.call(details);
    };

    try {
      if (_sharedPassword.isEmpty) {
        throw TestFailure(
          'SMOKE_SHARED_PASSWORD is required. Pass it with '
          '--dart-define=SMOKE_SHARED_PASSWORD=<pilot smoke password>.',
        );
      }
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      app.main();
      await _pumpFor(tester, const Duration(seconds: 8));

      // Account order is load-bearing: waiter creates an order, kitchen
      // advances that order, cashier pays that order, then admin/super
      // navigate the rest. Validation runs last with a full feature set.
      final accounts = <AccountSpec>[
        AccountSpec(
          email: _waiterEmail,
          expectedSurface: AccountSurface.waiterPos,
        ),
        AccountSpec(
          email: _kitchenEmail,
          expectedSurface: AccountSurface.kitchenPos,
        ),
        AccountSpec(
          email: _cashierEmail,
          expectedSurface: AccountSurface.cashierPos,
        ),
        AccountSpec(
          email: _adminEmail,
          expectedSurface: AccountSurface.adminPos,
        ),
        AccountSpec(
          email: _superAdminEmail,
          expectedSurface: AccountSurface.superAdminPos,
        ),
        // Office accounts live in a separate office app/Supabase project.
        // They exist in auth.users but have no public.users POS profile,
        // so _fetchUserProfile throws. skipIfLoginFails records the outcome
        // as EXPECTED_OUT_OF_SCOPE without stopping the run.
        if (_includeOfficeAccounts) ...[
          AccountSpec(
            email: 'office.store@globos.vn',
            expectedSurface: AccountSurface.officeStore,
            skipIfLoginFails: true,
          ),
          AccountSpec(
            email: 'office.brand.kn@globos.vn',
            expectedSurface: AccountSurface.officeBrand,
            skipIfLoginFails: true,
          ),
          AccountSpec(
            email: 'office.brand.mk@globos.vn',
            expectedSurface: AccountSurface.officeBrand,
            skipIfLoginFails: true,
          ),
          AccountSpec(
            email: 'office.staff@globos.vn',
            expectedSurface: AccountSurface.officeStaff,
            skipIfLoginFails: true,
          ),
          AccountSpec(
            email: 'office.super@globos.vn',
            expectedSurface: AccountSurface.officeSuper,
            skipIfLoginFails: true,
          ),
        ],
        AccountSpec(
          email: _validationEmail,
          expectedSurface: AccountSurface.validation,
        ),
        // Negative fixture (env-gated): an account provisioned WITHOUT any
        // store scope. Login must be refused with a visible error
        // (login gate contract AC3). Provide via
        // --dart-define=SMOKE_NOSTORE_EMAIL=zz.negative.nostore@globos.test
        if (_noStoreScopeEmail.isNotEmpty)
          AccountSpec(
            email: _noStoreScopeEmail,
            // Surface is irrelevant: the run asserts login is blocked and
            // returns before any surface discovery.
            expectedSurface: AccountSurface.waiterPos,
            expectLoginBlocked: true,
          ),
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
      report.finalVerdict = report.finalVerdict == 'PASS'
          ? 'FAIL'
          : report.finalVerdict;
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

  // Blocked-login gate check (storeId=null / unknown-role fixtures): the
  // login attempt itself must fail with a surfaced error, never a home
  // screen (harness C3).
  if (account.expectLoginBlocked) {
    await _safeStep(ctx, 'login_blocked_gate[${account.email}]', () async {
      await _performLogin(
        tester,
        email: account.email,
        password: _sharedPassword,
      );
      await _pumpFor(tester, const Duration(seconds: 6));

      final errorVisible = find
          .byKey(const Key(UiKeys.authErrorText))
          .evaluate()
          .isNotEmpty;
      final stillOnLogin = find
          .byKey(const Key(UiKeys.loginSubmitButton))
          .evaluate()
          .isNotEmpty;
      if (!errorVisible || !stillOnLogin) {
        throw TestFailure(
          'Blocked account ${account.email} was not refused at login: '
          'errorVisible=$errorVisible stillOnLogin=$stillOnLogin. '
          'storeId=null / unknown-role sessions must never reach home.',
        );
      }
      accountResult.loginResult = 'BLOCKED_AS_EXPECTED';
      accountResult.landingSurface = 'login (refused)';
    });
    await _forceSignOut(tester);
    return;
  }

  // Login once per account. skipIfLoginFails: log+skip on auth failure.
  if (account.skipIfLoginFails) {
    try {
      ctx.report.commandsRun.add('login_pass_1');
      await _performLogin(
        tester,
        email: account.email,
        password: _sharedPassword,
      );
      await _acceptPrivacyConsentIfPresent(tester);
      final landing = await _waitForLandingSurface(tester);
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
      await _performLogin(
        tester,
        email: account.email,
        password: _sharedPassword,
      );
      await _acceptPrivacyConsentIfPresent(tester);
      final landing = await _waitForLandingSurface(tester);
      accountResult.loginResult = 'PASS';
      accountResult.landingSurface = landing;
      accountResult.effectiveScope = landing;
    });
  }

  // Discover features that are visibly reachable for this account
  final visible = await _safeStepReturn<List<FeatureSpec>>(
    ctx,
    'surface_inventory',
    () => _discoverVisibleFeatures(tester, account.expectedSurface),
  );

  accountResult.visibleFeatures = visible.map((e) => e.name).toList();

  // Run each visible feature exactly maxPasses times (default 1).
  for (final feature in visible) {
    for (var pass = 1; pass <= feature.maxPasses; pass++) {
      await _safeStep(
        ctx,
        '${feature.name}_pass_$pass[${account.email}]',
        () async {
          await feature.run(ctx, account);
        },
      );
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
  await _pumpFor(tester, const Duration(seconds: 2));

  final emailFinder = find.byKey(const Key(UiKeys.loginEmailField));
  final passwordFinder = find.byKey(const Key(UiKeys.loginPasswordField));
  final buttonFinder = find.byKey(const Key(UiKeys.loginSubmitButton));

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
  final emailField = find.byKey(const Key(UiKeys.loginEmailField));
  final passField = find.byKey(const Key(UiKeys.loginPasswordField));
  final loginButton = find.byKey(const Key(UiKeys.loginSubmitButton));

  await tester.tap(emailField);
  await _pumpFor(tester, const Duration(milliseconds: 300));
  await tester.enterText(emailField, email);

  await tester.tap(passField);
  await _pumpFor(tester, const Duration(milliseconds: 300));
  await tester.enterText(passField, password);

  await tester.tap(loginButton);
  await _pumpFor(tester, const Duration(seconds: 6));

  final errorText = find.byKey(const Key(UiKeys.authErrorText));
  if (errorText.evaluate().isNotEmpty) {
    final widget = tester.widget<Text>(errorText);
    throw TestFailure('Login failed for $email: ${widget.data}');
  }
}

Future<void> _acceptPrivacyConsentIfPresent(WidgetTester tester) async {
  final checkbox = find.byKey(const Key(UiKeys.privacyConsentCheckbox));
  final acceptButton = find.byKey(const Key(UiKeys.privacyConsentAcceptButton));

  if (checkbox.evaluate().isEmpty || acceptButton.evaluate().isEmpty) {
    return;
  }

  await tester.ensureVisible(checkbox.first);
  await tester.tap(checkbox.first);
  await _pumpFor(tester, const Duration(seconds: 1));

  await tester.ensureVisible(acceptButton.first);
  await tester.tap(acceptButton.first);
  await _pumpFor(tester, const Duration(seconds: 6));
}

String _captureLandingSurface(WidgetTester tester) {
  for (final candidate in [
    UiKeys.kitchenRoot,
    UiKeys.cashierRoot,
    UiKeys.dashboardRoot, // waiterPos
    UiKeys.adminRoot, // adminPos / officePos / superAdminPos
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

Future<String> _waitForLandingSurface(
  WidgetTester tester, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    try {
      return _captureLandingSurface(tester);
    } catch (_) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  final authError = find.byKey(const Key(UiKeys.authErrorText));
  if (authError.evaluate().isNotEmpty) {
    final widget = tester.widget<Text>(authError.first);
    throw TestFailure(
      'Could not determine landing surface after ${timeout.inSeconds}s. '
      'Auth error visible: ${widget.data}',
    );
  }

  final stillOnLogin = find
      .byKey(const Key(UiKeys.loginEmailField))
      .evaluate()
      .isNotEmpty;
  throw TestFailure(
    'Could not determine landing surface after ${timeout.inSeconds}s. '
    'stillOnLogin=$stillOnLogin',
  );
}

Future<void> _pumpFor(
  WidgetTester tester,
  Duration duration, {
  Duration step = const Duration(milliseconds: 100),
}) async {
  var elapsed = Duration.zero;
  while (elapsed < duration) {
    final remaining = duration - elapsed;
    final delta = remaining < step ? remaining : step;
    await tester.pump(delta);
    elapsed += delta;
  }
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
    await tester.ensureVisible(logoutButton.first);
    await tester.tap(logoutButton.first, warnIfMissed: false);
    await _pumpFor(tester, const Duration(seconds: 3));
  }
  if (find.byKey(const Key(UiKeys.loginEmailField)).evaluate().isEmpty) {
    await _forceSignOut(tester);
  }
}

// ---------------------------------------------------------------------------
// Feature discovery
// ---------------------------------------------------------------------------

Future<List<FeatureSpec>> _discoverVisibleFeatures(
  WidgetTester tester,
  AccountSurface surface,
) async {
  final all = _featureMatrix(surface);
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  var missing = <FeatureSpec>[];
  while (DateTime.now().isBefore(deadline)) {
    missing = all.where((feature) {
      return find.byKey(Key(feature.entryKey)).evaluate().isEmpty;
    }).toList();
    if (missing.isEmpty) {
      return all;
    }
    await _pumpFor(tester, const Duration(milliseconds: 500));
  }

  throw TestFailure(
    'Required surface features missing for $surface: '
    '${missing.map((feature) => '${feature.name}[${feature.entryKey}]').join(', ')}',
  );
}

List<FeatureSpec> _blockedFeatures(
  AccountSurface surface,
  List<FeatureSpec> visible,
) {
  final visibleNames = visible.map((e) => e.name).toSet();
  return _featureMatrix(
    surface,
  ).where((e) => !visibleNames.contains(e.name)).toList();
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
      return [_cashierFeature()];
    case AccountSurface.waiterPos:
      return [
        _waiterDashboardFeature(),
        _waiterTablesFeature(),
        // Cancel path runs BEFORE the handoff order so the cancelled order
        // never collides with the one kitchen/cashier must see.
        _waiterCancelPathFeature(),
        _waiterOrderFeature(),
      ];
    case AccountSurface.kitchenPos:
      return [_kitchenFeature()];
    case AccountSurface.officeStore:
      return [
        _adminLandingFeature(),
        _reportsFeature(),
        _dailyClosingFeature(),
      ];
    case AccountSurface.officeBrand:
      return [_adminLandingFeature(), _reportsFeature()];
    case AccountSurface.officeStaff:
      return [_adminLandingFeature()];
    case AccountSurface.officeSuper:
      return [
        _adminLandingFeature(),
        _adminTablesNavFeature(),
        _adminMenuNavFeature(),
        _reportsFeature(),
      ];
    case AccountSurface.validation:
      // The validation account is an admin fixture. Dedicated waiter,
      // kitchen, cashier, and super-admin accounts own their role workflows.
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
      await _pumpFor(tester, const Duration(seconds: 2));
      _expectVisible(
        tester,
        UiKeys.adminTablesRoot,
        'admin_tables_root not visible after Tables nav',
      );
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
      await _pumpFor(tester, const Duration(seconds: 2));
      _expectVisible(
        tester,
        UiKeys.adminMenuRoot,
        'admin_menu_root not visible after Menu nav',
      );
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
      await _pumpFor(tester, const Duration(seconds: 2));
      _expectVisible(
        tester,
        UiKeys.staffRoot,
        'staff_root not visible after Staff nav',
      );
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
      await _pumpFor(tester, const Duration(seconds: 2));
      _expectVisible(
        tester,
        UiKeys.attendanceRoot,
        'attendance_root not visible after Attendance nav',
      );
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
      await _pumpFor(tester, const Duration(seconds: 2));
      _expectVisible(
        tester,
        UiKeys.inventoryRoot,
        'inventory_root not visible after Inventory nav',
      );
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
      await _pumpFor(tester, const Duration(seconds: 2));
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
      await _pumpFor(tester, const Duration(seconds: 2));
      _expectVisible(
        tester,
        UiKeys.settingsRoot,
        'settings_root not visible after Settings nav',
      );
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
      await _pumpFor(tester, const Duration(seconds: 2));
      _expectVisible(
        tester,
        UiKeys.einvoiceRoot,
        'einvoice_root not visible after E-Invoice nav',
      );
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
      await _pumpFor(tester, const Duration(seconds: 2));
      _expectVisible(
        tester,
        UiKeys.deliverySettlementRoot,
        'delivery_settlement_root not visible after Delivery Settlement nav',
      );
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
      await _pumpFor(tester, const Duration(seconds: 3));
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
      await _pumpFor(tester, const Duration(seconds: 3));
      _expectVisible(tester, UiKeys.reportsRoot, 'reports_root not visible');
      _expectVisible(
        tester,
        UiKeys.dailyClosingRoot,
        'daily_closing_root not reachable in Reports',
      );

      // Already-closed → record artifact and skip without failing the run.
      final alreadyClosed = find.byKey(
        const Key(UiKeys.dailyClosingAlreadyClosedBanner),
      );
      if (alreadyClosed.evaluate().isNotEmpty) {
        ctx.report.linkArtifacts.add(
          'daily_closing[${account.email}]: already closed for today (non-repeatable boundary observed)',
        );
        return;
      }

      final closeButton = find.byKey(
        const Key(UiKeys.dailyClosingSubmitButton),
      );
      if (closeButton.evaluate().isEmpty) {
        throw TestFailure(
          'daily_closing_submit_button is required for ${account.email}',
        );
      }

      await tester.ensureVisible(closeButton);
      await _pumpFor(tester, const Duration(milliseconds: 300));

      await tester.tap(closeButton);
      await _pumpFor(tester, const Duration(milliseconds: 500));

      final dialogConfirm = find.byKey(
        const Key(UiKeys.toastConfirmDialogConfirm),
      );
      if (dialogConfirm.evaluate().isNotEmpty) {
        await tester.tap(dialogConfirm);
      }
      await _pumpFor(tester, const Duration(seconds: 4));

      final successBanner = find.byKey(
        const Key(UiKeys.dailyClosingSuccessBanner),
      );
      final nowAlreadyClosed = find.byKey(
        const Key(UiKeys.dailyClosingAlreadyClosedBanner),
      );
      final closeButtonAfter = find.byKey(
        const Key(UiKeys.dailyClosingSubmitButton),
      );

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
        await _waitForKey(tester, 'kitchen_order_$capturedId');
        final perOrderCard = find.byKey(Key('kitchen_order_$capturedId'));
        if (perOrderCard.evaluate().isEmpty) {
          // Lane lists are lazy: with backlog the card may be below the fold.
          try {
            await tester.scrollUntilVisible(
              perOrderCard,
              200,
              scrollable: find.byType(Scrollable).first,
            );
          } catch (_) {}
          await _pumpFor(tester, const Duration(seconds: 1));
        }
        if (perOrderCard.evaluate().isEmpty) {
          try {
            final container = ProviderScope.containerOf(
              tester.element(find.byKey(const Key(UiKeys.kitchenRoot))),
            );
            final ks = container.read(kitchenProvider);
            final auth = container.read(authProvider);
            ctx.report.linkArtifacts.add(
              'kitchen[provider-dump]: storeId=${auth.storeId} '
              'loading=${ks.isLoading} error=${ks.error} '
              'orders=${ks.orders.map((o) => o.orderId).toList()} '
              'completed=${ks.completedOrders.length}',
            );
          } catch (e) {
            ctx.report.linkArtifacts.add('kitchen[provider-dump]: failed $e');
          }
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

      await _waitForKey(tester, UiKeys.kitchenFirstOrderCard);
      final firstOrder = find.byKey(const Key(UiKeys.kitchenFirstOrderCard));
      final advanceButton = find.byKey(
        const Key(UiKeys.kitchenAdvanceStatusButton),
      );

      if (firstOrder.evaluate().isEmpty) {
        // Even waiter's order would manifest as the first card; absence here
        // means the cross-account flow is broken.
        if (capturedId != null) {
          throw TestFailure(
            'kitchen_first_order_card absent despite waiter having created '
            'order $capturedId',
          );
        }
        throw TestFailure(
          'kitchen_first_order_card absent for ${account.email}; '
          'the required waiter handoff order was not available',
        );
      }

      _expectVisible(
        tester,
        UiKeys.kitchenFirstOrderCard,
        'kitchen_first_order_card disappeared',
      );

      // Cycle every visible item to ready/served: the cashier queue only
      // shows orders whose ACTIVE items are all ready|served (order status
      // 'serving' per ORDER_LIFECYCLE_STATE_CONTRACT).
      var taps = 0;
      while (advanceButton.evaluate().isNotEmpty && taps < 12) {
        // Narrow layouts put the lane below the fold — scroll to the button
        // or the tap lands outside the viewport and never hits.
        await tester.ensureVisible(advanceButton.first);
        await _pumpFor(tester, const Duration(milliseconds: 200));
        await tester.tap(advanceButton.first, warnIfMissed: false);
        taps++;
        await _pumpFor(tester, const Duration(seconds: 2));
      }
      if (taps == 0) {
        throw TestFailure(
          'kitchen_item_status_button was not actionable for the required order',
        );
      }
      ctx.report.linkArtifacts.add(
        'kitchen[${account.email}]: item status cycle taps=$taps',
      );
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
        await _waitForKey(tester, 'cashier_order_$capturedId');
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
        await _waitForKey(tester, UiKeys.paymentFirstCandidate);
        targetCandidate = find.byKey(const Key(UiKeys.paymentFirstCandidate));
        if (targetCandidate.evaluate().isEmpty) {
          throw TestFailure(
            'payment_first_candidate is required for ${account.email}',
          );
        }
      }

      await tester.ensureVisible(targetCandidate);
      await _pumpFor(tester, const Duration(milliseconds: 200));
      await tester.tap(targetCandidate, warnIfMissed: false);
      await _pumpFor(tester, const Duration(seconds: 2));

      final payButton = find.byKey(const Key(UiKeys.paymentSubmitButton));
      if (payButton.evaluate().isEmpty) {
        throw TestFailure(
          'payment_submit_button not visible after candidate selection',
        );
      }

      await tester.ensureVisible(payButton);
      await _pumpFor(tester, const Duration(milliseconds: 200));
      await tester.tap(payButton, warnIfMissed: false);
      await _pumpFor(tester, const Duration(seconds: 2));

      final cashMethod = find.byKey(const Key(UiKeys.cashierMethodDialogCash));
      _expectVisible(
        tester,
        UiKeys.cashierMethodDialogCash,
        'cashier_method_dialog_CASH not visible after first payment button tap',
      );

      // The banner widget is always mounted behind an AnimatedOpacity, so
      // presence alone is meaningless — check the actual success state.
      final containerMid = ProviderScope.containerOf(
        tester.element(find.byKey(const Key(UiKeys.cashierRoot))),
      );
      if (containerMid.read(paymentProvider).paymentSuccess) {
        throw TestFailure(
          'payment completed after method lookup only. '
          'Cashier payment must complete only after a selected method is confirmed.',
        );
      }

      await tester.ensureVisible(cashMethod);
      await tester.tap(cashMethod, warnIfMissed: false);
      await _pumpFor(tester, const Duration(seconds: 1));

      await tester.ensureVisible(payButton);
      await tester.tap(payButton, warnIfMissed: false);
      await _pumpFor(tester, const Duration(seconds: 4));

      // Success evidence: the transient paymentSuccess flag OR the durable
      // outcome — the paid order leaving the payable queue (the flag is
      // auto-reset by the screen, so polling can legitimately miss it).
      var paymentConfirmed = false;
      final paidOrderId = capturedId;
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        final c = ProviderScope.containerOf(
          tester.element(find.byKey(const Key(UiKeys.cashierRoot))),
        );
        final ps = c.read(paymentProvider);
        final stillQueued =
            paidOrderId != null &&
            ps.orders.any((order) => order.orderId == paidOrderId);
        if (ps.paymentSuccess || (paidOrderId != null && !stillQueued)) {
          paymentConfirmed = true;
          break;
        }
        await _pumpFor(tester, const Duration(milliseconds: 500));
      }
      if (!paymentConfirmed) {
        throw TestFailure(
          'payment outcome not observed: paymentSuccess never set and the '
          'paid order is still in the payable queue',
        );
      }

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
      _expectVisible(
        tester,
        UiKeys.dashboardRoot,
        'dashboard_root not visible',
      );
      _expectVisible(
        tester,
        UiKeys.tablesRoot,
        'tables_root not visible on waiter dashboard',
      );
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
        throw TestFailure(
          'table_first_card is required for waiter table selection',
        );
      }

      await tester.tap(firstTable);
      await _pumpFor(tester, const Duration(seconds: 2));

      await _dismissGuestCountDialogIfPresent(tester);

      final ordersVisible = find
          .byKey(const Key(UiKeys.ordersRoot))
          .evaluate()
          .isNotEmpty;
      if (ordersVisible) {
        _expectVisible(
          tester,
          UiKeys.ordersRoot,
          'orders_root not visible in workspace',
        );
        // Cancel back to grid without creating an order — waiter_order
        // is the dedicated feature that performs the create.
        final cancelButton = find.byKey(
          const Key(UiKeys.orderWorkspaceCancelButton),
        );
        if (cancelButton.evaluate().isEmpty) {
          throw TestFailure(
            'order_workspace_cancel_button is required in waiter workspace',
          );
        }
        await tester.tap(cancelButton.first);
        await _pumpFor(tester, const Duration(seconds: 2));
      } else {
        throw TestFailure(
          'orders_root not visible after selecting table_first_card',
        );
      }
    },
  );
}

/// Gate 3 cancel path (PILOT_SMOKE_GATE_TEST_PLAN 3.6): create an order,
/// cancel it through the workspace cancel action, and verify the table is
/// released back to available. Runs before _waiterOrderFeature so the
/// cancelled order is never the cross-account handoff order.
FeatureSpec _waiterCancelPathFeature() {
  return FeatureSpec(
    name: 'waiter_cancel_path',
    entryKey: UiKeys.tableFirstCard,
    run: (ctx, account) async {
      final tester = ctx.tester;

      final firstTable = find.byKey(const Key(UiKeys.tableFirstCard));
      if (firstTable.evaluate().isEmpty) {
        throw TestFailure(
          'waiter_cancel_path requires table_first_card for ${account.email}',
        );
      }

      await tester.tap(firstTable);
      await _pumpFor(tester, const Duration(seconds: 2));
      await _dismissGuestCountDialogIfPresent(tester);

      final menuReady = await _waitForKey(tester, UiKeys.menuFirstItem);
      final submitReady = await _waitForKey(
        tester,
        UiKeys.cartSubmitOrder,
        timeout: const Duration(seconds: 4),
      );
      final menuItem = find.byKey(const Key(UiKeys.menuFirstItem));
      final submitBtn = find.byKey(const Key(UiKeys.cartSubmitOrder));
      if (!menuReady || !submitReady) {
        String has(String keyName) =>
            find.byKey(Key(keyName)).evaluate().isNotEmpty ? 'Y' : 'n';
        final dialogs = find.byType(AlertDialog).evaluate().length;
        ctx.report.linkArtifacts.add(
          'waiter_cancel_path[${account.email}]: workspace or menu not '
          'available — skipping cancel path '
          '[diag ordersRoot=${has(UiKeys.ordersRoot)} '
          'tablesRoot=${has(UiKeys.tablesRoot)} '
          'guestInput=${has(UiKeys.waiterGuestCountInput)} '
          'guestConfirm=${has(UiKeys.waiterGuestCountConfirm)} '
          'menuGrid=${has('menu_item_grid')} '
          'submit=${has(UiKeys.cartSubmitOrder)} '
          'alertDialogs=$dialogs '
          'chips=${find.byType(ToastFilterChip).evaluate().length} '
          'empty=${find.byType(ToastOperationalEmptyState).evaluate().length} '
          'spinners=${find.byType(CircularProgressIndicator).evaluate().length} '
          'menuRoot=${has('menu_root')} '
          'errorStates=${find.byType(AppErrorState).evaluate().length}]',
        );
        try {
          final container = ProviderScope.containerOf(
            tester.element(find.byKey(const Key(UiKeys.ordersRoot))),
          );
          final auth = container.read(authProvider);
          final sid = auth.storeId;
          String menuDump = 'storeId=null';
          if (sid != null) {
            final menu = container.read(menuProvider(sid));
            menuDump =
                'storeId=$sid '
                'catLoading=${menu.categories.isLoading} '
                'catError=${menu.categories.hasError} '
                'catCount=${menu.categories.valueOrNull?.length} '
                'itemCount=${menu.items.valueOrNull?.length} '
                'selectedCat=${menu.selectedCategoryId} '
                'catErrorDetail=${menu.categories.hasError ? menu.categories.error : ''}';
          }
          ctx.report.linkArtifacts.add(
            'waiter_cancel_path[provider-dump]: role=${auth.role} '
            'stores=${auth.accessibleStores.length} $menuDump',
          );
        } catch (e) {
          ctx.report.linkArtifacts.add(
            'waiter_cancel_path[provider-dump]: failed — $e',
          );
        }
        throw TestFailure(
          'waiter_cancel_path requires menu_first_item and cart_submit_order',
        );
      }

      await tester.tap(menuItem);
      await _pumpFor(tester, const Duration(milliseconds: 300));
      await tester.tap(submitBtn);
      await _pumpFor(tester, const Duration(seconds: 4));
      _expectVisible(
        tester,
        UiKeys.orderCreateSuccessBanner,
        'order_create_success_banner not visible before cancel path',
      );

      var cancelAction = find.byKey(
        const Key(UiKeys.orderCancelOrderDirectAction),
      );
      if (cancelAction.evaluate().isEmpty) {
        // Narrow layouts render the compact variant of the same action.
        cancelAction = find.byKey(
          const Key(UiKeys.orderCancelOrderDirectActionCompact),
        );
      }
      if (cancelAction.evaluate().isEmpty) {
        throw TestFailure(
          'waiter_cancel_path: order_cancel_order_direct_action not visible '
          'for an active order',
        );
      }
      await tester.ensureVisible(cancelAction);
      await tester.tap(cancelAction);
      await _pumpFor(tester, const Duration(seconds: 1));

      final confirmButton = find.byKey(
        const Key(UiKeys.waiterCancelOrderConfirmButton),
      );
      _expectVisible(
        tester,
        UiKeys.waiterCancelOrderConfirmButton,
        'cancel-order confirm dialog not shown',
      );
      await tester.tap(confirmButton);
      await _pumpFor(tester, const Duration(seconds: 4));

      // Contract C2: cancel releases the table — the grid must be back with
      // the first table selectable (available), not stuck in the workspace.
      _expectVisible(
        tester,
        UiKeys.tablesRoot,
        'tables grid not visible after order cancel (table not released?)',
      );
      _expectVisible(
        tester,
        UiKeys.tableFirstCard,
        'table_first_card not visible after order cancel — table stuck',
      );
      ctx.report.linkArtifacts.add(
        'waiter_cancel_path[${account.email}]: order cancelled and table '
        'released (Gate 3 cancel path PASS)',
      );
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
      if (firstTable.evaluate().isEmpty) {
        throw TestFailure(
          'waiter_order requires table_first_card for ${account.email}',
        );
      }

      await tester.tap(firstTable);
      await _pumpFor(tester, const Duration(seconds: 2));

      await _dismissGuestCountDialogIfPresent(tester);

      final menuReady = await _waitForKey(tester, UiKeys.menuFirstItem);
      final submitReady = await _waitForKey(
        tester,
        UiKeys.cartSubmitOrder,
        timeout: const Duration(seconds: 4),
      );
      final menuItem = find.byKey(const Key(UiKeys.menuFirstItem));
      final submitBtn = find.byKey(const Key(UiKeys.cartSubmitOrder));

      if (!menuReady || !submitReady) {
        throw TestFailure(
          'waiter_order requires menu_first_item and cart_submit_order',
        );
      }

      await tester.tap(menuItem);
      await _pumpFor(tester, const Duration(milliseconds: 300));

      await tester.tap(submitBtn);
      await _pumpFor(tester, const Duration(seconds: 4));

      _expectVisible(
        tester,
        UiKeys.orderCreateSuccessBanner,
        'order_create_success_banner not visible after order submission',
      );

      // Capture FULL order id from offstage debug widget for cross-account
      // routing. The visible latest_order_number_text only shows 8 chars.
      final fullIdFinder = find.byKey(
        const Key(UiKeys.latestOrderIdFullText),
        skipOffstage: false,
      );
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
      if (ctx.capturedOrderId == null) {
        throw TestFailure(
          'latest_order_id_full_text did not expose the created order id',
        );
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
      _expectVisible(
        ctx.tester,
        UiKeys.adminRoot,
        'admin_root (SuperAdminScreen) not visible',
      );
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
      await _pumpFor(tester, const Duration(seconds: 2));
      _expectVisible(
        tester,
        UiKeys.adminRoot,
        'admin_root lost after super_admin Stores tab nav',
      );
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
      await _pumpFor(tester, const Duration(seconds: 3));
      _expectVisible(
        tester,
        UiKeys.adminRoot,
        'admin_root lost after super_admin Reports tab nav',
      );
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
      await _pumpFor(tester, const Duration(seconds: 3));
      _expectVisible(
        tester,
        UiKeys.adminRoot,
        'admin_root lost after super_admin QC Status tab nav',
      );
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
      await _pumpFor(tester, const Duration(seconds: 3));
      _expectVisible(
        tester,
        UiKeys.adminRoot,
        'admin_root lost after super_admin QC Template tab nav',
      );
    },
  );
}

FeatureSpec _superAdminSystemSettingsTabFeature() {
  return FeatureSpec(
    name: 'super_admin_system_settings_tab',
    entryKey: UiKeys.superAdminNavSystemSettings,
    run: (ctx, account) async {
      final tester = ctx.tester;
      await tester.tap(
        find.byKey(const Key(UiKeys.superAdminNavSystemSettings)),
      );
      await _pumpFor(tester, const Duration(seconds: 3));
      _expectVisible(
        tester,
        UiKeys.adminRoot,
        'admin_root lost after super_admin System Settings tab nav',
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Dialog helper
// ---------------------------------------------------------------------------

/// Polls until [keyName] is visible or [timeout] elapses. Network-backed
/// surfaces (menu list, payment queue) load asynchronously from prod, so
/// fixed pumps are flaky.
Future<bool> _waitForKey(
  WidgetTester tester,
  String keyName, {
  Duration timeout = const Duration(seconds: 12),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (find.byKey(Key(keyName)).evaluate().isNotEmpty) return true;
    await _pumpFor(tester, const Duration(milliseconds: 500));
  }
  return find.byKey(Key(keyName)).evaluate().isNotEmpty;
}

Future<void> _dismissGuestCountDialogIfPresent(WidgetTester tester) async {
  // Key-based, locale-independent: the dialog title/confirm labels are
  // localized (default locale is Korean), so text finders never match and
  // the mandatory guest-count dialog silently aborted table selection —
  // the root cause of the persistent waiter_order/cancel_path skips.
  final guestInput = find.byKey(const Key(UiKeys.waiterGuestCountInput));
  if (guestInput.evaluate().isEmpty) return;

  await tester.enterText(guestInput, '2');
  await _pumpFor(tester, const Duration(milliseconds: 300));

  final confirmButton = find.byKey(const Key(UiKeys.waiterGuestCountConfirm));
  if (confirmButton.evaluate().isNotEmpty) {
    await tester.tap(confirmButton);
    await _pumpFor(tester, const Duration(seconds: 1));
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
  static const loginEmailField = 'login_email_field';
  static const loginPasswordField = 'login_password_field';
  static const loginSubmitButton = 'login_submit_button';
  static const authErrorText = 'auth_error_text';
  static const logoutButton = 'logout_button';
  static const privacyConsentCheckbox = 'privacy_consent_checkbox';
  static const privacyConsentAcceptButton = 'privacy_consent_accept_button';

  // Admin sidebar nav (all entries now keyed)
  static const navTables = 'nav_tables';
  static const navMenu = 'nav_menu';
  static const navStaff = 'nav_staff';
  static const navReports = 'nav_reports';
  static const navAttendance = 'nav_attendance';
  static const navInventory = 'nav_inventory';
  static const navQc = 'nav_qc';
  static const navSettings = 'nav_settings';
  static const navEinvoice = 'nav_einvoice';
  static const navDeliverySettlement = 'nav_delivery_settlement';
  // nav_daily_closing is the section header inside Reports tab; not a sidebar
  // entry. Used via ensureVisible elsewhere.
  static const navDailyClosing = 'nav_daily_closing';

  // Root screens
  static const dashboardRoot = 'dashboard_root';
  static const tablesRoot = 'tables_root';
  static const kitchenRoot = 'kitchen_root';
  static const cashierRoot = 'cashier_root';
  static const adminRoot = 'admin_root';
  static const reportsRoot = 'reports_root';
  static const dailyClosingRoot = 'daily_closing_root';
  static const menuRoot = 'menu_root';
  static const ordersRoot = 'orders_root';

  // Admin tab body roots
  static const adminTablesRoot = 'admin_tables_root';
  static const adminMenuRoot = 'admin_menu_root';
  static const staffRoot = 'staff_root';
  static const attendanceRoot = 'attendance_root';
  static const inventoryRoot = 'inventory_root';
  static const qcRoot = 'qc_root';
  static const settingsRoot = 'settings_root';
  static const einvoiceRoot = 'einvoice_root';
  static const deliverySettlementRoot = 'delivery_settlement_root';

  // SuperAdmin sidebar
  static const superAdminNavStores = 'super_admin_nav_stores';
  static const superAdminNavReports = 'super_admin_nav_reports';
  static const superAdminNavQcStatus = 'super_admin_nav_qc_status';
  static const superAdminNavQcTemplate = 'super_admin_nav_qc_template';
  static const superAdminNavSystemSettings = 'super_admin_nav_system_settings';

  // Order workspace
  static const menuFirstItem = 'menu_first_item';
  static const cartSubmitOrder = 'cart_submit_order';
  static const orderCreateSuccessBanner = 'order_create_success_banner';
  static const latestOrderNumberText = 'latest_order_number_text';
  static const latestOrderIdFullText = 'latest_order_id_full_text';
  static const orderCancelOrderDirectAction =
      'order_cancel_order_direct_action';
  static const orderCancelOrderDirectActionCompact =
      'order_cancel_order_direct_action_compact';
  static const waiterCancelOrderConfirmButton =
      'waiter_cancel_order_confirm_button';
  static const waiterGuestCountInput = 'waiter_guest_count_input';
  static const waiterGuestCountConfirm = 'waiter_guest_count_confirm';
  static const orderWorkspaceCancelButton = 'order_workspace_cancel_button';

  // Tables
  static const tableFirstCard = 'table_first_card';

  // Payment
  static const paymentFirstCandidate = 'payment_first_candidate';
  static const paymentSubmitButton = 'payment_submit_button';
  static const cashierMethodDialogCash = 'cashier_method_dialog_CASH';
  static const paymentSuccessBanner = 'payment_success_banner';
  static const toastConfirmDialogConfirm = 'toast_confirm_dialog_confirm';

  // Kitchen
  static const kitchenFirstOrderCard = 'kitchen_first_order_card';
  // phase5 kitchen redesign: status advance is a per-item cycle button.
  static const kitchenAdvanceStatusButton = 'kitchen_item_status_button';

  // Daily closing
  static const dailyClosingSubmitButton = 'daily_closing_submit_button';
  static const dailyClosingSuccessBanner = 'daily_closing_success_banner';
  static const dailyClosingAlreadyClosedBanner =
      'daily_closing_already_closed_banner';
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
    this.expectLoginBlocked = false,
  });
  final String email;
  final AccountSurface expectedSurface;

  /// When true, login failure is recorded as EXPECTED_OUT_OF_SCOPE without
  /// failing the run. Used for office-system accounts whose profiles live in
  /// a separate Supabase project.
  final bool skipIfLoginFails;

  /// When true, the login MUST be refused with a visible auth error and no
  /// landing surface (STAFF_ACCOUNT_LOGIN_GATE_CONTRACT AC3/AC5). Reaching a
  /// home screen is a failure.
  final bool expectLoginBlocked;
}

class FeatureSpec {
  const FeatureSpec({
    required this.name,
    required this.entryKey,
    required this.run,
    this.maxPasses = 1,
  }) : assert(
         maxPasses >= 1 && maxPasses <= _maxTestDataInputsPerActivatableButton,
         'Button activation test data is capped at 3 inputs per button.',
       );
  final String name;
  final String entryKey;
  final Future<void> Function(SmokeContext ctx, AccountSpec account) run;

  /// Per-account execution count. Default 1; non-repeatable operations
  /// (daily_closing) must remain at 1. Do not raise this above the
  /// per-button test-data cap.
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
  final List<String> commandsRun = [];
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
    for (final item in linkArtifacts) {
      debugPrint('   - $item');
    }
    debugPrint('6. Steps Run:');
    for (final item in commandsRun) {
      debugPrint('   - $item');
    }
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
