import 'direct_order_money.dart';

enum DirectOrderChatTemplate { received, quote, address, deliveryFee }

/// Uses the selected order only; does not send messages or change order state.
String directOrderChatDraft({
  required DirectOrderChatTemplate template,
  required String locale,
  required String storeName,
  required String referenceCode,
  required String customerName,
  required String phone,
  required String address,
  required bool pickup,
  required bool customerPaysDriver,
  int? deliveryFee,
}) {
  String pick(String ko, String vi, String en) => switch (locale) {
    'ko' => ko,
    'en' => en,
    _ => vi,
  };
  switch (template) {
    case DirectOrderChatTemplate.received:
      return pick(
        '안녕하세요, $storeName입니다. 고객님의 주문 #$referenceCode이 정상적으로 접수되었습니다. 이용해 주셔서 감사합니다!',
        'Xin chào, đây là $storeName. Đơn hàng #$referenceCode đã được tiếp nhận. Cảm ơn quý khách!',
        'Hello from $storeName. Your order #$referenceCode has been received. Thank you for ordering!',
      );
    case DirectOrderChatTemplate.quote:
      if (pickup) {
        return pick(
          '$storeName에서 방문 수령 주문 #$referenceCode의 금액을 안내드립니다. 배송비는 없습니다. 견적을 확인하신 후 결제해 주세요. 매장에서 입금을 확인한 뒤 조리를 시작합니다.',
          '$storeName gửi báo giá đơn nhận tại cửa hàng #$referenceCode. Không có phí giao hàng. Vui lòng kiểm tra và thanh toán. Cửa hàng bắt đầu chuẩn bị sau khi xác nhận thanh toán.',
          '$storeName has sent the quote for pickup order #$referenceCode. There is no delivery fee. Please review and pay. Preparation starts after the store confirms payment.',
        );
      }
      return customerPaysDriver
          ? pick(
              '$storeName에서 주문 #$referenceCode의 금액을 안내드립니다. 매장 결제금액에는 배송비가 포함되어 있지 않으며, 배송비는 기사에게 별도로 지급합니다. 견적을 확인하신 후 결제해 주세요. 매장에서 입금을 확인한 뒤 조리를 시작합니다.',
              '$storeName gửi báo giá đơn #$referenceCode. Phí giao hàng không gồm trong thanh toán cửa hàng và được trả riêng cho tài xế. Vui lòng kiểm tra và thanh toán. Cửa hàng chuẩn bị sau khi xác nhận thanh toán.',
              '$storeName has sent the quote for order #$referenceCode. Delivery fees are excluded from store payment and paid separately to the driver. Please review and pay. Preparation starts after payment confirmation.',
            )
          : pick(
              '$storeName에서 주문 #$referenceCode의 최종 금액을 안내드립니다. 배송비는 견적에 포함되어 있습니다. 금액을 확인하신 후 결제해 주세요. 매장에서 입금을 확인한 뒤 조리를 시작합니다.',
              '$storeName gửi báo giá cuối cùng cho đơn #$referenceCode, đã gồm phí giao hàng. Vui lòng kiểm tra và thanh toán. Cửa hàng chuẩn bị sau khi xác nhận thanh toán.',
              '$storeName has sent the final quote for order #$referenceCode, including delivery fees. Please review and pay. Preparation starts after payment confirmation.',
            );
    case DirectOrderChatTemplate.address:
      return pick(
        '$storeName에서 배송 정보를 확인드립니다.\n주문번호: #$referenceCode\n고객명: $customerName\n전화번호: $phone\n배송 주소: $address\n위 정보가 정확한지 확인 부탁드립니다. 감사합니다.',
        '$storeName xác nhận thông tin giao hàng.\nMã đơn: #$referenceCode\nTên khách: $customerName\nĐiện thoại: $phone\nĐịa chỉ: $address\nVui lòng xác nhận thông tin trên. Cảm ơn quý khách.',
        '$storeName would like to confirm your delivery details.\nOrder: #$referenceCode\nName: $customerName\nPhone: $phone\nAddress: $address\nPlease confirm these details. Thank you.',
      );
    case DirectOrderChatTemplate.deliveryFee:
      if (deliveryFee == null || deliveryFee < 0) {
        throw ArgumentError('A confirmed delivery fee is required');
      }
      final fee = '${formatDirectOrderVnd(deliveryFee)} VND';
      return pick(
        '$storeName에서 확인한 주문 #$referenceCode의 현재 배송비는 $fee입니다. 확인해 주시면 매장에서 배차를 진행하겠습니다.',
        'Phí giao hàng hiện tại cho đơn #$referenceCode được $storeName xác nhận là $fee. Sau khi quý khách xác nhận, cửa hàng sẽ đặt tài xế.',
        '$storeName has confirmed the current delivery fee for order #$referenceCode is $fee. Once you confirm, the store will arrange a driver.',
      );
  }
}
