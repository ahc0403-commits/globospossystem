import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('cashier screen routes key operational copy through localization', () {
    final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');

    expect(cashier, contains('context.l10n'));
    expect(cashier, contains('l10n.cashierTitle'));
    expect(cashier, contains('l10n.cashierSubtitle'));
    expect(cashier, contains('l10n.cashierNoPayableOrdersTitle'));
    expect(cashier, contains('l10n.cashierSelectTableTitle'));
    expect(cashier, contains('l10n.cashierCancelOrderTitle'));
    expect(cashier, contains('l10n.cashierServiceProvisionTitle'));
    expect(cashier, contains('l10n.cashierPaymentDue'));
    expect(cashier, contains('l10n.cashierPayNow'));
    expect(cashier, contains('l10n.logout'));
  });

  test('waiter screen routes guest, table transfer, and dining floor copy through localization', () {
    final waiter = readRepoFile('lib/features/waiter/waiter_screen.dart');

    expect(waiter, contains('context.l10n'));
    expect(waiter, contains('l10n.waiterGuestCountTitle'));
    expect(waiter, contains('l10n.waiterGuestCountField'));
    expect(waiter, contains('l10n.waiterCancelOrderTitle'));
    expect(waiter, contains('l10n.waiterMoveTableTitle'));
    expect(waiter, contains('l10n.waiterOrderCancelled'));
    expect(waiter, contains('l10n.waiterDiningFloor'));
    expect(waiter, contains('l10n.waiterTapTableToStart'));
  });

  test('order workspace routes menu, sent, payment, and ticket copy through localization', () {
    final workspace = readRepoFile('lib/widgets/order_workspace.dart');

    expect(workspace, contains('context.l10n'));
    expect(workspace, contains('l10n.orderWorkspaceMenus'));
    expect(workspace, contains('l10n.orderWorkspaceMenuOfflineTitle'));
    expect(workspace, contains('l10n.orderWorkspaceSentToKitchen'));
    expect(workspace, contains('l10n.orderWorkspaceNewItems'));
    expect(workspace, contains('l10n.orderWorkspaceSendToKitchen'));
    expect(workspace, contains('l10n.orderWorkspacePay'));
    expect(workspace, contains('l10n.orderWorkspacePaymentDue'));
    expect(workspace, contains('l10n.orderWorkspaceCurrentCheck'));
    expect(workspace, contains('l10n.orderWorkspaceKitchenTicketSent'));
  });
}
