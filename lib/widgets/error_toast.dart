import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../main.dart';

void showErrorToast(BuildContext context, String message) {
  _showToast(
    context,
    message: message,
    backgroundColor: AppColors.statusCancelled,
    icon: Icons.error_outline,
  );
}

void showSuccessToast(BuildContext context, String message) {
  _showToast(
    context,
    message: message,
    backgroundColor: AppColors.statusAvailable,
    icon: Icons.check_circle_outline,
  );
}

void _showToast(
  BuildContext context, {
  required String message,
  required Color backgroundColor,
  required IconData icon,
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      backgroundColor: backgroundColor,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
      margin: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      content: Row(
        children: [
          Icon(icon, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: GoogleFonts.notoSansKr(
                color: Colors.white,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
