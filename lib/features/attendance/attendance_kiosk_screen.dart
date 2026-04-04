import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/layout/platform_info.dart';
import '../../core/services/connectivity_service.dart';
import '../../core/utils/time_utils.dart';
import '../../main.dart';
import '../../widgets/app_nav_bar.dart';
import '../../widgets/error_toast.dart';
import '../../widgets/offline_banner.dart';
import '../auth/auth_provider.dart';
import 'fingerprint_provider.dart';

enum _KioskViewState { idle, typeSelect, camera, preview, uploading, done }

class AttendanceKioskScreen extends ConsumerStatefulWidget {
  const AttendanceKioskScreen({super.key});

  @override
  ConsumerState<AttendanceKioskScreen> createState() =>
      _AttendanceKioskScreenState();
}

class _AttendanceKioskScreenState extends ConsumerState<AttendanceKioskScreen> {
  _KioskViewState _viewState = _KioskViewState.idle;
  Map<String, dynamic>? _selectedStaff;
  String? _selectedType;
  CameraController? _cameraController;
  XFile? _capturedFile;
  Timer? _clockTimer;
  Timer? _countdownTimer;
  Timer? _doneTimer;
  DateTime _nowVn = TimeUtils.nowVietnam();
  int _countdown = 3;
  String? _initializedRestaurantId;

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) {
        setState(() => _nowVn = TimeUtils.nowVietnam());
      }
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _countdownTimer?.cancel();
    _doneTimer?.cancel();
    _disposeCamera();
    super.dispose();
  }

  Future<void> _disposeCamera() async {
    final controller = _cameraController;
    _cameraController = null;
    if (controller != null) {
      await controller.dispose();
    }
  }

  Future<void> _loadStaffIfNeeded(String restaurantId) async {
    if (_initializedRestaurantId == restaurantId) return;
    _initializedRestaurantId = restaurantId;
    await ref.read(attendanceKioskProvider.notifier).loadStaff(restaurantId);
  }

  void _backToIdle() {
    _countdownTimer?.cancel();
    _doneTimer?.cancel();
    ref.read(attendanceKioskProvider.notifier).clearTransientState();
    setState(() {
      _viewState = _KioskViewState.idle;
      _selectedStaff = null;
      _selectedType = null;
      _capturedFile = null;
      _countdown = 3;
    });
  }

  Future<void> _goToCamera() async {
    setState(() {
      _viewState = _KioskViewState.camera;
      _countdown = 3;
    });

    try {
      final cameras = await availableCameras();
      final back = cameras.where(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      final front = cameras.where(
        (c) => c.lensDirection == CameraLensDirection.front,
      );
      final chosen = back.isNotEmpty
          ? back.first
          : (front.isNotEmpty
                ? front.first
                : (cameras.isNotEmpty ? cameras.first : null));

      if (chosen == null) {
        await _submitAttendance(photoFile: null);
        return;
      }

      await _disposeCamera();
      final controller = CameraController(
        chosen,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) return;
      setState(() {
        _cameraController = controller;
      });
      _startCountdown();
    } catch (_) {
      await _submitAttendance(photoFile: null);
    }
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    setState(() => _countdown = 3);

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_countdown <= 1) {
        timer.cancel();
        await _capturePhoto();
        return;
      }
      setState(() => _countdown -= 1);
    });
  }

  Future<void> _capturePhoto() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      await _submitAttendance(photoFile: null);
      return;
    }

    try {
      final file = await controller.takePicture();
      if (!mounted) return;
      setState(() {
        _capturedFile = file;
        _viewState = _KioskViewState.preview;
      });
    } catch (_) {
      await _submitAttendance(photoFile: null);
    }
  }

  Future<void> _submitAttendance({File? photoFile}) async {
    final restaurantId = ref.read(authProvider).restaurantId;
    final selected = _selectedStaff;
    final selectedType = _selectedType;
    if (restaurantId == null || selected == null || selectedType == null) {
      _backToIdle();
      return;
    }

    setState(() => _viewState = _KioskViewState.uploading);

    final success = await ref
        .read(attendanceKioskProvider.notifier)
        .recordAttendance(
          userId: selected['id'].toString(),
          restaurantId: restaurantId,
          type: selectedType,
          photoFile: photoFile,
        );

    if (!mounted) return;

    final state = ref.read(attendanceKioskProvider);
    if (state.error == 'PHOTO_UPLOAD_FAILED') {
      showErrorToast(context, '사진 업로드 실패. 출근은 기록됐습니다.');
    }

    if (!success) {
      showErrorToast(context, '근태 기록 실패');
      _backToIdle();
      return;
    }

    setState(() => _viewState = _KioskViewState.done);
    _doneTimer?.cancel();
    _doneTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) _backToIdle();
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final restaurantId = auth.restaurantId;
    final kioskState = ref.watch(attendanceKioskProvider);
    final isOnline = ref.watch(connectivityProvider).asData?.value ?? true;

    if (!PlatformInfo.isAndroid) {
      return Scaffold(
        backgroundColor: AppColors.surface0,
        body: Center(
          child: Text(
            '카메라는 Android 태블릿에서만 지원됩니다',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 18,
            ),
          ),
        ),
      );
    }

    if (restaurantId != null) {
      Future.microtask(() => _loadStaffIfNeeded(restaurantId));
    }

    return Scaffold(
      backgroundColor: AppColors.surface0,
      body: SafeArea(
        child: Column(
          children: [
            const OfflineBanner(),
            Expanded(
              child: Stack(
                children: [
                  Positioned(
                    top: 16,
                    right: 20,
                    child: Row(
                      children: [
                        if (_viewState == _KioskViewState.idle) ...[
                          const AppNavBar(),
                          const SizedBox(width: 10),
                        ],
                        Text(
                          '${_nowVn.hour.toString().padLeft(2, '0')}:${_nowVn.minute.toString().padLeft(2, '0')}',
                          style: GoogleFonts.bebasNeue(
                            color: AppColors.textPrimary,
                            fontSize: 42,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    top: 16,
                    left: 20,
                    child: Text(
                      'KIOSK',
                      style: GoogleFonts.bebasNeue(
                        color: AppColors.textSecondary,
                        fontSize: 26,
                      ),
                    ),
                  ),
                  Positioned.fill(child: _buildBody(kioskState, isOnline)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(AttendanceKioskState state, bool isOnline) {
    switch (_viewState) {
      case _KioskViewState.idle:
        return _buildIdle(state);
      case _KioskViewState.typeSelect:
        return _buildTypeSelect(isOnline);
      case _KioskViewState.camera:
        return _buildCamera();
      case _KioskViewState.preview:
        return _buildPreview();
      case _KioskViewState.uploading:
        return _buildUploading();
      case _KioskViewState.done:
        return _buildDone(state.lastAction);
    }
  }

  Widget _buildIdle(AttendanceKioskState state) {
    if (state.isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.amber500),
      );
    }

    return Column(
      children: [
        const SizedBox(height: 60),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                childAspectRatio: 2.6,
              ),
              itemCount: state.staffList.length,
              itemBuilder: (context, index) {
                final staff = state.staffList[index];
                return Material(
                  color: AppColors.surface1,
                  borderRadius: BorderRadius.circular(18),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () {
                      setState(() {
                        _selectedStaff = staff;
                        _viewState = _KioskViewState.typeSelect;
                      });
                    },
                    child: Center(
                      child: Text(
                        staff['full_name']?.toString() ?? '-',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.notoSansKr(
                          color: AppColors.textPrimary,
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Text(
            '이름을 선택하세요',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTypeSelect(bool isOnline) {
    final selectedName = _selectedStaff?['full_name']?.toString() ?? '-';

    return Column(
      children: [
        const SizedBox(height: 80),
        Text(
          selectedName,
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontSize: 36,
            fontWeight: FontWeight.w800,
          ),
        ),
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 220,
              height: 80,
              child: FilledButton(
                onPressed: !isOnline
                    ? null
                    : () {
                        _selectedType = 'clock_in';
                        _goToCamera();
                      },
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.amber500,
                  foregroundColor: AppColors.surface0,
                ),
                child: Text(
                  '출근',
                  style: GoogleFonts.notoSansKr(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            SizedBox(
              width: 220,
              height: 80,
              child: OutlinedButton(
                onPressed: !isOnline
                    ? null
                    : () {
                        _selectedType = 'clock_out';
                        _goToCamera();
                      },
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.surface2),
                ),
                child: Text(
                  '퇴근',
                  style: GoogleFonts.notoSansKr(
                    color: AppColors.textPrimary,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (!isOnline) ...[
          const SizedBox(height: 12),
          Text(
            '인터넷 연결 후 이용 가능합니다',
            style: GoogleFonts.notoSansKr(
              color: AppColors.statusOccupied,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        const SizedBox(height: 24),
        TextButton(
          onPressed: _backToIdle,
          child: Text(
            '← 돌아가기',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textSecondary,
              fontSize: 14,
            ),
          ),
        ),
        const Spacer(),
      ],
    );
  }

  Widget _buildCamera() {
    final controller = _cameraController;
    return Stack(
      children: [
        Positioned.fill(
          child: controller != null && controller.value.isInitialized
              ? CameraPreview(controller)
              : Container(color: Colors.black),
        ),
        Positioned.fill(
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.30),
            child: Center(
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$_countdown',
                  style: GoogleFonts.bebasNeue(
                    color: Colors.white,
                    fontSize: 100,
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 22,
          child: Text(
            '얼굴을 원 안에 맞춰주세요',
            textAlign: TextAlign.center,
            style: GoogleFonts.notoSansKr(color: Colors.white, fontSize: 16),
          ),
        ),
      ],
    );
  }

  Widget _buildPreview() {
    final file = _capturedFile;
    if (file == null) {
      return _buildUploading();
    }

    return Stack(
      children: [
        Positioned.fill(child: Image.file(File(file.path), fit: BoxFit.cover)),
        Positioned(
          left: 16,
          right: 16,
          bottom: 20,
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _goToCamera,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white),
                    foregroundColor: Colors.white,
                  ),
                  child: Text(
                    '다시 찍기',
                    style: GoogleFonts.notoSansKr(fontSize: 16),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () =>
                      _submitAttendance(photoFile: File(file.path)),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.amber500,
                    foregroundColor: AppColors.surface0,
                  ),
                  child: Text(
                    '확인 ✓',
                    style: GoogleFonts.notoSansKr(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildUploading() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: AppColors.amber500),
          const SizedBox(height: 14),
          Text(
            '기록 중...',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 18,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDone(String? lastAction) {
    final isIn = lastAction == 'clock_in';
    return Center(
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
            isIn ? '출근 완료' : '퇴근 완료',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontSize: 32,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
