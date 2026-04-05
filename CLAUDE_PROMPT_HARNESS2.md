Project: /Users/andreahn/globos_pos_system
Task: Harness audit fixes — 8 issues found vs Obsidian design docs

---

# ═══════════════════════════════════
# ISSUE 1 [RULES.md 위반 - HIGH]
# 주문 생성/아이템 추가 오프라인 차단 미구현
# ═══════════════════════════════════
# RULES.md: "주문 생성 / 아이템 추가 → 온라인 필수"
# 현재: OfflineBanner만 표시, 주문 전송 버튼은 오프라인에서도 활성화됨
# OrderWorkspace.onSendOrder 버튼에 isOnline 체크 없음

## Fix: lib/widgets/order_workspace.dart

Add connectivityProvider watch and disable order send button when offline.

In _OrderWorkspaceBody.build() (the stateful widget that renders the send button):
1. Watch connectivityProvider: `final isOnline = ref.watch(connectivityProvider).asData?.value ?? true;`
2. Add isOnline to send button disable condition:

```dart
// BEFORE:
onPressed:
    widget.state.isSubmitting ||
        (!widget.allowSubmitWithoutCart && widget.state.cart.isEmpty)
    ? null
    : widget.onSendOrder,

// AFTER:
onPressed:
    widget.state.isSubmitting ||
        (!widget.allowSubmitWithoutCart && widget.state.cart.isEmpty) ||
        !isOnline  // RULES.md: 주문 생성은 온라인 필수
    ? null
    : widget.onSendOrder,
```

3. When offline and user tries to send, show tooltip or text below button:
   "인터넷 연결이 필요합니다"

Import: `import '../../core/services/connectivity_service.dart';`

Note: _OrderWorkspaceBody needs to be ConsumerStatefulWidget (or ConsumerWidget)
to use ref.watch. Check current implementation — if it's already ConsumerWidget,
just add the watch. If it's StatefulWidget, convert to ConsumerStatefulWidget.

---

# ═══════════════════════════════════
# ISSUE 2 [RULES.md 위반 - HIGH]
# 근태 기록 오프라인 차단 완전 없음
# ═══════════════════════════════════
# RULES.md: "근태 기록 → 온라인 필수"
# 현재: attendance_kiosk_screen.dart에 connectivityProvider 사용 없음
# 오프라인에서 촬영 후 "확인" 누르면 업로드/DB insert 실패 → 조용히 실패

## Fix: lib/features/attendance/attendance_kiosk_screen.dart

1. Add ConnectivityProvider watch in build():
```dart
final isOnline = ref.watch(connectivityProvider).asData?.value ?? true;
```

2. In idle state: show OfflineBanner at top if !isOnline

3. In type_select state: if !isOnline, disable "출근"/"퇴근" buttons and show
   "인터넷 연결 후 이용 가능합니다" message

4. In uploading state: if connectivityProvider returns false mid-upload,
   attendanceService already handles gracefully (logs without photo).
   But the initial guard prevents starting the flow offline.

Import: `import '../../core/services/connectivity_service.dart';`
Import: `import '../../widgets/offline_banner.dart';`

---

# ═══════════════════════════════════
# ISSUE 3 [RULES.md 위반 - MEDIUM]
# 근태 기록 시간 표시 UTC→VN 미변환
# ═══════════════════════════════════
# RULES.md: "timestamp: DB는 UTC. UI에서만 Asia/Ho_Chi_Minh 변환"
# 현재: attendance_tab.dart line 578-604에서
#   DateTime.tryParse(row['logged_at']) → toLocal() 없이 DateFormat 사용
#   → 시간이 UTC로 표시됨 (VN 시간보다 7시간 느림)

## Fix: lib/features/admin/tabs/attendance_tab.dart

Replace raw DateTime.tryParse with TimeUtils.toVietnam():

```dart
// BEFORE (line ~578):
final dateTime = DateTime.tryParse(
  row['logged_at']?.toString() ?? '',
);

// AFTER:
final rawDt = DateTime.tryParse(row['logged_at']?.toString() ?? '');
final dateTime = rawDt != null ? TimeUtils.toVietnam(rawDt) : null;
```

Also fix payroll date calculations that use DateTime.now() directly:
```dart
// BEFORE:
DateTime _logFrom = _startOfWeek(DateTime.now());
DateTime _logTo = DateTime.now();

// AFTER:
DateTime _logFrom = _startOfWeek(TimeUtils.nowVietnam());
DateTime _logTo = TimeUtils.nowVietnam();
```

Import: `import '../../../core/utils/time_utils.dart';`

Same fix needed in payroll period calculations (_payrollFrom, _payrollTo).

---

# ═══════════════════════════════════
# ISSUE 4 [SCHEMA.md 문서 누락 - LOW]
# restaurant_settings, external_sales 테이블 SCHEMA.md에 없음
# ═══════════════════════════════════
# 현재: 두 테이블이 migration에는 있으나 SCHEMA.md에 문서화 안됨

## Fix: Obsidian SCHEMA.md 업데이트
File: /Users/andreahn/Desktop/obsidian macmini/obsidian macmini/GLOBOSVN-POS/Governance/SCHEMA.md

Append these two sections at the end of the file:

```markdown
## external_sales (Deliberry 연동)

\```sql
CREATE TABLE external_sales (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id     UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  source_system     TEXT NOT NULL CHECK (source_system IN ('deliberry')),
  external_order_id TEXT NOT NULL,
  sales_channel     TEXT NOT NULL DEFAULT 'delivery',
  amount            DECIMAL(12,2) NOT NULL,
  is_revenue        BOOLEAN NOT NULL DEFAULT TRUE,
  sale_date         DATE NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
\```

## restaurant_settings (매장 설정)

\```sql
CREATE TABLE restaurant_settings (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id   UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE UNIQUE,
  payroll_pin     TEXT,   -- SHA-256 hash of 4-6 digit PIN
  settings_json   JSONB DEFAULT '{}',
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
\```
```

---

# ═══════════════════════════════════
# ISSUE 5 [RPC.md 문서 누락 - LOW]
# cancel_order RPC가 RPC.md에 없음
# ═══════════════════════════════════
# 현재: cancel_order가 migration 005에 구현됐으나 RPC.md에 문서화 안됨

## Fix: Obsidian RPC.md 업데이트
File: /Users/andreahn/Desktop/obsidian macmini/obsidian macmini/GLOBOSVN-POS/Governance/RPC.md

Append section after process_payment:

```markdown
## 5. `cancel_order` — 주문 취소

\```sql
CREATE OR REPLACE FUNCTION cancel_order(
  p_order_id      UUID,
  p_restaurant_id UUID
) RETURNS orders AS $$
...
\```

**허용 상태:** `pending`, `confirmed`만 취소 가능
`serving`, `completed`, `cancelled` → `ORDER_NOT_CANCELLABLE` 예외

**사이드이펙트:**
- orders.status = 'cancelled'
- tables.status = 'available' (table_id가 있는 경우)

**호출 위치:** `core/services/order_service.dart`
```

Also update the RPC 사용 분기 table to add cancel_order row.

---

# ═══════════════════════════════════
# ISSUE 6 [ROLES.md 위반 - HIGH]
# admin 주문 아이템 상태 변경 실제 연동 확인
# ═══════════════════════════════════
# 현재: tables_tab.dart에 canManageSentItems: true, onCycleSentItemStatus 있음
# BUT: updateOrderItemStatus가 order_provider에 있는지, 실제로 작동하는지 확인 필요

## Fix: Verify and fix lib/features/order/order_provider.dart

Ensure `updateOrderItemStatus` method exists and works:

```dart
Future<void> updateOrderItemStatus(
  String itemId,
  String newStatus,
  String restaurantId,
  String tableId,
) async {
  try {
    await supabase
        .from('order_items')
        .update({'status': newStatus})
        .eq('id', itemId);
    // Reload active order to reflect change
    await loadActiveOrder(tableId, restaurantId);
  } catch (e) {
    state = state.copyWith(error: 'Failed to update item status: $e');
  }
}
```

If this method doesn't exist → add it.
If it exists but doesn't reload → add loadActiveOrder call after update.

Also verify OrderWorkspace renders item status cycling UI when canManageSentItems=true.
Check that sent items (status != null/pending) show a tappable status chip.

---

# ═══════════════════════════════════
# ISSUE 7 [RULES.md 위반 - MEDIUM]
# Provider 3개 이상 테이블 직접 뮤테이션 여전히 위반
# ═══════════════════════════════════
# RULES.md: "Provider가 3개 이상 테이블 직접 뮤테이션 금지 → core/services/로 추출"
# 현재 위반 목록 (read-only SELECT는 제외, INSERT/UPDATE/DELETE만):
#   - menu_provider.dart (menu_items, menu_categories: CRUD)
#   - staff_provider.dart (users, staff_wage_configs 등)
#   - tables_provider.dart (tables: CRUD)
#   - super_admin_provider.dart (restaurants, qc_templates 등)
#
# 이 항목은 대규모 리팩토링이므로 이번 fix에서는
# 가장 단순하고 임팩트 높은 tables_provider만 추출

## Fix: Create lib/core/services/tables_service.dart

```dart
import '../../main.dart';

class TablesService {
  Future<List<Map<String, dynamic>>> fetchTables(String restaurantId) async {
    final r = await supabase
        .from('tables')
        .select()
        .eq('restaurant_id', restaurantId)
        .order('table_number');
    return List<Map<String, dynamic>>.from(r as List);
  }

  Future<void> addTable(String restaurantId, String tableNumber, int seatCount) async {
    await supabase.from('tables').insert({
      'restaurant_id': restaurantId,
      'table_number': tableNumber,
      'seat_count': seatCount,
      'status': 'available',
    });
  }

  Future<void> deleteTable(String tableId) async {
    await supabase.from('tables').delete().eq('id', tableId);
  }

  Future<void> updateTableStatus(String tableId, String status) async {
    await supabase.from('tables')
        .update({'status': status, 'updated_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', tableId);
  }
}

final tablesService = TablesService();
```

Then update lib/features/admin/providers/tables_provider.dart to use tablesService
instead of direct supabase calls.

---

# ═══════════════════════════════════
# ISSUE 8 [ADR-009 미반영 - MEDIUM]
# 급여 탭 날짜 계산이 UTC 기반
# ═══════════════════════════════════
# ADR-009: 급여 계산 시 출퇴근 시간 쌍 매칭
# 현재: payroll_service.dart에서 DateTime.parse(logged_at) 후 로컬 시간 기준으로
#       clock_in/clock_out 쌍 매칭 → UTC 기준이면 날짜 경계에서 오차 발생
# 예: VN 00:30 출근 = UTC 17:30 (전날) → 날짜 경계 오류

## Fix: lib/core/services/payroll_service.dart

In pairLogs() and calculatePayroll(), convert all logged_at timestamps to VN time
before grouping by date:

```dart
// When grouping logs by date for pairing:
final vnTime = TimeUtils.toVietnam(DateTime.parse(log['logged_at']));
final dateKey = '${vnTime.year}-${vnTime.month}-${vnTime.day}';
```

Import: `import '../utils/time_utils.dart';`

---

# ═══════════════════════════════════
# FINAL STEPS
# ═══════════════════════════════════

1. flutter analyze → 0 errors
2. flutter build macos → pass
3. flutter build web --release → pass
4. flutter build apk --release → pass
5. echo "Y" | supabase db push (no new migrations, just verify)
6. vercel deploy build/web --prod --yes
7. git add -A && git commit -m "fix: harness audit 2 - offline order guard, VN timezone in attendance, docs sync, tables service layer" && git push
