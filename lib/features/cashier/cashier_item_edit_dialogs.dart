import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/models/pos_table.dart';
import '../order/order_model.dart';

String? cashierItemEditErrorText(BuildContext context, String code) {
  final index = switch (Localizations.localeOf(context).languageCode) {
    'en' => 1,
    'vi' => 2,
    _ => 0,
  };
  final messages = switch (code) {
    'CASHIER_ITEM_CHANGED' || 'CASHIER_OPERATION_CHANGED' => const [
      '주문이나 조리 상태가 변경되었습니다. 새로 확인한 뒤 다시 시도하세요.',
      'The order or preparation changed. Refresh and try again.',
      'Đơn hàng hoặc tiến độ đã thay đổi. Tải lại và thử lại.',
    ],
    'CASHIER_MOVE_CANCELLED_SPLIT' ||
    'CASHIER_COMBO_QUANTITY_CHANGED' => const [
      '이 메뉴는 조리·취소 이력을 보존하기 위해 남은 수량 전체를 함께 이동해야 합니다.',
      'Move the entire remaining line to preserve its preparation and cancellation history.',
      'Chuyển toàn bộ số lượng còn lại để giữ lịch sử chế biến và hủy món.',
    ],
    'CASHIER_TARGET_ORDER_AMBIGUOUS' || 'CASHIER_TARGET_INCOMPATIBLE' => const [
      '대상 테이블의 주문을 먼저 확인하세요. 현재 주문과 합칠 수 없는 상태입니다.',
      'Review the destination table. Its current orders cannot be combined with this order.',
      'Kiểm tra bàn đích. Đơn hiện tại không thể ghép với đơn này.',
    ],
    'ORDER_HAS_PAYMENTS_USE_ADJUSTMENT' ||
    'DIRECT_ORDER_FINAL_AMOUNT_LOCKED' => const [
      '결제 또는 최종금액이 확정된 주문은 수정할 수 없습니다. 정산·환불 기능을 이용하세요.',
      'Payment or the final amount is already fixed. Use an adjustment or refund.',
      'Thanh toán hoặc số tiền cuối đã chốt. Vui lòng dùng điều chỉnh hoặc hoàn tiền.',
    ],
    _ => null,
  };
  return messages?[index];
}

String cashierItemEditText(BuildContext context, String key) {
  final index = switch (Localizations.localeOf(context).languageCode) {
    'en' => 1,
    'vi' => 2,
    _ => 0,
  };
  return const <String, List<String>>{
    'move': ['테이블로 이동', 'Move to table', 'Chuyển sang bàn'],
    'move_all': [
      '메뉴 이동·합석',
      'Move items / combine tables',
      'Chuyển món / ghép bàn',
    ],
    'target': ['이동할 테이블', 'Destination table', 'Bàn đích'],
    'cancel': ['취소할 수량', 'Quantity to cancel', 'Số lượng hủy'],
    'amount_reduction': [
      '메뉴 금액 차감',
      'Item amount removed',
      'Số tiền món được trừ',
    ],
    'confirm': ['확인', 'Confirm', 'Xác nhận'],
    'close': ['닫기', 'Close', 'Đóng'],
    'select_all': ['전체 선택', 'Select all', 'Chọn tất cả'],
    'discount_review': [
      '메뉴를 이동했습니다. 할인·무료 적용을 다시 확인하세요.',
      'Items moved. Review discounts and complimentary items.',
      'Đã chuyển món. Kiểm tra lại giảm giá và món miễn phí.',
    ],
  }[key]![index];
}

Future<int?> showCashierCancelQuantity(
  BuildContext context,
  OrderItem item,
) => showDialog<int>(
  context: context,
  builder: (dialogContext) {
    var quantity = 1;
    return StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: Text(cashierItemEditText(context, 'cancel')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              item.localizedName(Localizations.localeOf(context).languageCode),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  key: const Key('cashier_cancel_quantity_minus'),
                  onPressed: quantity > 1
                      ? () => update(() => quantity--)
                      : null,
                  icon: const Icon(Icons.remove),
                ),
                Text(
                  '$quantity / ${item.quantity}',
                  key: const Key('cashier_cancel_quantity_value'),
                ),
                IconButton(
                  key: const Key('cashier_cancel_quantity_plus'),
                  onPressed: quantity < item.quantity
                      ? () => update(() => quantity++)
                      : null,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            Text('${item.quantity} → ${item.quantity - quantity}'),
            Text(
              '${cashierItemEditText(context, 'amount_reduction')} · '
              '${NumberFormat.currency(locale: 'vi_VN', symbol: '₫', decimalDigits: 0).format(item.isServiceItem ? 0 : (item.payingAmountIncTax != null && item.payingAmountIncTax! > 0 ? item.payingAmountIncTax! / item.quantity : item.unitPrice) * quantity)}',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(cashierItemEditText(context, 'close')),
          ),
          FilledButton(
            key: const Key('cashier_cancel_quantity_confirm'),
            onPressed: () => Navigator.pop(dialogContext, quantity),
            child: Text(cashierItemEditText(context, 'confirm')),
          ),
        ],
      ),
    );
  },
);

class CashierMoveSelection {
  const CashierMoveSelection(this.tableId, this.items);
  final String tableId;
  final List<Map<String, dynamic>> items;
}

Future<CashierMoveSelection?> showCashierMoveItems(
  BuildContext context, {
  required List<OrderItem> items,
  required List<PosTable> tables,
  required String? currentTableId,
  OrderItem? initialItem,
}) => showDialog<CashierMoveSelection>(
  context: context,
  builder: (dialogContext) {
    final eligible = items
        .where((i) => i.itemType == 'menu_item' && i.status != 'cancelled')
        .toList();
    final destinations = tables
        .where((t) => t.id != currentTableId && (t.isAvailable || t.isOccupied))
        .toList();
    final selected = <String, int>{
      if (initialItem != null) initialItem.id: initialItem.quantity,
    };
    String? table;
    return StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: Text(cashierItemEditText(context, 'move_all')),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  key: const Key('cashier_move_target_table'),
                  initialValue: table,
                  items: destinations
                      .map(
                        (t) => DropdownMenuItem(
                          value: t.id,
                          child: Text('${t.floorLabel} · ${t.tableNumber}'),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => update(() => table = v),
                  decoration: InputDecoration(
                    labelText: cashierItemEditText(context, 'target'),
                  ),
                ),
                TextButton(
                  onPressed: () => update(() {
                    selected.clear();
                    for (final i in eligible) {
                      selected[i.id] = i.quantity;
                    }
                  }),
                  child: Text(cashierItemEditText(context, 'select_all')),
                ),
                for (final item in eligible)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: selected.containsKey(item.id),
                    onChanged: (v) => update(() {
                      if (v == true) {
                        selected[item.id] = item.quantity;
                      } else {
                        selected.remove(item.id);
                      }
                    }),
                    title: Text(
                      item.label ??
                          item.nameKo ??
                          item.nameVi ??
                          item.nameEn ??
                          'Menu',
                    ),
                    subtitle: selected.containsKey(item.id)
                        ? Row(
                            children: [
                              IconButton(
                                onPressed: selected[item.id]! > 1
                                    ? () => update(
                                        () => selected[item.id] =
                                            selected[item.id]! - 1,
                                      )
                                    : null,
                                icon: const Icon(Icons.remove),
                              ),
                              Text('${selected[item.id]} / ${item.quantity}'),
                              IconButton(
                                onPressed: selected[item.id]! < item.quantity
                                    ? () => update(
                                        () => selected[item.id] =
                                            selected[item.id]! + 1,
                                      )
                                    : null,
                                icon: const Icon(Icons.add),
                              ),
                            ],
                          )
                        : Text('${item.quantity}'),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(cashierItemEditText(context, 'close')),
          ),
          FilledButton(
            key: const Key('cashier_move_confirm'),
            onPressed: table != null && selected.isNotEmpty
                ? () => Navigator.pop(
                    dialogContext,
                    CashierMoveSelection(table!, [
                      for (final i in eligible)
                        if (selected.containsKey(i.id))
                          {
                            'item_id': i.id,
                            'quantity': selected[i.id],
                            'expected_quantity': i.quantity,
                          },
                    ]),
                  )
                : null,
            child: Text(cashierItemEditText(context, 'confirm')),
          ),
        ],
      ),
    );
  },
);
