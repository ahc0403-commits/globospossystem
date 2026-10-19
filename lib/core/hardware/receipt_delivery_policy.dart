/// Payment scope belongs to the issued snapshot, never to the displayed amount.
bool recipientPaysDelivery(String? mode, String? fulfillmentMethod) =>
    mode == 'customer_direct' && fulfillmentMethod == 'delivery';

const recipientDeliveryNoticeVi =
    'Phí giao hàng không bao gồm trong tiền trả cửa hàng. Trả trực tiếp cho tài xế khi nhận món.';
const driverFoodPaidVi = 'TIEN MON DA THANH TOAN TAI CUA HANG';
const driverDoNotCollectFoodVi = 'KHONG THU LAI TIEN MON';
const driverCollectDeliveryVi = 'CHI THU PHI GIAO HANG TU NGUOI NHAN';
