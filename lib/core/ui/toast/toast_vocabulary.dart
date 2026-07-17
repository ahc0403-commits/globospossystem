// Toast operational vocabulary + tone/icon mapping systems.
//
// Phase 1 scaffold. The handoff doc specifies that "action vocabulary",
// "action tone", "action icon", "disabled-state vocabulary",
// "empty-state operational vocabulary", and "loading-state operational
// vocabulary" were normalized — but it does NOT enumerate the concrete
// verb/tone/icon entries. Per project rule (CLAUDE.md §1: "Don't assume.
// Don't hide confusion."), this file establishes the type-system
// scaffolding with TODO placeholders rather than inventing values.
//
// Future passes should populate these maps from the live screens
// (`order_workspace.dart`, `kitchen_screen.dart`, `cashier_screen.dart`,
// admin tabs) once those are migrated.

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../pos_design_tokens.dart';

/// Tone slot for an operational action button.
///
/// - [primary]    : the single recommended next action (accent, filled)
/// - [affirm]     : positive operational confirmation (green, filled).
///                  Used for deposit / receipt / resolution confirms where
///                  semantic color is "money received / issue cleared".
///                  Sits below [primary] in the hierarchy: the pick is
///                  primary > affirm > recovery > secondary > destructive.
/// - [recovery]   : exception/issue resolution (info-blue, filled)
/// - [secondary]  : non-blocking supporting action (outlined, neutral)
/// - [destructive]: cancel / void / refund (red, filled)
enum PosActionTone { primary, affirm, recovery, secondary, destructive }

/// Reason an operational action is currently disabled. Used to drive
/// disabled-state hover/help language.
enum PosActionDisabledReason {
  noSelection,
  notReady,
  permissionDenied,
  upstreamPending,
  offline,
  cartEmpty,
  cartHasUnsentItems,
  paymentMethodNotSelected,
}

/// Resolves the colour for a [PosActionTone].
Color toneBackground(PosActionTone tone) {
  switch (tone) {
    case PosActionTone.primary:
      return AppColors.amber500;
    case PosActionTone.affirm:
      return AppColors.statusAvailable;
    case PosActionTone.recovery:
      return AppColors.statusInfo;
    case PosActionTone.secondary:
      return AppColors.surface2;
    case PosActionTone.destructive:
      return AppColors.statusCancelled;
  }
}

Color toneForeground(PosActionTone tone) {
  switch (tone) {
    case PosActionTone.primary:
      return AppColors.surface0;
    case PosActionTone.affirm:
      return Colors.white;
    case PosActionTone.recovery:
      return AppColors.surface0;
    case PosActionTone.secondary:
      return AppColors.textPrimary;
    case PosActionTone.destructive:
      return Colors.white;
  }
}

Widget iconWithLabel({
  required IconData icon,
  required String label,
  Color? color,
}) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, color: color ?? PosColors.accent),
      const SizedBox(height: 4),
      Text(
        label,
        style: const TextStyle(fontSize: 12, color: PosColors.primaryText),
        textAlign: TextAlign.center,
      ),
    ],
  );
}

/// Internal action verb identifiers. User-facing labels must come from l10n at
/// the call site so fixed system words do not mix languages.
class PosActionVerbs {
  static const String sendOrder = 'send_order';
  static const String cancel = 'cancel';
  static const String cancelOrder = 'cancel_order';
  static const String moveTable = 'move_table';
  static const String paymentComplete = 'payment_complete';
  static const String addTable = 'add_table';
  static const String deleteTable = 'delete_table';
  static const String startPrep = 'start_prep';
  static const String markReady = 'mark_ready';
  static const String markServed = 'mark_served';
  static const String advanceStatus = 'advance_status';
  static const String processPayment = 'process_payment';
  static const String serviceProcessed = 'service_processed';
  static const String reprintReceipt = 'reprint_receipt';
  static const String todaysSettlement = 'todays_settlement';
}

/// Action icon mapping. Mirrors the verbs above; icons match what the
/// existing screens already use so the visual language stays stable.
class PosActionIcons {
  static const IconData sendOrder = Icons.send_rounded;
  static const IconData cancel = Icons.close_rounded;
  static const IconData cancelOrder = Icons.cancel;
  static const IconData moveTable = Icons.swap_horiz;
  static const IconData paymentComplete = Icons.check_circle_outline;
  static const IconData addTable = Icons.add;
  static const IconData deleteTable = Icons.delete_outline;
  static const IconData startPrep = Icons.restaurant_menu;
  static const IconData markReady = Icons.done;
  static const IconData markServed = Icons.check_circle;
  static const IconData advanceStatus = Icons.chevron_right;
  static const IconData processPayment = Icons.point_of_sale;
  static const IconData reprintReceipt = Icons.print;
  static const IconData todaysSettlement = Icons.summarize;
}

/// Disabled-state hover/help language slots.
class PosDisabledCopy {
  static String forReason(
    AppLocalizations l10n,
    PosActionDisabledReason reason,
  ) {
    switch (reason) {
      case PosActionDisabledReason.noSelection:
        return l10n.posDisabledNoSelection;
      case PosActionDisabledReason.notReady:
        return l10n.posDisabledNotReady;
      case PosActionDisabledReason.permissionDenied:
        return l10n.posDisabledPermissionDenied;
      case PosActionDisabledReason.upstreamPending:
        return l10n.posDisabledUpstreamPending;
      case PosActionDisabledReason.offline:
        return l10n.posDisabledOffline;
      case PosActionDisabledReason.cartEmpty:
        return l10n.posDisabledCartEmpty;
      case PosActionDisabledReason.cartHasUnsentItems:
        return l10n.posDisabledCartHasUnsentItems;
      case PosActionDisabledReason.paymentMethodNotSelected:
        return l10n.posDisabledPaymentMethodNotSelected;
    }
  }
}

/// Operational empty-state disclosure language. Sourced from the pilot
/// surfaces — extend per surface as screens migrate.
class PosEmptyStateCopy {
  static String queueClear(AppLocalizations l10n) => l10n.posEmptyQueueClear;
  static String noOpenIssues(AppLocalizations l10n) =>
      l10n.posEmptyNoOpenIssues;
  static String nothingSelected(AppLocalizations l10n) =>
      l10n.posEmptyNothingSelected;
  static String cartEmpty(AppLocalizations l10n) =>
      l10n.orderWorkspaceNoItemsAdded;
  static String menuCategoryEmpty(AppLocalizations l10n) =>
      l10n.orderWorkspaceNoItemsTitle;
  static String menuNoCategories(AppLocalizations l10n) =>
      l10n.menuNoCategories;
  static String tablesEmpty(AppLocalizations l10n) => l10n.tablesNoTablesTitle;
  static String kitchenQueueClear(AppLocalizations l10n) =>
      l10n.kitchenNoActiveOrdersTitle;
  static String kitchenQueueClearHelper(AppLocalizations l10n) =>
      l10n.kitchenNoActiveOrdersMessage;
  static String kitchenNothingSelected(AppLocalizations l10n) =>
      l10n.posEmptyKitchenNothingSelected;
  static String kitchenNothingSelectedHelper(AppLocalizations l10n) =>
      l10n.posEmptyKitchenNothingSelectedHelper;
  static String cashierQueueClear(AppLocalizations l10n) =>
      l10n.cashierNoPayableOrdersTitle;
  static String cashierQueueClearHelper(AppLocalizations l10n) =>
      l10n.cashierNoPayableOrdersMessage;
  static String cashierNothingSelected(AppLocalizations l10n) =>
      l10n.cashierSelectTableTitle;
  static String cashierNothingSelectedHelper(AppLocalizations l10n) =>
      l10n.cashierSelectTableMessage;
  static String settlementsEmpty(AppLocalizations l10n) =>
      l10n.posEmptySettlements;
  static String settlementsFilterEmpty(AppLocalizations l10n) =>
      l10n.posEmptySettlementsInStatus;
  static String einvoiceJobsEmpty(AppLocalizations l10n) =>
      l10n.posEmptyEinvoiceJobs;
}

/// Operational loading-state disclosure language. Sourced from the pilot
/// surfaces — extend per surface as screens migrate.
class PosLoadingCopy {
  static String loadingQueue(AppLocalizations l10n) => l10n.posLoadingQueue;
  static String loadingDetail(AppLocalizations l10n) => l10n.posLoadingDetail;
  static String syncing(AppLocalizations l10n) => l10n.posLoadingSyncing;
  static String loadingMenu(AppLocalizations l10n) => l10n.posLoadingMenu;
  static String loadingKitchen(AppLocalizations l10n) => l10n.posLoadingKitchen;
  static String loadingTables(AppLocalizations l10n) => l10n.posLoadingTables;
  static String loadingReport(AppLocalizations l10n) => l10n.posLoadingReport;
  static String loadingSettlements(AppLocalizations l10n) =>
      l10n.posLoadingSettlements;
  static String loadingEinvoiceJobs(AppLocalizations l10n) =>
      l10n.posLoadingEinvoiceJobs;
}
