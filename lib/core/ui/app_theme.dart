import 'package:flutter/material.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';

import 'pos_design_tokens.dart';

/// Compatibility aliases retained for current tracked runtime paths.
///
/// They now resolve onto the active light-first operational token set rather
/// than defining a separate legacy visual baseline.
/// See `docs/office/TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md`.
class AppColors {
  static const surface0 = ToastColorTokens.canvas;
  static const surface1 = ToastColorTokens.surface;
  static const surface2 = ToastColorTokens.mutedSurface;
  static const surface3 = ToastColorTokens.border;
  static const surfaceTopbar = ToastColorTokens.topbarSurface;
  static const surfaceHero = ToastColorTokens.heroTint;
  static const textPrimary = ToastColorTokens.textPrimary;
  static const textSecondary = ToastColorTokens.textSecondary;
  static const textMuted = ToastColorTokens.textMuted;
  static const amber500 = ToastColorTokens.accent;
  static const amber600 = ToastColorTokens.accentStrong;
  static const statusAvailable = ToastColorTokens.success;
  static const statusOccupied = ToastColorTokens.warning;
  static const statusReady = ToastColorTokens.warning;
  static const statusCancelled = ToastColorTokens.danger;
  static const statusInfo = ToastColorTokens.info;
}

class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

class AppRadius {
  static const BorderRadius sm = ToastRadiusTokens.sm;
  static const BorderRadius md = ToastRadiusTokens.md;
  static const BorderRadius lg = ToastRadiusTokens.lg;
  static const BorderRadius pill = ToastRadiusTokens.pill;
}

class AppTheme {
  static ThemeData build() {
    final baseTextTheme = AppFonts.textTheme();

    return ThemeData(
      brightness: Brightness.light,
      useMaterial3: true,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      scaffoldBackgroundColor: AppColors.surface0,
      cardColor: AppColors.surface1,
      colorScheme: const ColorScheme.light(
        primary: AppColors.amber500,
        secondary: AppColors.statusInfo,
        surface: AppColors.surface1,
        error: AppColors.statusCancelled,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: AppColors.textPrimary,
        onError: Colors.white,
      ),
      textTheme: baseTextTheme.copyWith(
        displayLarge: baseTextTheme.displayLarge?.copyWith(
          color: AppColors.textPrimary,
          fontSize: 32,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
        displayMedium: baseTextTheme.displayMedium?.copyWith(
          color: AppColors.textPrimary,
          fontSize: 28,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
        headlineLarge: baseTextTheme.headlineLarge?.copyWith(
          color: AppColors.textPrimary,
          fontSize: 24,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
        headlineMedium: baseTextTheme.headlineMedium?.copyWith(
          color: AppColors.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
        titleLarge: baseTextTheme.titleLarge?.copyWith(
          color: AppColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
        titleMedium: baseTextTheme.titleMedium?.copyWith(
          color: AppColors.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
        bodyLarge: baseTextTheme.bodyLarge?.copyWith(
          color: AppColors.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w500,
          height: 1.45,
        ),
        bodyMedium: baseTextTheme.bodyMedium?.copyWith(
          color: AppColors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w500,
          height: 1.45,
        ),
        bodySmall: baseTextTheme.bodySmall?.copyWith(
          color: AppColors.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w400,
          height: 1.4,
        ),
        labelLarge: baseTextTheme.labelLarge?.copyWith(
          color: AppColors.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
        labelMedium: baseTextTheme.labelMedium?.copyWith(
          color: AppColors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
      iconTheme: const IconThemeData(color: AppColors.textSecondary),
      dividerColor: AppColors.surface3,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.surfaceTopbar,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: AppFonts.system(
          color: AppColors.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface1,
        elevation: 0,
        shadowColor: const Color(0x140F172A),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.lg,
          side: const BorderSide(color: AppColors.surface3),
        ),
        margin: EdgeInsets.zero,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surface1,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.lg),
        titleTextStyle: baseTextTheme.titleLarge?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: baseTextTheme.bodyMedium?.copyWith(
          color: AppColors.textSecondary,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface1,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface1,
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        hintStyle: const TextStyle(color: AppColors.textMuted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 13,
        ),
        border: OutlineInputBorder(
          borderRadius: AppRadius.lg,
          borderSide: const BorderSide(color: AppColors.surface3),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.lg,
          borderSide: const BorderSide(color: AppColors.surface3),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.lg,
          borderSide: const BorderSide(color: AppColors.amber500, width: 1.8),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: AppRadius.lg,
          borderSide: const BorderSide(color: AppColors.statusCancelled),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: AppRadius.lg,
          borderSide: const BorderSide(
            color: AppColors.statusCancelled,
            width: 1.8,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(style: _filledButtonStyle()),
      filledButtonTheme: FilledButtonThemeData(style: _filledButtonStyle()),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          side: const BorderSide(color: AppColors.surface3),
          backgroundColor: Colors.white,
          minimumSize: const Size(0, PosDensity.touchTargetMin),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          textStyle: baseTextTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.lg),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, PosDensity.touchTargetMin),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size.square(PosDensity.touchTargetMin),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.surface1,
        disabledColor: AppColors.surface2,
        selectedColor: AppColors.amber500,
        secondarySelectedColor: AppColors.amber500,
        side: const BorderSide(color: AppColors.surface3),
        labelStyle: baseTextTheme.bodySmall?.copyWith(
          color: AppColors.textPrimary,
        ),
        secondaryLabelStyle: baseTextTheme.bodySmall?.copyWith(
          color: AppColors.surface0,
        ),
        shape: const StadiumBorder(),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.amber500,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.surface1,
        selectedItemColor: AppColors.amber500,
        unselectedItemColor: AppColors.textSecondary,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.amber500,
      ),
    );
  }

  static ButtonStyle _filledButtonStyle() {
    return FilledButton.styleFrom(
      backgroundColor: AppColors.amber500,
      foregroundColor: Colors.white,
      disabledBackgroundColor: AppColors.amber500.withValues(alpha: 0.4),
      disabledForegroundColor: Colors.white.withValues(alpha: 0.75),
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      minimumSize: const Size(0, PosDensity.touchTargetMin),
      textStyle: AppFonts.system(fontSize: 14, fontWeight: FontWeight.w700),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.lg),
    );
  }
}

class AppTextStyles {
  static TextStyle operationalTitle({
    Color color = AppColors.textPrimary,
    double size = 28,
    double letterSpacing = -0.2,
  }) {
    return AppFonts.system(
      color: color,
      fontSize: size,
      letterSpacing: letterSpacing,
      fontWeight: FontWeight.w700,
    );
  }

  static TextStyle operationalCaption({
    Color color = AppColors.textSecondary,
    FontWeight fontWeight = FontWeight.w600,
  }) {
    return AppFonts.system(color: color, fontSize: 12, fontWeight: fontWeight);
  }
}
