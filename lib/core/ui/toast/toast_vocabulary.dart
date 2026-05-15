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

/// Action verb vocabulary slots. Sourced from the two pilot surfaces
/// (Sidebar, Order Workspace). New entries should only be added when a
/// real surface needs them — do not invent operational concepts.
class PosActionVerbs {
  // Order Workspace — match the existing screen's user-facing labels so
  // semantics are preserved (`SEND ORDER`, `CANCEL`, `Cancel Order`,
  // `Move`, `Payment complete`).
  static const String sendOrder = 'SEND ORDER';
  static const String cancel = 'CANCEL';
  static const String cancelOrder = 'Cancel Order';
  static const String moveTable = 'Move';
  static const String paymentComplete = 'Payment complete';

  // Tables (admin tab) — preserves existing labels.
  static const String addTable = 'Add Table';
  static const String deleteTable = 'Delete';

  // Kitchen — verbs derived from the existing status-cycle behaviour
  // (pending → preparing → ready → served).
  static const String startPrep = 'Start Prep';
  static const String markReady = 'Mark Ready';
  static const String markServed = 'Mark Served';
  static const String advanceStatus = 'Advance';

  // Cashier — preserves the existing user-facing labels.
  static const String processPayment = 'PROCESS PAYMENT';
  static const String serviceProcessed = 'Service processed';
  static const String reprintReceipt = 'Reprint Receipt';
  static const String todaysSettlement = "Today's Settlement";
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
  static String forReason(PosActionDisabledReason reason) {
    switch (reason) {
      case PosActionDisabledReason.noSelection:
        return 'Select a row to continue';
      case PosActionDisabledReason.notReady:
        return 'Not ready yet';
      case PosActionDisabledReason.permissionDenied:
        return 'Not permitted for this role';
      case PosActionDisabledReason.upstreamPending:
        return 'Waiting on upstream step';
      case PosActionDisabledReason.offline:
        return 'Internet connection required';
      case PosActionDisabledReason.cartEmpty:
        return 'Add items before sending';
      case PosActionDisabledReason.cartHasUnsentItems:
        return 'Send newly added items before payment';
      case PosActionDisabledReason.paymentMethodNotSelected:
        return 'Select a payment method';
    }
  }
}

/// Operational empty-state disclosure language. Sourced from the pilot
/// surfaces — extend per surface as screens migrate.
class PosEmptyStateCopy {
  static const String queueClear = 'Queue clear';
  static const String noOpenIssues = 'No open issues';
  static const String nothingSelected = 'Nothing selected';
  // Order Workspace — preserves the original semantics of the inline
  // strings being replaced ('No items added yet.', 'No menu items in
  // this category', 'No categories').
  static const String cartEmpty = 'No items added yet';
  static const String menuCategoryEmpty = 'No items in this category';
  static const String menuNoCategories = 'No categories';

  // Tables (admin tab) — preserves the original phrasing.
  static const String tablesEmpty = 'No tables. Add your first table.';

  // Kitchen — preserves AppEmptyState copy used today.
  static const String kitchenQueueClear = 'No active orders';
  static const String kitchenQueueClearHelper =
      'Incoming tickets will appear here as soon as the dining floor sends them.';
  static const String kitchenNothingSelected = 'Select a ticket';
  static const String kitchenNothingSelectedHelper =
      'Choose a ticket from the queue to advance prep status.';

  // Cashier — preserves AppEmptyState copy used today.
  static const String cashierQueueClear = 'No payable orders';
  static const String cashierQueueClearHelper =
      'Completed table orders will appear here when they are ready for payment.';
  static const String cashierNothingSelected = 'Select a table';
  static const String cashierNothingSelectedHelper =
      'Choose a payable order from the left to open the payment workspace.';

  // Delivery settlement — preserves prior phrasing.
  static const String settlementsEmpty = 'No settlements';
  static const String settlementsFilterEmpty = 'No settlements in this status';

  // E-invoice jobs (admin tab) — preserves prior phrasing.
  static const String einvoiceJobsEmpty = 'No jobs';
}

/// Operational loading-state disclosure language. Sourced from the pilot
/// surfaces — extend per surface as screens migrate.
class PosLoadingCopy {
  static const String loadingQueue = 'Loading queue';
  static const String loadingDetail = 'Loading detail';
  static const String syncing = 'Syncing';
  // Order Workspace — replaces 'Loading menu'.
  static const String loadingMenu = 'Loading menu';
  // Kitchen — preserves the existing AppLoadingView label.
  static const String loadingKitchen = 'Loading kitchen orders';
  // Tables — preserves prior loading semantics.
  static const String loadingTables = 'Loading tables';
  // Reports (admin tab).
  static const String loadingReport = 'Loading report';
  // Delivery settlement.
  static const String loadingSettlements = 'Loading settlements';
  // E-invoice jobs (admin tab).
  static const String loadingEinvoiceJobs = 'Loading e-invoice jobs';
}
