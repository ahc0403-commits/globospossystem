import 'package:flutter/material.dart';

import '../pos_design_tokens.dart';

/// Additive Toast-style primitives that are NOT yet defined under
/// `lib/core/ui/app_primitives.dart` or the existing `toast/` files.
///
/// This file is intentionally minimal — it only seeds the foundation that
/// later screen-migration PRs will build on. Do not add widgets here that
/// would shadow or replace existing `App*` / `Toast*` widgets already on
/// main; introduce them in dedicated follow-up PRs as their callers land.
class ToastWorkSurface extends StatelessWidget {
  const ToastWorkSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(ToastSpacingTokens.lg),
    this.backgroundColor = ToastColorTokens.surface,
    this.borderColor = ToastColorTokens.border,
    this.clip = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color backgroundColor;
  final Color borderColor;
  final bool clip;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: clip ? Clip.antiAlias : Clip.none,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: ToastRadiusTokens.md,
        border: Border.all(color: borderColor),
        boxShadow: ToastElevationTokens.none,
      ),
      padding: padding,
      child: child,
    );
  }
}
