import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/services/connectivity_service.dart';
import '../main.dart';

class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectivity = ref.watch(connectivityProvider);
    final isOffline = connectivity.maybeWhen(
      data: (connected) => !connected,
      orElse: () => false,
    );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      height: isOffline ? 36 : 0,
      child: ClipRect(
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          offset: isOffline ? Offset.zero : const Offset(0, -1),
          child: Container(
            color: AppColors.statusOccupied,
            alignment: Alignment.center,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.wifi_off, color: AppColors.surface0, size: 16),
                const SizedBox(width: 6),
                Text(
                  '인터넷 연결이 끊겼습니다',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.surface0,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
