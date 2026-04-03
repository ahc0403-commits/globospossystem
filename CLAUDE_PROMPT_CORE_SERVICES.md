Project: /Users/andreahn/globos_pos_system
Task: Extract core/services/ layer per RULES.md and RPC.md design spec.

## Why This Exists (RULES.md violation)
RULES.md states:
- "Provider가 3개 이상 테이블 직접 뮤테이션 금지 → core/services/로 추출"
- "고위험 뮤테이션(주문 생성·결제): DB RPC 원자 경계 필수"

RPC.md states:
- "core/services/order_service.dart → create_order, create_buffet_order, add_items_to_order"
- "core/services/payment_service.dart → process_payment"

Currently ALL RPC calls live directly in feature providers. This task extracts them.

## Current State
All supabase.rpc() calls are in:
- lib/features/order/order_provider.dart → 4 rpc calls (create_order, create_buffet_order, add_items_to_order, cancel_order)
- lib/features/payment/payment_provider.dart → 2 rpc calls (process_payment, cancel_order)
- lib/features/attendance/fingerprint_provider.dart → inserts to fingerprint_templates + attendance_logs
- lib/features/admin/providers/tables_provider.dart → insert/delete to tables
- lib/features/admin/providers/menu_provider.dart → insert/update/delete to menu_items + menu_categories
- lib/features/admin/providers/staff_provider.dart → supabase.functions.invoke (Edge Function)

## What To Build

### 1. lib/core/services/order_service.dart

Extract ALL order-related RPC calls from order_provider.dart.

```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../main.dart';

class OrderService {
  // create_order RPC — standard 매장 첫 주문
  Future<Map<String, dynamic>> createOrder({
    required String restaurantId,
    required String tableId,
    required List<Map<String, dynamic>> items, // [{menu_item_id, quantity}]
  }) async {
    final result = await supabase.rpc('create_order', params: {
      'p_restaurant_id': restaurantId,
      'p_table_id': tableId,
      'p_items': items,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  // create_buffet_order RPC — buffet/hybrid 매장 첫 주문
  Future<Map<String, dynamic>> createBuffetOrder({
    required String restaurantId,
    required String tableId,
    required int guestCount,
    List<Map<String, dynamic>> extraItems = const [],
  }) async {
    final result = await supabase.rpc('create_buffet_order', params: {
      'p_restaurant_id': restaurantId,
      'p_table_id': tableId,
      'p_guest_count': guestCount,
      'p_extra_items': extraItems,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  // add_items_to_order RPC — 추가 주문
  Future<List<Map<String, dynamic>>> addItemsToOrder({
    required String orderId,
    required String restaurantId,
    required List<Map<String, dynamic>> items,
  }) async {
    final result = await supabase.rpc('add_items_to_order', params: {
      'p_order_id': orderId,
      'p_restaurant_id': restaurantId,
      'p_items': items,
    });
    return (result as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  // cancel_order RPC — 주문 취소 (pending/confirmed만 가능)
  Future<Map<String, dynamic>> cancelOrder({
    required String orderId,
    required String restaurantId,
  }) async {
    final result = await supabase.rpc('cancel_order', params: {
      'p_order_id': orderId,
      'p_restaurant_id': restaurantId,
    });
    return Map<String, dynamic>.from(result as Map);
  }
}

// Singleton instance
final orderService = OrderService();
```

### 2. lib/core/services/payment_service.dart

Extract ALL payment-related RPC calls from payment_provider.dart.

```dart
import '../../main.dart';

class PaymentService {
  // process_payment RPC — 결제 + 테이블 해제 (RULES.md: RPC 내에서만 처리)
  Future<Map<String, dynamic>> processPayment({
    required String orderId,
    required String restaurantId,
    required double amount,
    required String method, // cash | card | pay | service
  }) async {
    final result = await supabase.rpc('process_payment', params: {
      'p_order_id': orderId,
      'p_restaurant_id': restaurantId,
      'p_amount': amount,
      'p_method': method,
    });
    return Map<String, dynamic>.from(result as Map);
  }
}

final paymentService = PaymentService();
```

### 3. lib/core/services/staff_service.dart

Extract Edge Function call from staff_provider.dart.

```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../main.dart';

class StaffService {
  // create_staff_user Edge Function — 실제 Supabase Auth 계정 생성
  Future<Map<String, dynamic>> createStaffUser({
    required String email,
    required String password,
    required String fullName,
    required String role,
    required String restaurantId,
  }) async {
    final response = await supabase.functions.invoke(
      'create_staff_user',
      body: {
        'email': email,
        'password': password,
        'full_name': fullName,
        'role': role,
        'restaurant_id': restaurantId,
      },
    );
    if (response.status != 200) {
      final errorData = response.data;
      final errorMsg = errorData is Map
          ? errorData['error'] ?? 'Failed to create staff'
          : 'Failed to create staff';
      throw Exception(errorMsg.toString());
    }
    return Map<String, dynamic>.from(response.data as Map);
  }
}

final staffService = StaffService();
```

### 4. Update order_provider.dart

Replace all supabase.rpc() calls with orderService calls:
- supabase.rpc('create_order', ...) → await orderService.createOrder(...)
- supabase.rpc('create_buffet_order', ...) → await orderService.createBuffetOrder(...)
- supabase.rpc('add_items_to_order', ...) → await orderService.addItemsToOrder(...)
- supabase.rpc('cancel_order', ...) → await orderService.cancelOrder(...)

Add import: import '../../core/services/order_service.dart';
Remove direct supabase.rpc() calls from this file.

### 5. Update payment_provider.dart

Replace all supabase.rpc() calls with paymentService calls:
- supabase.rpc('process_payment', ...) → await paymentService.processPayment(...)
- supabase.rpc('cancel_order', ...) → await orderService.cancelOrder(...)

Add imports:
- import '../../core/services/payment_service.dart';
- import '../../core/services/order_service.dart';

### 6. Update staff_provider.dart

Replace supabase.functions.invoke('create_staff_user', ...) with staffService.createStaffUser(...)
Add import: import '../../core/services/staff_service.dart';

---

## IMPORTANT: Do NOT change

- Do NOT change any business logic, state management, or UI
- Do NOT change how providers load data (SELECT queries stay in providers)
- Do NOT change kitchen_provider, table_provider, fingerprint_provider (they are read-heavy, not high-risk mutations)
- Do NOT change admin providers (menu, tables) — they are CRUD but not high-risk RPC
- ONLY extract the 4 supabase.rpc() functions and 1 Edge Function call

---

## Rules
- Run flutter analyze → fix ALL errors
- flutter build macos → must pass
- flutter build web --release → must pass
- flutter build apk --release → must pass
- git add -A && git commit -m "refactor: extract core/services layer - OrderService, PaymentService, StaffService per RULES.md" && git push
