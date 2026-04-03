Project: /Users/andreahn/globos_pos_system
Task: Three items — (1) Inventory 2.0 full implementation, (2) QC/Inventory separate permissions, (3) Payroll PIN protection

---

# ═══════════════════════════════════════════
# ITEM 1: INVENTORY 2.0 (Full Implementation)
# ═══════════════════════════════════════════
# Reference: CLAUDE_PROMPT_INVENTORY.md (already in this repo)
# Status: features/inventory/ folder is EMPTY. Nothing was implemented.
# This must be fully built from scratch.

## 1-A: DB Migration
Create: supabase/migrations/20260403000002_inventory_v2.sql

```sql
-- inventory_items 기존 테이블 확장
ALTER TABLE inventory_items
  ADD COLUMN IF NOT EXISTS unit           TEXT DEFAULT 'g' CHECK (unit IN ('g','ml','ea')),
  ADD COLUMN IF NOT EXISTS current_stock  DECIMAL(12,3) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS reorder_point  DECIMAL(12,3),
  ADD COLUMN IF NOT EXISTS cost_per_unit  DECIMAL(12,2),
  ADD COLUMN IF NOT EXISTS supplier_name  TEXT;

-- 배합비 (메뉴 → 원재료)
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
  USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']));

-- 재고 입출고 이력
CREATE TABLE IF NOT EXISTS inventory_transactions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id    UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  ingredient_id    UUID NOT NULL REFERENCES inventory_items(id) ON DELETE CASCADE,
  transaction_type TEXT NOT NULL CHECK (transaction_type IN ('deduct','restock','adjust','waste')),
  quantity_g       DECIMAL(12,3) NOT NULL,
  reference_type   TEXT,
  reference_id     UUID,
  note             TEXT,
  created_by       UUID REFERENCES auth.users(id),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE inventory_transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "restaurant_isolation" ON inventory_transactions
  USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']));

-- 일별 실재고 실사
CREATE TABLE IF NOT EXISTS inventory_physical_counts (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id           UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  ingredient_id           UUID NOT NULL REFERENCES inventory_items(id) ON DELETE CASCADE,
  count_date              DATE NOT NULL,
  actual_quantity_g       DECIMAL(12,3) NOT NULL,
  theoretical_quantity_g  DECIMAL(12,3),
  variance_g              DECIMAL(12,3),
  counted_by              UUID REFERENCES auth.users(id),
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (ingredient_id, count_date)
);
ALTER TABLE inventory_physical_counts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "restaurant_isolation" ON inventory_physical_counts
  USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']));

-- process_payment RPC 교체: 재고 자동차감 추가 (결제 완료 시 원자적 처리)
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
  IF EXISTS (SELECT 1 FROM payments WHERE order_id = p_order_id) THEN
    RAISE EXCEPTION 'PAYMENT_ALREADY_EXISTS';
  END IF;

  v_is_revenue := (p_method != 'service');

  INSERT INTO payments (order_id, restaurant_id, amount, method, processed_by, is_revenue)
  VALUES (p_order_id, p_restaurant_id, p_amount, p_method, auth.uid(), v_is_revenue)
  RETURNING * INTO v_payment;

  UPDATE orders SET status = 'completed', updated_at = now()
  WHERE id = p_order_id RETURNING table_id INTO v_table_id;

  IF v_table_id IS NOT NULL THEN
    UPDATE tables SET status = 'available', updated_at = now() WHERE id = v_table_id;
  END IF;

  -- 재고 자동차감
  FOR v_item IN
    SELECT oi.id AS order_item_id, oi.menu_item_id, oi.quantity AS ordered_qty
    FROM order_items oi
    WHERE oi.order_id = p_order_id AND oi.menu_item_id IS NOT NULL
  LOOP
    FOR v_recipe IN
      SELECT mr.ingredient_id, mr.quantity_g
      FROM menu_recipes mr
      WHERE mr.menu_item_id = v_item.menu_item_id AND mr.restaurant_id = p_restaurant_id
    LOOP
      v_deduct_qty := v_item.ordered_qty * v_recipe.quantity_g;
      UPDATE inventory_items
      SET current_stock = current_stock - v_deduct_qty, updated_at = now()
      WHERE id = v_recipe.ingredient_id AND restaurant_id = p_restaurant_id;
      INSERT INTO inventory_transactions
        (restaurant_id, ingredient_id, transaction_type, quantity_g, reference_type, reference_id, created_by)
      VALUES
        (p_restaurant_id, v_recipe.ingredient_id, 'deduct', -v_deduct_qty, 'order_item', v_item.order_item_id, auth.uid());
    END LOOP;
  END LOOP;

  RETURN v_payment;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

Run: echo "Y" | supabase db push


## 1-B: InventoryService
Create: lib/core/services/inventory_service.dart

```dart
import '../../main.dart';

class InventoryService {

  // ── 원재료 ────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> fetchIngredients(String restaurantId) async {
    final r = await supabase.from('inventory_items')
        .select().eq('restaurant_id', restaurantId).order('name');
    return List<Map<String, dynamic>>.from(r as List);
  }

  Future<void> createIngredient({
    required String restaurantId, required String name, required String unit,
    double? currentStock, double? reorderPoint, double? costPerUnit, String? supplierName,
  }) async {
    await supabase.from('inventory_items').insert({
      'restaurant_id': restaurantId, 'name': name, 'unit': unit,
      'quantity': 0,
      if (currentStock != null) 'current_stock': currentStock,
      if (reorderPoint != null) 'reorder_point': reorderPoint,
      if (costPerUnit != null) 'cost_per_unit': costPerUnit,
      if (supplierName != null) 'supplier_name': supplierName,
    });
  }

  Future<void> updateIngredient(String id, Map<String, dynamic> data) async {
    await supabase.from('inventory_items').update(data).eq('id', id);
  }

  Future<void> restockIngredient({
    required String restaurantId, required String ingredientId,
    required double quantityG, String? note, String? userId,
  }) async {
    // 1. current_stock 증가
    final current = await supabase.from('inventory_items')
        .select('current_stock').eq('id', ingredientId).single();
    final newStock = ((current['current_stock'] as num?)?.toDouble() ?? 0) + quantityG;
    await supabase.from('inventory_items')
        .update({'current_stock': newStock, 'updated_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', ingredientId);
    // 2. 이력 기록
    await supabase.from('inventory_transactions').insert({
      'restaurant_id': restaurantId, 'ingredient_id': ingredientId,
      'transaction_type': 'restock', 'quantity_g': quantityG,
      'reference_type': 'manual', 'note': note, 'created_by': userId,
    });
  }

  // ── 배합비 ────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> fetchAllRecipes(String restaurantId) async {
    final r = await supabase.from('menu_recipes')
        .select('*, menu_items(id, name), inventory_items(id, name, unit)')
        .eq('restaurant_id', restaurantId);
    return List<Map<String, dynamic>>.from(r as List);
  }

  Future<List<Map<String, dynamic>>> fetchRecipesForMenu(String menuItemId) async {
    final r = await supabase.from('menu_recipes')
        .select('*, inventory_items(id, name, unit)').eq('menu_item_id', menuItemId);
    return List<Map<String, dynamic>>.from(r as List);
  }

  Future<void> upsertRecipe({
    required String restaurantId, required String menuItemId,
    required String ingredientId, required double quantityG,
  }) async {
    await supabase.from('menu_recipes').upsert({
      'restaurant_id': restaurantId, 'menu_item_id': menuItemId,
      'ingredient_id': ingredientId, 'quantity_g': quantityG,
    }, onConflict: 'menu_item_id,ingredient_id');
  }

  Future<void> deleteRecipe(String menuItemId, String ingredientId) async {
    await supabase.from('menu_recipes')
        .delete().eq('menu_item_id', menuItemId).eq('ingredient_id', ingredientId);
  }

  // ── 실재고 실사 ────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> fetchPhysicalCounts(
      String restaurantId, String countDate) async {
    final r = await supabase.from('inventory_physical_counts')
        .select('*, inventory_items(id, name, unit)')
        .eq('restaurant_id', restaurantId).eq('count_date', countDate);
    return List<Map<String, dynamic>>.from(r as List);
  }

  Future<void> submitPhysicalCount({
    required String restaurantId, required String ingredientId,
    required String countDate, required double actualQty,
    required double theoreticalQty, String? userId,
  }) async {
    final variance = actualQty - theoreticalQty;
    await supabase.from('inventory_physical_counts').upsert({
      'restaurant_id': restaurantId, 'ingredient_id': ingredientId,
      'count_date': countDate, 'actual_quantity_g': actualQty,
      'theoretical_quantity_g': theoreticalQty, 'variance_g': variance, 'counted_by': userId,
    }, onConflict: 'ingredient_id,count_date');
    // current_stock 실측값으로 보정
    await supabase.from('inventory_items')
        .update({'current_stock': actualQty, 'updated_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', ingredientId);
    await supabase.from('inventory_transactions').insert({
      'restaurant_id': restaurantId, 'ingredient_id': ingredientId,
      'transaction_type': 'adjust', 'quantity_g': variance,
      'reference_type': 'physical_count', 'note': '실재고 실사 ($countDate)', 'created_by': userId,
    });
  }

  // ── 리포트 ────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> fetchTransactions({
    required String restaurantId, required DateTime from, required DateTime to,
  }) async {
    final r = await supabase.from('inventory_transactions')
        .select('*, inventory_items(id, name, unit)')
        .eq('restaurant_id', restaurantId)
        .gte('created_at', from.toIso8601String())
        .lte('created_at', to.toIso8601String())
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(r as List);
  }
}

final inventoryService = InventoryService();
```


## 1-C: InventoryProvider
Create: lib/features/inventory/inventory_provider.dart

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/services/inventory_service.dart';

// ── 원재료 Provider ───────────────────────────────────────
class IngredientState {
  final List<Map<String, dynamic>> items;
  final bool isLoading;
  final String? error;
  const IngredientState({this.items = const [], this.isLoading = false, this.error});
  IngredientState copyWith({List<Map<String, dynamic>>? items, bool? isLoading, String? error, bool clearError = false}) =>
      IngredientState(items: items ?? this.items, isLoading: isLoading ?? this.isLoading,
          error: clearError ? null : (error ?? this.error));
}
class IngredientNotifier extends StateNotifier<IngredientState> {
  IngredientNotifier() : super(const IngredientState());
  Future<void> load(String restaurantId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final items = await inventoryService.fetchIngredients(restaurantId);
      state = state.copyWith(items: items, isLoading: false);
    } catch (e) { state = state.copyWith(isLoading: false, error: e.toString()); }
  }
  Future<void> add({required String restaurantId, required String name, required String unit,
      double? currentStock, double? reorderPoint, double? costPerUnit, String? supplierName}) async {
    await inventoryService.createIngredient(restaurantId: restaurantId, name: name, unit: unit,
        currentStock: currentStock, reorderPoint: reorderPoint, costPerUnit: costPerUnit, supplierName: supplierName);
    await load(restaurantId);
  }
  Future<void> update(String id, String restaurantId, Map<String, dynamic> data) async {
    await inventoryService.updateIngredient(id, data);
    await load(restaurantId);
  }
  Future<void> restock(String restaurantId, String ingredientId, double qty, String? note, String? userId) async {
    await inventoryService.restockIngredient(restaurantId: restaurantId,
        ingredientId: ingredientId, quantityG: qty, note: note, userId: userId);
    await load(restaurantId);
  }
}
final ingredientProvider = StateNotifierProvider<IngredientNotifier, IngredientState>((ref) => IngredientNotifier());

// ── 배합비 Provider ───────────────────────────────────────
class RecipeState {
  final List<Map<String, dynamic>> allRecipes;
  final bool isLoading;
  final String? error;
  const RecipeState({this.allRecipes = const [], this.isLoading = false, this.error});
  RecipeState copyWith({List<Map<String, dynamic>>? allRecipes, bool? isLoading, String? error, bool clearError = false}) =>
      RecipeState(allRecipes: allRecipes ?? this.allRecipes, isLoading: isLoading ?? this.isLoading,
          error: clearError ? null : (error ?? this.error));
}
class RecipeNotifier extends StateNotifier<RecipeState> {
  RecipeNotifier() : super(const RecipeState());
  Future<void> loadAll(String restaurantId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final r = await inventoryService.fetchAllRecipes(restaurantId);
      state = state.copyWith(allRecipes: r, isLoading: false);
    } catch (e) { state = state.copyWith(isLoading: false, error: e.toString()); }
  }
  Future<void> upsert({required String restaurantId, required String menuItemId,
      required String ingredientId, required double quantityG}) async {
    await inventoryService.upsertRecipe(restaurantId: restaurantId, menuItemId: menuItemId,
        ingredientId: ingredientId, quantityG: quantityG);
    await loadAll(restaurantId);
  }
  Future<void> delete(String restaurantId, String menuItemId, String ingredientId) async {
    await inventoryService.deleteRecipe(menuItemId, ingredientId);
    await loadAll(restaurantId);
  }
}
final recipeProvider = StateNotifierProvider<RecipeNotifier, RecipeState>((ref) => RecipeNotifier());

// ── 실재고 실사 Provider ──────────────────────────────────
class PhysicalCountState {
  final List<Map<String, dynamic>> counts;
  final bool isLoading;
  final bool isSaving;
  final String? error;
  const PhysicalCountState({this.counts = const [], this.isLoading = false, this.isSaving = false, this.error});
  PhysicalCountState copyWith({List<Map<String, dynamic>>? counts, bool? isLoading, bool? isSaving, String? error, bool clearError = false}) =>
      PhysicalCountState(counts: counts ?? this.counts, isLoading: isLoading ?? this.isLoading,
          isSaving: isSaving ?? this.isSaving, error: clearError ? null : (error ?? this.error));
}
class PhysicalCountNotifier extends StateNotifier<PhysicalCountState> {
  PhysicalCountNotifier() : super(const PhysicalCountState());
  Future<void> load(String restaurantId, String countDate) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final c = await inventoryService.fetchPhysicalCounts(restaurantId, countDate);
      state = state.copyWith(counts: c, isLoading: false);
    } catch (e) { state = state.copyWith(isLoading: false, error: e.toString()); }
  }
  Future<void> submit({required String restaurantId, required String ingredientId,
      required String countDate, required double actualQty, required double theoreticalQty, String? userId}) async {
    state = state.copyWith(isSaving: true);
    try {
      await inventoryService.submitPhysicalCount(restaurantId: restaurantId,
          ingredientId: ingredientId, countDate: countDate, actualQty: actualQty,
          theoreticalQty: theoreticalQty, userId: userId);
      await load(restaurantId, countDate);
    } catch (e) { state = state.copyWith(isSaving: false, error: e.toString()); }
  }
}
final physicalCountProvider = StateNotifierProvider<PhysicalCountNotifier, PhysicalCountState>((ref) => PhysicalCountNotifier());
```


## 1-D: Admin Inventory Tab
Create: lib/features/admin/tabs/inventory_tab.dart

Add "재고" tab to Admin screen (Web sidebar + Android BottomNav).
Icon: Icons.inventory_2_outlined

Four sub-tabs via TabBar: ["원재료 관리", "배합비 관리", "실재고 실사", "재고 리포트"]

### Sub-tab 1: 원재료 관리
- Load ingredientProvider on init
- List of ingredient cards:
  - Name, unit, current_stock display
  - Red border + "⚠️ 발주 필요" when current_stock <= reorder_point
  - Deep red bg + "재고 없음" when current_stock <= 0
  - [입고] [수정] [삭제] buttons per row
- FAB or top-right button: [+ 원재료 추가]
- Add/Edit Dialog fields: 이름, 단위(g/ml/ea dropdown), 현재고, 발주기준, 단가(VND), 공급처
- Restock Dialog: 입고량 NumberField + 메모 TextField

### Sub-tab 2: 배합비 관리
- Dropdown: select menu_item (from supabase menu_items for this restaurant)
- When selected: show recipe rows for that menu
  - Table: [원재료명] [사용량 + 단위] [삭제 버튼]
- [+ 원재료 추가] button → row with: ingredient dropdown + quantity NumberField + [저장]
- On save: recipeProvider.upsert(...)

### Sub-tab 3: 실재고 실사
- Date picker (default: today in VN timezone)
- [실사 시작] button → loads all ingredients
- For each ingredient:
  - Name + 이론재고 (current_stock from DB) label
  - Large NumberField for 실측재고 entry
- Progress indicator: "X / Y 입력 완료"
- [전체 저장] button → submit all at once
- After save: show summary snackbar "저장 완료: X개, 손실 Y개, 잉여 Z개"
- Pre-populate existing counts if already entered today

### Sub-tab 4: 재고 리포트
- Date range picker: From ~ To + [적용]
- Summary cards row:
  - 총 차감량 (sum of deduct transactions)
  - 총 입고량 (sum of restock transactions)
  - 총 손실량 (sum of variance_g from physical_counts, negatives only)
- Table: 원재료 | 이론차감 | 실측조정 | 손실량 | 손실률%
- Reorder alert section at bottom: list of ingredients where current_stock <= reorder_point

---

# ═══════════════════════════════════════════
# ITEM 2: QC / INVENTORY SEPARATE PERMISSIONS
# ═══════════════════════════════════════════

## 2-A: DB Migration
Add to: supabase/migrations/20260403000003_permissions.sql

```sql
-- users 테이블에 extra_permissions 컬럼 추가
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS extra_permissions TEXT[] DEFAULT '{}';

-- extra_permissions 가능한 값:
-- 'qc_check'       — QC 점검 수행 가능 (점검 입력 화면 접근)
-- 'inventory_count' — 실재고 실사 수행 가능
-- 기본적으로 admin/super_admin은 모든 권한 보유
-- waiter/kitchen/cashier는 admin이 부여해야 접근 가능

-- restaurant_settings 테이블 (급여 PIN 등 매장 설정)
CREATE TABLE IF NOT EXISTS restaurant_settings (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id   UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE UNIQUE,
  payroll_pin     TEXT,   -- bcrypt hash of 4-6 digit PIN
  settings_json   JSONB DEFAULT '{}',
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE restaurant_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admin_only" ON restaurant_settings
  USING (restaurant_id = get_user_restaurant_id() AND has_any_role(ARRAY['admin','super_admin']));
```

Run: echo "Y" | supabase db push

## 2-B: Permission Helper
Create: lib/core/utils/permission_utils.dart

```dart
class PermissionUtils {
  // Check if user has a specific extra permission
  // admin/super_admin always return true regardless of extra_permissions
  static bool hasPermission(String? role, List<String> extraPermissions, String permission) {
    if (role == 'admin' || role == 'super_admin') return true;
    return extraPermissions.contains(permission);
  }

  static bool canDoQcCheck(String? role, List<String> extraPermissions) =>
      hasPermission(role, extraPermissions, 'qc_check');

  static bool canDoInventoryCount(String? role, List<String> extraPermissions) =>
      hasPermission(role, extraPermissions, 'inventory_count');
}
```

## 2-C: AuthProvider Update
In lib/features/auth/auth_provider.dart:

AuthState already has `role`. Add `extraPermissions` field:
```dart
// In AuthState:
final List<String> extraPermissions; // default []

// In AuthNotifier._fetchUserData():
// When fetching user from users table, also fetch extra_permissions column
// extra_permissions is TEXT[] in DB → List<String> in Dart
```

## 2-D: Admin Staff Tab — Permission Management UI
In lib/features/admin/tabs/staff_tab.dart:

For each non-admin staff member, add a "권한 설정" button/section in their detail view or edit dialog:
- Checkboxes:
  - [x] QC 점검 수행 가능 (qc_check)
  - [x] 실재고 실사 수행 가능 (inventory_count)
- On save: UPDATE users SET extra_permissions = '{qc_check,inventory_count}' WHERE id = ...

## 2-E: Route Guards
In lib/core/router/app_router.dart and relevant screens:

- `/qc-check` route: allow if canDoQcCheck(role, extraPermissions) OR role is admin/super_admin
- Inventory 실재고 실사 sub-tab: show/hide based on canDoInventoryCount
- QC 점검 tab in admin: always visible to admin/super_admin
- If unauthorized user tries to access: show "권한이 없습니다. 관리자에게 문의하세요." and redirect

---

# ═══════════════════════════════════════════
# ITEM 3: PAYROLL PIN PROTECTION
# ═══════════════════════════════════════════

## 3-A: PIN Flow Design

```
[Admin] 급여 관리 탭 진입
  ↓
PIN이 설정되어 있는지 확인 (restaurant_settings.payroll_pin IS NOT NULL)
  ↓
설정된 경우:
  PIN 입력 다이얼로그 표시
  4자리 숫자 입력 (숫자 키패드 UI)
  [확인] → PIN 검증 → 맞으면 급여 탭 열림, 틀리면 "PIN이 올바르지 않습니다"
  3회 실패 시: "잠시 후 다시 시도하세요" (30초 대기)

설정 안 된 경우:
  바로 급여 탭 열림
```

## 3-B: PIN Setting UI
In Admin 설정 탭 (settings_tab.dart):

Add a "급여 관리 PIN 설정" section:
```
현재 상태: [설정됨 ✅] 또는 [미설정]

[PIN 변경] button → Dialog:
  새 PIN (4자리 숫자): [____]
  PIN 확인: [____]
  [저장] → hash PIN → upsert restaurant_settings
  [PIN 삭제] (현재 PIN 입력 후 삭제)
```

## 3-C: PinService
Create: lib/core/services/pin_service.dart

```dart
import 'dart:convert';
import 'package:crypto/crypto.dart'; // add crypto: ^3.0.3 to pubspec
import '../../main.dart';

class PinService {
  // Hash PIN using SHA-256 (simple, sufficient for 4-digit PIN)
  String hashPin(String pin) {
    final bytes = utf8.encode(pin);
    return sha256.convert(bytes).toString();
  }

  // Fetch current PIN hash for restaurant
  Future<String?> fetchPinHash(String restaurantId) async {
    try {
      final r = await supabase.from('restaurant_settings')
          .select('payroll_pin').eq('restaurant_id', restaurantId).maybeSingle();
      return r?['payroll_pin'] as String?;
    } catch (_) { return null; }
  }

  // Verify entered PIN against stored hash
  Future<bool> verifyPin(String restaurantId, String enteredPin) async {
    final stored = await fetchPinHash(restaurantId);
    if (stored == null) return true; // no PIN set = open
    return hashPin(enteredPin) == stored;
  }

  // Save/update PIN
  Future<void> setPin(String restaurantId, String pin) async {
    await supabase.from('restaurant_settings').upsert({
      'restaurant_id': restaurantId,
      'payroll_pin': hashPin(pin),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'restaurant_id');
  }

  // Remove PIN
  Future<void> clearPin(String restaurantId) async {
    await supabase.from('restaurant_settings').upsert({
      'restaurant_id': restaurantId,
      'payroll_pin': null,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'restaurant_id');
  }
}

final pinService = PinService();
```

Add to pubspec.yaml: crypto: ^3.0.3

## 3-D: PIN Dialog Widget
Create: lib/widgets/pin_dialog.dart

```dart
// A numeric keypad PIN entry dialog
// Shows 4 circles (○ ○ ○ ○) that fill as user enters digits
// Numeric buttons 0-9 + backspace + confirm
// Returns the entered PIN string or null if cancelled
// Usage: final pin = await showPinDialog(context, title: '급여 관리 PIN 입력');

Future<String?> showPinDialog(BuildContext context, {String title = 'PIN 입력'}) async {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _PinDialog(title: title),
  );
}

class _PinDialog extends StatefulWidget { ... }
// PIN length: 4 digits
// Style: dark dialog matching AppColors theme
// Confirm button only enabled when 4 digits entered
```

## 3-E: Payroll Tab PIN Gate
In lib/features/admin/tabs/attendance_tab.dart (payroll sub-tab):

Wrap the payroll sub-tab content with a PIN gate:

```dart
// State: bool _payrollUnlocked = false;

// When user taps "급여 관리" sub-tab:
if (!_payrollUnlocked) {
  // Check if PIN is set
  final hasPin = await pinService.fetchPinHash(restaurantId) != null;
  if (hasPin) {
    final pin = await showPinDialog(context, title: '급여 관리 PIN 입력');
    if (pin == null) { /* user cancelled, switch back to 근태기록 tab */ return; }
    final ok = await pinService.verifyPin(restaurantId, pin);
    if (!ok) {
      // increment fail count, show error
      showErrorToast(context, 'PIN이 올바르지 않습니다.');
      return;
    }
  }
  setState(() => _payrollUnlocked = true);
}
// Once unlocked, show payroll content normally
// Reset _payrollUnlocked = false when tab is disposed or admin logs out
```

---

# ═══════════════════════════════════════════
# FINAL STEPS
# ═══════════════════════════════════════════

1. Add to pubspec.yaml if not present: crypto: ^3.0.3
2. echo "Y" | supabase db push  (runs migrations 20260403000002 and 20260403000003)
3. flutter analyze → 0 errors
4. flutter build macos → pass
5. flutter build web --release → pass
6. flutter build apk --release → pass
7. vercel deploy build/web --prod --yes
8. git add -A && git commit -m "feat: Inventory 2.0, QC/Inventory permissions, Payroll PIN protection" && git push
