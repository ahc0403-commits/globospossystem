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
  String get pausedTitle => _pick(
    '현재 배달 주문을 잠시 쉬고 있습니다',
    'Cửa hàng đang tạm ngưng nhận đơn giao hàng',
    'Delivery ordering is temporarily paused',
  );
  String get pausedMessage => _pick(
    '현재 주문량이 많아 새 배달 주문을 받기 어렵습니다. 불편을 드려 정말 죄송합니다. 잠시 후 다시 주문해 주세요.',
    'Hiện tại cửa hàng có nhiều đơn nên tạm thời chưa thể nhận thêm đơn giao hàng. Chúng tôi thành thật xin lỗi vì sự bất tiện này. Vui lòng quay lại đặt hàng sau ít phút.',
    'We are handling a high volume of orders and cannot accept new delivery orders right now. We are very sorry for the inconvenience. Please try again a little later.',
  );
  String get paused => pausedTitle;
  String get apologyEmojiLabel =>
      _pick('죄송한 마음', 'Lời xin lỗi chân thành', 'A sincere apology');
  String get checkAgain => _pick('다시 확인', 'Kiểm tra lại', 'Check again');
  String get deliveryOpen =>
      _pick('배달 OPEN', 'Giao hàng OPEN', 'Delivery OPEN');
  String get deliveryClosed =>
      _pick('배달 CLOSED', 'Giao hàng CLOSED', 'Delivery CLOSED');
  String get deliveryNotConfigured =>
      _pick('배달 미설정', 'Chưa bật giao hàng', 'Delivery not configured');
  String get deliveryStateUnavailable => _pick(
    '배달 상태 확인 실패',
    'Không thể kiểm tra giao hàng',
    'Delivery state unavailable',
  );
  String get pauseConfirmTitle => _pick(
    '배달 주문을 닫을까요?',
    'Tạm ngưng nhận đơn giao hàng?',
    'Close delivery ordering?',
  );
  String get pauseConfirmMessage => _pick(
    '새 배달 주문 접수만 중지됩니다. 이미 접수된 주문은 계속 처리할 수 있습니다.',
    'Chỉ ngưng nhận đơn giao hàng mới. Các đơn đã nhận vẫn có thể tiếp tục xử lý.',
    'Only new delivery orders will stop. Orders already received can still be processed.',
  );
  String get pauseAction =>
      _pick('배달 주문 닫기', 'Tạm ngưng giao hàng', 'Close delivery');
  String get resumeConfirmTitle => _pick(
    '배달 주문을 다시 열까요?',
    'Nhận lại đơn giao hàng?',
    'Reopen delivery ordering?',
  );
  String get resumeConfirmMessage => _pick(
    '주방에서 새 배달 주문을 받을 준비가 되었는지 확인해 주세요.',
    'Vui lòng xác nhận bếp đã sẵn sàng nhận đơn giao hàng mới.',
    'Please confirm that the kitchen is ready for new delivery orders.',
  );
  String get resumeAction =>
      _pick('배달 주문 열기', 'Mở lại giao hàng', 'Reopen delivery');
  String get keepCurrentState => _pick('취소', 'Hủy', 'Cancel');
  String get deliveryPausedSuccess => _pick(
    '새 배달 주문 접수를 닫았습니다.',
    'Đã tạm ngưng nhận đơn giao hàng mới.',
    'New delivery ordering is closed.',
  );
  String get deliveryResumedSuccess => _pick(
    '새 배달 주문 접수를 열었습니다.',
    'Đã mở lại nhận đơn giao hàng.',
    'New delivery ordering is open.',
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
    'DIRECT_ORDER_VERIFIED_PAYMENT_REQUIRED' => verifiedPaymentRequired,
    'DIRECT_ORDER_SEPAY_TRANSACTION_ALREADY_USED' => _pick(
      '이 입금은 이미 다른 주문에 연결되었습니다.',
      'Giao dịch này đã được liên kết với đơn khác.',
      'This transfer is already linked to another order.',
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
    'DIRECT_ORDER_CASH_PAYOUT_LOCKED' => _pick(
      '이미 금고에서 지급한 배달비는 변경할 수 없습니다.',
      'Không thể thay đổi phí giao hàng đã chi tiền mặt từ két.',
      'A delivery fee already paid from the safe cannot be changed.',
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
    'DIRECT_ORDER_DRIVER_RECEIPT_REPRINT_NOT_AVAILABLE' ||
    'DIRECT_ORDER_CUSTOMER_RECEIPT_REPRINT_NOT_AVAILABLE' => _pick(
      '첫 출력이 완료된 뒤 재출력할 수 있습니다.',
      'Chỉ có thể in lại sau khi bản đầu tiên hoàn tất.',
      'Reprinting is available after the first copy completes.',
    ),
    'DIRECT_ORDER_REQUEST_NOT_APPROVABLE' ||
    'DIRECT_ORDER_REQUEST_NOT_REJECTABLE' ||
    'DIRECT_ORDER_NOT_APPROVED' ||
    'DIRECT_ORDER_FINANCIAL_RECONCILIATION_FAILED' ||
    'DIRECT_ORDER_SEPAY_CANDIDATE_INVALID' ||
    'DIRECT_ORDER_CUSTOMER_DIRECT_FEE_MUST_BE_EMPTY' ||
    'DIRECT_ORDER_DELIVERY_PAYMENT_MODE_CONFLICT' ||
    'DIRECT_DELIVERY_TICKET_VERSION_CONFLICT' ||
    'DIRECT_DELIVERY_TICKET_TRANSITION_INVALID' ||
    'DIRECT_ORDER_CLEANUP_NOT_ELIGIBLE' ||
    'DIRECT_ORDER_CLEANUP_TOO_EARLY' => actionFailed,
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
  String get deliveryAddress =>
      _pick('배송 주소', 'Địa chỉ giao hàng', 'Delivery address');
  String get addressInputHint => _pick(
    '도로명·건물명·동네를 포함한 전체 주소를 입력하세요',
    'Nhập địa chỉ đầy đủ: đường, tòa nhà, phường/xã',
    'Enter the full street, building and neighborhood address',
  );
  String get invalidPhone => _pick(
    '전화번호 형식을 확인해 주세요.',
    'Vui lòng kiểm tra định dạng số điện thoại.',
    'Please check the phone number format.',
  );
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
  String get requiredFields => _pick(
    '배송 주소(3자 이상), 상세주소, 받는 분, 전화번호를 모두 입력해 주세요.',
    'Vui lòng nhập địa chỉ giao hàng (ít nhất 3 ký tự), địa chỉ chi tiết, tên và số điện thoại.',
    'Enter a delivery address (at least 3 characters), address details, recipient and phone number.',
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
  String get completedOrderReady => _pick(
    '이전 주문이 완료되었습니다. 바로 새 주문을 시작할 수 있습니다.',
    'Đơn trước đã hoàn tất. Bạn có thể đặt đơn mới ngay.',
    'Your previous order is complete. You can start a new order now.',
  );
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
  String get orderItems => _pick('주문 메뉴', 'Món đã đặt', 'Order items');
  String get enterGrabFee => _pick(
    '고객에게 안내할 Grab 배송비',
    'Phí Grab báo khách',
    'Grab fee quoted to customer',
  );
  String get deliveryPaymentMethod => _pick(
    '배송비 결제 방식',
    'Cách thanh toán phí giao hàng',
    'Delivery fee payment',
  );
  String get customerPaysDriver => _pick(
    '고객이 기사에게 직접 결제',
    'Khách trả trực tiếp cho tài xế',
    'Customer pays the driver',
  );
  String get customerPaysDriverHelp => _pick(
    '배송비는 매장 결제 금액과 Bill에 포함되지 않습니다.',
    'Phí giao hàng không nằm trong số tiền trả cho cửa hàng hoặc hóa đơn.',
    'The delivery fee is excluded from the store payment and bill.',
  );
  String get storePrepaysDriver => _pick(
    '매장이 기사비 대납',
    'Cửa hàng trả trước phí tài xế',
    'Store prepays the driver',
  );
  String get storePrepaysDriverHelp => _pick(
    '기사를 호출해 실제 금액을 확인하고 고객 동의를 받은 뒤 입력해 주세요.',
    'Hãy gọi tài xế, xác nhận phí thực tế và được khách đồng ý trước khi nhập.',
    'Call the driver, confirm the actual fee, and obtain customer agreement before entering it.',
  );
  String get storeCollectedDeliveryFee => _pick(
    '매장이 고객에게 받을 실제 배송비',
    'Phí giao hàng thực tế cửa hàng thu của khách',
    'Actual delivery fee collected by store',
  );
  String get noStoreCashPayout => _pick(
    '고객이 기사에게 직접 지급하므로 매장 현금 지출로 기록하지 않습니다.',
    'Khách trả trực tiếp cho tài xế nên không ghi nhận chi tiền mặt của cửa hàng.',
    'The customer pays the driver, so no store cash payout is recorded.',
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
  String paymentConfirmed(String amount) => _pick(
    '입금 확인: $amount',
    'Đã nhận tiền: $amount',
    'Payment received: $amount',
  );
  String verifiedPaymentSummary(String amount, String? reference) {
    final suffix = reference == null || reference.trim().isEmpty
        ? ''
        : ' · $reference';
    return '${paymentConfirmed(amount)}$suffix';
  }

  String get verifiedPaymentRequired => _pick(
    '실제 입금 거래를 이 주문에 연결한 후 승인할 수 있습니다.',
    'Chỉ có thể duyệt sau khi liên kết giao dịch thực tế với đơn này.',
    'Link a verified bank transfer to this order before approval.',
  );
  String get confirmedAmount =>
      _pick('확인한 입금액', 'Số tiền đã xác nhận', 'Confirmed transfer amount');
  String get bankReference =>
      _pick('은행 거래번호·메모', 'Mã giao dịch ngân hàng', 'Bank reference');
  String get manualApprovalCheck => _pick(
    '시스템이 확인한 실제 입금과 주문 금액이 일치합니다. 승인 시 주문이 주방으로 전달됩니다.',
    'Giao dịch thực tế do hệ thống xác nhận khớp với đơn. Khi duyệt, đơn sẽ được gửi vào bếp.',
    'The verified bank transfer matches this order. Approval sends the order to the kitchen.',
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
  String get actualGrabFeeCashPayout => _pick(
    '실제 Grab 비용 (금고 현금 지출)',
    'Phí Grab thực tế (chi tiền mặt từ két)',
    'Actual Grab cost (cash paid from safe)',
  );
  String get deliveryCashPayoutRequired => _pick(
    'Grab 링크와 금고에서 지급한 실제 배달비를 입력해 주세요.',
    'Nhập link Grab và phí giao hàng thực tế đã chi tiền mặt từ két.',
    'Enter the Grab link and the actual delivery fee paid in cash from the safe.',
  );
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
  String get customerBill =>
      _pick('고객 Bill', 'Hóa đơn khách hàng', 'Customer bill');
  String get customerBillHelp => _pick(
    '결제 완료 금액의 최초 Bill은 자동 요청됩니다. 실패 시 같은 요청을 다시 시도할 수 있습니다.',
    'Hóa đơn đầu tiên được tự động yêu cầu sau khi thanh toán. Có thể thử lại cùng yêu cầu nếu lỗi.',
    'The first paid bill is queued automatically. A failed request can be retried safely.',
  );
  String get printCustomerBill => _pick('Bill 출력', 'In hóa đơn', 'Print bill');
  String get reprintCustomerBill =>
      _pick('Bill 재출력', 'In lại hóa đơn', 'Reprint bill');
  String get retryCustomerBill =>
      _pick('Bill 출력 다시 시도', 'Thử in lại hóa đơn', 'Retry bill printing');
  String get customerBillQueued => _pick(
    '고객 Bill 출력을 요청했습니다.',
    'Đã gửi yêu cầu in hóa đơn khách hàng.',
    'The customer bill was queued.',
  );
  String get customerBillReprintQueued => _pick(
    '고객 Bill 재출력을 요청했습니다.',
    'Đã gửi yêu cầu in lại hóa đơn khách hàng.',
    'The customer bill reprint was queued.',
  );
  String customerBillStatus(String? status, String? errorCode) =>
      switch (status) {
        'pending' => _pick('출력 대기', 'Đang chờ in', 'Queued'),
        'printing' => _pick('출력 중', 'Đang in', 'Printing'),
        'done' => _pick('출력 완료', 'Đã in', 'Printed'),
        'failed' when errorCode == 'NO_DESTINATION' => _pick(
          '영수증 프린터가 설정되지 않았습니다.',
          'Chưa cài đặt máy in hóa đơn.',
          'The receipt printer is not configured.',
        ),
        'failed' => _pick('출력 실패', 'In thất bại', 'Print failed'),
        _ => _pick('출력 요청 없음', 'Chưa yêu cầu in', 'Not queued'),
      };
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
    '입금 이미지는 참고 자료입니다. 실제 SePay 입금 거래를 연결해야 승인할 수 있습니다.',
    'Ảnh chuyển khoản chỉ để tham khảo. Phải liên kết giao dịch SePay thực tế mới có thể duyệt.',
    'The image is supporting evidence. A verified SePay transfer must be linked before approval.',
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
  String get saved => _pick('저장했습니다.', 'Đã lưu.', 'Saved.');
  String get enableBlocked => _pick(
    '회계 승인 전에는 외부 주문을 활성화할 수 없습니다.',
    'Không thể bật trước khi kế toán phê duyệt.',
    'The storefront cannot be enabled before accounting approval.',
  );
}
