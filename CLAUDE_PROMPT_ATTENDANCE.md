Project: /Users/andreahn/globos_pos_system
Task: Attendance 2.0 — Replace fingerprint with camera selfie + name selection. Add payroll calculation with Excel export.

## Design Reference
- ADR-009: /Users/andreahn/Desktop/obsidian macmini/obsidian macmini/GLOBOSVN-POS/Decisions/ADR-009-Attendance-Camera-Based.md
- RULES.md applies throughout

---

## PART 1: Dependencies (pubspec.yaml)

Add these packages (run flutter pub add for each):
- camera: ^0.10.5+9         — Android camera access
- image: ^4.1.7              — image resize/compress (pure Dart, no native)
- path_provider: ^2.1.3      — temp file storage
- excel: ^4.0.6              — Excel export for payroll
- file_saver: ^0.2.14        — save Excel file to device

---

## PART 2: DB Migration

Create: supabase/migrations/20260403000000_attendance_camera_payroll.sql

```sql
-- attendance_logs: add photo columns
ALTER TABLE attendance_logs
  ADD COLUMN IF NOT EXISTS photo_url TEXT,
  ADD COLUMN IF NOT EXISTS photo_thumbnail_url TEXT;

-- staff_wage_configs: payroll settings per staff
CREATE TABLE IF NOT EXISTS staff_wage_configs (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id  UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  user_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  wage_type      TEXT NOT NULL CHECK (wage_type IN ('hourly','shift')),
  hourly_rate    DECIMAL(12,2),
  shift_rates    JSONB,
  effective_from DATE NOT NULL DEFAULT CURRENT_DATE,
  is_active      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, effective_from)
);

ALTER TABLE staff_wage_configs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "restaurant_isolation" ON staff_wage_configs
  USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']));

-- payroll_records: computed payroll cache
CREATE TABLE IF NOT EXISTS payroll_records (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  period_start  DATE NOT NULL,
  period_end    DATE NOT NULL,
  total_hours   DECIMAL(8,2),
  total_amount  DECIMAL(12,2),
  breakdown     JSONB,
  status        TEXT DEFAULT 'draft' CHECK (status IN ('draft','confirmed','paid')),
  confirmed_by  UUID REFERENCES auth.users(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE payroll_records ENABLE ROW LEVEL SECURITY;
CREATE POLICY "restaurant_isolation" ON payroll_records
  USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']));

-- Supabase Storage bucket
INSERT INTO storage.buckets (id, name, public)
VALUES ('attendance-photos', 'attendance-photos', false)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "restaurant_staff_access" ON storage.objects
  FOR ALL USING (
    bucket_id = 'attendance-photos'
    AND auth.role() = 'authenticated'
  );
```

After creating the migration file, run: echo "Y" | supabase db push


---

## PART 3: AttendanceService (NEW)

Create: lib/core/services/attendance_service.dart

```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import '../../main.dart';

class AttendanceService {
  // MANDATORY: compress before upload — never upload original file
  Future<String?> uploadAttendancePhoto({
    required String restaurantId,
    required String userId,
    required File originalFile,
    required String type,
  }) async {
    final bytes = await originalFile.readAsBytes();
    final original = img.decodeImage(bytes);
    if (original == null) return null;

    // Resize: max 800px on longest side
    final resized = img.copyResize(
      original,
      width: original.width > original.height ? 800 : -1,
      height: original.height >= original.width ? 800 : -1,
    );

    // JPEG quality 70
    final compressed = Uint8List.fromList(img.encodeJpg(resized, quality: 70));

    // Path: {restaurantId}/{userId}/{YYYY-MM-DD}/{timestamp}_{type}.jpg
    final now = DateTime.now().toUtc();
    final dateStr = '${now.year}-'
        '${now.month.toString().padLeft(2,'0')}-'
        '${now.day.toString().padLeft(2,'0')}';
    final tsStr = now.millisecondsSinceEpoch.toString();
    final path = '$restaurantId/$userId/$dateStr/${tsStr}_$type.jpg';

    await supabase.storage.from('attendance-photos').uploadBinary(
      path,
      compressed,
      fileOptions: const FileOptions(contentType: 'image/jpeg'),
    );

    return await supabase.storage
        .from('attendance-photos')
        .createSignedUrl(path, 60 * 60 * 24 * 365 * 10);
  }

  Future<void> logAttendance({
    required String restaurantId,
    required String userId,
    required String type,
    String? photoUrl,
  }) async {
    await supabase.from('attendance_logs').insert({
      'restaurant_id': restaurantId,
      'user_id': userId,
      'type': type,
      'photo_url': photoUrl,
      'logged_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> fetchLogs({
    required String restaurantId,
    required DateTime from,
    required DateTime to,
  }) async {
    final result = await supabase
        .from('attendance_logs')
        .select('*, users(id, full_name, role)')
        .eq('restaurant_id', restaurantId)
        .gte('logged_at', from.toIso8601String())
        .lte('logged_at', to.toIso8601String())
        .order('logged_at', ascending: false);
    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<List<Map<String, dynamic>>> fetchStaffList(String restaurantId) async {
    final result = await supabase
        .from('users')
        .select('id, full_name, role')
        .eq('restaurant_id', restaurantId)
        .eq('is_active', true)
        .order('full_name');
    return List<Map<String, dynamic>>.from(result as List);
  }
}

final attendanceService = AttendanceService();
```


---

## PART 4: AttendanceKioskScreen (FULL REWRITE)

Replace: lib/features/attendance/attendance_kiosk_screen.dart

Completely replace the existing fingerprint-based kiosk with camera-based flow.

### Kiosk States:
1. **idle** — Staff name grid (2 columns). Large tap targets. VN time clock top-right.
2. **type_select** — Selected name shown large + "출근" / "퇴근" two big buttons.
3. **camera** — Full-screen CameraPreview + circular face guide overlay + 3s countdown → auto-capture.
4. **preview** — Captured photo full-screen + "다시 찍기" / "확인 ✓" buttons.
5. **uploading** — CircularProgressIndicator + "기록 중...".
6. **done** — Green checkmark + "출근 완료" or "퇴근 완료" → auto-back to idle after 2 seconds.

### Platform guard:
- If !PlatformInfo.isAndroid → show centered message: "카메라는 Android 태블릿에서만 지원됩니다"
- Import PlatformInfo from core/layout/platform_info.dart — never use kIsWeb directly

### Camera behavior:
- Use `camera` package. On init: find back camera, fallback to front.
- CameraController resolution: ResolutionPreset.medium
- Dispose controller on screen dispose and when navigating away.
- On countdown end: controller.takePicture() → XFile → File

### Error handling:
- If photo upload fails → still call logAttendance(photoUrl: null) + showErrorToast "사진 업로드 실패. 출근은 기록됐습니다."
- If camera init fails → skip camera state, go directly to uploading with photoUrl: null

### Layout (idle):
```
[top-right] TimeUtils.nowVietnam() formatted as HH:mm, auto-updates every minute
[center]    GridView 2-column of staff name buttons
            Each button: large rounded rectangle, staff full_name centered
[bottom]    "이름을 선택하세요" hint text
```

### Layout (type_select):
```
[top]    Selected staff name (large, bold)
[center] Row: [출근 - amber filled] [퇴근 - grey outlined]
[bottom] TextButton "← 돌아가기"
```

### Layout (camera):
```
[full screen] CameraPreview
[overlay]     Semi-transparent circle guide center of screen
[overlay]     Countdown number (3, 2, 1) inside the circle, large white text
[bottom bar]  "얼굴을 원 안에 맞춰주세요" white text
```

### Layout (preview):
```
[full screen] Image.file(capturedFile) with BoxFit.cover
[bottom bar]  Row: [다시 찍기 - outlined] [확인 ✓ - amber filled]
```

---

## PART 5: AttendanceKioskNotifier (NEW Provider)

Add to: lib/features/attendance/fingerprint_provider.dart
(Keep existing FingerprintProvider as-is. Add new provider below it.)

```dart
class AttendanceKioskState {
  final List<Map<String, dynamic>> staffList;
  final bool isLoading;   // loading staff list
  final bool isUploading; // uploading photo + saving log
  final String? error;
  final String? lastAction; // 'clock_in' or 'clock_out' — for done screen

  const AttendanceKioskState({
    this.staffList = const [],
    this.isLoading = false,
    this.isUploading = false,
    this.error,
    this.lastAction,
  });

  AttendanceKioskState copyWith({...});
}

class AttendanceKioskNotifier extends StateNotifier<AttendanceKioskState> {
  Future<void> loadStaff(String restaurantId);
  // Returns true on success (even if photo failed)
  Future<bool> recordAttendance({
    required String userId,
    required String restaurantId,
    required String type, // 'clock_in' or 'clock_out'
    File? photoFile,
  });
}

final attendanceKioskProvider =
    StateNotifierProvider<AttendanceKioskNotifier, AttendanceKioskState>(
  (ref) => AttendanceKioskNotifier(),
);
```


---

## PART 6: Admin Attendance Tab (UPDATE)

Update: lib/features/admin/tabs/attendance_tab.dart

Replace the existing single-view tab with a TabBar containing 2 sub-tabs.

### Sub-tab 1: "근태 기록"
- Keep existing log list layout
- Add photo thumbnail: small 40x40 CircleAvatar showing photo_url
  - If photo_url is null: show grey person icon
  - Tap → showDialog with full-screen photo (InteractiveViewer for zoom)
- Add filters at top:
  - Date range: From / To date pickers (default: this week)
  - Staff dropdown: "전체" + each staff name
- Table columns: 날짜 | 직원 | 유형(출근/퇴근) | 시간 | 사진

### Sub-tab 2: "급여 관리"

#### Section A — 급여 설정 (wage config per staff)
- Dropdown: select staff member
- Radio: 시급제 / 시프트제
- If 시급제: TextField for hourly_rate (VND, number keyboard)
- If 시프트제: dynamic list of shift rows
  - Each row: [시작시간 picker] [종료시간 picker] [금액 TextField]
  - [+ 시프트 추가] button
  - [x] delete button per row
- [저장] button → upsert staff_wage_configs

#### Section B — 급여 계산
- Date range picker: period_start ~ period_end
- [계산하기] button → fetch logs → pair clock_in/clock_out → compute
- Result table:
  - Columns: 직원명 | 날짜 | 출근 | 퇴근 | 근무시간 | 금액(VND)
  - Group by staff with subtotal rows
  - Grand total row at bottom (bold, amber background)
- Unpaired logs (clock_in without clock_out): show in red, hours=0

#### Section C — 엑셀 출력
- [엑셀 저장 📥] FilledButton (amber) — only enabled after calculation
- On tap: generate .xlsx → save via file_saver
- Excel structure:
  - Sheet: "급여계산"
  - Row 1: Title "GLOBOS 급여 계산서 {period_start} ~ {period_end}"
  - Row 2: empty
  - Row 3: headers ["직원명", "날짜", "출근", "퇴근", "근무시간(h)", "금액(VND)"]
  - Rows: individual daily records
  - Last row: ["합계", "", "", "", total_hours, total_amount] bold
  - File name: "globos_payroll_{YYYY-MM-DD}.xlsx"

---

## PART 7: PayrollService (NEW)

Create: lib/core/services/payroll_service.dart

```dart
import 'package:excel/excel.dart';
import '../utils/time_utils.dart';
import '../../main.dart';

class DailyRecord {
  final String userId;
  final String userName;
  final DateTime date;
  final DateTime? clockIn;
  final DateTime? clockOut;
  final double hours;
  final double amount;
}

class StaffPayroll {
  final String userId;
  final String userName;
  final List<DailyRecord> dailyRecords;
  double get totalHours => dailyRecords.fold(0, (s, r) => s + r.hours);
  double get totalAmount => dailyRecords.fold(0, (s, r) => s + r.amount);
}

class PayrollService {
  // Fetch logs + wage configs → compute payroll
  Future<List<StaffPayroll>> calculatePayroll({
    required String restaurantId,
    required DateTime periodStart,
    required DateTime periodEnd,
  }) async { ... }

  // Match clock_in / clock_out pairs (handle missing gracefully)
  List<(DateTime?, DateTime?)> pairLogs(List<Map<String, dynamic>> logs) { ... }

  // Apply hourly wage
  double calcHourlyAmount(double hours, double hourlyRate) =>
      (hours * hourlyRate).roundToDouble();

  // Apply shift wage (check which shift the time falls in)
  double calcShiftAmount(DateTime clockIn, DateTime clockOut, List shifts) { ... }

  // Export to Excel bytes
  Future<List<int>> exportToExcel({
    required List<StaffPayroll> payrolls,
    required DateTime periodStart,
    required DateTime periodEnd,
  }) async {
    final excel = Excel.createExcel();
    final sheet = excel['급여계산'];
    // ... build rows
    final bytes = excel.encode();
    return bytes ?? [];
  }
}

final payrollService = PayrollService();
```

---

## PART 8: Admin Staff Tab — Remove Fingerprint UI

In lib/features/admin/tabs/staff_tab.dart:
- Find and REMOVE any "지문 등록" button or fingerprint-related UI elements
- Do NOT delete core/hardware/zkteco_fingerprint_service.dart or fingerprint_provider.dart
- Just remove the UI trigger buttons

---

## Rules
- PlatformInfo.isAndroid / PlatformInfo.isPrinterSupported from core/layout/platform_info.dart
  Never use kIsWeb or Platform.isAndroid directly in feature layer
- All Supabase calls go through AttendanceService / PayrollService
- Image compression MANDATORY before upload (max 800px, JPEG 70%)
- If photo upload fails → still record attendance (log without photo_url) + warning toast
- Camera only on Android → show message on Web/macOS
- flutter analyze → 0 errors
- flutter build macos → pass
- flutter build web --release → pass
- flutter build apk --release → pass
- echo "Y" | supabase db push
- git add -A && git commit -m "feat: Attendance 2.0 - camera selfie kiosk, payroll calculation, Excel export (ADR-009)" && git push
