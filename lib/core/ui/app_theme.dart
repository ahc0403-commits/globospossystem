import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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
    final baseTextTheme = GoogleFonts.notoSansKrTextTheme();

    return ThemeData(
      brightness: Brightness.light,
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.surface0,
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
          fontWeight: FontWeight.w900,
          letterSpacing: -0.4,
        ),
        displayMedium: baseTextTheme.displayMedium?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.3,
        ),
        headlineMedium: baseTextTheme.headlineMedium?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w800,
        ),
        titleLarge: baseTextTheme.titleLarge?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w800,
        ),
        titleMedium: baseTextTheme.titleMedium?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        bodyLarge: baseTextTheme.bodyLarge?.copyWith(
          color: AppColors.textPrimary,
          height: 1.35,
        ),
        bodyMedium: baseTextTheme.bodyMedium?.copyWith(
          color: AppColors.textPrimary,
          height: 1.35,
        ),
        bodySmall: baseTextTheme.bodySmall?.copyWith(
          color: AppColors.textSecondary,
          height: 1.3,
        ),
        labelLarge: baseTextTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
      dividerColor: AppColors.surface3,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.surface1,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.notoSansKr(
          color: AppColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface1,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.md,
          side: const BorderSide(color: AppColors.surface3),
        ),
        margin: EdgeInsets.zero,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surface1,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.md),
        titleTextStyle: baseTextTheme.titleLarge?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: baseTextTheme.bodyMedium?.copyWith(
          color: AppColors.textSecondary,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface2,
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        hintStyle: const TextStyle(color: AppColors.textMuted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: AppRadius.md,
          borderSide: const BorderSide(color: AppColors.surface3),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.md,
          borderSide: const BorderSide(color: AppColors.surface3),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.md,
          borderSide: const BorderSide(color: AppColors.amber500, width: 1.8),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: AppRadius.md,
          borderSide: const BorderSide(color: AppColors.statusCancelled),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: AppRadius.md,
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          textStyle: baseTextTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.md),
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
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      textStyle: GoogleFonts.notoSansKr(
        fontSize: 14,
        fontWeight: FontWeight.w800,
      ),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.md),
    );
  }
}

class AppTextStyles {
  static TextStyle operationalTitle({
    Color color = AppColors.textPrimary,
    double size = 28,
    double letterSpacing = -0.2,
  }) {
    return GoogleFonts.notoSansKr(
      color: color,
      fontSize: size,
      letterSpacing: letterSpacing,
      fontWeight: FontWeight.w900,
    );
  }

  static TextStyle operationalCaption({
    Color color = AppColors.textSecondary,
    FontWeight fontWeight = FontWeight.w600,
  }) {
    return GoogleFonts.notoSansKr(
      color: color,
      fontSize: 12,
      fontWeight: fontWeight,
    );
  }
}
