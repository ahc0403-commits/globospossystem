Project: /Users/andreahn/globos_pos_system
Task: Inventory 2.0 — Recipe-based auto-deduction on payment, daily physical count, inventory reports (ADR-011)

## Design Reference
- ADR-011: /Users/andreahn/Desktop/obsidian macmini/obsidian macmini/GLOBOSVN-POS/Decisions/ADR-011-Inventory-Recipe-Based-Deduction.md

---

## PART 1: DB Migration

Create: supabase/migrations/20260403000002_inventory_v2.sql

```sql
-- ============================================================
-- 1. inventory_items 기존 테이블 확장
-- ============================================================
ALTER TABLE inventory_items
  ADD COLUMN IF NOT EXISTS unit           TEXT DEFAULT 'g'
    CHECK (unit IN ('g','ml','ea')),
  ADD COLUMN IF NOT EXISTS current_stock  DECIMAL(12,3) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS reorder_point  DECIMAL(12,3),
  ADD COLUMN IF NOT EXISTS cost_per_unit  DECIMAL(12,2),
  ADD COLUMN IF NOT EXISTS supplier_name  TEXT;

-- ============================================================
-- 2. menu_recipes — 배합비 (메뉴→원재료 연결)
-- ============================================================
CREATE TABLE IF NOT EXISTS menu_recipes (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id  UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  menu_item_id   UUID NOT NULL REFERENCES menu_items(id) ON DELETE CASCADE,
  ingredient_id  UUID NOT NULL REFERENCES inventory_items(id) ON DELETE CASCADE,
  quantity_g     DECIMAL(10,3) NOT NULL CHECK (quantity_g > 0),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (menu_item_id, ingredient_id)
);

ALTER TABLE menu_recipes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "restaurant_isolation" ON menu_recipes
  USING (restaurant_id = get_user_restaurant_id()
         OR has_any_role(ARRAY['super_admin']));

-- ============================================================
-- 3. inventory_transactions — 재고 입출고 이력
-- ============================================================
CREATE TABLE IF NOT EXISTS inventory_transactions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id    UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  ingredient_id    UUID NOT NULL REFERENCES inventory_items(id) ON DELETE CASCADE,
  transaction_type TEXT NOT NULL
    CHECK (transaction_type IN ('deduct','restock','adjust','waste')),
  quantity_g       DECIMAL(12,3) NOT NULL, -- 양수=입고, 음수=차감
  reference_type   TEXT,                   -- 'order_item','manual','waste'
  reference_id     UUID,                   -- order_item_id 등
  note             TEXT,
  created_by       UUID REFERENCES auth.users(id),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE inventory_transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "restaurant_isolation" ON inventory_transactions
  USING (restaurant_id = get_user_restaurant_id()
         OR has_any_role(ARRAY['super_admin']));

-- ============================================================
-- 4. inventory_physical_counts — 일별 실재고 실사
-- ============================================================
CREATE TABLE IF NOT EXISTS inventory_physical_counts (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id           UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  ingredient_id           UUID NOT NULL REFERENCES inventory_items(id) ON DELETE CASCADE,
  count_date              DATE NOT NULL,
  actual_quantity_g       DECIMAL(12,3) NOT NULL,
  theoretical_quantity_g  DECIMAL(12,3),
  variance_g              DECIMAL(12,3),  -- actual - theoretical (음수=손실)
  counted_by              UUID REFERENCES auth.users(id),
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (ingredient_id, count_date)
);

ALTER TABLE inventory_physical_counts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "restaurant_isolation" ON inventory_physical_counts
  USING (restaurant_id = get_user_restaurant_id()
         OR has_any_role(ARRAY['super_admin']));

-- ============================================================
-- 5. process_payment RPC 교체 — 재고 자동차감 추가
--    기존 RPC에 inventory deduction 로직 원자적으로 추가
-- ============================================================
CREATE OR REPLACE FUNCTION process_payment(
  p_order_id      UUID,
  p_restaurant_id UUID,
  p_amount        DECIMAL(12,2),
  p_method        TEXT
) RETURNS payments AS $$
DECLARE
  v_payment    payments;
  v_table_id   UUID;
  v_is_revenue BOOLEAN;
  v_item       RECORD;
  v_recipe     RECORD;
  v_deduct_qty DECIMAL(12,3);
BEGIN
  -- 중복 결제 방지
  IF EXISTS (SELECT 1 FROM payments WHERE order_id = p_order_id) THEN
    RAISE EXCEPTION 'PAYMENT_ALREADY_EXISTS';
  END IF;

  v_is_revenue := (p_method != 'service');

  -- 결제 기록
  INSERT INTO payments
    (order_id, restaurant_id, amount, method, processed_by, is_revenue)
  VALUES
    (p_order_id, p_restaurant_id, p_amount, p_method, auth.uid(), v_is_revenue)
  RETURNING * INTO v_payment;

  -- 주문 완료 + 테이블 해제
  UPDATE orders SET status = 'completed', updated_at = now()
  WHERE id = p_order_id
  RETURNING table_id INTO v_table_id;

  IF v_table_id IS NOT NULL THEN
    UPDATE tables SET status = 'available', updated_at = now()
    WHERE id = v_table_id;
  END IF;

  -- ============================================================
  -- 재고 자동차감 (ADR-011)
  -- order_items → menu_recipes → inventory_items.current_stock
  -- ============================================================
  FOR v_item IN
    SELECT oi.id AS order_item_id,
           oi.menu_item_id,
           oi.quantity AS ordered_qty
    FROM order_items oi
    WHERE oi.order_id = p_order_id
      AND oi.menu_item_id IS NOT NULL
  LOOP
    FOR v_recipe IN
      SELECT mr.ingredient_id,
             mr.quantity_g
      FROM menu_recipes mr
      WHERE mr.menu_item_id = v_item.menu_item_id
        AND mr.restaurant_id = p_restaurant_id
    LOOP
      v_deduct_qty := v_item.ordered_qty * v_recipe.quantity_g;

      -- current_stock 차감 (0 아래로 내려갈 수 있음 — 재고 부족 경고용)
      UPDATE inventory_items
      SET current_stock = current_stock - v_deduct_qty,
          updated_at    = now()
      WHERE id = v_recipe.ingredient_id
        AND restaurant_id = p_restaurant_id;

      -- 차감 이력 기록
      INSERT INTO inventory_transactions
        (restaurant_id, ingredient_id, transaction_type,
         quantity_g, reference_type, reference_id, created_by)
      VALUES
        (p_restaurant_id, v_recipe.ingredient_id, 'deduct',
         -v_deduct_qty, 'order_item', v_item.order_item_id, auth.uid());
    END LOOP;
  END LOOP;

  RETURN v_payment;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

After creating the file run: echo "Y" | supabase db push


---

## PART 2: InventoryService (NEW)

Create: lib/core/services/inventory_service.dart

```dart
import '../../main.dart';

class InventoryService {

  // ── 원재료 (ingredients) ──────────────────────────────────

  Future<List<Map<String, dynamic>>> fetchIngredients(String restaurantId) async {
    final result = await supabase
        .from('inventory_items')
        .select()
        .eq('restaurant_id', restaurantId)
        .order('name');
    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<void> upsertIngredient({
    required String restaurantId,
    String? id,
    required String name,
    required String unit,
    double? currentStock,
    double? reorderPoint,
    double? costPerUnit,
    String? supplierName,
  }) async {
    final data = {
      'restaurant_id': restaurantId,
      'name': name,
      'unit': unit,
      if (currentStock != null) 'current_stock': currentStock,
      if (reorderPoint != null) 'reorder_point': reorderPoint,
      if (costPerUnit != null) 'cost_per_unit': costPerUnit,
      if (supplierName != null) 'supplier_name': supplierName,
    };
    if (id != null) {
      await supabase.from('inventory_items').update(data).eq('id', id);
    } else {
      await supabase.from('inventory_items').insert(data);
    }
  }

  Future<void> restockIngredient({
    required String restaurantId,
    required String ingredientId,
    required double quantityG,
    String? note,
  }) async {
    await supabase.from('inventory_items')
        .update({'current_stock': supabase.rpc('increment_stock',
            params: {'row_id': ingredientId, 'amount': quantityG})})
        .eq('id', ingredientId);
    // Simpler: just do two operations — update stock + insert transaction
    await supabase.rpc('restock_ingredient', params: {
      'p_restaurant_id': restaurantId,
      'p_ingredient_id': ingredientId,
      'p_quantity_g': quantityG,
      'p_note': note,
    });
  }

  // ── 배합비 (recipes) ──────────────────────────────────────

  Future<List<Map<String, dynamic>>> fetchRecipes({
    required String restaurantId,
    required String menuItemId,
  }) async {
    final result = await supabase
        .from('menu_recipes')
        .select('*, inventory_items(id, name, unit)')
        .eq('restaurant_id', restaurantId)
        .eq('menu_item_id', menuItemId);
    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<List<Map<String, dynamic>>> fetchAllRecipes(String restaurantId) async {
    final result = await supabase
        .from('menu_recipes')
        .select('*, menu_items(id, name), inventory_items(id, name, unit)')
        .eq('restaurant_id', restaurantId);
    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<void> upsertRecipe({
    required String restaurantId,
    required String menuItemId,
    required String ingredientId,
    required double quantityG,
  }) async {
    await supabase.from('menu_recipes').upsert({
      'restaurant_id': restaurantId,
      'menu_item_id': menuItemId,
      'ingredient_id': ingredientId,
      'quantity_g': quantityG,
    }, onConflict: 'menu_item_id,ingredient_id');
  }

  Future<void> deleteRecipe({
    required String menuItemId,
    required String ingredientId,
  }) async {
    await supabase.from('menu_recipes')
        .delete()
        .eq('menu_item_id', menuItemId)
        .eq('ingredient_id', ingredientId);
  }

  // ── 실재고 실사 ────────────────────────────────────────────

  Future<void> submitPhysicalCount({
    required String restaurantId,
    required String ingredientId,
    required String countDate, // 'YYYY-MM-DD'
    required double actualQuantityG,
    required double theoreticalQuantityG,
    String? countedBy,
  }) async {
    final variance = actualQuantityG - theoreticalQuantityG;
    await supabase.from('inventory_physical_counts').upsert({
      'restaurant_id': restaurantId,
      'ingredient_id': ingredientId,
      'count_date': countDate,
      'actual_quantity_g': actualQuantityG,
      'theoretical_quantity_g': theoreticalQuantityG,
      'variance_g': variance,
      'counted_by': countedBy,
    }, onConflict: 'ingredient_id,count_date');

    // 실사 완료 후 current_stock을 실측값으로 조정
    await supabase.from('inventory_items')
        .update({'current_stock': actualQuantityG, 'updated_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', ingredientId);

    // adjust 이력
    await supabase.from('inventory_transactions').insert({
      'restaurant_id': restaurantId,
      'ingredient_id': ingredientId,
      'transaction_type': 'adjust',
      'quantity_g': variance,
      'reference_type': 'physical_count',
      'note': '실재고 실사 조정 ($countDate)',
      'created_by': countedBy,
    });
  }

  // ── 리포트 ────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> fetchTransactions({
    required String restaurantId,
    required DateTime from,
    required DateTime to,
    String? ingredientId,
  }) async {
    var query = supabase
        .from('inventory_transactions')
        .select('*, inventory_items(id, name, unit)')
        .eq('restaurant_id', restaurantId)
        .gte('created_at', from.toIso8601String())
        .lte('created_at', to.toIso8601String());
    if (ingredientId != null) {
      query = query.eq('ingredient_id', ingredientId);
    }
    final result = await query.order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<List<Map<String, dynamic>>> fetchPhysicalCounts({
    required String restaurantId,
    required String countDate,
  }) async {
    final result = await supabase
        .from('inventory_physical_counts')
        .select('*, inventory_items(id, name, unit)')
        .eq('restaurant_id', restaurantId)
        .eq('count_date', countDate);
    return List<Map<String, dynamic>>.from(result as List);
  }
}

final inventoryService = InventoryService();
```

NOTE: Remove the `restockIngredient` RPC pattern — instead implement restock
as a direct two-step: update inventory_items.current_stock += amount, then
insert inventory_transactions. No additional RPC needed.


---

## PART 3: InventoryProvider (NEW)

Create: lib/features/inventory/inventory_provider.dart

```dart
// Three separate providers for three concerns:

// 1. 원재료 목록
class IngredientState {
  final List<Map<String, dynamic>> ingredients;
  final bool isLoading;
  final String? error;
}
class IngredientNotifier extends StateNotifier<IngredientState> {
  Future<void> load(String restaurantId);
  Future<void> add({required String restaurantId, required String name,
    required String unit, double? reorderPoint, double? costPerUnit, String? supplierName});
  Future<void> update(String id, Map<String, dynamic> data);
  Future<void> restock(String restaurantId, String ingredientId, double qty, String? note);
}
final ingredientProvider = StateNotifierProvider<IngredientNotifier, IngredientState>(
  (ref) => IngredientNotifier(),
);

// 2. 배합비
class RecipeState {
  // Map<menuItemId, List<recipe rows>>
  final Map<String, List<Map<String, dynamic>>> recipesByMenu;
  final bool isLoading;
  final String? error;
}
class RecipeNotifier extends StateNotifier<RecipeState> {
  Future<void> loadAll(String restaurantId);
  Future<void> upsert({required String restaurantId,
    required String menuItemId, required String ingredientId, required double quantityG});
  Future<void> delete({required String menuItemId, required String ingredientId});
}
final recipeProvider = StateNotifierProvider<RecipeNotifier, RecipeState>(
  (ref) => RecipeNotifier(),
);

// 3. 실재고 실사
class PhysicalCountState {
  // List of {ingredient + today's count if exists}
  final List<Map<String, dynamic>> items;
  final bool isLoading;
  final bool isSaving;
  final String? error;
}
class PhysicalCountNotifier extends StateNotifier<PhysicalCountState> {
  Future<void> load({required String restaurantId, required String countDate});
  Future<void> submitCount({required String restaurantId,
    required String ingredientId, required String countDate,
    required double actualQty, required double theoreticalQty, required String userId});
}
final physicalCountProvider = StateNotifierProvider<PhysicalCountNotifier, PhysicalCountState>(
  (ref) => PhysicalCountNotifier(),
);
```

---

## PART 4: Admin Inventory Tab (FULL BUILD)

Create: lib/features/admin/tabs/inventory_tab.dart

Add "재고" tab to Admin screen (both Web sidebar and Android BottomNav).
Icon: Icons.inventory_2_outlined

This tab has FOUR sub-tabs via TabBar:

---

### Sub-tab 1: "원재료 관리"

List of all ingredients for this restaurant.

```
[+ 원재료 추가] button (top right)

List rows — each ingredient:
  ┌────────────────────────────────────────────────────────┐
  │ 🥩 돼지고기 앞다리살                                     │
  │ 현재고: 2,450g    단위: g    발주기준: 1,000g             │
  │ 공급처: 한일식품   단가: ₫85,000/kg                      │
  │                              [입고] [수정] [삭제]        │
  └────────────────────────────────────────────────────────┘

Color coding:
  - current_stock <= reorder_point → red border + warning icon "발주 필요"
  - current_stock <= 0 → deep red background "재고 없음"
```

#### 원재료 추가/수정 Dialog:
- 이름 TextField
- 단위 Dropdown: g / ml / ea
- 현재고 NumberField (optional on create)
- 발주기준 NumberField
- 단가 (VND) NumberField
- 공급처 TextField
- [저장] button

#### 입고 Dialog:
- 입고량 NumberField
- 메모 TextField (optional)
- [입고 확인] → inventoryService restock

---

### Sub-tab 2: "배합비 관리"

Shows all menu items. For each menu item, configure which ingredients are used.

```
[메뉴 선택] Dropdown — list of active menu_items

Selected menu: "삼겹살 세트"
배합비:
  ┌─────────────────────────────┬──────────────┬──────┐
  │ 원재료                       │ 사용량        │      │
  ├─────────────────────────────┼──────────────┼──────┤
  │ 삼겹살                       │ 200 g        │ [삭제]│
  │ 상추                         │ 50 g         │ [삭제]│
  │ 쌈장                         │ 30 g         │ [삭제]│
  └─────────────────────────────┴──────────────┴──────┘

[+ 원재료 추가] button
  → Dropdown: 원재료 선택
  → NumberField: 사용량 (g/ml/ea)
  → [저장]
```

Note: quantity_g label adapts to the ingredient's unit
(if unit='ml' → show ml, if unit='ea' → show 개)

---

### Sub-tab 3: "실재고 실사"

Daily physical count entry. Used primarily on Android tablet.

```
날짜: [오늘 날짜] (Date picker, default today)

[실사 시작] button → loads ingredient list

For each ingredient:
  ┌──────────────────────────────────────────────────────┐
  │ 돼지고기 앞다리살                                       │
  │ 이론재고: 2,450g                                       │
  │ 실측재고: [____] g  (NumberField, large, easy to tap) │
  └──────────────────────────────────────────────────────┘

Progress: "3 / 12 완료"

[전체 저장] FilledButton (amber)
  → submit all entered counts
  → show summary: 총 X개 | 손실 Y개 | 잉여 Z개
```

Pre-populate: if a count already exists for today → show existing actual_qty

---

### Sub-tab 4: "재고 리포트"

```
기간 선택: From ~ To [적용] button

Summary cards:
  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
  │  총 차감량    │ │  총 입고량   │ │  총 손실량    │
  │  45,230g     │ │  80,000g    │ │  -2,340g     │
  └──────────────┘ └──────────────┘ └──────────────┘

원재료별 손실률 테이블:
  원재료       │ 이론차감 │ 실측차감 │ 손실량  │ 손실률
  삼겹살       │ 12,000g │ 11,650g │ -350g  │ 2.9%
  상추         │  3,000g │  2,840g │ -160g  │ 5.3%
  ...

발주 필요 목록 (current_stock <= reorder_point):
  🔴 돼지고기 앞다리살  현재고: 850g  발주기준: 1,000g
  🔴 쌈장              현재고: 120g  발주기준: 200g
```

---

## PART 5: RPC.md 문서 업데이트

Update Obsidian file:
/Users/andreahn/Desktop/obsidian macmini/obsidian macmini/GLOBOSVN-POS/Governance/RPC.md

Append section describing the updated process_payment RPC with inventory deduction logic.
Mention:
- Inventory deduction happens atomically inside process_payment
- Loop: order_items → menu_recipes → inventory_items.current_stock -= qty
- inventory_transactions INSERT for each deduction
- stock can go negative (no exception thrown) — UI shows warning

---

## Rules
- All Supabase calls through InventoryService — never from widgets
- PlatformInfo.isAndroid from core/layout/platform_info.dart — no kIsWeb in feature layer
- process_payment RPC migration replaces existing function with CREATE OR REPLACE
- Inventory deduction is best-effort: if menu has no recipe → skip silently (no crash)
- current_stock CAN go negative — this is intentional for "ran out" detection
- restock flow: update inventory_items.current_stock += amount, then INSERT inventory_transactions (type='restock')
- flutter analyze → 0 errors
- flutter build macos → pass
- flutter build web --release → pass
- flutter build apk --release → pass
- echo "Y" | supabase db push
- git add -A && git commit -m "feat: Inventory 2.0 - recipe-based auto-deduction, physical count, inventory reports (ADR-011)" && git push
