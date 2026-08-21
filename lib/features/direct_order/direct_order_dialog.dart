import 'package:flutter/material.dart';

Future<T?> showDirectOrderDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return Navigator.of(context, rootNavigator: true).push<T>(
    DialogRoute<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
    ),
  );
}
