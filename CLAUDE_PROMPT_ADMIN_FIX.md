Project: /Users/andreahn/globos_pos_system
Task: Fix admin permissions — admin must be able to manage everything including table orders, item status, payments

---

## ROOT CAUSE

Admin currently has a "Tables" tab that only shows table management (add/delete).
There is NO way for admin to:
1. Click a table and open an order panel (like waiter)
2. Update order item status (like kitchen)
3. Process payments (like cashier)

Admin role has full permissions per ROLES.md but the UI doesn't expose those flows.

---

## FIX 1: Admin Tables Tab — Click table to open order panel

File: lib/features/admin/tabs/tables_tab.dart

### Problem
Table cards have no onTap handler — only a delete icon. Admin cannot enter order management.

### Fix
Wrap the entire table Card in a GestureDetector/InkWell that opens an admin order panel.

The admin order panel should be identical to the waiter's `_OrderWorkspace` —
reuse the same widget or extract it to a shared location.

**Option A (recommended):** Extract `_OrderWorkspace` from waiter_screen.dart to:
`lib/widgets/order_workspace.dart`
Then import it in both waiter_screen.dart and tables_tab.dart.

**Option B:** Navigate to /waiter with a special "admin mode" flag.

Use Option A.

### Implementation

In tables_tab.dart, convert to `ConsumerStatefulWidget`.
Add state:
```dart
PosTable? _selectedTable;
bool _showOrderPanel = false;
```

Wrap the table card in InkWell:
```dart
InkWell(
  onTap: () => _onTapTable(table, restaurantId),
  borderRadius: BorderRadius.circular(16),
  child: ... // existing card content
)
```

Add `_onTapTable`:
```dart
Future<void> _onTapTable(Map<String, dynamic> table, String restaurantId) async {
  final tableId = table['id']?.toString() ?? '';
  final tableNumber = table['table_number']?.toString() ?? '-';
  if (tableId.isEmpty) return;

  setState(() {
    _selectedTable = PosTable(
      id: tableId,
      tableNumber: tableNumber,
      seatCount: int.tryParse(table['seat_count']?.toString() ?? '0') ?? 0,
      status: table['status']?.toString() ?? 'available',
    );
    _showOrderPanel = true;
  });
  await ref.read(orderProvider.notifier).loadActiveOrder(tableId, restaurantId);
}
```

Layout: split into left (table grid) + right (order panel) when _showOrderPanel is true.
Same pattern as waiter_screen.dart — use a Row with AnimatedSwitcher.

Import needed:
- order_provider.dart
- order_workspace.dart (new shared widget)
- waiter_screen.dart's PosTable model (or create shared model)

---

## FIX 2: Extract Shared OrderWorkspace Widget

Create: lib/widgets/order_workspace.dart

Move `_OrderWorkspace` class from waiter_screen.dart to this file.
Export it so both waiter_screen.dart and tables_tab.dart can use it.

The widget already handles:
- Cart management
- Order submission (create_order, add_items_to_order)
- Order cancellation
- Buffet mode

No logic changes needed — just move and export.

Update waiter_screen.dart to import from widgets/order_workspace.dart instead.

---

## FIX 3: Admin can update order item status (Kitchen functionality)

File: lib/features/admin/tabs/tables_tab.dart (order panel)

When admin opens a table's order panel and there's an active order,
show order items with their current status and allow status cycling:
pending → preparing → ready → served

Add to the order workspace (when role is admin/super_admin):
- Each order item shows current status chip
- Tap status chip → cycle to next status
- Call: supabase.from('order_items').update({'status': nextStatus}).eq('id', itemId)

Use the same `_cycleStatus` logic from kitchen_provider.dart.

---

## FIX 4: Admin can process payment from table view

In the admin order panel (tables_tab.dart order workspace):

When an order exists and is not yet paid, show a "결제 처리" button.
This should open a payment dialog (reuse cashier payment UI or a simplified version):
- CASH / CARD / PAY / SERVICE buttons
- Amount display
- [결제 완료] button → call paymentService.processPayment(...)
- On success: close panel, refresh tables

---

## FIX 5: Other admin issues found during audit

### 5-A: Menu Tab — no price editing inline
In menu_tab.dart, ensure price can be edited inline or via dialog.
Currently items might show but not be editable. Add edit button per item if missing.

### 5-B: Staff Tab — role display Korean labels
In staff_tab.dart, role labels should be in Korean:
- waiter → 홀 직원
- kitchen → 주방
- cashier → 캐셔
- admin → 관리자
Check if this is already done. If English only, add Korean mapping.

### 5-C: Tables Tab — show active order summary on card
When a table is occupied, show a brief summary on the card:
- Number of items ordered
- Approximate time since order started (e.g., "35분 전")
- This requires fetching active orders for occupied tables

In tablesProvider or a new provider, fetch:
```dart
// For each occupied table, fetch the active order
final orders = await supabase
    .from('orders')
    .select('id, created_at, order_items(id)')
    .eq('restaurant_id', restaurantId)
    .inFilter('status', ['pending', 'confirmed', 'serving'])
    .inFilter('table_id', occupiedTableIds);
```

Show on card: "🍽 3개 메뉴 · 25분 전"

### 5-D: Settings Tab — verify payroll PIN setting works
Check that payroll PIN save/verify flow is complete end-to-end.
If restaurant_settings table entry doesn't exist yet, ensure upsert creates it.

---

## FIX 6: PosTable Model — extract to shared location

Currently PosTable model may be defined inside waiter_screen.dart.
Move to: lib/core/models/pos_table.dart

```dart
class PosTable {
  final String id;
  final String tableNumber;
  final int seatCount;
  final String status; // 'available' | 'occupied'

  const PosTable({
    required this.id,
    required this.tableNumber,
    required this.seatCount,
    required this.status,
  });

  bool get isOccupied => status == 'occupied';
}
```

Import this model in:
- waiter_screen.dart
- tables_tab.dart
- table_provider.dart (if needed)

---

## Rules
- Admin must have full access to all order operations (create, modify items, cancel, pay)
- No new routes needed — everything happens within the Admin Tables tab via panel
- Reuse existing providers: orderProvider, paymentProvider, kitchenProvider
- PlatformInfo from core/layout/platform_info.dart — no kIsWeb in feature layer
- flutter analyze → 0 errors
- flutter build macos → pass
- flutter build web --release → pass
- flutter build apk --release → pass
- echo "Y" | supabase db push (if any migration needed)
- vercel deploy build/web --prod --yes
- git add -A && git commit -m "fix: admin full order management - table click, item status, payment from tables tab" && git push
