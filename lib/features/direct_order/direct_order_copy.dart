class DirectOrderCopy {
  const DirectOrderCopy(this.languageCode);

  final String languageCode;

  String _pick(String ko, String vi, String en) => switch (languageCode) {
    'ko' => ko,
    'en' => en,
    _ => vi,
  };

  String get directDelivery =>
      _pick('배달 주문', 'Đặt giao hàng', 'Delivery order');
  String get menu => _pick('메뉴', 'Thực đơn', 'Menu');
  String get address => _pick('배송지', 'Địa chỉ', 'Address');
  String get orderStatus => _pick('주문 현황', 'Trạng thái', 'Order status');
  String get cart => _pick('장바구니', 'Giỏ hàng', 'Cart');
  String get cartEmpty =>
      _pick('메뉴를 선택해 주세요.', 'Vui lòng chọn món.', 'Please choose an item.');
  String get paused => _pick(
    '현재 배달 주문을 잠시 쉬고 있습니다.',
    'Cửa hàng đang tạm ngưng nhận đơn giao hàng.',
    'Delivery ordering is temporarily paused.',
  );
  String get unavailable => _pick(
    '배달 주문 페이지를 불러올 수 없습니다.',
    'Không thể tải trang đặt giao hàng.',
    'Delivery ordering is unavailable.',
  );
  String errorMessage(String code) => switch (code) {
    'DIRECT_ORDER_STOREFRONT_PAUSED' => paused,
    'DIRECT_ORDER_OUTSIDE_HOURS' || 'DIRECT_ORDER_APPROVAL_CUTOFF' => _pick(
      '현재는 배달 주문 시간이 아닙니다.',
      'Hiện không phải giờ nhận đơn giao hàng.',
      'Delivery ordering is currently closed.',
    ),
    'DIRECT_ORDER_OPEN_REQUEST_EXISTS' => _pick(
      '진행 중인 배달 주문을 먼저 확인해 주세요.',
      'Vui lòng kiểm tra đơn giao hàng đang xử lý.',
      'Please check your active delivery order first.',
    ),
    'DIRECT_ORDER_ADDRESS_INVALID' => _pick(
      '배송지 정보를 다시 확인해 주세요.',
      'Vui lòng kiểm tra lại địa chỉ giao hàng.',
      'Please check the delivery address.',
    ),
    'DIRECT_ORDER_ITEM_INVALID' ||
    'DIRECT_ORDER_MENU_UNAVAILABLE' ||
    'DIRECT_ORDER_MENU_CHANGED' => _pick(
      '메뉴가 변경되었습니다. 장바구니를 다시 확인해 주세요.',
      'Thực đơn đã thay đổi. Vui lòng kiểm tra lại giỏ hàng.',
      'The menu changed. Please review your cart.',
    ),
    'DIRECT_ORDER_QUANTITY_LIMIT' => _pick(
      '주문 수량을 다시 확인해 주세요.',
      'Vui lòng kiểm tra lại số lượng món.',
      'Please check the item quantities.',
    ),
    'DIRECT_ORDER_BELOW_MINIMUM' => _pick(
      '최소 주문 금액을 확인해 주세요.',
      'Vui lòng kiểm tra giá trị đơn tối thiểu.',
      'Please meet the minimum order amount.',
    ),
    'DIRECT_ORDER_REQUEST_NOT_CHATABLE' ||
    'DIRECT_ORDER_MESSAGE_INVALID' => _pick(
      '현재 이 주문에는 메시지를 보낼 수 없습니다.',
      'Hiện không thể gửi tin nhắn cho đơn này.',
      'A message cannot be sent for this order now.',
    ),
    'DIRECT_ORDER_REQUEST_NOT_CANCELLABLE' => _pick(
      '현재 상태에서는 주문을 취소할 수 없습니다.',
      'Không thể hủy đơn ở trạng thái hiện tại.',
      'This order can no longer be cancelled.',
    ),
    'DIRECT_ORDER_PROOF_NOT_ALLOWED' ||
    'INVALID_PROOF' ||
    'PROOF_UPLOAD_INCOMPLETE' => _pick(
      '입금 증빙 이미지를 다시 확인해 주세요.',
      'Vui lòng kiểm tra lại ảnh chuyển khoản.',
      'Please check the transfer proof image.',
    ),
    'PROOF_UPLOAD_TEMPORARILY_UNAVAILABLE' ||
    'PROOF_TEMPORARILY_UNAVAILABLE' ||
    'PROOF_NOT_FOUND' => _pick(
      '입금 증빙을 불러오지 못했습니다. 다시 시도해 주세요.',
      'Không thể tải ảnh chuyển khoản. Vui lòng thử lại.',
      'The transfer proof could not be loaded. Please retry.',
    ),
    'DIRECT_ORDER_QUOTE_EXPIRED' ||
    'DIRECT_ORDER_REQUEST_NOT_QUOTABLE' => _pick(
      '견적이 만료되었거나 다시 확인이 필요합니다.',
      'Báo giá đã hết hạn hoặc cần kiểm tra lại.',
      'The quote expired or needs to be checked again.',
    ),
    'DIRECT_ORDER_STOREFRONT_DISABLED' ||
    'DIRECT_ORDER_REQUIRES_POS_PRINT' ||
    'DIRECT_ORDER_EMERGENCY_ACTIVE' ||
    'DIRECT_ORDER_PROMOTION_ACTIVE' => _pick(
      '현재 매장에서 배달 주문을 진행할 수 없습니다.',
      'Hiện cửa hàng không thể xử lý đơn giao hàng.',
      'The store cannot process delivery orders right now.',
    ),
    'DIRECT_ORDER_PAYMENT_AMOUNT_MISMATCH' => _pick(
      '확인한 입금액이 최종 금액과 다릅니다.',
      'Số tiền xác nhận không khớp tổng thanh toán.',
      'The confirmed transfer does not match the final total.',
    ),
    'DIRECT_ORDER_PAYMENT_PROOF_REQUIRED' => _pick(
      '입금 증빙을 먼저 확인해 주세요.',
      'Vui lòng kiểm tra ảnh chuyển khoản trước.',
      'Please review the transfer proof first.',
    ),
    'DIRECT_ORDER_REJECTION_REASON_INVALID' => _pick(
      '거절 사유는 3자 이상 입력해 주세요.',
      'Vui lòng nhập lý do từ 3 ký tự trở lên.',
      'Enter at least 3 characters for the rejection reason.',
    ),
    'DIRECT_ORDER_APPROVAL_INPUT_INVALID' => _pick(
      '확인한 입금액과 은행 메모를 다시 확인해 주세요.',
      'Vui lòng kiểm tra lại số tiền và ghi chú ngân hàng.',
      'Please check the confirmed amount and bank reference.',
    ),
    'DIRECT_ORDER_DISPATCH_INPUT_INVALID' => _pick(
      'Grab 공유 링크와 실제 배송비를 다시 확인해 주세요.',
      'Vui lòng kiểm tra lại link Grab và phí giao hàng thực tế.',
      'Please check the Grab link and actual delivery fee.',
    ),
    'DIRECT_ORDER_DRIVER_RECEIPT_ADDRESS_UNAVAILABLE' => _pick(
      '배송지 정보가 없어 기사용 영수증을 출력할 수 없습니다.',
      'Không thể in phiếu tài xế vì không còn địa chỉ giao hàng.',
      'The driver receipt cannot be printed because the delivery address is unavailable.',
    ),
    'DIRECT_ORDER_DRIVER_RECEIPT_TOTAL_MISMATCH' ||
    'DIRECT_ORDER_DRIVER_RECEIPT_ITEMS_UNAVAILABLE' => _pick(
      '주문 금액 또는 메뉴 정보를 확인한 뒤 다시 시도해 주세요.',
      'Vui lòng kiểm tra lại món và tổng tiền trước khi thử lại.',
      'Check the order items and total before trying again.',
    ),
    'DIRECT_ORDER_DRIVER_RECEIPT_REPRINT_NOT_AVAILABLE' => _pick(
      '첫 출력이 완료된 뒤 재출력할 수 있습니다.',
      'Chỉ có thể in lại sau khi bản đầu tiên hoàn tất.',
      'Reprinting is available after the first copy completes.',
    ),
    'DIRECT_ORDER_REQUEST_NOT_APPROVABLE' ||
    'DIRECT_ORDER_REQUEST_NOT_REJECTABLE' ||
    'DIRECT_ORDER_NOT_APPROVED' ||
    'DIRECT_ORDER_FINANCIAL_RECONCILIATION_FAILED' ||
    'DIRECT_ORDER_SEPAY_CANDIDATE_INVALID' ||
    'DIRECT_DELIVERY_TICKET_VERSION_CONFLICT' ||
    'DIRECT_DELIVERY_TICKET_TRANSITION_INVALID' ||
    'DIRECT_ORDER_CLEANUP_NOT_ELIGIBLE' ||
    'DIRECT_ORDER_CLEANUP_TOO_EARLY' => actionFailed,
    'MAP_TEMPORARILY_UNAVAILABLE' => mapUnavailable,
    'MAP_LOCATION_NOT_FOUND' => _pick(
      '선택한 위치의 주소를 찾지 못했습니다.',
      'Không tìm thấy địa chỉ cho vị trí đã chọn.',
      'No address was found for the selected location.',
    ),
    'TOO_MANY_REQUESTS' => _pick(
      '요청이 많습니다. 잠시 후 다시 시도해 주세요.',
      'Có quá nhiều yêu cầu. Vui lòng thử lại sau.',
      'Too many requests. Please try again shortly.',
    ),
    'REQUEST_FORBIDDEN' || 'UNAUTHORIZED' => _pick(
      '이 작업을 수행할 권한이 없습니다.',
      'Bạn không có quyền thực hiện thao tác này.',
      'You do not have permission for this action.',
    ),
    'INVALID_REQUEST' ||
    'INVALID_ACTION' ||
    'UNSUPPORTED_MEDIA_TYPE' ||
    'REQUEST_TOO_LARGE' ||
    'METHOD_NOT_ALLOWED' => _pick(
      '입력 내용을 다시 확인해 주세요.',
      'Vui lòng kiểm tra lại thông tin đã nhập.',
      'Please check the submitted information.',
    ),
    'DIRECT_ORDER_UNAVAILABLE' ||
    'DIRECT_ORDER_TEMPORARILY_UNAVAILABLE' ||
    'CLEANUP_TEMPORARILY_UNAVAILABLE' => unavailable,
    _ => unavailable,
  };
  String get retry => _pick('다시 시도', 'Thử lại', 'Retry');
  String get continueLabel => _pick('계속', 'Tiếp tục', 'Continue');
  String get subtotal => _pick('예상 메뉴 금액', 'Tạm tính món', 'Menu subtotal');
  String get vatNotice => _pick(
    '세금과 서비스 요금은 캐셔 견적에 반영됩니다.',
    'Thuế và phí dịch vụ sẽ được tính trong báo giá.',
    'Tax and service charge are included in the cashier quote.',
  );
  String get useSavedAddress =>
      _pick('저장된 배송지 사용', 'Dùng địa chỉ đã lưu', 'Use saved address');
  String get deleteSavedAddress =>
      _pick('이 기기에서 삭제', 'Xóa khỏi thiết bị', 'Delete from this device');
  String get changeSavedAddress =>
      _pick('다른 배송지 사용', 'Dùng địa chỉ khác', 'Use a different address');
  String get savedOnlyOnDevice => _pick(
    '이 주소는 현재 브라우저에만 저장됩니다.',
    'Địa chỉ chỉ được lưu trên trình duyệt này.',
    'This address is stored only in this browser.',
  );
  String get rememberAddress => _pick(
    '이 기기에 배송지 저장',
    'Lưu địa chỉ trên thiết bị này',
    'Save this address on this device',
  );
  String get searchAddress =>
      _pick('주소 붙여넣기·검색', 'Dán hoặc tìm địa chỉ', 'Paste or search address');
  String get pickOnMap =>
      _pick('지도에서 직접 선택', 'Chọn trực tiếp trên bản đồ', 'Pick directly on map');
  String get addressSearchHint => _pick(
    '건물명이나 전체 주소를 입력하세요',
    'Nhập tên tòa nhà hoặc địa chỉ đầy đủ',
    'Enter a building or full address',
  );
  String get confirmOnMap => _pick(
    '지도에서 위치 확인',
    'Xác nhận vị trí trên bản đồ',
    'Confirm location on map',
  );
  String get tapMapHint => _pick(
    '지도를 눌러 정확한 위치를 선택하세요.',
    'Chạm bản đồ để chọn đúng vị trí.',
    'Tap the map to select the exact location.',
  );
  String get useCurrentLocation =>
      _pick('현재 위치 사용', 'Dùng vị trí hiện tại', 'Use current location');
  String get locatingCurrentLocation => _pick(
    '현재 위치를 확인하고 있습니다…',
    'Đang xác định vị trí hiện tại…',
    'Finding your current location…',
  );
  String get locationPermissionDenied => _pick(
    '위치 권한이 거부되었습니다.',
    'Quyền vị trí đã bị từ chối.',
    'Location permission was denied.',
  );
  String get locationTimedOut => _pick(
    '현재 위치 확인 시간이 초과되었습니다.',
    'Hết thời gian xác định vị trí.',
    'Current location timed out.',
  );
  String get locationUnavailable => _pick(
    '현재 위치를 확인할 수 없습니다.',
    'Không thể xác định vị trí hiện tại.',
    'Current location is unavailable.',
  );
  String get locationUnsupported => _pick(
    '이 브라우저는 현재 위치를 지원하지 않습니다.',
    'Trình duyệt này không hỗ trợ vị trí hiện tại.',
    'This browser does not support current location.',
  );
  String get manualPinFallback => _pick(
    '지도에서 직접 위치를 선택해 주세요.',
    'Vui lòng chọn vị trí trực tiếp trên bản đồ.',
    'Please pick the location directly on the map.',
  );
  String get resolvingMapLocation => _pick(
    '선택한 위치의 주소를 확인하고 있습니다…',
    'Đang xác nhận địa chỉ tại vị trí đã chọn…',
    'Confirming the address at the selected location…',
  );
  String get deliveryMapLabel => _pick(
    '배송 위치 선택 지도',
    'Bản đồ chọn vị trí giao hàng',
    'Delivery location map',
  );
  String get mapUnavailable => _pick(
    '지도를 불러오지 못했습니다. 주소 검색을 이용해 주세요.',
    'Không tải được bản đồ. Vui lòng dùng tìm kiếm địa chỉ.',
    'The map could not load. Please use address search.',
  );
  String get selectedLocation =>
      _pick('선택한 위치', 'Vị trí đã chọn', 'Selected location');
  String get locationConfirmed =>
      _pick('위치 확인 완료', 'Đã xác nhận vị trí', 'Location confirmed');
  String get customerName => _pick('받는 분', 'Tên người nhận', 'Recipient name');
  String get phone => _pick('전화번호', 'Số điện thoại', 'Phone number');
  String get detailAddress =>
      _pick('상세주소·층·호수', 'Số nhà, tầng, phòng', 'Unit, floor, room');
  String get detailAddressHint => _pick(
    '기사님이 찾을 수 있게 자세히 입력하세요',
    'Nhập chi tiết để tài xế dễ tìm',
    'Add details so the driver can find you',
  );
  String get deliveryNote => _pick('요청사항', 'Ghi chú', 'Note');
  String get submitForQuote =>
      _pick('배송비 견적 요청', 'Yêu cầu báo phí giao hàng', 'Request delivery quote');
  String get addressRequired => _pick(
    '지도에서 배송 위치를 확인해 주세요.',
    'Vui lòng xác nhận vị trí giao hàng trên bản đồ.',
    'Please confirm the delivery location on the map.',
  );
  String get requiredFields => _pick(
    '받는 분, 전화번호, 상세주소를 모두 입력해 주세요.',
    'Vui lòng nhập tên, số điện thoại và địa chỉ chi tiết.',
    'Enter the recipient, phone number, and address details.',
  );
  String get awaitingQuote => _pick(
    '캐셔가 Grab 배송비를 확인하고 있습니다.',
    'Thu ngân đang kiểm tra phí Grab.',
    'The cashier is checking the Grab fee.',
  );
  String get quoteReady => _pick(
    '최종 금액이 준비되었습니다.',
    'Báo giá cuối cùng đã sẵn sàng.',
    'Your final quote is ready.',
  );
  String get menuTotal => _pick('메뉴 합계', 'Tiền món', 'Menu total');
  String get serviceCharge => _pick('서비스 요금', 'Phí dịch vụ', 'Service charge');
  String get deliveryFee => _pick('배송비', 'Phí giao hàng', 'Delivery fee');
  String get finalTotal =>
      _pick('최종 입금액', 'Tổng chuyển khoản', 'Transfer total');
  String get transferInstruction => _pick(
    '아래 QR로 정확한 금액을 이체한 뒤 입금 화면을 보내 주세요.',
    'Chuyển đúng số tiền bằng QR rồi gửi ảnh xác nhận.',
    'Transfer the exact amount by QR, then send a confirmation image.',
  );
  String get accountHolder => _pick('예금주', 'Chủ tài khoản', 'Account holder');
  String get accountNumber => _pick('계좌번호', 'Số tài khoản', 'Account number');
  String get attachProof =>
      _pick('입금 캡처 보내기', 'Gửi ảnh chuyển khoản', 'Send transfer screenshot');
  String get proofUploading =>
      _pick('이미지 전송 중…', 'Đang gửi ảnh…', 'Uploading image…');
  String get awaitingApproval => _pick(
    '캐셔가 입금을 확인하고 있습니다. 확인 전에는 주방으로 전달되지 않습니다.',
    'Thu ngân đang xác nhận. Đơn chưa được chuyển vào bếp.',
    'The cashier is verifying payment. Nothing reaches the kitchen yet.',
  );
  String get approved => _pick(
    '입금 확인 완료 · 조리를 시작합니다.',
    'Đã xác nhận thanh toán · Bếp bắt đầu làm món.',
    'Payment confirmed · The kitchen is preparing your order.',
  );
  String get rejected => _pick(
    '주문을 진행할 수 없습니다. 채팅 내용을 확인해 주세요.',
    'Không thể tiếp tục đơn. Vui lòng xem tin nhắn.',
    'The order cannot continue. Please check the chat.',
  );
  String get rejectedByStore => _pick(
    '매장에서 주문을 거절했습니다.',
    'Cửa hàng đã từ chối đơn hàng.',
    'The store rejected the order.',
  );
  String get cancelled =>
      _pick('주문이 취소되었습니다.', 'Đơn đã hủy.', 'Order cancelled.');
  String get preparing => _pick('조리 중', 'Đang chuẩn bị', 'Preparing');
  String get ready =>
      _pick('픽업 준비 완료', 'Sẵn sàng lấy hàng', 'Ready for pickup');
  String get dispatched => _pick(
    'Grab 기사 전달 완료',
    'Đã bàn giao cho tài xế Grab',
    'Handed to Grab driver',
  );
  String get completed => _pick('배달 완료', 'Đã giao', 'Delivered');
  String get openGrab =>
      _pick('Grab 배송 확인', 'Theo dõi trên Grab', 'Track on Grab');
  String get chat => _pick('매장과 채팅', 'Nhắn với cửa hàng', 'Chat with store');
  String get messageHint =>
      _pick('메시지를 입력하세요', 'Nhập tin nhắn', 'Type a message');
  String get send => _pick('보내기', 'Gửi', 'Send');
  String get cancelOrder => _pick('주문 취소', 'Hủy đơn', 'Cancel order');
  String get startNewOrder =>
      _pick('새 주문 시작', 'Bắt đầu đơn mới', 'Start a new order');
  String get cancelConfirm => _pick(
    '입금 전 주문만 취소할 수 있습니다. 취소할까요?',
    'Chỉ có thể hủy trước khi gửi ảnh chuyển khoản. Tiếp tục?',
    'Only pre-payment orders can be cancelled. Continue?',
  );
  String get close => _pick('닫기', 'Đóng', 'Close');
  String get refresh => _pick('새로고침', 'Làm mới', 'Refresh');
  String get paymentProof =>
      _pick('입금 증빙 이미지', 'Ảnh chuyển khoản', 'Transfer proof image');
  String get systemUpdate =>
      _pick('주문 상태 안내', 'Cập nhật đơn hàng', 'Order update');
  String get orderProgress =>
      _pick('주문 진행 상황', 'Tiến trình đơn hàng', 'Order progress');
  String get progressOrderConfirmed =>
      _pick('주문 확인', 'Đã xác nhận đơn', 'Order confirmed');
  String get progressPaymentConfirmed =>
      _pick('입금 확인', 'Đã xác nhận thanh toán', 'Payment confirmed');
  String get progressPreparing =>
      _pick('메뉴 조리 중', 'Đang chuẩn bị món', 'Preparing food');
  String get progressGrabHandoff => _pick(
    'Grab 기사 전달 완료',
    'Đã bàn giao cho tài xế Grab',
    'Handed to Grab driver',
  );

  String get arrivalAlertTitle =>
      _pick('배달 주문', 'Đơn giao hàng', 'Delivery order');
  String arrivalAlertBody(int count) => count == 1
      ? _pick(
          '새 배달 주문이 들어왔습니다.',
          'Có đơn giao hàng mới.',
          'A new delivery order has arrived.',
        )
      : _pick(
          '새 배달 주문 $count건이 들어왔습니다.',
          'Có $count đơn giao hàng mới.',
          '$count new delivery orders have arrived.',
        );
  String arrivalPendingChip(int count) => _pick(
    '배달 주문 · $count',
    'Đơn giao hàng · $count',
    'Delivery order · $count',
  );
  String get viewArrivalOrder => _pick('주문 확인', 'Xem đơn', 'View order');

  String get directOrderDesk => _pick(
    '직접 배달 주문 데스크',
    'Bàn đơn giao hàng trực tiếp',
    'Direct delivery desk',
  );
  String get incomingOrders => _pick('주문 대기열', 'Hàng đợi đơn', 'Order queue');
  String get noOrders => _pick(
    '대기 중인 주문이 없습니다.',
    'Không có đơn đang chờ.',
    'No orders are waiting.',
  );
  String get quoteNeeded => _pick('배송비 견적 필요', 'Cần báo phí', 'Quote needed');
  String get paymentReview =>
      _pick('입금 확인 필요', 'Cần xác nhận tiền', 'Payment review');
  String get addressAndContact =>
      _pick('배송지·연락처', 'Địa chỉ & liên hệ', 'Address & contact');
  String get openMap => _pick('지도에서 열기', 'Mở trên bản đồ', 'Open in map');
  String get orderItems => _pick('주문 메뉴', 'Món đã đặt', 'Order items');
  String get enterGrabFee => _pick(
    '고객에게 안내할 Grab 배송비',
    'Phí Grab báo khách',
    'Grab fee quoted to customer',
  );
  String get quoteNote => _pick('견적 메모', 'Ghi chú báo giá', 'Quote note');
  String get sendQuote =>
      _pick('최종 금액 보내기', 'Gửi báo giá cuối', 'Send final quote');
  String get proof =>
      _pick('입금 증빙', 'Bằng chứng chuyển khoản', 'Payment proof');
  String get viewProof => _pick('이미지 확인', 'Xem ảnh', 'View image');
  String get sepayCandidates =>
      _pick('SePay 일치 후보', 'Giao dịch SePay phù hợp', 'SePay candidates');
  String get noSepayCandidates => _pick(
    '자동 일치 후보 없음',
    'Không có giao dịch phù hợp',
    'No matching transaction',
  );
  String get confirmedAmount =>
      _pick('확인한 입금액', 'Số tiền đã xác nhận', 'Confirmed transfer amount');
  String get bankReference =>
      _pick('은행 거래번호·메모', 'Mã giao dịch ngân hàng', 'Bank reference');
  String get manualApprovalCheck => _pick(
    '입금액과 증빙을 직접 확인했습니다. 승인 시에만 주문이 주방으로 전달됩니다.',
    'Tôi đã kiểm tra số tiền và ảnh. Chỉ sau khi duyệt đơn mới vào bếp.',
    'I manually verified the amount and proof. Only approval sends the order to the kitchen.',
  );
  String get approveAndSendKitchen => _pick(
    '입금 승인·주방 전달',
    'Duyệt tiền & gửi bếp',
    'Approve payment & send to kitchen',
  );
  String get rejectOrder => _pick('주문 거절', 'Từ chối đơn', 'Reject order');
  String get rejectionReason =>
      _pick('거절 사유', 'Lý do từ chối', 'Rejection reason');
  String get rejectionReasonOptional => _pick(
    '거절 사유 (선택)',
    'Lý do từ chối (không bắt buộc)',
    'Rejection reason (optional)',
  );
  String get grabTrackingUrl =>
      _pick('Grab 공유 링크', 'Link theo dõi Grab', 'Grab tracking link');
  String get actualGrabFee =>
      _pick('실제 Grab 비용', 'Phí Grab thực tế', 'Actual Grab cost');
  String get sendGrabLink => _pick(
    '고객에게 Grab 링크 전송',
    'Gửi link Grab cho khách',
    'Send Grab link to customer',
  );
  String get driverReceipt => _pick(
    '배달 기사용 영수증',
    'Phiếu cho tài xế giao hàng',
    'Delivery driver receipt',
  );
  String get driverReceiptHelp => _pick(
    '배송지와 고객 청구 Grab 배송비가 포함된 결제 완료 전표입니다.',
    'Phiếu đã thanh toán gồm địa chỉ giao hàng và phí Grab thu của khách.',
    'A paid handoff slip with the delivery address and customer-charged Grab fee.',
  );
  String get printDriverReceipt =>
      _pick('기사용 영수증 출력', 'In phiếu cho tài xế', 'Print driver receipt');
  String get reprintDriverReceipt =>
      _pick('기사용 영수증 재출력', 'In lại phiếu tài xế', 'Reprint driver receipt');
  String get retryDriverReceipt =>
      _pick('기사용 영수증 다시 시도', 'Thử in lại phiếu tài xế', 'Retry driver receipt');
  String get driverReceiptQueued => _pick(
    '기사용 영수증 출력을 요청했습니다.',
    'Đã gửi yêu cầu in phiếu tài xế.',
    'The driver receipt was queued.',
  );
  String get driverReceiptReprintQueued => _pick(
    '기사용 영수증 재출력을 요청했습니다.',
    'Đã gửi yêu cầu in lại phiếu tài xế.',
    'The driver receipt reprint was queued.',
  );
  String driverReceiptStatus(
    String? status, {
    int? batchNo,
    String? errorCode,
  }) {
    final batch = batchNo == null
        ? ''
        : _pick(' · $batchNo차', ' · bản $batchNo', ' · batch $batchNo');
    final label = switch (status) {
      'pending' => _pick('출력 대기', 'Đang chờ in', 'Queued'),
      'printing' => _pick('출력 중', 'Đang in', 'Printing'),
      'done' => _pick('출력 완료', 'Đã in', 'Printed'),
      'failed' when errorCode == 'NO_DESTINATION' => _pick(
        '영수증 프린터 미설정',
        'Chưa cài máy in hóa đơn',
        'Receipt printer not configured',
      ),
      'failed' => _pick('출력 실패', 'In thất bại', 'Print failed'),
      'cancelled' => _pick(
        '출력 정보 보존기간 만료',
        'Thông tin in đã hết hạn',
        'Print data expired',
      ),
      _ => _pick('출력 전', 'Chưa in', 'Not printed'),
    };
    return '$label$batch';
  }

  String get kitchenBoard => _pick(
    '직접 배달 주방 보드',
    'Bảng bếp giao hàng',
    'Direct delivery kitchen board',
  );
  String get pending => _pick('신규', 'Mới', 'New');
  String get startPreparing => _pick('조리 시작', 'Bắt đầu làm', 'Start preparing');
  String get markReady => _pick('픽업 준비 완료', 'Sẵn sàng lấy', 'Mark ready');
  String get markCompleted => _pick('배달 완료', 'Hoàn tất giao', 'Mark delivered');
  String get ticketConflict => _pick(
    '다른 기기에서 상태가 변경되었습니다.',
    'Trạng thái đã đổi trên thiết bị khác.',
    'Status changed on another device.',
  );
  String get analytics =>
      _pick('직접 배달 분석', 'Phân tích giao hàng', 'Direct delivery analytics');
  String get grossSales =>
      _pick('배달 총매출', 'Doanh thu giao hàng', 'Delivery gross sales');
  String get orderCount => _pick('주문 건수', 'Số đơn', 'Orders');
  String get averageOrder => _pick('평균 주문액', 'Giá trị đơn TB', 'Average order');
  String get deliveryFeeSales =>
      _pick('고객 배송비', 'Phí giao hàng thu', 'Delivery fees charged');
  String get grabCost =>
      _pick('실제 Grab 비용', 'Chi phí Grab', 'Actual Grab cost');
  String get feeVariance => _pick('배송비 차액', 'Chênh lệch phí', 'Fee variance');
  String get ordersByHour => _pick('시간대별 주문', 'Đơn theo giờ', 'Orders by hour');
  String get ordersByRegion =>
      _pick('지역별 주문', 'Đơn theo khu vực', 'Orders by region');
  String get privacySuppressed =>
      _pick('소량 데이터 비공개', 'Ẩn do ít dữ liệu', 'Suppressed for privacy');
  String get settings =>
      _pick('직접 배달 설정', 'Cài đặt giao hàng', 'Direct delivery settings');
  String get publicSlug =>
      _pick('공개 주문 주소', 'Đường dẫn đặt hàng', 'Public order path');
  String get enableStorefront =>
      _pick('외부 주문 활성화', 'Bật đặt hàng bên ngoài', 'Enable storefront');
  String get pauseStorefront =>
      _pick('주문 일시중지', 'Tạm dừng nhận đơn', 'Pause ordering');
  String get accountingApproval =>
      _pick('회계 처리 방식 승인', 'Kế toán phê duyệt', 'Accounting approval');
  String get accountingApprovalWarning => _pick(
    '배송비가 기존 영수증·MISA에서 서비스 항목으로 처리되는 방식을 회계 담당자가 승인해야 활성화할 수 있습니다.',
    'Kế toán phải duyệt cách phí giao hàng được ghi nhận như một mục dịch vụ trên hóa đơn/MISA.',
    'Accounting must approve recording the delivery fee as a service line on receipts and MISA.',
  );
  String get bankBin =>
      _pick('은행 BIN 6자리', 'BIN ngân hàng 6 số', '6-digit bank BIN');
  String get bankAccount =>
      _pick('입금 계좌번호', 'Số tài khoản nhận', 'Receiving account');
  String get bankAccountHolder =>
      _pick('예금주', 'Chủ tài khoản', 'Account holder');
  String get minimumOrder =>
      _pick('최소 주문 금액', 'Đơn tối thiểu', 'Minimum order');
  String get save => _pick('저장', 'Lưu', 'Save');
  String get openCustomerPage => _pick(
    '고객 주문 페이지 열기',
    'Mở trang khách đặt hàng',
    'Open customer order page',
  );
  String get externalOrderQr => _pick(
    '외부 주문 QR 코드',
    'Mã QR đặt hàng bên ngoài',
    'External order QR code',
  );
  String get externalOrderQrHelp => _pick(
    '이 QR을 인쇄하거나 공유하면 고객이 해당 매장의 외부 주문 페이지로 바로 들어옵니다.',
    'In hoặc chia sẻ mã QR này để khách mở thẳng trang đặt hàng của cửa hàng.',
    'Print or share this QR to open this store’s external order page.',
  );
  String get copyPublicLink =>
      _pick('주문 링크 복사', 'Sao chép liên kết', 'Copy order link');
  String get downloadQr =>
      _pick('QR PNG 다운로드', 'Tải QR PNG', 'Download QR PNG');
  String get printQr => _pick('QR 인쇄', 'In mã QR', 'Print QR');
  String get publicLinkCopied =>
      _pick('주문 링크를 복사했습니다.', 'Đã sao chép liên kết.', 'Order link copied.');
  String get qrDownloaded =>
      _pick('QR 이미지를 저장했습니다.', 'Đã lưu ảnh QR.', 'QR image saved.');
  String get today => _pick('오늘', 'Hôm nay', 'Today');
  String get last7Days => _pick('최근 7일', '7 ngày qua', 'Last 7 days');
  String get last30Days => _pick('최근 30일', '30 ngày qua', 'Last 30 days');
  String get loading => _pick('불러오는 중', 'Đang tải', 'Loading');
  String get loadFailed => _pick(
    '데이터를 불러오지 못했습니다.',
    'Không thể tải dữ liệu.',
    'Could not load data.',
  );
  String get actionFailed => _pick(
    '처리하지 못했습니다.',
    'Không thể xử lý.',
    'The action could not be completed.',
  );
  String get requiredField => _pick('필수 입력입니다.', 'Bắt buộc.', 'Required.');
  String get currentState => _pick('현재 상태', 'Trạng thái', 'Current state');
  String get requestTime => _pick('접수 시간', 'Thời gian nhận', 'Received');
  String get quoteBreakdown =>
      _pick('최종 견적', 'Chi tiết báo giá', 'Final quote');
  String get supportingEvidence => _pick(
    'SePay는 보조 증거일 뿐이며 자동 승인하지 않습니다.',
    'SePay chỉ là bằng chứng hỗ trợ và không tự duyệt.',
    'SePay is supporting evidence only and never approves an order.',
  );
  String get linked => _pick('연결됨', 'Đã liên kết', 'Linked');
  String get link => _pick('연결', 'Liên kết', 'Link');
  String get approveConfirmTitle => _pick(
    '입금 확인 및 주문 확정',
    'Xác nhận tiền & đơn',
    'Confirm payment and order',
  );
  String get approvalSuccess => _pick(
    '입금을 확인해 주방으로 전달했습니다.',
    'Đã xác nhận tiền và gửi vào bếp.',
    'Payment confirmed and sent to the kitchen.',
  );
  String get quoteSent => _pick(
    '최종 금액을 고객에게 보냈습니다.',
    'Đã gửi tổng tiền cho khách.',
    'The final amount was sent to the customer.',
  );
  String get grabLinkSent => _pick(
    'Grab 링크를 고객에게 보냈습니다.',
    'Đã gửi link Grab cho khách.',
    'The Grab link was sent to the customer.',
  );
  String get invalidGrabLink => _pick(
    '올바른 Grab 공유 링크를 입력하세요.',
    'Nhập đúng liên kết chia sẻ Grab.',
    'Enter a valid Grab share link.',
  );
  String get backToQueue => _pick('주문 목록', 'Danh sách đơn', 'Order queue');
  String get all => _pick('전체', 'Tất cả', 'All');
  String get quoted => _pick('견적 완료', 'Đã báo giá', 'Quoted');
  String get proofSubmitted =>
      _pick('입금증 접수', 'Đã gửi bằng chứng', 'Proof submitted');
  String stateLabel(String state) => switch (state) {
    'awaiting_quote' => awaitingQuote,
    'quoted' => quoted,
    'awaiting_payment_review' => proofSubmitted,
    'proof_submitted' => proofSubmitted,
    'approved' => approved,
    'rejected' => rejected,
    'cancelled' => cancelled,
    'pending' => pending,
    'preparing' => _pick('조리 중', 'Đang làm', 'Preparing'),
    'ready' => _pick('픽업 준비', 'Sẵn sàng', 'Ready'),
    'dispatched' => dispatched,
    'completed' => _pick('완료', 'Hoàn tất', 'Completed'),
    _ => state,
  };
  String get paidDirect =>
      _pick('입금확인 · 직접배달', 'Đã trả · Giao trực tiếp', 'PAID · DIRECT DELIVERY');
  String get noTickets => _pick(
    '표시할 배달 티켓이 없습니다.',
    'Không có phiếu giao hàng.',
    'No delivery tickets to show.',
  );
  String get waitingForDispatch =>
      _pick('배차 대기', 'Chờ điều phối', 'Waiting for dispatch');
  String get dateRange => _pick('기간', 'Khoảng ngày', 'Date range');
  String get noAnalytics => _pick(
    '선택한 기간에 승인된 배달 주문이 없습니다.',
    'Không có đơn đã duyệt trong khoảng này.',
    'No approved delivery orders in this period.',
  );
  String get dailySales => _pick('일별 매출', 'Doanh thu theo ngày', 'Daily sales');
  String get bankLabel =>
      _pick('은행 표시명', 'Tên hiển thị ngân hàng', 'Bank display name');
  String get latitude => _pick('기본 위도', 'Vĩ độ mặc định', 'Default latitude');
  String get longitude =>
      _pick('기본 경도', 'Kinh độ mặc định', 'Default longitude');
  String get saved => _pick('저장했습니다.', 'Đã lưu.', 'Saved.');
  String get enableBlocked => _pick(
    '회계 승인 전에는 외부 주문을 활성화할 수 없습니다.',
    'Không thể bật trước khi kế toán phê duyệt.',
    'The storefront cannot be enabled before accounting approval.',
  );
}
