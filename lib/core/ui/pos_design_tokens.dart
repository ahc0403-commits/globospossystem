import 'package:flutter/material.dart';

/// Toast-style POS design tokens.
///
/// Additive foundation introduced alongside the existing `AppColors` /
/// `AppRadius` / `AppSpacing` constants in `app_theme.dart`. Do not modify or
/// shadow those legacy tokens; this file only adds the new `Toast*Tokens` /
/// `PosColors` / `PosMetrics` / `PosShadows` namespaces required by upcoming
/// Toast-style screens.
class ToastColorTokens {
  static const canvas = Color(0xFFF7F8FA);
  static const canvasAlt = Color(0xFFEFF2F5);
  static const surface = Color(0xFFFFFFFF);
  static const elevatedSurface = Color(0xFFFFFFFF);
  static const mutedSurface = Color(0xFFF1F3F5);
  static const selectedRow = Color(0xFFFFF1EA);
  static const disabledSurface = Color(0xFFE7EAEE);
  static const border = Color(0xFFD9DEE5);
  static const borderStrong = Color(0xFFB6BEC9);
  static const focusBorder = Color(0xFFE25D2A);
  static const divider = border;
  static const textPrimary = Color(0xFF1D232B);
  static const textSecondary = Color(0xFF4E5866);
  static const textMuted = Color(0xFF7B8491);
  static const accent = Color(0xFFE45F2B);
  static const accentStrong = Color(0xFFC54D20);
  static const accentMuted = Color(0xFFFFEDE6);
  static const success = Color(0xFF127A55);
  static const successMuted = Color(0xFFE7F5EF);
  static const warning = Color(0xFFB4610F);
  static const warningMuted = Color(0xFFFFF1D6);
  static const danger = Color(0xFFB4322B);
  static const dangerMuted = Color(0xFFFCE8E6);
  static const info = Color(0xFF236BC3);
  static const infoMuted = Color(0xFFE9F1FF);
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
  static const BorderRadius xs = BorderRadius.all(Radius.circular(3));
  static const BorderRadius sm = BorderRadius.all(Radius.circular(4));
  static const BorderRadius md = BorderRadius.all(Radius.circular(6));
  static const BorderRadius lg = BorderRadius.all(Radius.circular(8));
  static const BorderRadius xl = BorderRadius.all(Radius.circular(10));
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
}

class ToastElevationTokens {
  static const none = <BoxShadow>[];
  static const low = <BoxShadow>[
    BoxShadow(color: Color(0x05000000), blurRadius: 6, offset: Offset(0, 1)),
  ];
  static const medium = <BoxShadow>[
    BoxShadow(color: Color(0x08000000), blurRadius: 10, offset: Offset(0, 3)),
  ];
}

class ToastShellTokens {
  static const double sidebarWidth = 232;
  static const double sidebarCompactWidth = 68;
  static const double topbarHeight = 56;
  static const double navItemHeight = 36;
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
  static const textSecondary = ToastColorTokens.textSecondary;
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

class PosShadows {
  static const low = ToastElevationTokens.none;
  static const raised = ToastElevationTokens.low;
}

class PosMetrics {
  static const double tableRowHeight = 48;
  static const double tableRowCompactHeight = 40;
  static const double formFieldHeight = 44;
  static const double buttonHeight = 44;
  static const double buttonCompactHeight = 36;
  static const double touchTarget = 44;
  static const double sidebarWidth = ToastShellTokens.sidebarWidth;
  static const double topBarHeight = ToastShellTokens.topbarHeight;
  static const double panelBorderWidth = ToastShellTokens.borderWidth;
  static const double focusBorderWidth = ToastShellTokens.focusBorderWidth;
}
