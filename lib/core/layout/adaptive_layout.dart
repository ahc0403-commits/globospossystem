import 'package:flutter/material.dart';
import 'platform_info.dart';

export 'platform_info.dart';

/// Canonical viewport classes for every POS surface.
///
/// Use the available content width from [LayoutBuilder], not the physical
/// device type. A browser window can be phone-sized and a tablet can have a
/// wide external display, so platform checks are not a responsive contract.
enum PosWindowClass { compact, medium, wide, large }

abstract final class PosBreakpoints {
  static const double compact = 600;
  static const double wide = 1024;
  static const double large = 1440;
  static const double largeTextScale = 1.3;
}

@immutable
class PosLayoutSpec {
  const PosLayoutSpec({
    required this.windowClass,
    required this.availableWidth,
    required this.textScale,
    this.availableHeight = double.infinity,
  });

  factory PosLayoutSpec.fromWidth({
    required double width,
    double textScale = 1,
    double height = double.infinity,
  }) {
    final windowClass = switch (width) {
      < PosBreakpoints.compact => PosWindowClass.compact,
      < PosBreakpoints.wide => PosWindowClass.medium,
      < PosBreakpoints.large => PosWindowClass.wide,
      _ => PosWindowClass.large,
    };
    return PosLayoutSpec(
      windowClass: windowClass,
      availableWidth: width,
      textScale: textScale,
      availableHeight: height,
    );
  }

  factory PosLayoutSpec.from(
    BuildContext context,
    BoxConstraints constraints,
  ) => PosLayoutSpec.fromWidth(
    width: constraints.hasBoundedWidth
        ? constraints.maxWidth
        : MediaQuery.sizeOf(context).width,
    textScale: MediaQuery.textScalerOf(context).scale(1),
    height: constraints.hasBoundedHeight
        ? constraints.maxHeight
        : MediaQuery.sizeOf(context).height,
  );

  factory PosLayoutSpec.fromMediaQuery(BuildContext context) =>
      PosLayoutSpec.fromWidth(
        width: MediaQuery.sizeOf(context).width,
        textScale: MediaQuery.textScalerOf(context).scale(1),
        height: MediaQuery.sizeOf(context).height,
      );

  final PosWindowClass windowClass;
  final double availableWidth;
  final double textScale;
  final double availableHeight;

  bool get isCompact => windowClass == PosWindowClass.compact;
  bool get isMedium => windowClass == PosWindowClass.medium;
  bool get isWide => windowClass == PosWindowClass.wide;
  bool get isLarge => windowClass == PosWindowClass.large;
  bool get usesLargeText => textScale >= PosBreakpoints.largeTextScale;

  /// Master/detail and dense multi-column work areas collapse below 1024px.
  bool get prefersSingleColumn =>
      windowClass == PosWindowClass.compact ||
      windowClass == PosWindowClass.medium ||
      usesLargeText;

  /// Headers and action groups stack earlier to protect long EN/VI labels.
  bool get prefersStackedControls => isCompact || usesLargeText;

  /// Phone landscape remains a top-nav workflow even when its width falls in
  /// Medium. This uses available pane dimensions, never the device platform.
  bool get prefersCompactShell =>
      isCompact ||
      (availableWidth < PosBreakpoints.wide &&
          availableHeight < PosBreakpoints.compact);

  EdgeInsets get pagePadding => switch (windowClass) {
    PosWindowClass.compact => const EdgeInsets.all(12),
    PosWindowClass.medium => const EdgeInsets.all(16),
    PosWindowClass.wide || PosWindowClass.large => const EdgeInsets.all(20),
  };

  EdgeInsets get densePagePadding => switch (windowClass) {
    PosWindowClass.compact => const EdgeInsets.all(8),
    PosWindowClass.medium || PosWindowClass.wide => const EdgeInsets.all(12),
    PosWindowClass.large => const EdgeInsets.all(16),
  };
}

/// RULES.md: 레이아웃 분기는 core/layout/에서만 처리
/// feature 레이어에서는 이 위젯만 사용할 것
class AdaptiveLayout extends StatelessWidget {
  const AdaptiveLayout({
    super.key,
    required this.mobileLayout,
    required this.desktopLayout,
    this.breakpoint = 768,
  });

  final Widget mobileLayout;
  final Widget desktopLayout;
  final double breakpoint;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= breakpoint) {
      return desktopLayout;
    }
    return mobileLayout;
  }
}

/// Web/Desktop 전용 렌더링
class WebOnly extends StatelessWidget {
  const WebOnly({super.key, required this.child, this.fallback});
  final Widget child;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) =>
      PlatformInfo.isWeb ? child : (fallback ?? const SizedBox.shrink());
}

/// Android 전용 렌더링
class AndroidOnly extends StatelessWidget {
  const AndroidOnly({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      PlatformInfo.isAndroid ? child : const SizedBox.shrink();
}

/// 프린터 지원 플랫폼 전용 렌더링 (Web 제외)
class PrinterPlatformOnly extends StatelessWidget {
  const PrinterPlatformOnly({super.key, required this.child, this.fallback});
  final Widget child;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) => PlatformInfo.isPrinterSupported
      ? child
      : (fallback ?? const SizedBox.shrink());
}
