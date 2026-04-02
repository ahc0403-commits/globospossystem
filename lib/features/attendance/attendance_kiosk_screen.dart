import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../main.dart';
import '../auth/auth_provider.dart';
import 'fingerprint_provider.dart';

class AttendanceKioskScreen extends ConsumerStatefulWidget {
  const AttendanceKioskScreen({super.key});

  @override
  ConsumerState<AttendanceKioskScreen> createState() =>
      _AttendanceKioskScreenState();
}

class _AttendanceKioskScreenState extends ConsumerState<AttendanceKioskScreen> {
  Timer? _clockTimer;
  DateTime _now = DateTime.now();
  String? _initializedRestaurantId;

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _now = DateTime.now());
      }
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final restaurantId = auth.restaurantId;
    final fpState = ref.watch(fingerprintProvider);
    final fpNotifier = ref.read(fingerprintProvider.notifier);

    if (restaurantId != null && _initializedRestaurantId != restaurantId) {
      _initializedRestaurantId = restaurantId;
      Future.microtask(fpNotifier.initialize);
    }

    final restaurantNameAsync = restaurantId == null
        ? const AsyncValue<String>.data('GLOBOS POS')
        : ref.watch(restaurantNameProvider(restaurantId));

    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                children: [
                  Text(
                    'ATTENDANCE',
                    style: GoogleFonts.bebasNeue(
                      color: AppColors.amber500,
                      fontSize: 32,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const Spacer(),
                  restaurantNameAsync.when(
                    data: (name) => Text(
                      name,
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    loading: () => const SizedBox.shrink(),
                    error: (_, _) => Text(
                      'Restaurant',
                      style: GoogleFonts.notoSansKr(
                        color: AppColors.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    DateFormat('HH:mm:ss').format(_now),
                    style: GoogleFonts.bebasNeue(
                      color: AppColors.textPrimary,
                      fontSize: 32,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          onTap: (restaurantId == null || fpState.isCapturing)
                              ? null
                              : () =>
                                    fpNotifier.identifyAndRecord(restaurantId),
                          child: AnimatedScale(
                            scale: fpState.isCapturing ? 1.04 : 1,
                            duration: const Duration(milliseconds: 200),
                            child: Container(
                              width: 190,
                              height: 190,
                              decoration: BoxDecoration(
                                color: AppColors.surface1,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: fpState.isCapturing
                                      ? AppColors.amber500
                                      : AppColors.surface2,
                                  width: fpState.isCapturing ? 3 : 1,
                                ),
                              ),
                              alignment: Alignment.center,
                              child: const Icon(
                                Icons.fingerprint,
                                size: 120,
                                color: AppColors.amber500,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          '지문을 스캐너에 올려주세요',
                          style: GoogleFonts.notoSansKr(
                            color: AppColors.textSecondary,
                            fontSize: 20,
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (fpState.isCapturing) ...[
                          const CircularProgressIndicator(
                            color: AppColors.amber500,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '인식 중...',
                            style: GoogleFonts.notoSansKr(
                              color: AppColors.textSecondary,
                              fontSize: 16,
                            ),
                          ),
                        ],
                        if (fpState.successMessage != null &&
                            !fpState.isCapturing)
                          _SuccessPanel(
                            userName: fpState.lastIdentifiedUserName ?? '스태프',
                            type: fpState.attendanceType ?? 'clock_in',
                            now: _now,
                          ),
                        if (fpState.error != null && !fpState.isCapturing)
                          _ErrorPanel(
                            message: fpState.error!,
                            onRetry: fpNotifier.clearResult,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SuccessPanel extends StatelessWidget {
  const _SuccessPanel({
    required this.userName,
    required this.type,
    required this.now,
  });

  final String userName;
  final String type;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final isClockIn = type == 'clock_in';
    final accent = isClockIn
        ? AppColors.statusAvailable
        : const Color(0xFF4A90E2);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent),
      ),
      child: Column(
        children: [
          Icon(
            isClockIn ? Icons.check_circle : Icons.logout,
            color: accent,
            size: 56,
          ),
          const SizedBox(height: 8),
          Text(
            isClockIn ? 'WELCOME' : 'GOODBYE',
            style: GoogleFonts.bebasNeue(color: accent, fontSize: 40),
          ),
          Text(
            userName,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            DateFormat('HH:mm:ss').format(now),
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.statusCancelled),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.cancel_outlined,
            color: AppColors.statusCancelled,
            size: 52,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onRetry,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.textPrimary,
              side: const BorderSide(color: AppColors.surface2),
            ),
            child: const Text('다시 시도'),
          ),
        ],
      ),
    );
  }
}
