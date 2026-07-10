import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/main.dart' as app;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sharedPassword = String.fromEnvironment(
  'SMOKE_SHARED_PASSWORD',
  defaultValue: '',
);
const _cashierEmail = String.fromEnvironment(
  'SMOKE_CASHIER_EMAIL',
  defaultValue: 'gate3.cashier@globos.test',
);
const _kitchenEmail = String.fromEnvironment(
  'SMOKE_KITCHEN_EMAIL',
  defaultValue: 'gate3.kitchen@globos.test',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('manual delivery order pilot flow', (tester) async {
    if (_sharedPassword.isEmpty) {
      throw TestFailure('SMOKE_SHARED_PASSWORD is required.');
    }

    SharedPreferences.setMockInitialValues(const <String, Object>{});
    app.main();
    await _pumpFor(tester, const Duration(seconds: 8));

    await _signIn(tester, email: _cashierEmail, expectedRoot: 'cashier_root');

    final cashierUser = app.supabase.auth.currentUser;
    if (cashierUser == null) {
      throw TestFailure('Cashier session is missing after login.');
    }
    final profile = await app.supabase
        .from('users')
        .select('restaurant_id')
        .eq('auth_id', cashierUser.id)
        .single();
    final storeId = profile['restaurant_id']?.toString() ?? '';
    if (storeId.isEmpty) {
      throw TestFailure('Cashier store scope is missing.');
    }

    final createdAfter = DateTime.now()
        .toUtc()
        .subtract(const Duration(seconds: 1))
        .toIso8601String();

    final newDeliveryButton = find.byKey(
      const Key('cashier_new_delivery_order'),
    );
    await _waitForFinder(tester, newDeliveryButton);
    await tester.ensureVisible(newDeliveryButton);
    await tester.tap(newDeliveryButton);
    await _pumpFor(tester, const Duration(seconds: 2));

    final dialog = find.byKey(const Key('cashier_delivery_order_dialog'));
    final firstItem = find.byKey(const Key('cashier_delivery_first_item'));
    final submit = find.byKey(const Key('cashier_delivery_submit'));
    await _waitForFinder(tester, dialog);
    await _waitForFinder(tester, firstItem);
    await tester.ensureVisible(firstItem);
    await tester.tap(firstItem);
    await _pumpFor(tester, const Duration(milliseconds: 500));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await _waitForGone(tester, dialog);

    final deliveryOrder = await _waitForOrder(
      storeId: storeId,
      createdBy: cashierUser.id,
      createdAfter: createdAfter,
    );
    final orderId = deliveryOrder['id']?.toString() ?? '';
    if (orderId.isEmpty || deliveryOrder['sales_channel'] != 'delivery') {
      throw TestFailure(
        'Delivery order was not created with delivery identity.',
      );
    }

    final kitchenJob = await _waitForPrintJob(orderId, 'kitchen');
    _expectDeliveryPayload(kitchenJob, 'kitchen');

    await _forceSignOut(tester);
    await _signIn(tester, email: _kitchenEmail, expectedRoot: 'kitchen_root');

    final kitchenSearch = find.byKey(const Key('kitchen_ticket_search_field'));
    await _waitForFinder(tester, kitchenSearch);
    await tester.enterText(kitchenSearch, orderId.substring(0, 8));
    await _pumpFor(tester, const Duration(seconds: 1));

    final kitchenCard = find.byKey(Key('kitchen_order_$orderId'));
    await _waitForFinder(tester, kitchenCard);
    if (kitchenCard.evaluate().isEmpty) {
      throw TestFailure('Kitchen did not receive delivery order $orderId.');
    }

    final kitchenBadge = find.byKey(
      Key('kitchen_delivery_order_badge_$orderId'),
    );
    await _waitForFinder(tester, kitchenBadge);

    var status = deliveryOrder['status']?.toString() ?? 'pending';
    for (var tapCount = 0; status != 'serving' && tapCount < 4; tapCount++) {
      final currentCard = find.byKey(Key('kitchen_order_$orderId'));
      final advance = find.descendant(
        of: currentCard,
        matching: find.byKey(const Key('kitchen_item_status_button')),
      );
      await _waitForFinder(tester, advance);
      await tester.ensureVisible(advance.first);
      await tester.tap(advance.first, warnIfMissed: false);
      await _pumpFor(tester, const Duration(seconds: 2));
      status = await _orderStatus(orderId);
    }
    if (status != 'serving') {
      throw TestFailure('Kitchen did not advance delivery order to serving.');
    }

    final trayJob = await _waitForPrintJob(orderId, 'tray');
    _expectDeliveryPayload(trayJob, 'tray');

    await _forceSignOut(tester);
    await _signIn(tester, email: _cashierEmail, expectedRoot: 'cashier_root');

    final cashierSearch = find.byKey(const Key('cashier_order_search'));
    await _waitForFinder(tester, cashierSearch);
    await tester.enterText(cashierSearch, orderId.substring(0, 8));
    await _pumpFor(tester, const Duration(seconds: 1));

    final cashierOrder = find.byKey(Key('cashier_order_$orderId'));
    final cashierBadge = find.byKey(
      Key('cashier_delivery_order_badge_$orderId'),
    );
    await _waitForFinder(tester, cashierOrder);
    await _waitForFinder(tester, cashierBadge);
    await tester.ensureVisible(cashierOrder);
    await tester.tap(cashierOrder, warnIfMissed: false);
    await _pumpFor(tester, const Duration(seconds: 1));

    final payButton = find.byKey(const Key('payment_submit_button'));
    await _waitForFinder(tester, payButton);
    await tester.ensureVisible(payButton);
    await tester.tap(payButton, warnIfMissed: false);
    await _pumpFor(tester, const Duration(seconds: 1));

    final cashMethod = find.byKey(const Key('cashier_method_dialog_CASH'));
    await _waitForFinder(tester, cashMethod);
    await tester.tap(cashMethod, warnIfMissed: false);
    await _pumpFor(tester, const Duration(milliseconds: 500));
    await tester.ensureVisible(payButton);
    await tester.tap(payButton, warnIfMissed: false);

    await _waitForStatus(orderId, 'completed');

    final automaticReceipt = await _findPrintJob(orderId, 'receipt');
    if (automaticReceipt == null) {
      await app.supabase.rpc(
        'enqueue_receipt_print_job',
        params: {'p_order_id': orderId, 'p_reprint': false},
      );
    }
    final receiptJob = await _waitForPrintJob(orderId, 'receipt');
    _expectDeliveryPayload(receiptJob, 'receipt');

    final paymentRows = await app.supabase
        .from('payments')
        .select('amount')
        .eq('order_id', orderId)
        .eq('is_revenue', true);
    final paidAmount = paymentRows.fold<double>(0, (sum, row) {
      final raw = row['amount'];
      return sum + (raw is num ? raw.toDouble() : double.tryParse('$raw') ?? 0);
    });
    if (paidAmount <= 0) {
      throw TestFailure('Delivery payment was not recorded as revenue.');
    }

    final revenueRows = await app.supabase
        .from('v_daily_revenue_by_channel')
        .select('delivery_revenue,total_revenue')
        .eq('restaurant_id', storeId)
        .eq(
          'sale_date',
          DateTime.now()
              .toUtc()
              .add(const Duration(hours: 7))
              .toIso8601String()
              .substring(0, 10),
        );
    if (revenueRows.isEmpty) {
      throw TestFailure('Delivery revenue report row is missing.');
    }
    final deliveryRevenue = revenueRows.fold<double>(0, (sum, row) {
      final raw = row['delivery_revenue'];
      return sum + (raw is num ? raw.toDouble() : double.tryParse('$raw') ?? 0);
    });
    if (deliveryRevenue < paidAmount) {
      throw TestFailure(
        'Delivery report revenue $deliveryRevenue is below payment $paidAmount.',
      );
    }

    debugPrint(
      'MANUAL_DELIVERY_PILOT_PASS order=$orderId '
      'kitchen=DELIVERY tray=DELIVERY receipt=DELIVERY '
      'paid=$paidAmount deliveryRevenue=$deliveryRevenue',
    );
  });
}

Future<void> _signIn(
  WidgetTester tester, {
  required String email,
  required String expectedRoot,
}) async {
  await _waitForFinder(tester, find.byKey(const Key('login_email_field')));
  final emailField = find.byKey(const Key('login_email_field'));
  final passwordField = find.byKey(const Key('login_password_field'));
  final submit = find.byKey(const Key('login_submit_button'));

  await tester.enterText(emailField, email);
  await tester.enterText(passwordField, _sharedPassword);
  await tester.tap(submit);
  await _pumpFor(tester, const Duration(seconds: 6));
  await _acceptPrivacyConsentIfPresent(tester);
  await _waitForFinder(tester, find.byKey(Key(expectedRoot)));

  final authError = find.byKey(const Key('auth_error_text'));
  if (authError.evaluate().isNotEmpty) {
    final widget = tester.widget<Text>(authError.first);
    throw TestFailure('Login failed for $email: ${widget.data}');
  }
}

Future<void> _acceptPrivacyConsentIfPresent(WidgetTester tester) async {
  final checkbox = find.byKey(const Key('privacy_consent_checkbox'));
  final accept = find.byKey(const Key('privacy_consent_accept_button'));
  if (checkbox.evaluate().isEmpty || accept.evaluate().isEmpty) {
    return;
  }
  await tester.tap(checkbox.first);
  await _pumpFor(tester, const Duration(milliseconds: 500));
  await tester.tap(accept.first);
  await _pumpFor(tester, const Duration(seconds: 4));
}

Future<void> _forceSignOut(WidgetTester tester) async {
  await app.supabase.auth.signOut();
  await _waitForFinder(tester, find.byKey(const Key('login_email_field')));
}

Future<Map<String, dynamic>> _waitForOrder({
  required String storeId,
  required String createdBy,
  required String createdAfter,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    final rows = await app.supabase
        .from('orders')
        .select('id,status,sales_channel')
        .eq('restaurant_id', storeId)
        .eq('created_by', createdBy)
        .eq('sales_channel', 'delivery')
        .gte('created_at', createdAfter)
        .order('created_at', ascending: false)
        .limit(1);
    if (rows.isNotEmpty) {
      return Map<String, dynamic>.from(rows.first);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  throw TestFailure('Created delivery order was not found.');
}

Future<String> _orderStatus(String orderId) async {
  final row = await app.supabase
      .from('orders')
      .select('status')
      .eq('id', orderId)
      .single();
  return row['status']?.toString() ?? '';
}

Future<void> _waitForStatus(String orderId, String expected) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    if (await _orderStatus(orderId) == expected) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  throw TestFailure('Order $orderId did not reach $expected.');
}

Future<Map<String, dynamic>> _waitForPrintJob(
  String orderId,
  String copyType,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    final job = await _findPrintJob(orderId, copyType);
    if (job != null) {
      return job;
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  throw TestFailure('$copyType print job was not created for $orderId.');
}

Future<Map<String, dynamic>?> _findPrintJob(
  String orderId,
  String copyType,
) async {
  final rows = await app.supabase
      .from('print_jobs')
      .select('copy_type,payload,status,last_error')
      .eq('order_id', orderId)
      .eq('copy_type', copyType)
      .order('created_at', ascending: false)
      .limit(1);
  return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
}

void _expectDeliveryPayload(Map<String, dynamic> job, String copyType) {
  final payload = Map<String, dynamic>.from(job['payload'] as Map);
  if (payload['sales_channel'] != 'delivery' ||
      payload['table_number'] != 'DELIVERY' ||
      payload['floor_label'] != 'DELIVERY') {
    throw TestFailure(
      '$copyType print payload lost delivery identity: $payload',
    );
  }
}

Future<void> _waitForFinder(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isNotEmpty) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
  throw TestFailure('Timed out waiting for $finder.');
}

Future<void> _waitForGone(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isEmpty) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
  throw TestFailure('Timed out waiting for $finder to disappear.');
}

Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  var elapsed = Duration.zero;
  while (elapsed < duration) {
    const step = Duration(milliseconds: 100);
    final remaining = duration - elapsed;
    final delta = remaining < step ? remaining : step;
    await tester.pump(delta);
    elapsed += delta;
  }
}
