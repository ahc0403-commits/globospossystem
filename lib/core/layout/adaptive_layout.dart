import 'package:flutter/material.dart';
import 'platform_info.dart';

export 'platform_info.dart';

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
    if (PlatformInfo.isWebOrDesktop) return desktopLayout;
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
