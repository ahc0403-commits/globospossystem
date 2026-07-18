import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/services/connectivity_service.dart';
import '../../core/ui/toast/toast_primitives_extended.dart';
import '../../core/utils/time_utils.dart';
import '../../main.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/error_toast.dart';
import '../../widgets/offline_banner.dart';
import '../auth/auth_provider.dart';
import 'attendance_kiosk_provider.dart';

enum _KioskViewState { idle, submitting, done }

class AttendanceKioskScreen extends ConsumerStatefulWidget {
  const AttendanceKioskScreen({super.key});

  @override
  ConsumerState<AttendanceKioskScreen> createState() =>
      _AttendanceKioskScreenState();
}

class _AttendanceKioskScreenState extends ConsumerState<AttendanceKioskScreen> {
  final _employeeNumberController = TextEditingController();
  final _employeeNumberFocus = FocusNode();
  _KioskViewState _viewState = _KioskViewState.idle;
  Timer? _clockTimer;
  Timer? _doneTimer;
  DateTime _nowVn = TimeUtils.nowVietnam();

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _nowVn = TimeUtils.nowVietnam());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _employeeNumberFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _doneTimer?.cancel();
    _employeeNumberController.dispose();
    _employeeNumberFocus.dispose();
    super.dispose();
  }

  void _reset() {
    _doneTimer?.cancel();
    ref.read(attendanceKioskProvider.notifier).clearResult();
    _employeeNumberController.clear();
    setState(() => _viewState = _KioskViewState.idle);
    _employeeNumberFocus.requestFocus();
  }

  Future<void> _submit(String type) async {
    final storeId = ref.read(authProvider).storeId;
    final employeeNumber = _employeeNumberController.text.trim();
    if (storeId == null) {
      showErrorToast(context, context.l10n.attendanceRecordFailed);
      return;
    }
    if (employeeNumber.isEmpty) {
      showErrorToast(context, context.l10n.attendanceEmployeeNumberRequired);
      _employeeNumberFocus.requestFocus();
      return;
    }

    setState(() => _viewState = _KioskViewState.submitting);
    final recorded = await ref
        .read(attendanceKioskProvider.notifier)
        .recordAttendance(
          employeeNumber: employeeNumber,
          storeId: storeId,
          type: type,
        );
    if (!mounted) return;

    if (!recorded) {
      final errorCode = ref.read(attendanceKioskProvider).errorCode;
      showErrorToast(context, _localizedAttendanceError(errorCode));
      setState(() => _viewState = _KioskViewState.idle);
      _employeeNumberFocus.requestFocus();
      return;
    }

    setState(() => _viewState = _KioskViewState.done);
    _doneTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) _reset();
    });
  }

  String _localizedAttendanceError(String? code) => switch (code) {
    'EMPLOYEE_NOT_FOUND' => context.l10n.attendanceEmployeeNotFound,
    'EMPLOYEE_INACTIVE' => context.l10n.attendanceEmployeeInactive,
    'ATTENDANCE_FORBIDDEN' => context.l10n.attendanceEmployeeForbidden,
    _ => context.l10n.attendanceRecordFailed,
  };

  @override
  Widget build(BuildContext context) {
    final isOnline = ref.watch(connectivityProvider).asData?.value ?? true;
    final kioskState = ref.watch(attendanceKioskProvider);

    return Scaffold(
      key: const Key('attendance_kiosk_root'),
      backgroundColor: AppColors.surface0,
      body: SafeArea(
        child: Column(
          children: [
            const OfflineBanner(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact =
                      constraints.maxWidth < 700 ||
                      MediaQuery.textScalerOf(context).scale(1) > 1.5;
                  final title = Text(
                    context.l10n.attendanceEmployeeKioskTitle,
                    style: AppFonts.system(
                      color: AppColors.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  );
                  final clock = Text(
                    '${_nowVn.hour.toString().padLeft(2, '0')}:${_nowVn.minute.toString().padLeft(2, '0')}',
                    style: AppFonts.system(
                      color: AppColors.textPrimary,
                      fontSize: 32,
                    ),
                  );

                  if (compact) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        title,
                        const SizedBox(height: 12),
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            const SizedBox(width: 110, child: AppNavBar()),
                            clock,
                          ],
                        ),
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: title),
                      const SizedBox(width: 12),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: const AppNavBar(),
                      ),
                      const SizedBox(width: 12),
                      clock,
                    ],
                  );
                },
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: switch (_viewState) {
                  _KioskViewState.idle => _buildIdle(isOnline),
                  _KioskViewState.submitting => _buildSubmitting(),
                  _KioskViewState.done => _buildDone(kioskState),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIdle(bool isOnline) {
    return ToastResponsiveBody(
      maxWidth: 720,
      padding: EdgeInsets.zero,
      child: Center(
        child: ToastWorkSurface(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.l10n.attendanceEnterEmployeeNumber,
                textAlign: TextAlign.center,
                style: AppFonts.system(
                  color: AppColors.textPrimary,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.attendanceEmployeeNumberOnlyHint,
                textAlign: TextAlign.center,
                style: AppFonts.system(
                  color: AppColors.textSecondary,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                key: const Key('attendance_employee_number_field'),
                controller: _employeeNumberController,
                focusNode: _employeeNumberFocus,
                textCapitalization: TextCapitalization.characters,
                textAlign: TextAlign.center,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9_-]')),
                ],
                onSubmitted: (_) => isOnline ? _submit('clock_in') : null,
                decoration: InputDecoration(
                  labelText: context.l10n.attendanceEmployeeNumber,
                  hintText: context.l10n.attendanceEmployeeNumberHint,
                ),
                style: AppFonts.system(
                  color: AppColors.textPrimary,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      key: const Key('attendance_employee_clock_in'),
                      onPressed: isOnline ? () => _submit('clock_in') : null,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(72),
                        backgroundColor: AppColors.amber500,
                        foregroundColor: AppColors.surface0,
                      ),
                      child: Text(
                        context.l10n.clockIn,
                        style: AppFonts.system(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('attendance_employee_clock_out'),
                      onPressed: isOnline ? () => _submit('clock_out') : null,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(72),
                      ),
                      child: Text(
                        context.l10n.clockOut,
                        style: AppFonts.system(
                          color: AppColors.textPrimary,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (!isOnline) ...[
                const SizedBox(height: 14),
                Text(
                  context.l10n.attendanceOnlineRequired,
                  textAlign: TextAlign.center,
                  style: AppFonts.system(
                    color: AppColors.statusOccupied,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSubmitting() => Center(
    child: ToastWorkSurface(
      padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 30),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: AppColors.amber500),
          const SizedBox(height: 14),
          Text(context.l10n.attendanceRecording),
        ],
      ),
    ),
  );

  Widget _buildDone(AttendanceKioskState state) {
    final isClockIn = state.lastAction == 'clock_in';
    return Center(
      child: ToastWorkSurface(
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.check_circle,
              color: AppColors.statusAvailable,
              size: 96,
            ),
            const SizedBox(height: 12),
            Text(
              isClockIn
                  ? context.l10n.attendanceClockInComplete
                  : context.l10n.attendanceClockOutComplete,
              style: AppFonts.system(
                color: AppColors.textPrimary,
                fontSize: 28,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              state.lastEmployeeNumber ?? '',
              style: AppFonts.system(
                color: AppColors.textSecondary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
