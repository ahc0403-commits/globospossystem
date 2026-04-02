Project: /Users/andreahn/globos_pos_system
Task: Implement Order Cancellation UI + Service Provision (서비스 제공) flow.

## Context
- DB: orders table has status CHECK including 'cancelled'
- DB: payments table has method='service' and is_revenue=false (already designed)
- process_payment RPC already handles method='service' → is_revenue=false automatically
- Cashier screen has SERVICE button but it's small and unclear
- No cancel_order RPC exists yet
- No order cancellation UI exists in Waiter or Cashier screen

---

## PART 1: Order Cancellation

### 1A. DB Migration — cancel_order RPC

Create: supabase/migrations/20260402000004_cancel_order_rpc.sql

```sql
-- cancel_order RPC
-- Only cancellable when status is 'pending' or 'confirmed'
CREATE OR REPLACE FUNCTION cancel_order(
  p_order_id      UUID,
  p_restaurant_id UUID
) RETURNS orders AS $$
DECLARE
  v_order    orders;
  v_table_id UUID;
BEGIN
  SELECT * INTO v_order
  FROM orders
  WHERE id = p_order_id AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_CANCELLABLE';
  END IF;

  UPDATE orders
  SET status = 'cancelled', updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  -- Release table if occupied
  IF v_order.table_id IS NOT NULL THEN
    UPDATE tables
    SET status = 'available', updated_at = now()
    WHERE id = v_order.table_id;
  END IF;

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

Deploy: echo "Y" | supabase db push

### 1B. Add cancelOrder to OrderProvider

In lib/features/order/order_provider.dart, add method:

```dart
Future<void> cancelOrder(String orderId, String restaurantId) async {
  state = state.copyWith(isSubmitting: true, error: null);
  try {
    await supabase.rpc('cancel_order', params: {
      'p_order_id': orderId,
      'p_restaurant_id': restaurantId,
    });
    state = state.copyWith(isSubmitting: false, activeOrder: null);
    clearCart();
  } on PostgrestException catch (e) {
    state = state.copyWith(
      isSubmitting: false,
      error: e.message == 'ORDER_NOT_CANCELLABLE'
          ? '완료되거나 이미 취소된 주문은 취소할 수 없습니다.'
          : '주문 취소 실패: ${e.message}',
    );
  } catch (e) {
    state = state.copyWith(isSubmitting: false, error: e.toString());
  }
}
```

### 1C. Add ERROR_CODES entry

In ERROR_CODES (for documentation, not code change):
- ORDER_NOT_CANCELLABLE: completed/cancelled 주문 취소 시도

### 1D. Add Cancel button to Waiter Screen

In lib/features/waiter/waiter_screen.dart:

In the order panel (right side, when activeOrder exists and status is pending/confirmed/serving):

Add a "주문 취소" button:
- Position: bottom of order panel, below SEND ORDER button
- Style: OutlinedButton, border color statusCancelled (#C0392B), text color statusCancelled
- Text: "주문 취소" with Icons.cancel icon
- Height: 48px, full width
- Only show when activeOrder exists AND activeOrder.status is NOT 'completed' or 'cancelled'
- On tap: show confirmation dialog

Confirmation dialog:
```
제목: "주문을 취소하시겠습니까?"
내용: "T[테이블번호] 주문이 취소되고 테이블이 비워집니다."
버튼: 
  - "돌아가기" (dismiss)
  - "주문 취소" (red, calls cancelOrder)
```

After successful cancel:
- Show error toast style but with orange: "주문이 취소되었습니다"
- Close order panel
- Table returns to available status (handled by RPC)

### 1E. Add Cancel option to Cashier Screen

In lib/features/cashier/cashier_screen.dart:

In the right panel (order detail view), when order status is NOT 'completed':
Add a "주문 취소" text button (small, red, at the bottom below payment methods):
- Only visible to admin/super_admin (check role from authProvider)
- On tap: same confirmation dialog as above
- After cancel: reload orders, clear selection

Add cancelOrder to PaymentProvider too:
In lib/features/payment/payment_provider.dart:
```dart
Future<void> cancelOrder(String orderId, String restaurantId) async {
  state = state.copyWith(isProcessing: true, error: null);
  try {
    await supabase.rpc('cancel_order', params: {
      'p_order_id': orderId,
      'p_restaurant_id': restaurantId,
    });
    state = state.copyWith(isProcessing: false, selectedOrder: null);
    await loadOrders(restaurantId);
  } catch (e) {
    state = state.copyWith(isProcessing: false, error: e.toString());
  }
}
```

---

## PART 2: Service Provision (서비스 제공)

### Context
- "서비스 제공" = 직원 식사, 서비스 음료 등 제공
- 주문은 정상 완료처리 (orders.status = completed)
- 결제는 method='service', is_revenue=false
- 매출 집계에서 제외됨 (기존 설계 그대로)
- admin/super_admin만 가능 (cashier 불가)

### 2A. Redesign SERVICE payment in Cashier Screen

The current SERVICE button is small and unclear.
Redesign to make service provision more prominent and clear.

In lib/features/cashier/cashier_screen.dart:

Payment methods layout change:
- CASH, CARD, PAY buttons: normal size (3 buttons in a row)
- SERVICE: separate row below, full width, different styling

SERVICE button new style:
- Full width button, height 48px
- Background: transparent
- Border: 1.5px dashed, color AppColors.textSecondary
- Text: "서비스 제공 (매출 미반영)" in NotoSansKR 13px, textSecondary
- Icon: Icons.volunteer_activism (service/gift icon), size 16
- Only show when isAdmin (role == 'admin' || 'super_admin')
- When selected: border becomes amber500, text becomes textPrimary, background surface2

When SERVICE is selected as payment method:
- Show an info banner above the PROCESS PAYMENT button:
  Container with amber/orange tint background:
  "⚠️ 서비스 처리 시 매출에 반영되지 않습니다"
  in NotoSansKR 12px

- PROCESS PAYMENT button text changes to:
  "서비스 처리 완료" (instead of "PROCESS PAYMENT")

### 2B. Service provision confirmation dialog

When "서비스 처리 완료" is tapped with method='service':
Show a confirmation dialog:

```
제목: "서비스 제공 처리"
내용: "이 주문은 매출에 반영되지 않고 서비스로 처리됩니다.\n직원 식사, 서비스 음료 등에 사용하세요."
버튼:
  - "취소"
  - "서비스 처리" (amber button)
```

### 2C. Service in Reports

In lib/features/admin/tabs/reports_tab.dart:
In the summary cards section, ensure there's a clear "서비스 지출" card:
- Shows sum of payments where method='service'
- Color: textSecondary (grey)
- Label: "서비스 지출 (매출 미포함)"
- Should already be queryable from payments where is_revenue=false

If not already showing, add it to the report summary.

In lib/features/report/report_provider.dart:
Ensure serviceTotal is calculated:
- SELECT SUM(amount) FROM payments WHERE is_revenue=false AND restaurant_id=...
- This is likely already implemented, just verify

---

## Rules
- Never call supabase directly from screen widgets
- Run flutter analyze → fix ALL errors
- flutter build macos → must pass
- flutter build web --release → must pass
- flutter build apk --release → must pass
- git add -A && git commit -m "feat: order cancellation UI + service provision (서비스 제공) redesign" && git push
