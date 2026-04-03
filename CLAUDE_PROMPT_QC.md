Project: /Users/andreahn/globos_pos_system
Task: QC Module — Quality control checklist with weekly view (ADR-010)

## Design Reference
- ADR-010: /Users/andreahn/Desktop/obsidian macmini/obsidian macmini/GLOBOSVN-POS/Decisions/ADR-010-Quality-Control-Module.md

---

## PART 1: DB Migration

Create: supabase/migrations/20260403000001_qc_module.sql

```sql
-- QC 기준표 (매장 admin이 직접 생성/관리)
CREATE TABLE IF NOT EXISTS qc_templates (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id      UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  category           TEXT NOT NULL,
  criteria_text      TEXT NOT NULL,
  criteria_photo_url TEXT,     -- 기준 참조 사진 (Supabase Storage)
  sort_order         INT DEFAULT 0,
  is_active          BOOLEAN NOT NULL DEFAULT TRUE,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE qc_templates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "restaurant_isolation" ON qc_templates
  USING (restaurant_id = get_user_restaurant_id()
         OR has_any_role(ARRAY['super_admin']));

-- 일별 점검 기록
CREATE TABLE IF NOT EXISTS qc_checks (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id      UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  template_id        UUID NOT NULL REFERENCES qc_templates(id) ON DELETE CASCADE,
  check_date         DATE NOT NULL,
  checked_by         UUID REFERENCES auth.users(id),
  result             TEXT NOT NULL CHECK (result IN ('pass','fail','na')),
  evidence_photo_url TEXT,     -- 첨부 사진 (Supabase Storage)
  note               TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (template_id, check_date)
);

ALTER TABLE qc_checks ENABLE ROW LEVEL SECURITY;
CREATE POLICY "restaurant_isolation" ON qc_checks
  USING (restaurant_id = get_user_restaurant_id()
         OR has_any_role(ARRAY['super_admin']));

-- Supabase Storage: qc-photos bucket
INSERT INTO storage.buckets (id, name, public)
VALUES ('qc-photos', 'qc-photos', false)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "authenticated_access" ON storage.objects
  FOR ALL USING (
    bucket_id = 'qc-photos'
    AND auth.role() = 'authenticated'
  );
```

After creating the file run: echo "Y" | supabase db push


---

## PART 2: QcService (NEW)

Create: lib/core/services/qc_service.dart

```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import '../../main.dart';

class QcService {
  // --- Templates ---

  Future<List<Map<String, dynamic>>> fetchTemplates(String restaurantId) async {
    final result = await supabase
        .from('qc_templates')
        .select()
        .eq('restaurant_id', restaurantId)
        .eq('is_active', true)
        .order('category')
        .order('sort_order');
    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<void> createTemplate({
    required String restaurantId,
    required String category,
    required String criteriaText,
    String? criteriaPhotoUrl,
    int sortOrder = 0,
  }) async {
    await supabase.from('qc_templates').insert({
      'restaurant_id': restaurantId,
      'category': category,
      'criteria_text': criteriaText,
      'criteria_photo_url': criteriaPhotoUrl,
      'sort_order': sortOrder,
    });
  }

  Future<void> updateTemplate(String id, Map<String, dynamic> data) async {
    await supabase.from('qc_templates').update(data).eq('id', id);
  }

  Future<void> deactivateTemplate(String id) async {
    await supabase.from('qc_templates').update({'is_active': false}).eq('id', id);
  }

  // --- Checks ---

  // Fetch checks for a date range (for weekly view)
  Future<List<Map<String, dynamic>>> fetchChecks({
    required String restaurantId,
    required DateTime from,
    required DateTime to,
  }) async {
    final result = await supabase
        .from('qc_checks')
        .select('*, qc_templates(id, category, criteria_text, criteria_photo_url)')
        .eq('restaurant_id', restaurantId)
        .gte('check_date', from.toIso8601String().substring(0, 10))
        .lte('check_date', to.toIso8601String().substring(0, 10));
    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<void> upsertCheck({
    required String restaurantId,
    required String templateId,
    required String checkDate, // 'YYYY-MM-DD'
    required String result,    // 'pass' | 'fail' | 'na'
    String? evidencePhotoUrl,
    String? note,
    String? checkedBy,
  }) async {
    await supabase.from('qc_checks').upsert({
      'restaurant_id': restaurantId,
      'template_id': templateId,
      'check_date': checkDate,
      'result': result,
      'evidence_photo_url': evidencePhotoUrl,
      'note': note,
      'checked_by': checkedBy,
    }, onConflict: 'template_id,check_date');
  }

  // --- Photo upload ---
  // Compress: max 1200px, JPEG 75%
  Future<String?> uploadQcPhoto({
    required String restaurantId,
    required String templateId,
    required File file,
    required String type, // 'template' | 'check'
    String? checkDate,
  }) async {
    final bytes = await file.readAsBytes();
    final original = img.decodeImage(bytes);
    if (original == null) return null;

    final resized = img.copyResize(
      original,
      width: original.width > original.height ? 1200 : -1,
      height: original.height >= original.width ? 1200 : -1,
    );
    final compressed = Uint8List.fromList(
      img.encodeJpg(resized, quality: 75),
    );

    final ts = DateTime.now().millisecondsSinceEpoch;
    final path = type == 'template'
        ? '$restaurantId/templates/$templateId.jpg'
        : '$restaurantId/checks/$checkDate/$templateId.jpg';

    await supabase.storage.from('qc-photos').uploadBinary(
      path,
      compressed,
      fileOptions: const FileOptions(
        contentType: 'image/jpeg',
        upsert: true,
      ),
    );

    return await supabase.storage
        .from('qc-photos')
        .createSignedUrl(path, 60 * 60 * 24 * 365 * 10);
  }
}

final qcService = QcService();
```


---

## PART 3: QcProvider (NEW)

Create: lib/features/qc/qc_provider.dart

```dart
// QcTemplateNotifier — manages qc_templates CRUD
class QcTemplateState {
  final List<Map<String, dynamic>> templates;
  final bool isLoading;
  final String? error;
}

class QcTemplateNotifier extends StateNotifier<QcTemplateState> {
  Future<void> loadTemplates(String restaurantId);
  Future<void> addTemplate({required String restaurantId, required String category, required String criteriaText, String? criteriaPhotoUrl});
  Future<void> updateTemplate(String id, Map<String, dynamic> data);
  Future<void> deleteTemplate(String id);
  Future<String?> uploadCriteriaPhoto(String restaurantId, String templateId, File file);
}

final qcTemplateProvider = StateNotifierProvider<QcTemplateNotifier, QcTemplateState>(
  (ref) => QcTemplateNotifier(),
);

// QcCheckNotifier — manages daily checks and weekly view data
class QcCheckState {
  final List<Map<String, dynamic>> checks; // flat list for the week
  final bool isLoading;
  final String? error;
}

class QcCheckNotifier extends StateNotifier<QcCheckState> {
  // Load checks for given week (7 days starting from weekStart)
  Future<void> loadWeek({required String restaurantId, required DateTime weekStart});
  // Submit a check with optional photo
  Future<void> submitCheck({
    required String restaurantId,
    required String templateId,
    required String checkDate,
    required String result,
    File? evidencePhoto,
    String? note,
    String? checkedBy,
  });
}

final qcCheckProvider = StateNotifierProvider<QcCheckNotifier, QcCheckState>(
  (ref) => QcCheckNotifier(),
);
```

---

## PART 4: QC Check Screen — /qc-check (NEW)

Create: lib/features/qc/qc_check_screen.dart

This is the daily check screen used on Android tablet.

### Route
Add to app_router.dart: `/qc-check` — accessible by all roles

### Layout
```
[AppBar] "오늘의 품질 점검"  날짜 표시 (오늘, VN timezone)

[Body] ListView of templates grouped by category

  Category header: "주방위생" (bold, amber accent bar)
  ┌──────────────────────────────────────────────────────┐
  │ 기준: 조리대 청결 유지                                  │
  │ [기준사진 썸네일 40x40]                               │
  │                                                      │
  │ 판정: [✅ 통과]  [❌ 불합격]  [— 해당없음]             │
  │                                                      │
  │ [📷 사진 첨부]  →  이미 첨부된 경우: 썸네일 표시        │
  │ [메모 입력] (optional TextField)                      │
  └──────────────────────────────────────────────────────┘

[Bottom] [저장 완료] FilledButton (amber)
  → save all checked items → show success toast → pop
```

### Behavior
- Load templates on init
- Each template row has local state: result (null/pass/fail/na), photo File, note
- "판정" buttons: toggle selection, amber = selected
- "사진 첨부": image_picker or camera (PlatformInfo.isAndroid → camera, else file picker)
- On save: upsert all filled-in checks (skip templates with null result)
- If photo exists: upload first → get URL → save with URL
- Pre-populate today's existing checks (allow re-submission / edit)

---

## PART 5: Admin QC Tab (NEW)

Add to Admin screen as a new tab: "QC" (or "품질관리")

Create: lib/features/admin/tabs/qc_tab.dart

This tab has TWO sub-tabs via TabBar:

### Sub-tab 1: "기준표 관리" (Template Management)

Admin creates/edits QC criteria for their restaurant.

```
[+ 기준 추가] button (top right)
  → Bottom sheet / dialog:
    - 카테고리: TextField (예: "주방위생", "서비스")
    - 기준(글): TextField (multi-line)
    - 기준(사진): optional — [사진 업로드] button → image_picker
    - 순서: Int field
    [저장] button

List of existing templates, grouped by category:
  Each item shows:
  - category chip
  - criteria_text
  - criteria_photo thumbnail (40x40) if exists
  - [수정] [삭제] icon buttons
  - drag handle for reordering sort_order
```

### Sub-tab 2: "주간 점검 현황" (Weekly View)

Shows 7 days in horizontal columns. This is the CORE feature.

```
[←] 이전주   2026-03-30 ~ 2026-04-05   [→] 다음주

Horizontal scrollable table:

┌────────────────┬──────┬──────┬──────┬──────┬──────┬──────┬──────┐
│ 기준           │ 월   │ 화   │ 수   │ 목   │ 금   │ 토   │ 일   │
│                │ 3/30 │ 3/31 │ 4/1  │ 4/2  │ 4/3  │ 4/4  │ 4/5  │
├────────────────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│ [주방위생]      │      │      │      │      │      │      │      │
│ 조리대 청결     │  ✅  │  ✅  │  ❌  │  ✅  │  ✅  │  ✅  │  -   │
│ 식자재 보관     │  ✅  │  ❌  │  ✅  │  ✅  │  ✅  │  ✅  │  -   │
├────────────────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│ [서비스]        │      │      │      │      │      │      │      │
│ 유니폼 착용     │  ✅  │  ✅  │  ✅  │  ✅  │  ✅  │  ❌  │  -   │
└────────────────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┘

Legend: ✅=pass  ❌=fail  —=na  빈칸=미점검
```

#### Cell tap behavior
- Tap any cell → showDialog:
  ```
  날짜: 2026-04-01 (화)
  기준: 조리대 청결 유지
  판정: ❌ 불합격
  [첨부사진] — InteractiveViewer for zoom
  [메모] — if any
  [닫기] button
  ```
- If cell is empty (미점검): dialog shows "해당 날짜 미점검"

#### Color coding
- ✅ pass cell: subtle green background
- ❌ fail cell: red background, draws attention
- — na: grey
- Empty: no color
- Category header rows: amber background, spanning all columns

#### Implementation notes
- Use a CustomScrollView with SliverToBoxAdapter
- Left column is fixed width 160px, 7 day columns are each 64px
- Use SingleChildScrollView(scrollDirection: Axis.horizontal) wrapping a fixed-width Table
- Week navigation: prev/next arrows update weekStart state → reload
- Default week: current week (Monday to Sunday)


---

## PART 6: Super Admin QC View (UPDATE)

In lib/features/super_admin/super_admin_screen.dart:

Add a "QC 현황" section in the Super Admin screen (existing tabs or new tab).

Shows a summary table: one row per restaurant.

```
레스토랑        │ 이번주 점검율  │ 불합격 수  │ 최근 점검일
GLOBOS 1호점   │ 85%          │ 2건       │ 2026-04-03
GLOBOS 2호점   │ 100%         │ 0건       │ 2026-04-03
K-Noodle      │ 60%          │ 5건       │ 2026-04-02
```

- "점검율" = (pass + fail + na) / total_templates × 7 days
- Click row → navigate to /admin/{restaurantId} QC tab (use existing super admin
  context switch flow)

---

## PART 7: Router Update

In lib/core/router/app_router.dart:

Add route: `/qc-check`
- Accessible by all authenticated roles (waiter, kitchen, cashier, admin, super_admin)
- Platform: Android preferred, but allow all

In Admin screen bottom nav / sidebar:
- Add "QC" tab item (icon: Icons.checklist or Icons.fact_check)

---

## PART 8: image_picker dependency

Add to pubspec.yaml if not already present:
- image_picker: ^1.1.2

The `camera` package may already be added from CLAUDE_PROMPT_ATTENDANCE.md.
Check pubspec.yaml first — if camera is already there, skip re-adding.
If image_picker is already there, skip re-adding.

For QC photo upload on Web/macOS: use image_picker (file picker mode)
For QC photo on Android: prefer camera for evidence photos, image_picker as fallback

---

## Rules
- All Supabase calls through QcService — never from widgets directly
- PlatformInfo.isAndroid from core/layout/platform_info.dart — no kIsWeb in feature layer
- Image compression MANDATORY before upload (max 1200px, JPEG 75%)
- Weekly view must handle missing checks gracefully (show empty cell, not crash)
- Weekly view left column must be sticky/fixed — use Row with fixed-width containers
- flutter analyze → 0 errors
- flutter build macos → pass
- flutter build web --release → pass
- flutter build apk --release → pass
- echo "Y" | supabase db push
- git add -A && git commit -m "feat: QC module - template management, daily check screen, weekly view (ADR-010)" && git push
