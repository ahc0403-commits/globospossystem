# Flexible Floor Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> [NEW UI SOURCE OF TRUTH]
> The current UI source of truth is
> [docs/office/TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md](../../office/TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md).
> Follow the Queue -> Select -> Act -> Optional Detail model.
> Preserve business logic, permissions, auth, route paths where possible,
> i18n, and data contracts.
> Do not use dashboard-first, KPI-first, card-heavy, panel-heavy, dark-admin,
> browser-like POS, or CRUD-first standards as the baseline.

**Goal:** Replace fixed POS table grids with a store-specific floor layout where admins can place, size, and edit tables to match the real restaurant floor, and waiters can use that same layout for live ordering.

**Architecture:** Store layout metadata directly on `public.tables` so existing table/order relations, RLS, realtime, and admin RPC boundaries stay intact. Add normalized canvas fields (`layout_x`, `layout_y`, `layout_w`, `layout_h`, `layout_rotation`, `layout_shape`, `layout_sort_order`) and a shared Flutter floor-plan widget that can render either an interactive editor or read-only waiter floor. Preserve `table_number`, `seat_count`, and `status` as the operational source of truth.

**UI Standard Override:** The floor canvas and table-card presentation are implementation options, not mandatory visual structure. The table workflow may be redesigned as a Toast-style table queue, table map, list/detail split workflow, or hybrid operations surface as long as table/order/payment data contracts, permissions, realtime behavior, and business logic remain intact.

**Tech Stack:** Flutter, Riverpod, Supabase Postgres/RLS/RPCs, Flutter widget tests, existing admin audit logs.

---

## Current State

The current implementation is table-list driven:

- `public.tables` has only identity, `restaurant_id`, `table_number`, `seat_count`, `status`, timestamps, and a per-store table-number unique constraint.
- `lib/core/models/pos_table.dart` models only `id`, `storeId`, `tableNumber`, `seatCount`, and `status`.
- `lib/features/table/table_provider.dart` fetches waiter tables ordered by `table_number` and keeps realtime insert/update/delete subscriptions.
- `lib/features/waiter/waiter_screen.dart` renders `_TableGridView` with a responsive `GridView.builder`.
- `lib/features/admin/tabs/tables_tab.dart` renders another fixed two-column `GridView.builder`, with add/delete table actions.
- `lib/core/services/tables_service.dart` wraps `admin_create_table`, `admin_update_table`, and `admin_delete_table`.

The change should keep all table/order/payment flows working. Visual arrangement is not limited to a floor canvas: Toast-style navigation, table queue/list/detail split workflows, action rails, and dense operational table surfaces may replace the older grid/card/tablet visual model.

## File Structure

- Modify `supabase/migrations/20260502000000_table_floor_layout.sql`: add layout columns and update table RPCs.
- Modify `lib/core/models/pos_table.dart`: parse and expose layout metadata.
- Modify `lib/core/services/tables_service.dart`: fetch by layout order and add `updateTableLayout`.
- Modify `lib/features/table/table_provider.dart`: sort by layout order and realtime layout fields.
- Modify `lib/features/admin/providers/tables_provider.dart`: add layout update method and preserve active order summaries.
- Create `lib/features/table/floor_layout.dart`: shared floor canvas, table tile, scaling, drag bounds, and layout helpers.
- Modify `lib/features/waiter/waiter_screen.dart`: replace `_TableGridView` fixed grid with read-only `FloorLayoutView`.
- Modify `lib/features/admin/tabs/tables_tab.dart`: replace fixed grid with editable layout mode and save/reset controls.
- Modify `lib/features/admin/widgets/admin_audit_trace_panel.dart`: label new layout fields in audit details.
- Add `test/table_layout_model_contract_test.dart`: model parsing and fallback defaults.
- Add `test/table_layout_sql_contract_test.dart`: migration/RPC contract checks.
- Add `test/waiter_floor_layout_contract_test.dart`: waiter screen no longer uses the fixed grid path.
- Add `test/admin_table_layout_editor_contract_test.dart`: admin editor exposes layout update path and audit field names.

## Data Model Decision

Use normalized coordinates instead of pixels:

- `layout_x NUMERIC(6,4) NOT NULL DEFAULT 0`
- `layout_y NUMERIC(6,4) NOT NULL DEFAULT 0`
- `layout_w NUMERIC(6,4) NOT NULL DEFAULT 0.18`
- `layout_h NUMERIC(6,4) NOT NULL DEFAULT 0.14`
- `layout_rotation INT NOT NULL DEFAULT 0`
- `layout_shape TEXT NOT NULL DEFAULT 'rectangle' CHECK (layout_shape IN ('rectangle','round'))`
- `layout_sort_order INT NOT NULL DEFAULT 0`

`layout_x/y/w/h` represent fractions of the floor canvas. This lets the same data render on tablet, desktop, web, and mobile without per-device layouts. For existing stores, backfill a simple grid with deterministic positions so no current table disappears.

---

### Task 1: Database Layout Fields and RPC Contract

**Files:**
- Create: `supabase/migrations/20260502000000_table_floor_layout.sql`
- Test: `test/table_layout_sql_contract_test.dart`

- [ ] **Step 1: Write the failing SQL contract test**

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('table floor layout migration adds normalized layout fields and RPC support', () {
    final migration = readRepoFile(
      'supabase/migrations/20260502000000_table_floor_layout.sql',
    );

    expect(migration, contains('layout_x NUMERIC(6,4)'));
    expect(migration, contains('layout_y NUMERIC(6,4)'));
    expect(migration, contains('layout_w NUMERIC(6,4)'));
    expect(migration, contains('layout_h NUMERIC(6,4)'));
    expect(migration, contains('layout_rotation INT'));
    expect(migration, contains("layout_shape TEXT"));
    expect(migration, contains('layout_sort_order INT'));
    expect(migration, contains('CHECK (layout_shape IN'));
    expect(migration, contains('p_layout_x NUMERIC DEFAULT NULL'));
    expect(migration, contains('p_layout_y NUMERIC DEFAULT NULL'));
    expect(migration, contains('admin_update_table'));
    expect(migration, contains("'layout_x'"));
    expect(migration, contains("'layout_y'"));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/table_layout_sql_contract_test.dart`

Expected: FAIL because the migration file does not exist yet.

- [ ] **Step 3: Add the migration**

Create `supabase/migrations/20260502000000_table_floor_layout.sql` with:

```sql
-- ============================================================
-- Table floor layout metadata
-- 2026-05-02
-- Adds normalized layout fields to public.tables and extends
-- admin table RPCs without changing existing order/table FKs.
-- ============================================================

ALTER TABLE public.tables
  ADD COLUMN IF NOT EXISTS layout_x NUMERIC(6,4) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS layout_y NUMERIC(6,4) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS layout_w NUMERIC(6,4) NOT NULL DEFAULT 0.18,
  ADD COLUMN IF NOT EXISTS layout_h NUMERIC(6,4) NOT NULL DEFAULT 0.14,
  ADD COLUMN IF NOT EXISTS layout_rotation INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS layout_shape TEXT NOT NULL DEFAULT 'rectangle',
  ADD COLUMN IF NOT EXISTS layout_sort_order INT NOT NULL DEFAULT 0;

ALTER TABLE public.tables
  DROP CONSTRAINT IF EXISTS tables_layout_bounds_check;

ALTER TABLE public.tables
  ADD CONSTRAINT tables_layout_bounds_check
  CHECK (
    layout_x >= 0 AND layout_x <= 1 AND
    layout_y >= 0 AND layout_y <= 1 AND
    layout_w > 0 AND layout_w <= 1 AND
    layout_h > 0 AND layout_h <= 1 AND
    layout_x + layout_w <= 1 AND
    layout_y + layout_h <= 1 AND
    layout_rotation >= -180 AND layout_rotation <= 180 AND
    layout_shape IN ('rectangle', 'round')
  );

WITH ranked AS (
  SELECT
    id,
    row_number() OVER (
      PARTITION BY restaurant_id
      ORDER BY table_number
    ) - 1 AS index_zero
  FROM public.tables
)
UPDATE public.tables t
SET
  layout_x = ((ranked.index_zero % 4) * 0.22)::NUMERIC(6,4),
  layout_y = ((ranked.index_zero / 4) * 0.18)::NUMERIC(6,4),
  layout_w = 0.18,
  layout_h = 0.14,
  layout_sort_order = ranked.index_zero
FROM ranked
WHERE ranked.id = t.id
  AND t.layout_sort_order = 0
  AND t.layout_x = 0
  AND t.layout_y = 0;

CREATE INDEX IF NOT EXISTS idx_tables_restaurant_layout_sort
  ON public.tables (restaurant_id, layout_sort_order, table_number);

CREATE OR REPLACE FUNCTION public.admin_update_table(
  p_table_id UUID,
  p_table_number TEXT DEFAULT NULL,
  p_seat_count INT DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_layout_x NUMERIC DEFAULT NULL,
  p_layout_y NUMERIC DEFAULT NULL,
  p_layout_w NUMERIC DEFAULT NULL,
  p_layout_h NUMERIC DEFAULT NULL,
  p_layout_rotation INT DEFAULT NULL,
  p_layout_shape TEXT DEFAULT NULL,
  p_layout_sort_order INT DEFAULT NULL
) RETURNS public.tables AS $$
DECLARE
  v_existing public.tables%ROWTYPE;
  v_updated public.tables%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_table_number TEXT := NULLIF(btrim(COALESCE(p_table_number, '')), '');
  v_layout_shape TEXT := NULLIF(btrim(COALESCE(p_layout_shape, '')), '');
BEGIN
  IF p_table_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_ID_REQUIRED';
  END IF;

  SELECT * INTO v_existing
  FROM public.tables
  WHERE id = p_table_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);

  IF p_table_number IS NOT NULL THEN
    IF v_table_number IS NULL THEN
      RAISE EXCEPTION 'TABLE_NUMBER_REQUIRED';
    END IF;
    IF v_table_number IS DISTINCT FROM v_existing.table_number THEN
      v_changed_fields := array_append(v_changed_fields, 'table_number');
      v_old_values := v_old_values || jsonb_build_object('table_number', v_existing.table_number);
      v_new_values := v_new_values || jsonb_build_object('table_number', v_table_number);
    END IF;
  ELSE
    v_table_number := v_existing.table_number;
  END IF;

  IF p_seat_count IS NOT NULL AND p_seat_count IS DISTINCT FROM v_existing.seat_count THEN
    v_changed_fields := array_append(v_changed_fields, 'seat_count');
    v_old_values := v_old_values || jsonb_build_object('seat_count', v_existing.seat_count);
    v_new_values := v_new_values || jsonb_build_object('seat_count', p_seat_count);
  END IF;

  IF p_status IS NOT NULL AND p_status IS DISTINCT FROM v_existing.status THEN
    v_changed_fields := array_append(v_changed_fields, 'status');
    v_old_values := v_old_values || jsonb_build_object('status', v_existing.status);
    v_new_values := v_new_values || jsonb_build_object('status', p_status);
  END IF;

  IF p_layout_x IS NOT NULL AND p_layout_x IS DISTINCT FROM v_existing.layout_x THEN
    v_changed_fields := array_append(v_changed_fields, 'layout_x');
    v_old_values := v_old_values || jsonb_build_object('layout_x', v_existing.layout_x);
    v_new_values := v_new_values || jsonb_build_object('layout_x', p_layout_x);
  END IF;

  IF p_layout_y IS NOT NULL AND p_layout_y IS DISTINCT FROM v_existing.layout_y THEN
    v_changed_fields := array_append(v_changed_fields, 'layout_y');
    v_old_values := v_old_values || jsonb_build_object('layout_y', v_existing.layout_y);
    v_new_values := v_new_values || jsonb_build_object('layout_y', p_layout_y);
  END IF;

  IF p_layout_w IS NOT NULL AND p_layout_w IS DISTINCT FROM v_existing.layout_w THEN
    v_changed_fields := array_append(v_changed_fields, 'layout_w');
    v_old_values := v_old_values || jsonb_build_object('layout_w', v_existing.layout_w);
    v_new_values := v_new_values || jsonb_build_object('layout_w', p_layout_w);
  END IF;

  IF p_layout_h IS NOT NULL AND p_layout_h IS DISTINCT FROM v_existing.layout_h THEN
    v_changed_fields := array_append(v_changed_fields, 'layout_h');
    v_old_values := v_old_values || jsonb_build_object('layout_h', v_existing.layout_h);
    v_new_values := v_new_values || jsonb_build_object('layout_h', p_layout_h);
  END IF;

  IF p_layout_rotation IS NOT NULL AND p_layout_rotation IS DISTINCT FROM v_existing.layout_rotation THEN
    v_changed_fields := array_append(v_changed_fields, 'layout_rotation');
    v_old_values := v_old_values || jsonb_build_object('layout_rotation', v_existing.layout_rotation);
    v_new_values := v_new_values || jsonb_build_object('layout_rotation', p_layout_rotation);
  END IF;

  IF p_layout_shape IS NOT NULL THEN
    IF v_layout_shape NOT IN ('rectangle', 'round') THEN
      RAISE EXCEPTION 'TABLE_LAYOUT_SHAPE_INVALID';
    END IF;
    IF v_layout_shape IS DISTINCT FROM v_existing.layout_shape THEN
      v_changed_fields := array_append(v_changed_fields, 'layout_shape');
      v_old_values := v_old_values || jsonb_build_object('layout_shape', v_existing.layout_shape);
      v_new_values := v_new_values || jsonb_build_object('layout_shape', v_layout_shape);
    END IF;
  ELSE
    v_layout_shape := v_existing.layout_shape;
  END IF;

  IF p_layout_sort_order IS NOT NULL AND p_layout_sort_order IS DISTINCT FROM v_existing.layout_sort_order THEN
    v_changed_fields := array_append(v_changed_fields, 'layout_sort_order');
    v_old_values := v_old_values || jsonb_build_object('layout_sort_order', v_existing.layout_sort_order);
    v_new_values := v_new_values || jsonb_build_object('layout_sort_order', p_layout_sort_order);
  END IF;

  UPDATE public.tables
  SET table_number = v_table_number,
      seat_count = COALESCE(p_seat_count, v_existing.seat_count),
      status = COALESCE(p_status, v_existing.status),
      layout_x = COALESCE(p_layout_x, v_existing.layout_x),
      layout_y = COALESCE(p_layout_y, v_existing.layout_y),
      layout_w = COALESCE(p_layout_w, v_existing.layout_w),
      layout_h = COALESCE(p_layout_h, v_existing.layout_h),
      layout_rotation = COALESCE(p_layout_rotation, v_existing.layout_rotation),
      layout_shape = v_layout_shape,
      layout_sort_order = COALESCE(p_layout_sort_order, v_existing.layout_sort_order),
      updated_at = now()
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_table',
      'tables',
      v_updated.id,
      jsonb_build_object(
        'store_id', v_updated.restaurant_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
```

- [ ] **Step 4: Run SQL contract test**

Run: `flutter test test/table_layout_sql_contract_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260502000000_table_floor_layout.sql test/table_layout_sql_contract_test.dart
git commit -m "feat: add table floor layout schema"
```

---

### Task 2: Model, Service, and Provider Layout Support

**Files:**
- Modify: `lib/core/models/pos_table.dart`
- Modify: `lib/core/services/tables_service.dart`
- Modify: `lib/features/table/table_provider.dart`
- Modify: `lib/features/admin/providers/tables_provider.dart`
- Test: `test/table_layout_model_contract_test.dart`

- [ ] **Step 1: Write the failing model contract test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/models/pos_table.dart';

void main() {
  test('PosTable parses normalized floor layout fields with defaults', () {
    final table = PosTable.fromJson({
      'id': 'table-1',
      'restaurant_id': 'store-1',
      'table_number': 'A1',
      'seat_count': 4,
      'status': 'available',
      'layout_x': '0.2500',
      'layout_y': 0.5,
      'layout_w': '0.1800',
      'layout_h': 0.14,
      'layout_rotation': '15',
      'layout_shape': 'round',
      'layout_sort_order': '7',
    });

    expect(table.layoutX, 0.25);
    expect(table.layoutY, 0.5);
    expect(table.layoutW, 0.18);
    expect(table.layoutH, 0.14);
    expect(table.layoutRotation, 15);
    expect(table.layoutShape, PosTableShape.round);
    expect(table.layoutSortOrder, 7);
  });

  test('PosTable falls back to visible layout defaults', () {
    final table = PosTable.fromJson({
      'id': 'table-1',
      'restaurant_id': 'store-1',
      'table_number': 'A1',
    });

    expect(table.layoutX, 0);
    expect(table.layoutY, 0);
    expect(table.layoutW, 0.18);
    expect(table.layoutH, 0.14);
    expect(table.layoutRotation, 0);
    expect(table.layoutShape, PosTableShape.rectangle);
    expect(table.layoutSortOrder, 0);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/table_layout_model_contract_test.dart`

Expected: FAIL because layout fields do not exist.

- [ ] **Step 3: Extend `PosTable`**

Add `PosTableShape`, layout fields, and parsers:

```dart
enum PosTableShape { rectangle, round }

class PosTable {
  const PosTable({
    required this.id,
    required this.storeId,
    required this.tableNumber,
    required this.seatCount,
    required this.status,
    required this.layoutX,
    required this.layoutY,
    required this.layoutW,
    required this.layoutH,
    required this.layoutRotation,
    required this.layoutShape,
    required this.layoutSortOrder,
  });

  final String id;
  final String storeId;
  final String tableNumber;
  final int? seatCount;
  final String status;
  final double layoutX;
  final double layoutY;
  final double layoutW;
  final double layoutH;
  final int layoutRotation;
  final PosTableShape layoutShape;
  final int layoutSortOrder;

  bool get isOccupied => status.toLowerCase() == 'occupied';

  static double _doubleValue(dynamic value, double fallback) {
    return switch (value) {
      num raw => raw.toDouble(),
      String raw => double.tryParse(raw) ?? fallback,
      _ => fallback,
    };
  }

  static int _intValue(dynamic value, int fallback) {
    return switch (value) {
      int raw => raw,
      num raw => raw.toInt(),
      String raw => int.tryParse(raw) ?? fallback,
      _ => fallback,
    };
  }

  static PosTableShape _shapeValue(dynamic value) {
    return value?.toString().toLowerCase() == 'round'
        ? PosTableShape.round
        : PosTableShape.rectangle;
  }
}
```

Then update `fromJson` to populate the new fields.

- [ ] **Step 4: Update service and providers**

Change table fetch ordering in `lib/core/services/tables_service.dart` and `lib/features/table/table_provider.dart`:

```dart
.order('layout_sort_order')
.order('table_number');
```

Add service method:

```dart
Future<void> updateTableLayout({
  required String tableId,
  required double layoutX,
  required double layoutY,
  required double layoutW,
  required double layoutH,
  required int layoutRotation,
  required String layoutShape,
  required int layoutSortOrder,
}) async {
  await supabase.rpc(
    'admin_update_table',
    params: {
      'p_table_id': tableId,
      'p_layout_x': layoutX,
      'p_layout_y': layoutY,
      'p_layout_w': layoutW,
      'p_layout_h': layoutH,
      'p_layout_rotation': layoutRotation,
      'p_layout_shape': layoutShape,
      'p_layout_sort_order': layoutSortOrder,
    },
  );
}
```

Add notifier method in `TablesNotifier`:

```dart
Future<bool> updateTableLayout({
  required String tableId,
  required double layoutX,
  required double layoutY,
  required double layoutW,
  required double layoutH,
  required int layoutRotation,
  required String layoutShape,
  required int layoutSortOrder,
}) async {
  try {
    await tablesService.updateTableLayout(
      tableId: tableId,
      layoutX: layoutX,
      layoutY: layoutY,
      layoutW: layoutW,
      layoutH: layoutH,
      layoutRotation: layoutRotation,
      layoutShape: layoutShape,
      layoutSortOrder: layoutSortOrder,
    );
    await fetchTables();
    return true;
  } catch (error) {
    state = state.copyWith(error: _mapTablesError(error, 'Failed to save table layout.'));
    return false;
  }
}
```

- [ ] **Step 5: Run focused tests**

Run:

```bash
flutter test test/table_layout_model_contract_test.dart test/waiter_table_realtime_contract_test.dart
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/core/models/pos_table.dart lib/core/services/tables_service.dart lib/features/table/table_provider.dart lib/features/admin/providers/tables_provider.dart test/table_layout_model_contract_test.dart
git commit -m "feat: wire table layout metadata"
```

---

### Task 3: Shared Floor Layout Widget

**Files:**
- Create: `lib/features/table/floor_layout.dart`
- Test: `test/waiter_floor_layout_contract_test.dart`

- [ ] **Step 1: Write the failing widget contract test**

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('waiter uses shared floor layout instead of fixed grid table rendering', () {
    final floorLayout = readRepoFile('lib/features/table/floor_layout.dart');
    final waiter = readRepoFile('lib/features/waiter/waiter_screen.dart');

    expect(floorLayout, contains('class FloorLayoutView'));
    expect(floorLayout, contains('Positioned('));
    expect(floorLayout, contains('onTableMoved'));
    expect(waiter, contains('FloorLayoutView('));
    expect(waiter, isNot(contains('SliverGridDelegateWithFixedCrossAxisCount')));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/waiter_floor_layout_contract_test.dart`

Expected: FAIL because the shared layout widget does not exist.

- [ ] **Step 3: Create `FloorLayoutView`**

Implement these public types in `lib/features/table/floor_layout.dart`:

```dart
typedef TableTapCallback = void Function(PosTable table);
typedef TableMoveCallback = void Function(PosTable table, Rect normalizedRect);

class FloorLayoutView extends StatelessWidget {
  const FloorLayoutView({
    super.key,
    required this.tables,
    required this.onTapTable,
    this.onTableMoved,
    this.selectedTableId,
    this.editable = false,
    this.padding = const EdgeInsets.all(20),
  });

  final List<PosTable> tables;
  final TableTapCallback onTapTable;
  final TableMoveCallback? onTableMoved;
  final String? selectedTableId;
  final bool editable;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final canvasSize = Size(
          constraints.maxWidth,
          constraints.maxHeight,
        );

        return InteractiveViewer(
          minScale: 0.8,
          maxScale: 2.5,
          constrained: true,
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: PosColors.panel,
                    border: Border.all(color: PosColors.border),
                  ),
                ),
              ),
              for (final table in tables)
                Positioned(
                  left: table.layoutX * canvasSize.width,
                  top: table.layoutY * canvasSize.height,
                  width: table.layoutW * canvasSize.width,
                  height: table.layoutH * canvasSize.height,
                  child: _FloorTableTile(
                    table: table,
                    selected: selectedTableId == table.id,
                    editable: editable,
                    onTap: () => onTapTable(table),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
```

Then add `_FloorTableTile` with occupied/available colors, table number, seats, and round/rectangle shape.

- [ ] **Step 4: Add drag support**

Wrap editable tiles in `GestureDetector` and calculate normalized movement:

```dart
onPanEnd: editable && onTableMoved != null
    ? (details) {
        final rect = Rect.fromLTWH(
          table.layoutX,
          table.layoutY,
          table.layoutW,
          table.layoutH,
        );
        onTableMoved!(table, rect);
      }
    : null,
```

During final implementation, track pan deltas in widget state or lift draft positions into the admin screen. Clamp every saved rect so `x >= 0`, `y >= 0`, `x + w <= 1`, and `y + h <= 1`.

- [ ] **Step 5: Commit**

```bash
git add lib/features/table/floor_layout.dart test/waiter_floor_layout_contract_test.dart
git commit -m "feat: add shared table floor canvas"
```

---

### Task 4: Waiter Read-Only Floor View

**Files:**
- Modify: `lib/features/waiter/waiter_screen.dart`
- Test: `test/waiter_floor_layout_contract_test.dart`

- [ ] **Step 1: Replace `_TableGridView` rendering**

In `lib/features/waiter/waiter_screen.dart`, import:

```dart
import '../table/floor_layout.dart';
```

Replace the table list body with:

```dart
FloorLayoutView(
  key: const Key('tables_root'),
  tables: state.tables,
  onTapTable: onTapTable,
  editable: false,
)
```

Keep loading, empty, and error states. Keep `table_first_card` by applying that key to the first tile inside `FloorLayoutView` so integration tests still find a tappable first table.

- [ ] **Step 2: Remove obsolete fixed grid delegate**

Remove the waiter `_TableGridView` `GridView.builder` and `SliverGridDelegateWithFixedCrossAxisCount` path after the replacement is stable.

- [ ] **Step 3: Run waiter tests**

Run:

```bash
flutter test test/waiter_floor_layout_contract_test.dart test/waiter_table_realtime_contract_test.dart test/waiter_buffet_guest_count_contract_test.dart
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/features/waiter/waiter_screen.dart test/waiter_floor_layout_contract_test.dart
git commit -m "feat: show waiter tables as floor layout"
```

---

### Task 5: Admin Layout Editor

**Files:**
- Modify: `lib/features/admin/tabs/tables_tab.dart`
- Modify: `lib/features/admin/widgets/admin_audit_trace_panel.dart`
- Test: `test/admin_table_layout_editor_contract_test.dart`

- [ ] **Step 1: Write the failing admin contract test**

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('admin tables tab exposes floor layout editor and saves table positions', () {
    final adminTables = readRepoFile('lib/features/admin/tabs/tables_tab.dart');
    final provider = readRepoFile('lib/features/admin/providers/tables_provider.dart');
    final audit = readRepoFile('lib/features/admin/widgets/admin_audit_trace_panel.dart');

    expect(adminTables, contains('FloorLayoutView('));
    expect(adminTables, contains('_layoutEditMode'));
    expect(adminTables, contains('onTableMoved:'));
    expect(adminTables, contains('updateTableLayout('));
    expect(provider, contains('Future<bool> updateTableLayout'));
    expect(audit, contains("'layout_x' => 'Layout X'"));
    expect(audit, contains("'layout_y' => 'Layout Y'"));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/admin_table_layout_editor_contract_test.dart`

Expected: FAIL until admin UI is changed.

- [ ] **Step 3: Add editor state**

Add to `_TablesTabState`:

```dart
bool _layoutEditMode = false;
final Map<String, Rect> _draftLayoutByTableId = {};
```

Add toolbar controls near the current Dining Floor header:

```dart
SegmentedButton<bool>(
  segments: const [
    ButtonSegment(value: false, icon: Icon(Icons.touch_app), label: Text('Use')),
    ButtonSegment(value: true, icon: Icon(Icons.edit_location_alt), label: Text('Edit')),
  ],
  selected: {_layoutEditMode},
  onSelectionChanged: (values) {
    setState(() {
      _layoutEditMode = values.first;
      _draftLayoutByTableId.clear();
    });
  },
)
```

- [ ] **Step 4: Replace admin fixed grid with editable floor**

Replace the `GridView.builder` table card area with:

```dart
FloorLayoutView(
  tables: tablesState.tables
      .map((row) => PosTable.fromJson(Map<String, dynamic>.from(row)))
      .toList(),
  selectedTableId: _selectedTable?.id,
  editable: _layoutEditMode,
  onTapTable: (table) {
    final row = tablesState.tables.firstWhere(
      (item) => item['id']?.toString() == table.id,
    );
    _onTapTable(row, storeId);
  },
  onTableMoved: (table, rect) {
    setState(() {
      _draftLayoutByTableId[table.id] = rect;
    });
  },
)
```

Keep delete action available through either a small selected-table action panel or an icon button in the table tile when `editable == true`.

- [ ] **Step 5: Add save action**

Add save button:

```dart
FilledButton.icon(
  onPressed: _draftLayoutByTableId.isEmpty
      ? null
      : () async {
          var success = true;
          var order = 0;
          for (final entry in _draftLayoutByTableId.entries) {
            final rect = entry.value;
            success = await tablesNotifier.updateTableLayout(
              tableId: entry.key,
              layoutX: rect.left,
              layoutY: rect.top,
              layoutW: rect.width,
              layoutH: rect.height,
              layoutRotation: 0,
              layoutShape: 'rectangle',
              layoutSortOrder: order,
            ) && success;
            order += 1;
          }
          if (!context.mounted) return;
          if (success) {
            setState(_draftLayoutByTableId.clear);
            showSuccessToast(context, 'Table layout saved.');
          }
        },
  icon: const Icon(Icons.save),
  label: const Text('Save layout'),
)
```

- [ ] **Step 6: Label audit fields**

Update `admin_audit_trace_panel.dart` field labels:

```dart
'layout_x' => 'Layout X',
'layout_y' => 'Layout Y',
'layout_w' => 'Layout Width',
'layout_h' => 'Layout Height',
'layout_rotation' => 'Layout Rotation',
'layout_shape' => 'Layout Shape',
'layout_sort_order' => 'Layout Order',
```

- [ ] **Step 7: Run admin tests**

Run:

```bash
flutter test test/admin_table_layout_editor_contract_test.dart test/admin_tables_order_workspace_contract_test.dart test/admin_tables_payment_amount_contract_test.dart
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/features/admin/tabs/tables_tab.dart lib/features/admin/widgets/admin_audit_trace_panel.dart test/admin_table_layout_editor_contract_test.dart
git commit -m "feat: add admin table layout editor"
```

---

### Task 6: Verification and Regression Sweep

**Files:**
- No new files unless a failing test reveals a necessary targeted fix.

- [ ] **Step 1: Run table and ordering tests**

Run:

```bash
flutter test \
  test/table_layout_sql_contract_test.dart \
  test/table_layout_model_contract_test.dart \
  test/waiter_floor_layout_contract_test.dart \
  test/admin_table_layout_editor_contract_test.dart \
  test/waiter_table_realtime_contract_test.dart \
  test/admin_tables_order_workspace_contract_test.dart \
  test/admin_tables_payment_amount_contract_test.dart \
  test/order_workspace_realtime_contract_test.dart \
  test/order_panel_close_session_contract_test.dart
```

Expected: PASS.

- [ ] **Step 2: Run analyzer**

Run: `flutter analyze`

Expected: no new errors.

- [ ] **Step 3: Manual app checks**

Run the app and verify:

```bash
flutter run -d chrome
```

Manual checks:

- Login as admin, open Tables, switch to layout edit mode, drag a table, save, reload, confirm position persists.
- Login as waiter, open Dining Floor, confirm the same position appears and tapping a table opens `OrderWorkspace`.
- Create an order, confirm the table changes to occupied through existing realtime handling.
- Complete/cancel the order, confirm the table returns to available and the panel auto-closes as before.

- [ ] **Step 4: Commit final fixes if any**

```bash
git add <changed-files>
git commit -m "fix: stabilize table floor layout"
```

## Risks and Guardrails

- Do not rename `restaurants`, `restaurant_id`, or existing table/order relations; Office app coupling requires those to remain stable.
- Do not move table status out of `public.tables`; orders and payment flows already depend on it.
- Do not make payment completion depend on layout save success.
- Preserve existing realtime insert/update/delete behavior for waiters.
- Keep the first-table key path working for integration tests (`table_first_card`).
- Avoid adding a separate `floor_plans` subsystem in this phase. Per-table layout fields are enough for Stage 1 and keep the blast radius small.

## Open Product Decisions

- Whether admins need walls/sections/labels now, or only table positions. Recommendation: table positions only for this implementation.
- Whether table shape should be editable in the first UI pass. Recommendation: store shape now, expose simple rectangle/round selector after drag-save works.
- Whether layout should support multiple floors/rooms. Recommendation: defer; add `zone` later if a real store needs it.

## Self-Review

- Spec coverage: The plan covers DB persistence, admin editing, waiter rendering, existing ordering behavior, audit labels, and tests.
- Placeholder scan: No task relies on an unspecified “handle later” item for the core feature.
- Type consistency: Layout field names are consistent across SQL, Dart model, service RPC params, provider method, and tests.
