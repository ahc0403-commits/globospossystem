Project: /Users/andreahn/globos_pos_system
Task: Fix 6 issues found in harness audit + user testing

---

# ══════════════════════════════════════════════
# FIX 1: WAITER — 테이블 선택 후 주문 패널 전환 안 됨
# ══════════════════════════════════════════════

File: lib/features/waiter/waiter_screen.dart

## Problem
_onSelectTable sets _showOrderPanel = true but panel doesn't appear reliably.
Root cause: setState is called but the AnimatedSwitcher child key doesn't change
when re-selecting the same table, so the transition doesn't fire.

## Fix
In _onSelectTable, always force a new key by appending a timestamp:

```dart
// Change the ValueKey to force rebuild every tap
// Instead of: key: ValueKey<String>('order-${selectedTable.id}')
// Use:        key: ValueKey<String>('order-${selectedTable.id}-${DateTime.now().millisecondsSinceEpoch}')
```

Also ensure setState is called BEFORE the async loadActiveOrder call,
so the panel appears immediately while data loads:

```dart
Future<void> _onSelectTable(PosTable table, String restaurantId, bool requireGuestCount) async {
  int? guestCount;
  if (requireGuestCount) {
    guestCount = await _showGuestCountDialog();
    if (guestCount == null) return;
  }
  // Show panel FIRST, then load data
  setState(() {
    _selectedTable = table;
    _selectedGuestCount = guestCount;
    _showOrderPanel = true;
  });
  await ref.read(orderProvider.notifier).loadActiveOrder(table.id, restaurantId);
}
```

And in the AnimatedSwitcher child, use timestamp in key:
```dart
child: _showOrderPanel && selectedTable != null
    ? _OrderWorkspace(
        key: ValueKey<String>('order-${selectedTable.id}-${_selectedTable.hashCode}'),
        ...
```

---

# ══════════════════════════════════════════════
# FIX 2: KITCHEN — 모든 아이템 served 후 주문 카드 제거
# ══════════════════════════════════════════════

File: lib/features/kitchen/kitchen_provider.dart

## Problem
When all items in an order reach 'served' status:
- Current: items are filtered out (items.isEmpty), so order disappears on NEXT loadOrders
- But if Realtime only triggers on order_items update (not orders update),
  and the order.status stays 'serving', the card stays until next reload
- Also: updateItemStatus only updates order_items, never updates orders.status

## Fix A: After updating last item to 'served', auto-update order status to 'completed'

In updateItemStatus, after the supabase update succeeds, check if ALL items are now served.
If so, update orders.status = 'serving' → keep as is (cashier handles completion).
But remove from kitchen view by filtering.

The real fix is: apply optimistic filter in updateItemStatus locally:

```dart
Future<void> updateItemStatus(String itemId, String newStatus) async {
  final previous = state.orders;

  // Optimistic update with local filter
  final optimisticOrders = state.orders
      .map((order) => order.copyWith(
            items: order.items
                .map((item) => item.itemId == itemId
                    ? item.copyWith(status: newStatus)
                    : item)
                .toList(),
          ))
      // KEY FIX: remove orders where ALL items are now served
      .where((order) {
        final updatedItems = order.items;
        if (updatedItems.isEmpty) return false;
        // Check if the item being updated is in this order
        final hasThisItem = updatedItems.any((i) => i.itemId == itemId);
        if (!hasThisItem) return true; // not related, keep
        // After update, check if all items would be served
        final allServed = updatedItems.every((i) =>
            i.itemId == itemId ? newStatus == 'served' : i.status == 'served');
        return !allServed; // remove from kitchen if all served
      })
      .toList();

  state = state.copyWith(orders: optimisticOrders, clearError: true);

  try {
    await supabase.from('order_items').update({'status': newStatus}).eq('id', itemId);
    // If all items served, also reload to sync with server
    if (_restaurantId != null) await loadOrders(_restaurantId!);
  } catch (error) {
    state = state.copyWith(orders: previous, error: 'Failed to update item status: $error');
  }
}
```

## Fix B: Kitchen screen visual improvement
In kitchen_screen.dart, add a subtle "모두 완료" completion animation before card disappears:
- When tapping last item to 'served': show green flash on the card for 500ms, then it disappears
- This gives visual feedback instead of abrupt removal

In _cycleStatus, after status becomes 'served' and all items are served:
- Brief delay of 500ms with green highlight
- Then the provider removes the card

---

# ══════════════════════════════════════════════
# FIX 3: QC — super_admin 본사 공통 기준표 일괄 등록
# ══════════════════════════════════════════════

## 3-A: DB Migration
Create: supabase/migrations/20260403000004_qc_global_templates.sql

```sql
-- qc_templates에 is_global 컬럼 추가
-- is_global=true: 본사(super_admin)가 만든 공통 기준, restaurant_id=NULL
-- is_global=false: 매장 어드민이 만든 개별 기준
ALTER TABLE qc_templates
  ADD COLUMN IF NOT EXISTS is_global BOOLEAN NOT NULL DEFAULT FALSE,
  ALTER COLUMN restaurant_id DROP NOT NULL;

-- restaurant_id가 NULL인 경우 is_global=TRUE 강제
ALTER TABLE qc_templates
  ADD CONSTRAINT qc_global_check
    CHECK (
      (is_global = TRUE AND restaurant_id IS NULL) OR
      (is_global = FALSE AND restaurant_id IS NOT NULL)
    );

-- RLS 업데이트: 전체 공통(is_global=TRUE)은 모든 인증 사용자가 조회 가능
DROP POLICY IF EXISTS "restaurant_isolation" ON qc_templates;

CREATE POLICY "qc_templates_select" ON qc_templates
  FOR SELECT USING (
    is_global = TRUE OR
    restaurant_id = get_user_restaurant_id() OR
    has_any_role(ARRAY['super_admin'])
  );

CREATE POLICY "qc_templates_insert" ON qc_templates
  FOR INSERT WITH CHECK (
    -- super_admin: 공통(is_global=TRUE) 또는 특정 매장 기준 생성 가능
    has_any_role(ARRAY['super_admin']) OR
    -- admin: 자기 매장 개별 기준만 생성 (is_global=FALSE)
    (has_any_role(ARRAY['admin']) AND is_global = FALSE
      AND restaurant_id = get_user_restaurant_id())
  );

CREATE POLICY "qc_templates_update" ON qc_templates
  FOR UPDATE USING (
    -- super_admin: 모든 기준 수정 가능
    has_any_role(ARRAY['super_admin']) OR
    -- admin: 자기 매장 개별 기준만 수정, 공통 기준 수정 불가
    (has_any_role(ARRAY['admin']) AND is_global = FALSE
      AND restaurant_id = get_user_restaurant_id())
  );

CREATE POLICY "qc_templates_delete" ON qc_templates
  FOR DELETE USING (
    has_any_role(ARRAY['super_admin']) OR
    (has_any_role(ARRAY['admin']) AND is_global = FALSE
      AND restaurant_id = get_user_restaurant_id())
  );
```

Run: echo "Y" | supabase db push

## 3-B: QcService update
In lib/core/services/qc_service.dart:

Update fetchTemplates to include both global and restaurant-specific:
```dart
Future<List<Map<String, dynamic>>> fetchTemplates(String restaurantId) async {
  // Fetch: global templates (is_global=TRUE) + this restaurant's own templates
  final result = await supabase
      .from('qc_templates')
      .select()
      .or('is_global.eq.true,restaurant_id.eq.$restaurantId')
      .eq('is_active', true)
      .order('is_global', ascending: false) // global first
      .order('category')
      .order('sort_order');
  return List<Map<String, dynamic>>.from(result as List);
}

// Create global template (super_admin only)
Future<void> createGlobalTemplate({
  required String category,
  required String criteriaText,
  String? criteriaPhotoUrl,
  int sortOrder = 0,
}) async {
  await supabase.from('qc_templates').insert({
    'is_global': true,
    'restaurant_id': null,
    'category': category,
    'criteria_text': criteriaText,
    'criteria_photo_url': criteriaPhotoUrl,
    'sort_order': sortOrder,
  });
}

// Fetch all global templates (for super_admin management)
Future<List<Map<String, dynamic>>> fetchGlobalTemplates() async {
  final result = await supabase
      .from('qc_templates')
      .select()
      .eq('is_global', true)
      .order('category')
      .order('sort_order');
  return List<Map<String, dynamic>>.from(result as List);
}
```

## 3-C: Super Admin Screen — QC 기준표 관리 탭 추가
In lib/features/super_admin/super_admin_screen.dart:

Add a new nav item: "QC 기준표" (icon: Icons.rule)
Side by side with existing "QC 현황"

This new tab shows:
- Header: "본사 공통 QC 기준표 관리"
- [+ 공통 기준 추가] button
  → Dialog: category TextField + criteria_text TextField + [기준사진 업로드] + [저장]
  → calls qcService.createGlobalTemplate(...)

- List of global templates grouped by category:
  - Category chip (amber)
  - criteria_text
  - criteria_photo thumbnail if exists
  - "📌 전체 매장 공통" badge
  - [수정] [비활성화] buttons (super_admin only)
  - Global templates show in ALL restaurant QC checks automatically

- Below global list: info text
  "✅ 위 항목은 모든 매장에 자동 적용됩니다. 매장별 추가 항목은 매장 어드민이 설정합니다."

## 3-D: Admin QC Tab — 권한 분리
In lib/features/admin/tabs/qc_tab.dart:

- Read role from authProvider
- Global templates (is_global=TRUE): show as read-only with "📌 본사 공통" badge, NO edit/delete buttons
- Store-specific templates (is_global=FALSE): show [수정] [삭제] buttons for admin

```dart
final role = ref.watch(authProvider).role;
final isSuperAdmin = role == 'super_admin';

// In template list item:
if (!template['is_global'] || isSuperAdmin) ...[
  IconButton(icon: Icon(Icons.edit), onPressed: () => _editTemplate(template)),
  IconButton(icon: Icon(Icons.delete), onPressed: () => _deleteTemplate(id)),
] else ...[
  Container(
    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: AppColors.amber500.withOpacity(0.2), borderRadius: BorderRadius.circular(8)),
    child: Text('📌 본사 공통', style: TextStyle(color: AppColors.amber500, fontSize: 11)),
  ),
]
```

---

# ══════════════════════════════════════════════
# FIX 4: QC — 일자별 검색 추가
# ══════════════════════════════════════════════

File: lib/features/admin/tabs/qc_tab.dart

## Current state
Only week navigation (← 이전주 / 다음주 →) exists.
No date-range search.

## Fix: Add date-range search mode toggle

In the weekly view sub-tab, add a toggle above the week navigation:
```
[주간 보기] [기간 검색]  ← SegmentedButton or TabBar
```

### 주간 보기 mode (existing):
- ← [이전주] [다음주] →
- 7-column horizontal table

### 기간 검색 mode (new):
- From date picker + To date picker + [검색] button
- Result: list view (not table) of check records
- Each record: date | template category | criteria | result (✅/❌/—) | 사진 썸네일
- Sorted by date desc
- Filter by: 결과 dropdown (전체/통과/불합격/해당없음) + category dropdown

In qc_provider.dart, add fetchChecksByDateRange:
```dart
Future<void> loadDateRange({
  required String restaurantId,
  required DateTime from,
  required DateTime to,
}) async {
  // fetch qc_checks joined with qc_templates for the date range
  final result = await supabase
      .from('qc_checks')
      .select('*, qc_templates(id, category, criteria_text, criteria_photo_url, is_global)')
      .eq('restaurant_id', restaurantId)
      .gte('check_date', from.toIso8601String().substring(0, 10))
      .lte('check_date', to.toIso8601String().substring(0, 10))
      .order('check_date', ascending: false);
  // store in state as dateRangeChecks
}
```

---

# ══════════════════════════════════════════════
# FIX 5: QC 점검 화면 — 예시사진 + 내용 더 잘 보이게
# ══════════════════════════════════════════════

File: lib/features/qc/qc_check_screen.dart

## Current state
criteria_photo_url shows as a small tap target. Not obvious enough.

## Fix
Make the criteria reference section more prominent:

```dart
// In each template check card:
// 1. Show criteria_text in larger, bold font
// 2. If criteria_photo_url exists:
//    - Show a larger thumbnail (80x80 or wider)
//    - Label: "📷 기준 예시사진 (탭하여 크게 보기)"
//    - On tap: full-screen InteractiveViewer dialog

// New layout per template card:
Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    // Criteria header
    Row(children: [
      Icon(Icons.assignment, color: AppColors.amber500, size: 16),
      SizedBox(width: 6),
      Expanded(child: Text(criteria_text, style: bold)),
    ]),

    // Reference photo - make it prominent
    if (criteriaPhotoUrl != null) ...[
      SizedBox(height: 8),
      GestureDetector(
        onTap: () => _showImageDialog(criteriaPhotoUrl),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.amber500.withOpacity(0.5)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
                child: Image.network(criteriaPhotoUrl,
                  height: 100, width: double.infinity, fit: BoxFit.cover),
              ),
              Container(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text('📷 예시사진 탭하여 크게 보기',
                  style: TextStyle(color: AppColors.amber500, fontSize: 11)),
              ),
            ],
          ),
        ),
      ),
    ],

    SizedBox(height: 10),
    // Result buttons (pass/fail/na) ...
  ],
)
```

---

# ══════════════════════════════════════════════
# FINAL STEPS
# ══════════════════════════════════════════════

1. echo "Y" | supabase db push  (migration 20260403000004)
2. flutter analyze → 0 errors
3. flutter build macos → pass
4. flutter build web --release → pass
5. flutter build apk --release → pass
6. vercel deploy build/web --prod --yes
7. git add -A && git commit -m "fix: waiter panel transition, kitchen auto-remove on all-served, QC global templates by super_admin, QC date search, QC criteria photo UI" && git push
