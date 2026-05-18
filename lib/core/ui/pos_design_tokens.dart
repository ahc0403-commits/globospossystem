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
  static const double navItemHeight = 46;
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

class PosShadows {
  static const low = ToastElevationTokens.low;
  static const raised = ToastElevationTokens.medium;
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
