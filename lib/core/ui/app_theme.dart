import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  static const surface0 = Color(0xFF111210);
  static const surface1 = Color(0xFF1C1D1A);
  static const surface2 = Color(0xFF252621);
  static const surface3 = Color(0xFF31322D);
  static const textPrimary = Color(0xFFF0EDE6);
  static const textSecondary = Color(0xFF9E9B92);
  static const textMuted = Color(0xFF7A776F);
  static const amber500 = Color(0xFFF5A623);
  static const amber600 = Color(0xFFE08E0B);
  static const statusAvailable = Color(0xFF4CAF7D);
  static const statusOccupied = Color(0xFFE8935A);
  static const statusReady = Color(0xFFF5A623);
  static const statusCancelled = Color(0xFFC0392B);
  static const statusInfo = Color(0xFF6EA8FE);
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
  static const BorderRadius sm = BorderRadius.all(Radius.circular(10));
  static const BorderRadius md = BorderRadius.all(Radius.circular(14));
  static const BorderRadius lg = BorderRadius.all(Radius.circular(18));
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
}

class AppTheme {
  static ThemeData build() {
    final baseTextTheme = GoogleFonts.notoSansKrTextTheme();
    final displayFont = GoogleFonts.bebasNeueTextTheme(baseTextTheme);

    return ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.surface0,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.amber500,
        secondary: AppColors.statusInfo,
        surface: AppColors.surface1,
        error: AppColors.statusCancelled,
        onPrimary: AppColors.surface0,
        onSecondary: AppColors.surface0,
        onSurface: AppColors.textPrimary,
        onError: Colors.white,
      ),
      textTheme: baseTextTheme.copyWith(
        displayLarge: displayFont.displayLarge?.copyWith(
          color: AppColors.amber500,
          letterSpacing: 2,
        ),
        displayMedium: displayFont.displayMedium?.copyWith(
          color: AppColors.amber500,
          letterSpacing: 1.6,
        ),
        headlineMedium: baseTextTheme.headlineMedium?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        titleLarge: baseTextTheme.titleLarge?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        titleMedium: baseTextTheme.titleMedium?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
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
        backgroundColor: AppColors.surface0,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.bebasNeue(
          color: AppColors.amber500,
          fontSize: 32,
          letterSpacing: 1.4,
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
        fillColor: AppColors.surface1,
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        hintStyle: const TextStyle(color: AppColors.textMuted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
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
        foregroundColor: AppColors.surface0,
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
      foregroundColor: AppColors.surface0,
      disabledBackgroundColor: AppColors.amber500.withValues(alpha: 0.4),
      disabledForegroundColor: AppColors.surface0.withValues(alpha: 0.7),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
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
    Color color = AppColors.amber500,
    double size = 34,
    double letterSpacing = 1.4,
  }) {
    return GoogleFonts.bebasNeue(
      color: color,
      fontSize: size,
      letterSpacing: letterSpacing,
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
