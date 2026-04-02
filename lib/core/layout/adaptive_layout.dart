import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

bool get isWebOrDesktop {
  if (kIsWeb) {
    return true;
  }
  try {
    return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  } catch (_) {
    return false;
  }
}

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
    if (isWebOrDesktop) {
      return desktopLayout;
    }
    return mobileLayout;
  }
}
