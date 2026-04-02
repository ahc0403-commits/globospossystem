Project: /Users/andreahn/globos_pos_system
Task: Implement ZKTeco ZK9500 fingerprint scanner integration for staff attendance.

## Hardware Spec
- Device: ZKTeco ZK9500
- Connection: USB OTG (Android tablet ↔ ZK9500)
- Flutter package: zk_finger_10 (https://github.com/Mamasodikov/zk_finger_10)
- Platform: Android only (skip on Web/macOS with platform check)

## Architecture
```
ZK9500 → USB OTG → Android tablet
  → Flutter zk_finger_10 plugin
  → fingerprint capture + matching
  → Supabase fingerprint_templates table
  → attendance_logs INSERT
```

---

## Step 1: Add zk_finger_10 package

Add to pubspec.yaml dependencies:
```yaml
  zk_finger_10:
    git:
      url: https://github.com/Mamasodikov/zk_finger_10.git
```

Run: flutter pub get

---

## Step 2: DB Migration

Create file: supabase/migrations/20260402000003_fingerprint_attendance.sql

```sql
-- fingerprint templates table
CREATE TABLE IF NOT EXISTS fingerprint_templates (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  template_data TEXT NOT NULL,
  finger_index  INT NOT NULL DEFAULT 0,
  enrolled_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, finger_index)
);

CREATE INDEX IF NOT EXISTS idx_fingerprint_templates_restaurant
  ON fingerprint_templates (restaurant_id);

ALTER TABLE fingerprint_templates ENABLE ROW LEVEL SECURITY;

CREATE POLICY fingerprint_templates_policy ON fingerprint_templates
  USING (restaurant_id = get_user_restaurant_id());

-- Allow service role full access for fingerprint matching
CREATE POLICY fingerprint_templates_service_policy ON fingerprint_templates
  FOR ALL TO service_role USING (true);
```

Deploy: echo "Y" | supabase db push

---

## Step 3: Fingerprint Service

Create: lib/core/hardware/fingerprint_service.dart

```dart
import 'package:flutter/foundation.dart';

/// Abstract interface for fingerprint operations
abstract class FingerprintService {
  Future<bool> init();
  Future<String?> captureTemplate(); // returns Base64 template or null on failure
  Future<bool> matchTemplate(String template1, String template2);
  Future<void> dispose();
  bool get isSupported;
}
```

Create: lib/core/hardware/zkteco_fingerprint_service.dart

This is the Android implementation using zk_finger_10.
On non-Android platforms, return a NoopFingerprintService.

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'fingerprint_service.dart';

// Platform check - ZK9500 only works on Android
bool get _isAndroid {
  if (kIsWeb) return false;
  try {
    return defaultTargetPlatform == TargetPlatform.android;
  } catch (_) {
    return false;
  }
}

FingerprintService createFingerprintService() {
  if (_isAndroid) {
    return ZKTecoFingerprintService();
  }
  return NoopFingerprintService();
}

/// No-op implementation for Web/macOS
class NoopFingerprintService implements FingerprintService {
  @override bool get isSupported => false;
  @override Future<bool> init() async => false;
  @override Future<String?> captureTemplate() async => null;
  @override Future<bool> matchTemplate(String t1, String t2) async => false;
  @override Future<void> dispose() async {}
}

/// ZKTeco ZK9500 implementation for Android
class ZKTecoFingerprintService implements FingerprintService {
  static const _channel = MethodChannel('zk_finger_10');
  bool _initialized = false;

  @override
  bool get isSupported => _isAndroid;

  @override
  Future<bool> init() async {
    try {
      final result = await _channel.invokeMethod<bool>('initDevice');
      _initialized = result ?? false;
      return _initialized;
    } catch (e) {
      _initialized = false;
      return false;
    }
  }

  @override
  Future<String?> captureTemplate() async {
    if (!_initialized) return null;
    try {
      final template = await _channel.invokeMethod<String>('captureFingerprint');
      return template;
    } catch (e) {
      return null;
    }
  }

  @override
  Future<bool> matchTemplate(String template1, String template2) async {
    try {
      final score = await _channel.invokeMethod<int>('matchTemplates', {
        'template1': template1,
        'template2': template2,
      });
      return (score ?? 0) >= 50; // matching threshold
    } catch (e) {
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await _channel.invokeMethod('closeDevice');
    } catch (_) {}
    _initialized = false;
  }
}
```

---

## Step 4: Fingerprint Provider

Create: lib/features/attendance/fingerprint_provider.dart

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../main.dart';
import '../../core/hardware/zkteco_fingerprint_service.dart';

// State
class FingerprintState {
  final bool isInitialized;
  final bool isCapturing;
  final bool isEnrolling;
  final String? lastIdentifiedUserId;
  final String? lastIdentifiedUserName;
  final String? attendanceType; // 'clock_in' or 'clock_out'
  final String? error;
  final String? successMessage;

  const FingerprintState({
    this.isInitialized = false,
    this.isCapturing = false,
    this.isEnrolling = false,
    this.lastIdentifiedUserId,
    this.lastIdentifiedUserName,
    this.attendanceType,
    this.error,
    this.successMessage,
  });

  FingerprintState copyWith({
    bool? isInitialized,
    bool? isCapturing,
    bool? isEnrolling,
    String? lastIdentifiedUserId,
    String? lastIdentifiedUserName,
    String? attendanceType,
    String? error,
    String? successMessage,
    bool clearResult = false,
    bool clearError = false,
  }) => FingerprintState(
    isInitialized: isInitialized ?? this.isInitialized,
    isCapturing: isCapturing ?? this.isCapturing,
    isEnrolling: isEnrolling ?? this.isEnrolling,
    lastIdentifiedUserId: clearResult ? null : (lastIdentifiedUserId ?? this.lastIdentifiedUserId),
    lastIdentifiedUserName: clearResult ? null : (lastIdentifiedUserName ?? this.lastIdentifiedUserName),
    attendanceType: clearResult ? null : (attendanceType ?? this.attendanceType),
    error: clearError ? null : (error ?? this.error),
    successMessage: clearResult ? null : (successMessage ?? this.successMessage),
  );
}

// Notifier
class FingerprintNotifier extends StateNotifier<FingerprintState> {
  FingerprintNotifier() : super(const FingerprintState());

  final _service = createFingerprintService();

  Future<void> initialize() async {
    if (!_service.isSupported) {
      state = state.copyWith(isInitialized: false, error: '이 기기에서는 지문 인식기를 지원하지 않습니다.');
      return;
    }
    final ok = await _service.init();
    state = state.copyWith(
      isInitialized: ok,
      error: ok ? null : 'ZK9500 연결 실패. USB 케이블을 확인해주세요.',
    );
  }

  /// Enroll fingerprint for a specific user (called from Admin Staff tab)
  Future<bool> enrollFingerprint({
    required String userId,
    required String restaurantId,
    required int fingerIndex,
  }) async {
    state = state.copyWith(isEnrolling: true, clearError: true);
    try {
      final template = await _service.captureTemplate();
      if (template == null) {
        state = state.copyWith(isEnrolling: false, error: '지문 인식 실패. 다시 시도해주세요.');
        return false;
      }

      await supabase.from('fingerprint_templates').upsert({
        'user_id': userId,
        'restaurant_id': restaurantId,
        'template_data': template,
        'finger_index': fingerIndex,
      }, onConflict: 'user_id,finger_index');

      state = state.copyWith(isEnrolling: false, successMessage: '지문 등록 완료!');
      return true;
    } catch (e) {
      state = state.copyWith(isEnrolling: false, error: e.toString());
      return false;
    }
  }

  /// Identify fingerprint and record attendance (called from kiosk screen)
  Future<void> identifyAndRecord(String restaurantId) async {
    if (!state.isInitialized) {
      state = state.copyWith(error: '지문 인식기가 연결되지 않았습니다.');
      return;
    }

    state = state.copyWith(isCapturing: true, clearError: true, clearResult: true);

    try {
      // 1. Capture fingerprint
      final capturedTemplate = await _service.captureTemplate();
      if (capturedTemplate == null) {
        state = state.copyWith(isCapturing: false, error: '지문 인식 실패. 다시 시도해주세요.');
        return;
      }

      // 2. Load all templates for this restaurant
      final templates = await supabase
          .from('fingerprint_templates')
          .select('user_id, template_data, users(full_name)')
          .eq('restaurant_id', restaurantId);

      // 3. Match against stored templates
      String? matchedUserId;
      String? matchedUserName;

      for (final row in templates) {
        final storedTemplate = row['template_data'] as String;
        final isMatch = await _service.matchTemplate(capturedTemplate, storedTemplate);
        if (isMatch) {
          matchedUserId = row['user_id'] as String;
          final userMap = row['users'];
          matchedUserName = userMap is Map ? userMap['full_name'] as String? : null;
          break;
        }
      }

      if (matchedUserId == null) {
        state = state.copyWith(isCapturing: false, error: '등록되지 않은 지문입니다.');
        return;
      }

      // 4. Determine clock_in or clock_out
      final lastLog = await supabase
          .from('attendance_logs')
          .select('type')
          .eq('user_id', matchedUserId)
          .eq('restaurant_id', restaurantId)
          .order('logged_at', ascending: false)
          .limit(1)
          .maybeSingle();

      final lastType = lastLog?['type'] as String?;
      final newType = (lastType == 'clock_in') ? 'clock_out' : 'clock_in';

      // 5. Insert attendance log
      await supabase.from('attendance_logs').insert({
        'restaurant_id': restaurantId,
        'user_id': matchedUserId,
        'type': newType,
        'logged_at': DateTime.now().toUtc().toIso8601String(),
      });

      state = state.copyWith(
        isCapturing: false,
        lastIdentifiedUserId: matchedUserId,
        lastIdentifiedUserName: matchedUserName ?? '스태프',
        attendanceType: newType,
        successMessage: newType == 'clock_in'
            ? '출근 완료: ${matchedUserName ?? '스태프'}'
            : '퇴근 완료: ${matchedUserName ?? '스태프'}',
      );

      // Auto-reset after 3 seconds
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) {
        state = state.copyWith(clearResult: true);
      }
    } catch (e) {
      state = state.copyWith(isCapturing: false, error: e.toString());
    }
  }

  void clearResult() {
    state = state.copyWith(clearResult: true, clearError: true);
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }
}

final fingerprintProvider = StateNotifierProvider<FingerprintNotifier, FingerprintState>(
  (ref) => FingerprintNotifier(),
);
```

---

## Step 5: Attendance Kiosk Screen

Create: lib/features/attendance/attendance_kiosk_screen.dart

Full-screen dark background, always-on kiosk mode:

Layout:
- Top: "ATTENDANCE" in BebasNeue 32px amber + restaurant name
- Center:
  - Large fingerprint icon (Icons.fingerprint, size 120, amber)
  - "지문을 스캐너에 올려주세요" in NotoSansKR 20px textSecondary
  - When isCapturing: CircularProgressIndicator + "인식 중..."
  - When successMessage: 
    - clock_in: Green checkmark + "WELCOME" + name + time
    - clock_out: Blue icon + "GOODBYE" + name + time
  - When error: Red X icon + error message + "다시 시도" button
- Bottom: current time (updates every second)

The screen initializes FingerprintNotifier on mount.
Calls identifyAndRecord() when user taps the fingerprint icon.
(In production, ZK9500 triggers automatically - for now, tap to simulate)

Add route to app_router.dart:
  GoRoute(path: '/attendance-kiosk', builder: (_, __) => const AttendanceKioskScreen())

Note: This route should be accessible without role restriction
(or with a special kiosk login). For now, make it accessible to all logged-in users.

---

## Step 6: Update Admin Staff Tab

In lib/features/admin/tabs/staff_tab.dart:

For each staff card, add "지문 등록" button:
- Icon: Icons.fingerprint
- Opens a bottom sheet for fingerprint enrollment
- Bottom sheet:
  - Title: "지문 등록 - [스태프 이름]"
  - Instructions: "ZK9500 스캐너에 손가락을 올려주세요"
  - Large fingerprint icon (animated pulse when capturing)
  - "등록 시작" button → calls fingerprintProvider.enrollFingerprint()
  - Success: show checkmark + "등록 완료"
  - Error: show error message
- Show badge on staff card if fingerprint already enrolled
  (query fingerprint_templates count for this user)

In the same file, add a provider to check enrollment status:
```dart
final staffFingerprintCountProvider = FutureProvider.family<int, String>((ref, userId) async {
  final result = await supabase
      .from('fingerprint_templates')
      .select('id', const FetchOptions(count: CountOption.exact))
      .eq('user_id', userId);
  return result.count ?? 0;
});
```

---

## Step 7: Add to Admin navigation

In lib/features/admin/admin_screen.dart:
Add "Kiosk" nav item:
- Icon: Icons.touch_app
- Opens AttendanceKioskScreen via context.go('/attendance-kiosk')
- Only visible on Android (check with !kIsWeb && Platform.isAndroid)

Or add a "근태 키오스크 모드" button in Settings tab.

---

## Important notes

1. zk_finger_10 uses MethodChannel - it ONLY works on Android
   On Web/macOS: NoopFingerprintService returns false/null safely

2. The MethodChannel method names ('initDevice', 'captureFingerprint', 'matchTemplates')
   must match the Android plugin implementation.
   Check the actual method names in:
   https://github.com/Mamasodikov/zk_finger_10/blob/master/android/src/main/kotlin/

   Update method names if they differ.

3. For the migration, run:
   echo "Y" | supabase db push

4. The matching threshold (50) may need tuning based on real device testing.

---

## Rules
- Platform guard: all ZK9500 code behind !kIsWeb && Platform.isAndroid checks
- Never call supabase directly from screen widgets
- Run flutter analyze and fix ALL errors
- flutter build macos must still pass
- flutter build web --release must still pass
- flutter build apk --release must pass
- git add -A && git commit -m "feat: ZKTeco ZK9500 fingerprint attendance - enrollment, kiosk screen, attendance logging" && git push
