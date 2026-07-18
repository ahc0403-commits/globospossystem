import 'package:flutter/material.dart';

/// Toast-style POS design tokens.
///
/// Additive foundation introduced alongside the existing `AppColors` /
/// `AppRadius` / `AppSpacing` constants in `app_theme.dart`. Do not modify or
/// shadow those legacy tokens; this file only adds the new `Toast*Tokens` /
/// `PosColors` / `PosMetrics` / `PosShadows` namespaces required by upcoming
/// Toast-style screens.
class ToastColorTokens {
  static const canvas = Color(0xFFF5F7FA);
  static const canvasAlt = Color(0xFFF8FAFC);
  static const surface = Color(0xFFFFFFFF);
  static const elevatedSurface = Color(0xFFFFFFFF);
  static const mutedSurface = Color(0xFFF8FAFC);
  static const sidebarSurface = Color(0xFFFFFFFF);
  static const topbarSurface = Color(0xFFFFFFFF);
  static const heroTint = Color(0xFFEEF5FF);
  static const selectedRow = Color(0xFFEEF5FF);
  static const disabledSurface = Color(0xFFEEF2F7);
  static const border = Color(0xFFE5E7EB);
  static const borderStrong = Color(0xFFCBD5E1);
  static const focusBorder = Color(0xFF2563EB);
  static const divider = border;
  static const textPrimary = Color(0xFF111827);
  static const textSecondary = Color(0xFF6B7280);
  static const textMuted = Color(0xFF94A3B8);
  static const accent = Color(0xFF2563EB);
  static const accentStrong = Color(0xFF1D4ED8);
  static const accentMuted = Color(0xFFDBEAFE);
  static const success = Color(0xFF059669);
  static const successMuted = Color(0xFFECFDF5);
  static const warning = Color(0xFFD97706);
  static const warningMuted = Color(0xFFFFF7ED);
  static const danger = Color(0xFFDC2626);
  static const dangerMuted = Color(0xFFFEF2F2);
  static const info = Color(0xFF0284C7);
  static const infoMuted = Color(0xFFE0F2FE);
}

class ToastStatusTokens {
  static const orderOpen = ToastColorTokens.info;
  static const orderPending = ToastColorTokens.warning;
  static const orderPreparing = ToastColorTokens.warning;
  static const orderReady = ToastColorTokens.success;
  static const orderServed = ToastColorTokens.textSecondary;
  static const orderCompleted = ToastColorTokens.success;
  static const orderCancelled = ToastColorTokens.danger;

  static const paymentUnpaid = ToastColorTokens.warning;
  static const paymentPartial = ToastColorTokens.info;
  static const paymentPaid = ToastColorTokens.success;
  static const paymentRefunded = ToastColorTokens.textSecondary;
  static const paymentFailed = ToastColorTokens.danger;

  static const inventoryInStock = ToastColorTokens.success;
  static const inventoryLow = ToastColorTokens.warning;
  static const inventoryOut = ToastColorTokens.danger;
  static const inventoryPending = ToastColorTokens.info;
}

class ToastSpacingTokens {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 28;
  static const double section = 32;
}

class ToastRadiusTokens {
  static const BorderRadius xs = BorderRadius.all(Radius.circular(8));
  static const BorderRadius sm = BorderRadius.all(Radius.circular(10));
  static const BorderRadius md = BorderRadius.all(Radius.circular(14));
  static const BorderRadius lg = BorderRadius.all(Radius.circular(16));
  static const BorderRadius xl = BorderRadius.all(Radius.circular(20));
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
}

class ToastElevationTokens {
  static const none = <BoxShadow>[];
  static const low = <BoxShadow>[
    BoxShadow(color: Color(0x0F0F172A), blurRadius: 24, offset: Offset(0, 10)),
  ];
  static const medium = <BoxShadow>[
    BoxShadow(color: Color(0x120F172A), blurRadius: 32, offset: Offset(0, 14)),
  ];
}

class ToastShellTokens {
  static const double sidebarWidth = 212;
  static const double sidebarCompactWidth = 68;
  static const double topbarHeight = 56;
  static const double navItemHeight = 48;
  static const double workSurfacePadding = ToastSpacingTokens.lg;
  static const double borderWidth = 1;
  static const double focusBorderWidth = 1.5;
}

/// Higher-level POS color aliases used by Toast-style widgets.
class PosColors {
  static const canvas = ToastColorTokens.canvas;
  static const background = canvas;
  static const canvasAlt = ToastColorTokens.canvasAlt;
  static const surface = ToastColorTokens.surface;
  static const sidebarSurface = ToastColorTokens.sidebarSurface;
  static const topbarSurface = ToastColorTokens.topbarSurface;
  static const heroTint = ToastColorTokens.heroTint;
  static const panel = ToastColorTokens.surface;
  static const panelMuted = ToastColorTokens.mutedSurface;
  static const panelStrong = surface;
  static const elevatedSurface = ToastColorTokens.elevatedSurface;
  static const mutedSurface = panelMuted;
  static const selectedRow = ToastColorTokens.selectedRow;
  static const disabledSurface = ToastColorTokens.disabledSurface;
  static const border = ToastColorTokens.border;
  static const borderStrong = ToastColorTokens.borderStrong;
  static const focusBorder = ToastColorTokens.focusBorder;
  static const divider = border;
  static const text = ToastColorTokens.textPrimary;
  static const textPrimary = text;
  static const primaryText = text;
  static const textSecondary = ToastColorTokens.textSecondary;
  static const secondaryText = textSecondary;
  static const textMuted = ToastColorTokens.textMuted;
  static const accent = ToastColorTokens.accent;
  static const accentStrong = ToastColorTokens.accentStrong;
  static const accentMuted = ToastColorTokens.accentMuted;
  static const success = ToastColorTokens.success;
  static const successMuted = ToastColorTokens.successMuted;
  static const warning = ToastColorTokens.warning;
  static const warningMuted = ToastColorTokens.warningMuted;
  static const danger = ToastColorTokens.danger;
  static const dangerMuted = ToastColorTokens.dangerMuted;
  static const info = ToastColorTokens.info;
  static const infoMuted = ToastColorTokens.infoMuted;

  static const orderOpen = ToastStatusTokens.orderOpen;
  static const orderPending = ToastStatusTokens.orderPending;
  static const orderPreparing = ToastStatusTokens.orderPreparing;
  static const orderReady = ToastStatusTokens.orderReady;
  static const orderServed = ToastStatusTokens.orderServed;
  static const orderCompleted = ToastStatusTokens.orderCompleted;
  static const orderCancelled = ToastStatusTokens.orderCancelled;

  static const paymentUnpaid = ToastStatusTokens.paymentUnpaid;
  static const paymentPartial = ToastStatusTokens.paymentPartial;
  static const paymentPaid = ToastStatusTokens.paymentPaid;
  static const paymentRefunded = ToastStatusTokens.paymentRefunded;
  static const paymentFailed = ToastStatusTokens.paymentFailed;

  static const inventoryInStock = ToastStatusTokens.inventoryInStock;
  static const inventoryLow = ToastStatusTokens.inventoryLow;
  static const inventoryOut = ToastStatusTokens.inventoryOut;
  static const inventoryPending = ToastStatusTokens.inventoryPending;
}

class PosTerminalColors {
  const PosTerminalColors._();

  static const darkShell = Color(0xFF111820);
  static const darkRail = Color(0xFF17202B);
  static const darkPanel = Color(0xFF202A37);
  static const darkPanelElevated = Color(0xFF263244);
  static const darkBorder = Color(0xFF3A4759);
  static const darkText = Color(0xFFF8F4EA);
  static const darkTextMuted = Color(0xFFAEB9C8);

  static const lightShell = Color(0xFFE9EDF1);
  static const lightPanel = Color(0xFFFBFAF5);
  static const lightPanelMuted = Color(0xFFF1F3F6);
  static const floorCanvas = Color(0xFFF4F1E8);
  static const floorGrid = Color(0xFFE0D9CA);
  static const ticketPaper = Color(0xFFF8F4EA);
  static const paymentPad = darkShell;
}

class PosDensity {
  const PosDensity._();

  static const double orderRailWidth = 308;
  static const double inspectorWidth = 320;
  static const double compactInspectorWidth = 280;
  static const double menuTileMinHeight = 76;
  static const double menuTileWideHeight = 88;
  static const double kdsTicketWidth = 284;
  static const double kdsTicketMinHeight = 204;
  static const double paymentMethodTileWidth = 104;
  static const double paymentMethodTileHeight = 60;
  static const double dataGridRowHeight = 56;
  static const double inventoryRowHeight = 62;
  static const double floorTableWidth = 120;
  static const double floorTableHeight = 64;
  static const double statusFilterHeight = 36;

  // V2 Phase 0 additions
  static const double touchTargetMin = 48;
  static const double actionTileMinHeight = 56;
  static const double actionTileMinWidth = 96;
  static const double amountAnchorMinHeight = 72;
  static const int destructiveConfirmTimeoutSec = 4;
}

class PosStatusPalette {
  const PosStatusPalette._();

  static const newOrder = Color(0xFFFFDFDF);
  static const preparing = Color(0xFFFFE3A8);
  static const handoffReady = Color(0xFFBFF1D4);
  static const unpaid = Color(0xFFFFEBC5);
  static const delayed = Color(0xFFFFE7E9);
  static const lowStock = Color(0xFFFFE3A8);
  static const blocked = Color(0xFFFFE7E9);
  static const available = Color(0xFFDFF7EE);
  static const selected = ToastColorTokens.accent;
}

class PosMoneyText {
  const PosMoneyText._();

  static const amountDue = TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.w900,
    letterSpacing: 0,
  );

  static const amountLarge = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w800,
    letterSpacing: 0,
  );

  static const amountLine = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w800,
    letterSpacing: 0,
  );

  static const amountCompact = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
  );
}

class PosShadows {
  static const low = ToastElevationTokens.low;
  static const raised = ToastElevationTokens.medium;
}

class PosMetrics {
  static const double tableRowHeight = 48;
  static const double tableRowCompactHeight = 48;
  static const double formFieldHeight = 48;
  static const double buttonHeight = 48;
  static const double buttonCompactHeight = 48;
  static const double touchTarget = PosDensity.touchTargetMin;
  static const double sidebarWidth = ToastShellTokens.sidebarWidth;
  static const double topBarHeight = ToastShellTokens.topbarHeight;
  static const double panelBorderWidth = ToastShellTokens.borderWidth;
  static const double focusBorderWidth = ToastShellTokens.focusBorderWidth;
}

// ---------------------------------------------------------------------------
// Phase 0 — Operational Premium V2 additive tokens
// ---------------------------------------------------------------------------

/// Named surface roles for the light shell.
///
/// Each role defines a background, border, foreground (text), and muted
/// (helper text) color. Widgets should use exactly one role; mixing roles
/// inside a single container is a review-rejection criterion.
class PosSurfaceRole {
  const PosSurfaceRole._({
    required this.fill,
    required this.stroke,
    required this.text,
    required this.helper,
  });

  final Color fill;
  final Color stroke;
  final Color text;
  final Color helper;

  /// Passive canvas behind everything — recedes.
  static const background = PosSurfaceRole._(
    fill: Color(0xFFEFF2F6),
    stroke: Color(0xFFDEE3EA),
    text: ToastColorTokens.textPrimary,
    helper: ToastColorTokens.textMuted,
  );

  /// Where live work renders (queue, board, map) — near-white, minimal shadow.
  static const operating = PosSurfaceRole._(
    fill: Color(0xFFFBFBFD),
    stroke: ToastColorTokens.border,
    text: ToastColorTokens.textPrimary,
    helper: ToastColorTokens.textSecondary,
  );

  /// Pressable inputs: tiles, pads, buttons — crisp border, visible affordance.
  static const action = PosSurfaceRole._(
    fill: Color(0xFFFFFFFF),
    stroke: Color(0xFFCBD5E1),
    text: ToastColorTokens.textPrimary,
    helper: ToastColorTokens.textSecondary,
  );

  /// Committed selection — accent-filled, unmistakably different from hover.
  static const selected = PosSurfaceRole._(
    fill: Color(0xFFDBEAFE),
    stroke: ToastColorTokens.accent,
    text: Color(0xFF1E40AF),
    helper: Color(0xFF3B6FCF),
  );

  /// Destructive/warning zones — danger family, never decorative.
  static const danger = PosSurfaceRole._(
    fill: Color(0xFFFEF2F2),
    stroke: Color(0xFFFCA5A5),
    text: Color(0xFF991B1B),
    helper: Color(0xFFDC2626),
  );

  /// Unavailable actions — reduced contrast but legible labels.
  static const disabled = PosSurfaceRole._(
    fill: Color(0xFFF1F5F9),
    stroke: Color(0xFFE2E8F0),
    text: Color(0xFF94A3B8),
    helper: Color(0xFFCBD5E1),
  );

  /// Locked mid-transaction — distinct "armed/busy" tone.
  static const processing = PosSurfaceRole._(
    fill: Color(0xFFF0F4FF),
    stroke: Color(0xFF93B4F5),
    text: Color(0xFF1D4ED8),
    helper: Color(0xFF60A5FA),
  );
}

/// Tabular-numeric text styles for POS surfaces.
///
/// All styles include [FontFeature.tabularFigures] so columns and live timers
/// do not jitter. Extends the existing [PosMoneyText] with identifier, elapsed,
/// and inventory-specific scales.
class PosNumericText {
  const PosNumericText._();

  static const _tabular = <FontFeature>[FontFeature.tabularFigures()];

  /// Dominant cashier due block — largest text on screen.
  static const amountHero = TextStyle(
    fontSize: 40,
    fontWeight: FontWeight.w900,
    letterSpacing: 0,
    fontFeatures: _tabular,
  );

  /// Existing amountDue scale with tabular figures.
  static const amountDue = TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.w900,
    letterSpacing: 0,
    fontFeatures: _tabular,
  );

  /// Section / supplier totals.
  static const amountLarge = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w800,
    letterSpacing: 0,
    fontFeatures: _tabular,
  );

  /// Row-level line item amount.
  static const amountLine = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w800,
    letterSpacing: 0,
    fontFeatures: _tabular,
  );

  /// Compact badge / chip amount.
  static const amountCompact = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
    fontFeatures: _tabular,
  );

  /// Table identifier — large, never truncated, scanned from distance.
  static const tableId = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w800,
    letterSpacing: 0,
    fontFeatures: _tabular,
  );

  /// Order identifier.
  static const orderId = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w800,
    letterSpacing: 0,
    fontFeatures: _tabular,
  );

  /// Kitchen ticket elapsed time — primary scale.
  static const elapsedPrimary = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
    fontFeatures: _tabular,
  );

  /// Overdue elapsed time — escalated weight/size, not only color.
  static const elapsedOverdue = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w900,
    letterSpacing: 0,
    fontFeatures: _tabular,
  );

  /// Quantity + unit unbreakable block (e.g. "12 pack").
  static const qtyUnit = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
    fontFeatures: _tabular,
  );

  /// Unit price in inventory rows.
  static const unitPrice = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    fontFeatures: _tabular,
  );

  /// Line-level estimated amount — never truncated.
  static const lineAmount = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w800,
    letterSpacing: 0,
    fontFeatures: _tabular,
  );
}

/// Touch-state tokens for POS operator surfaces.
///
/// Defines visual deltas and timing for each interaction state. Widgets
/// consume these as styling parameters, not as animation drivers.
class PosTouchStateTokens {
  const PosTouchStateTokens._();

  /// Immediate surface darkening on press.
  static const pressedOverlayOpacity = 0.08;
  static const pressedDuration = Duration(milliseconds: 40);

  /// Persistent selection highlight.
  static const selectedBorderWidth = 2.0;
  static const selectedOverlayOpacity = 0.0;

  /// Disabled — reduced but legible.
  static const disabledOpacity = 0.55;

  /// Locked during async operation — spinner + label swap.
  static const processingOverlayOpacity = 0.06;
  static const processingMinDuration = Duration(milliseconds: 300);

  /// Two-step destructive confirm — auto-disarm timeout.
  static const destructiveConfirmTimeout = Duration(seconds: 4);
  static const destructiveArmedBorderWidth = 2.5;

  /// Offline-blocked — distinct from disabled, shows cause.
  static const offlineBlockedOpacity = 0.45;
}

class PosSurfaceTints {
  const PosSurfaceTints._();

  static Color tone(
    Color color, {
    double alpha = 0.08,
    Color base = ToastColorTokens.surface,
  }) {
    return Color.alphaBlend(color.withValues(alpha: alpha), base);
  }

  static LinearGradient liftedGradient(Color baseColor) {
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color.alphaBlend(Colors.white.withValues(alpha: 0.38), baseColor),
        baseColor,
        Color.alphaBlend(
          ToastColorTokens.canvas.withValues(alpha: 0.05),
          baseColor,
        ),
      ],
      stops: const [0, 0.58, 1],
    );
  }
}
