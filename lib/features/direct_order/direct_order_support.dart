import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../core/payments/vietqr_payload.dart';
import 'direct_order_dialog.dart';
import 'direct_order_copy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'direct_order_models.dart';
import 'direct_order_money.dart';
import 'direct_order_service.dart';
import 'direct_order_staff_service.dart';

class DirectOrderSupportCopy {
  const DirectOrderSupportCopy(this.locale);
  final String locale;
  String text(String key) =>
      _labels[key]![locale == 'ko'
          ? 0
          : locale == 'vi'
          ? 2
          : 1];
  String get optional => text('optional');
  static const _labels = <String, List<String>>{
    'optional': ['선택', 'Optional', 'Không bắt buộc'],
    'save': ['저장', 'Save', 'Lưu'],
    'close': ['닫기', 'Close', 'Đóng'],
    'invoice': [
      'VAT 세금계산서 발행 정보',
      'VAT invoice details',
      'Thông tin xuất hóa đơn VAT',
    ],
    'requested': [
      '세금계산서 발행 요청',
      'Request VAT invoice',
      'Yêu cầu xuất hóa đơn VAT',
    ],
    'tax': ['세금번호', 'Tax code', 'Mã số thuế'],
    'legal': ['회사명 / 구매자명', 'Company / buyer name', 'Tên công ty / người mua'],
    'address': ['발행 주소', 'Billing address', 'Địa chỉ xuất hóa đơn'],
    'email': ['이메일', 'Email', 'Email'],
    'phone': ['연락처', 'Phone', 'Số điện thoại'],
    'partial': [
      '부분 입금을 확인했습니다. 부족금의 추가 결제를 요청하세요.',
      'Partial receipt confirmed. Request the outstanding balance.',
      'Đã xác nhận nhận tiền một phần. Yêu cầu thanh toán số còn thiếu.',
    ],
    'payments': [
      '결제·추가 청구',
      'Payments and additional requests',
      'Thanh toán và yêu cầu bổ sung',
    ],
    'received': [
      '확인된 입금액',
      'Confirmed received amount',
      'Số tiền đã xác nhận nhận',
    ],
    'remaining': ['미수금', 'Amount outstanding', 'Số tiền còn thiếu'],
    'actual': [
      '실제 입금 확인 금액',
      'Actual received amount',
      'Số tiền thực nhận đã kiểm tra',
    ],
    'reference': [
      '은행 입금 확인 근거 / 거래 참조',
      'Bank receipt confirmation / reference',
      'Thông tin xác nhận nhận tiền / mã giao dịch',
    ],
    'view': ['이미지 확인', 'View image', 'Xem ảnh'],
    'review': ['입금 확인', 'Confirm receipt', 'Xác nhận nhận tiền'],
    'verify': [
      '고객 이미지와 실제 입금 내역을 대조했습니다.',
      'I compared the customer image with the actual bank receipt.',
      'Tôi đã đối chiếu ảnh của khách với tiền thực nhận.',
    ],
    'food_balance': [
      '부족금 추가 결제 요청',
      'Request outstanding food payment',
      'Yêu cầu thanh toán tiền món còn thiếu',
    ],
    'delivery': [
      '실제 배송비 정산',
      'Reconcile actual delivery fee',
      'Đối soát phí giao thực tế',
    ],
    'provider': ['배송 업체', 'Delivery provider', 'Đơn vị giao hàng'],
    'cost_reference': [
      '배송 예약·영수증 번호',
      'Booking / receipt reference',
      'Mã đặt giao / biên nhận',
    ],
    'cost_evidence': [
      '배송비 증빙 첨부',
      'Delivery cost evidence',
      'Chứng từ phí giao',
    ],
    'cost_difference': [
      '배송비 차액',
      'Delivery fee difference',
      'Chênh lệch phí giao',
    ],
    'cost_refund': [
      '배송비 차액 환불 확인',
      'Record delivery fee refund',
      'Xác nhận hoàn chênh lệch phí giao',
    ],

    'amount': ['청구 금액', 'Amount requested', 'Số tiền yêu cầu'],
    'reason': ['청구 사유', 'Reason', 'Lý do'],
    'defer': [
      '음식 먼저 결제 · 배송비는 조리 중 확정',
      'Pay food first; confirm delivery fee during preparation',
      'Thanh toán món trước; xác nhận phí giao hàng khi chuẩn bị',
    ],
    'no_fee': [
      '배송비 청구 없음으로 확정',
      'Confirm no delivery fee',
      'Xác nhận không thu phí giao hàng',
    ],
    'fee_pending': [
      '배송비 미확정 · 인계 및 최종 완료 대기',
      'Delivery fee unconfirmed; handoff and completion pending',
      'Chưa xác nhận phí giao hàng; chờ bàn giao và hoàn tất',
    ],
    'driver_fee_pending': [
      '배송비 미정 · 기사에게 직접 결제',
      'Delivery fee to be confirmed; pay the driver directly',
      'Phí giao hàng chưa xác nhận; trả trực tiếp cho tài xế',
    ],
    'delivery_separate_payments': [
      '배송비는 별도로 결제합니다. 추가 결제 내역을 확인하세요.',
      'Delivery is paid separately. Check the additional payment details.',
      'Phí giao hàng thanh toán riêng. Kiểm tra chi tiết thanh toán bổ sung.',
    ],
    'awaiting_consent': [
      '고객 동의 대기',
      'Awaiting customer agreement',
      'Chờ khách đồng ý',
    ],
    'pending': ['결제 대기', 'Awaiting payment', 'Chờ thanh toán'],
    'review_status': [
      '입금 확인 대기',
      'Awaiting receipt review',
      'Chờ xác nhận nhận tiền',
    ],
    'paid': ['입금 확인 완료', 'Payment confirmed', 'Đã xác nhận thanh toán'],
    'void': ['청구 취소', 'Request withdrawn', 'Đã hủy yêu cầu'],
    'accept': ['배송비 확인·동의', 'Agree to delivery fee', 'Đồng ý phí giao hàng'],
    'decline': ['동의하지 않음', 'Decline', 'Không đồng ý'],
    'attach': ['이미지·PDF 첨부', 'Attach image or PDF', 'Đính kèm ảnh hoặc PDF'],
    'proof': [
      '입금 증빙 이미지 보내기',
      'Send transfer proof image',
      'Gửi ảnh chứng từ chuyển khoản',
    ],
    'retry': ['전송 다시 시도', 'Retry sending', 'Thử gửi lại'],
    'sending': ['전송 중', 'Sending', 'Đang gửi'],
    'send': ['전송', 'Send', 'Gửi'],
    'file_limit': [
      '이미지·PDF 최대 5 MiB',
      'Images or PDF up to 5 MiB',
      'Ảnh hoặc PDF tối đa 5 MiB',
    ],
    'refund': [
      '취소·환불 상담',
      'Cancellation and refund support',
      'Hỗ trợ hủy và hoàn tiền',
    ],
    'bank': ['환불 은행', 'Refund bank', 'Ngân hàng hoàn tiền'],
    'account': ['환불 계좌', 'Refund account', 'Tài khoản hoàn tiền'],
    'holder': ['계좌 명의', 'Account holder', 'Chủ tài khoản'],
    'note': ['회계팀 전달 메모', 'Note for accounting', 'Ghi chú cho kế toán'],
    'refund_complete': [
      '실제 환불 완료 기록',
      'Record completed refund',
      'Ghi nhận đã hoàn tiền',
    ],
    'pickup_delivery_refund': [
      '픽업 전환 · 추가 배송비 환불 기록',
      'Record additional delivery refund for pickup',
      'Ghi nhận hoàn phí giao hàng bổ sung khi khách tự lấy',
    ],
    'pickup_refund_pending': [
      '추가 배송비 환불 확인 후 픽업을 완료할 수 있습니다.',
      'Complete pickup after confirming the additional delivery refund.',
      'Hoàn tất khách tự lấy sau khi xác nhận hoàn phí giao hàng bổ sung.',
    ],
    'refund_ref': [
      '환불 이체 참조',
      'Refund transfer reference',
      'Mã giao dịch hoàn tiền',
    ],
    'cancel_order': ['결제된 주문 취소', 'Cancel paid order', 'Hủy đơn đã thanh toán'],
    'close_chat': [
      '환불 상담 종료',
      'Close refund conversation',
      'Đóng hội thoại hoàn tiền',
    ],
    'chat_closed': [
      '상담이 종료되었습니다.',
      'This conversation is closed.',
      'Hội thoại đã đóng.',
    ],
    'overpayment': [
      '미수금보다 큽니다. 실제 초과 입금 내역을 별도로 대조하세요.',
      'Amount exceeds the balance. Reconcile the actual overpayment separately.',
      'Số tiền vượt công nợ. Đối soát riêng khoản chuyển dư.',
    ],
    'legacy_cost_review': [
      '매장에서 실제 배송비 증빙을 확인 중입니다.',
      'The store is verifying actual delivery cost.',
      'Cửa hàng đang xác minh phí giao thực tế.',
    ],
    'error': [
      '처리하지 못했습니다. 최신 주문을 확인하고 다시 시도하세요.',
      'Unable to complete. Refresh the order and try again.',
      'Không thể xử lý. Vui lòng làm mới đơn và thử lại.',
    ],
  };
}

Map<String, dynamic> supportMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<Map<String, dynamic>> supportRows(Object? value) => value is List
    ? value.whereType<Map>().map((v) => Map<String, dynamic>.from(v)).toList()
    : [];
num supportNumber(Object? value) =>
    value is num ? value : num.tryParse('$value') ?? 0;

class DirectOrderReceiptReview {
  const DirectOrderReceiptReview(this.amount, this.reference);
  final num amount;
  final String reference;
}

Future<DirectOrderReceiptReview?> showDirectOrderReceiptReview(
  BuildContext context,
  num due, {
  Future<void> Function()? viewProof,
}) async {
  final copy = DirectOrderSupportCopy(
    Localizations.localeOf(context).languageCode,
  );
  final amount = TextEditingController();
  final reference = TextEditingController();
  bool verified = false;
  final result = await showDirectOrderDialog<DirectOrderReceiptReview>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) {
        final parsed = parseDirectOrderVnd(amount.text);
        return AlertDialog(
          title: Text(copy.text('review')),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${copy.text('remaining')}: ${formatDirectOrderVnd(due)} VND',
                  ),
                  if (viewProof != null)
                    TextButton.icon(
                      onPressed: viewProof,
                      icon: const Icon(Icons.image_outlined),
                      label: Text(copy.text('view')),
                    ),
                  TextField(
                    key: const Key('direct_actual_received_amount'),
                    controller: amount,
                    keyboardType: TextInputType.number,
                    inputFormatters: const [DirectOrderVndInputFormatter()],
                    decoration: InputDecoration(
                      labelText: copy.text('actual'),
                      suffixText: 'VND',
                      errorText: parsed != null && parsed > due
                          ? copy.text('overpayment')
                          : null,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  TextField(
                    key: const Key('direct_bank_receipt_reference'),
                    controller: reference,
                    maxLength: 200,
                    decoration: InputDecoration(
                      labelText: copy.text('reference'),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  CheckboxListTile(
                    key: const Key('direct_actual_receipt_verified'),
                    value: verified,
                    title: Text(copy.text('verify')),
                    onChanged: (v) => setState(() => verified = v == true),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(copy.text('close')),
            ),
            FilledButton(
              key: const Key('direct_order_approval_confirm'),
              onPressed:
                  verified &&
                      parsed != null &&
                      parsed > 0 &&
                      parsed <= due &&
                      reference.text.trim().isNotEmpty
                  ? () => Navigator.pop(
                      dialogContext,
                      DirectOrderReceiptReview(parsed, reference.text.trim()),
                    )
                  : null,
              child: Text(copy.text('review')),
            ),
          ],
        );
      },
    ),
  );
  // Dialog route transitions may still reference controllers after completion.
  Future<void>.delayed(const Duration(milliseconds: 400), () {
    amount.dispose();
    reference.dispose();
  });
  return result;
}

class DirectOrderAttachmentButton extends StatefulWidget {
  const DirectOrderAttachmentButton({
    super.key,
    required this.storeId,
    required this.requestId,
    required this.upload,
    required this.onSent,
    this.proofOnly = false,
    this.enabled = true,
  });
  final String storeId, requestId;
  final Future<void> Function(
    String path,
    String filename,
    String mimeType,
    Uint8List bytes,
  )
  upload;
  final Future<void> Function() onSent;
  final bool proofOnly, enabled;
  @override
  State<DirectOrderAttachmentButton> createState() =>
      _DirectOrderAttachmentButtonState();
}

class _DirectOrderAttachmentButtonState
    extends State<DirectOrderAttachmentButton> {
  String? _path, _filename, _mime;
  Uint8List? _bytes;
  bool _busy = false;
  bool _uploaded = false;
  Future<void> _send() async {
    if (_busy) return;
    setState(() => _busy = true);
    final copy = DirectOrderSupportCopy(
      Localizations.localeOf(context).languageCode,
    );
    try {
      if (_bytes == null) {
        final file = await openFile(
          acceptedTypeGroups: [
            XTypeGroup(
              label: 'Attachments',
              extensions: [
                'jpg',
                'jpeg',
                'png',
                'webp',
                if (!widget.proofOnly) 'pdf',
              ],
            ),
          ],
        );
        if (file == null || !mounted) return;
        final bytes = await file.readAsBytes();
        if (!mounted) return;
        final extension = file.name.split('.').last.toLowerCase();
        final mime = {
          'jpg': 'image/jpeg',
          'jpeg': 'image/jpeg',
          'png': 'image/png',
          'webp': 'image/webp',
          'pdf': 'application/pdf',
        }[extension];
        if (mime == null || bytes.isEmpty || bytes.length > 5242880) {
          throw const DirectOrderException('DIRECT_ORDER_ATTACHMENT_INVALID');
        }
        final confirmed = await showDirectOrderDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(file.name),
            content: SizedBox(
              width: 420,
              child: mime == 'application/pdf'
                  ? const Icon(Icons.picture_as_pdf, size: 80)
                  : Image.memory(
                      bytes,
                      height: 220,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.broken_image),
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(copy.text('close')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(copy.text('send')),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        _bytes = bytes;
        _filename = file.name;
        _mime = mime;
        _path =
            '${widget.storeId}/${widget.requestId}/${const Uuid().v4()}.${extension == 'jpeg' ? 'jpg' : extension}';
      }
      if (!_uploaded) await widget.upload(_path!, _filename!, _mime!, _bytes!);
      _uploaded = true;
      await widget.onSent();
      _path = null;
      _bytes = null;
      _uploaded = false;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(copy.text('error'))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = DirectOrderSupportCopy(
      Localizations.localeOf(context).languageCode,
    );
    return OutlinedButton.icon(
      onPressed: _busy || !widget.enabled ? null : _send,
      icon: Icon(_busy ? Icons.hourglass_top : Icons.attach_file),
      label: Text(
        copy.text(
          _busy
              ? 'sending'
              : _bytes != null
              ? 'retry'
              : widget.proofOnly
              ? 'proof'
              : 'attach',
        ),
      ),
    );
  }
}

class DirectOrderStaffSupportPanel extends StatefulWidget {
  const DirectOrderStaffSupportPanel({
    super.key,
    required this.storeId,
    required this.requestId,
    required this.detail,
    required this.service,
    required this.onChanged,
  });
  final String storeId, requestId;
  final Map<String, dynamic> detail;
  final DirectOrderStaffService service;
  final Future<void> Function() onChanged;
  @override
  State<DirectOrderStaffSupportPanel> createState() =>
      _DirectOrderStaffSupportPanelState();
}

class _DirectOrderStaffSupportPanelState
    extends State<DirectOrderStaffSupportPanel> {
  bool _busy = false;
  Map<String, dynamic> get _support => supportMap(widget.detail['support']);
  DirectOrderSupportCopy get _copy =>
      DirectOrderSupportCopy(Localizations.localeOf(context).languageCode);
  Future<void> _act(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await widget.onChanged();
    } catch (error) {
      if (mounted) {
        await widget.onChanged();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              DirectOrderCopy(_copy.locale).errorMessage(
                error is PostgrestException
                    ? error.message
                    : error is DirectOrderException
                    ? error.code
                    : 'DIRECT_ORDER_SUPPORT_CHANGED',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _action(String action, Map<String, dynamic> payload) =>
      _act(() async {
        await widget.service.supportAction(
          storeId: widget.storeId,
          requestId: widget.requestId,
          expectedVersion: (_support['version'] as num?)?.toInt() ?? 1,
          action: action,
          payload: payload,
        );
      });
  Future<Map<String, String>?> _form(
    String title,
    Map<String, String> fields, {
    Set<String> requiredKeys = const {},
  }) async {
    final controllers = {
      for (final entry in fields.entries)
        entry.key: TextEditingController(text: entry.value),
    };
    final result = await showDirectOrderDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final entry in controllers.entries)
                    TextField(
                      controller: entry.value,
                      maxLength:
                          entry.key == 'address' ||
                              entry.key == 'reason' ||
                              entry.key == 'note'
                          ? 500
                          : const {
                                  'tax': 30,
                                  'legal': 300,
                                  'phone': 30,
                                  'email': 254,
                                  'bank': 100,
                                  'account': 100,
                                }[entry.key] ??
                                200,
                      keyboardType: entry.key == 'amount'
                          ? TextInputType.number
                          : TextInputType.text,
                      inputFormatters: entry.key == 'amount'
                          ? const [DirectOrderVndInputFormatter()]
                          : null,
                      decoration: InputDecoration(
                        labelText: _copy.text(entry.key),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(_copy.text('close')),
            ),
            FilledButton(
              onPressed:
                  requiredKeys.every(
                    (k) => controllers[k]!.text.trim().isNotEmpty,
                  )
                  ? () => Navigator.pop(dialogContext, {
                      for (final entry in controllers.entries)
                        entry.key: entry.value.text.trim(),
                    })
                  : null,
              child: Text(_copy.text('save')),
            ),
          ],
        ),
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      for (final c in controllers.values) {
        c.dispose();
      }
    });
    return result;
  }

  Future<void> _invoice() async {
    final current = supportMap(_support['invoice']);
    final fields = await _form(_copy.text('invoice'), {
      for (final key in ['tax', 'legal', 'address', 'email', 'phone'])
        key:
            '${current[{'tax': 'tax_code', 'legal': 'legal_name'}[key] ?? key] ?? ''}',
    });
    if (fields != null && mounted) {
      await _action('invoice', {
        'requested': true,
        'tax_code': fields['tax'],
        'legal_name': fields['legal'],
        'address': fields['address'],
        'email': fields['email'],
        'phone': fields['phone'],
      });
    }
  }

  Future<void> _charge(String kind) async {
    if (kind == 'delivery') {
      await _reconcileDelivery();
      return;
    }
    final fields = await _form(
      _copy.text(kind),
      {
        'amount': kind == 'food_balance' ? '${_support['food_due'] ?? ''}' : '',
        'reason': '',
      },
      requiredKeys: {'amount', 'reason'},
    );
    if (fields != null && mounted) {
      await _action('charge', {
        'kind': kind,
        'amount': parseDirectOrderVnd(fields['amount']!),
        'reason': fields['reason'],
      });
    }
  }

  Future<void> _reconcileDelivery() async {
    final amount = TextEditingController(
      text: formatDirectOrderVnd(
        supportNumber(
          supportMap(_support['delivery_cost'])['actual_fee'] ??
              supportMap(widget.detail['financial'])['delivery_fee_total'],
        ),
      ),
    );
    final reference = TextEditingController();
    String provider = 'grab';
    String? evidence;
    final result = await showDirectOrderDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) {
          final attachments = supportRows(widget.detail['messages'])
              .where(
                (m) =>
                    m['sender_type'] == 'cashier' &&
                    m['message_type'] == 'attachment',
              )
              .toList();
          final parsed = parseDirectOrderVnd(amount.text);
          final collected = supportNumber(
            supportMap(_support['delivery_cost'])['collected'],
          );
          return AlertDialog(
            title: Text(_copy.text('delivery')),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      key: const Key('direct_actual_delivery_cost'),
                      controller: amount,
                      keyboardType: TextInputType.number,
                      inputFormatters: const [DirectOrderVndInputFormatter()],
                      decoration: InputDecoration(
                        labelText: _copy.text('amount'),
                        suffixText: 'VND',
                      ),
                      onChanged: (_) => update(() {}),
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: provider,
                      items: ['grab', 'be', 'other']
                          .map(
                            (p) => DropdownMenuItem(value: p, child: Text(p)),
                          )
                          .toList(),
                      onChanged: (v) => update(() => provider = v!),
                      decoration: InputDecoration(
                        labelText: _copy.text('provider'),
                      ),
                    ),
                    TextField(
                      controller: reference,
                      maxLength: 200,
                      decoration: InputDecoration(
                        labelText: _copy.text('cost_reference'),
                      ),
                      onChanged: (_) => update(() {}),
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: evidence,
                      items: attachments
                          .map(
                            (m) => DropdownMenuItem(
                              value: m['id'].toString(),
                              child: Text(
                                supportMap(
                                      m['metadata'],
                                    )['filename']?.toString() ??
                                    m['body']?.toString() ??
                                    _copy.text('cost_evidence'),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => update(() => evidence = v),
                      decoration: InputDecoration(
                        labelText: _copy.text('cost_evidence'),
                      ),
                    ),
                    DirectOrderAttachmentButton(
                      storeId: widget.storeId,
                      requestId: widget.requestId,
                      upload: (path, name, mime, bytes) =>
                          widget.service.uploadChatAttachment(
                            storeId: widget.storeId,
                            requestId: widget.requestId,
                            path: path,
                            filename: name,
                            mimeType: mime,
                            bytes: bytes,
                          ),
                      onSent: () async {
                        await widget.onChanged();
                        update(() {});
                      },
                    ),
                    if (parsed != null)
                      Text(
                        '${_copy.text('cost_difference')}: ${formatDirectOrderVnd(parsed - collected)} VND',
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(_copy.text('close')),
              ),
              FilledButton(
                onPressed:
                    parsed != null &&
                        parsed >= 0 &&
                        evidence != null &&
                        reference.text.trim().isNotEmpty
                    ? () => Navigator.pop(dialogContext, {
                        'operation_id': const Uuid().v4(),
                        'amount': parsed,
                        'provider': provider,
                        'reference': reference.text.trim(),
                        'evidence_message_id': evidence,
                      })
                    : null,
                child: Text(_copy.text('save')),
              ),
            ],
          );
        },
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      amount.dispose();
      reference.dispose();
    });
    if (result != null && mounted) {
      await _action('reconcile_delivery_fee', result);
    }
  }

  Future<void> _review(Map<String, dynamic> charge) async {
    final reviewed = supportRows(
      _support['receipts'],
    ).map((r) => r['proof_message_id']).toSet();
    final proofs = supportRows(widget.detail['messages'])
        .where(
          (m) =>
              supportMap(m['metadata'])['charge_id'] == charge['id'] &&
              !reviewed.contains(m['id']),
        )
        .toList();
    if (proofs.isEmpty) return;
    final proof = proofs.last;
    final quotes = supportRows(widget.detail['quotes']);
    final quote = quotes
        .where((q) => q['id'] == supportMap(proof['metadata'])['quote_id'])
        .firstOrNull;
    if (quote == null) return;
    final review = await showDirectOrderReceiptReview(
      context,
      supportNumber(charge['amount']) - supportNumber(charge['received']),
      viewProof: () => openDirectOrderAttachment(
        context,
        () => widget.service.attachmentRequest(
          storeId: widget.storeId,
          requestId: widget.requestId,
          action: 'staff_attachment_url',
          payload: {'message_id': proof['id']},
        ),
      ),
    );
    if (review != null && mounted) {
      await _act(() async {
        await widget.service.recordReceipt(
          storeId: widget.storeId,
          requestId: widget.requestId,
          quoteId: quote['id'].toString(),
          proofMessageId: proof['id'].toString(),
          amount: review.amount,
          bankReference: review.reference,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_support.isEmpty) return const SizedBox.shrink();
    final request = supportMap(widget.detail['request']);
    final terminal = const {
      'cancelled',
      'rejected',
      'expired',
    }.contains(request['state']);
    final approved = request['state'] == 'approved';
    final beforeHandoff = !const {
      'dispatched',
      'completed',
      'cancelled',
    }.contains(supportMap(widget.detail['fulfillment'])['status']);
    final charges = supportRows(_support['charges']);
    final outstanding =
        supportNumber(_support['food_due']) +
        charges
            .where((c) => c['kind'] == 'delivery' && c['status'] != 'void')
            .fold<num>(
              0,
              (sum, c) =>
                  sum +
                  supportNumber(c['amount']) -
                  supportNumber(c['received']),
            );
    final invoice = supportMap(_support['invoice']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _copy.text('invoice'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (invoice['requested'] == true)
                  Text(
                    '${invoice['legal_name'] ?? ''} · ${invoice['tax_code'] ?? ''}\n${invoice['address'] ?? ''}\n${invoice['email'] ?? ''}',
                  ),
                OutlinedButton(
                  onPressed: _busy ? null : _invoice,
                  child: Text(_copy.text('requested')),
                ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _copy.text('payments'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  '${_copy.text('received')}: ${formatDirectOrderVnd(supportNumber(_support['food_received']) + supportNumber(_support['delivery_received']))} VND',
                ),
                Text(
                  '${_copy.text('remaining')}: ${formatDirectOrderVnd(outstanding)} VND',
                ),
                if (request['state'] == 'awaiting_quote' &&
                    supportMap(widget.detail['delivery'])['method'] != 'pickup')
                  SwitchListTile(
                    key: const Key('direct_deferred_delivery_fee'),
                    value: _support['delivery_fee_deferred'] == true,
                    onChanged: _busy
                        ? null
                        : (v) => _action('defer_delivery_fee', {'enabled': v}),
                    title: Text(_copy.text('defer')),
                  ),
                if (_support['delivery_fee_finalized'] == false)
                  Text(_copy.text('fee_pending')),
                for (final charge in charges)
                  ListTile(
                    title: Text(
                      '${_copy.text(charge['kind'].toString())} · ${formatDirectOrderVnd(supportNumber(charge['amount']))} VND',
                    ),
                    subtitle: Text(
                      '${charge['reason']} · ${_copy.text(charge['status'] == 'review' ? 'review_status' : charge['status'].toString())}',
                    ),
                    trailing: charge['status'] == 'review'
                        ? TextButton(
                            onPressed: _busy ? null : () => _review(charge),
                            child: Text(_copy.text('review')),
                          )
                        : null,
                  ),
                if (!terminal &&
                    supportNumber(_support['food_due']) > 0 &&
                    supportNumber(_support['food_received']) > 0)
                  OutlinedButton(
                    onPressed: _busy ? null : () => _charge('food_balance'),
                    child: Text(_copy.text('food_balance')),
                  ),
                if (approved &&
                    beforeHandoff &&
                    supportMap(widget.detail['delivery'])['method'] !=
                        'pickup') ...[
                  OutlinedButton(
                    onPressed: _busy ? null : () => _charge('delivery'),
                    child: Text(_copy.text('delivery')),
                  ),
                  if (supportNumber(
                        _support['delivery_adjustment_refund_due'],
                      ) >
                      0)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              final form = await _form(
                                _copy.text('cost_refund'),
                                {
                                  'amount':
                                      '${_support['delivery_adjustment_refund_due']}',
                                  'refund_ref': '',
                                },
                                requiredKeys: {'amount', 'refund_ref'},
                              );
                              if (form != null && mounted) {
                                await _action('refund_delivery_adjustment', {
                                  'operation_id': const Uuid().v4(),
                                  'amount': parseDirectOrderVnd(
                                    form['amount']!,
                                  ),
                                  'reference': form['refund_ref'],
                                });
                              }
                            },
                      child: Text(
                        '${_copy.text('cost_refund')} · ${formatDirectOrderVnd(supportNumber(_support['delivery_adjustment_refund_due']))} VND',
                      ),
                    ),
                ],
                if (approved && beforeHandoff)
                  TextButton(
                    onPressed: _busy ? null : () => _action('cancel_order', {}),
                    child: Text(_copy.text('cancel_order')),
                  ),
                if (approved &&
                    supportNumber(_support['pickup_delivery_refund_due']) > 0)
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            final form = await _form(
                              _copy.text('pickup_delivery_refund'),
                              {'amount': '', 'refund_ref': ''},
                              requiredKeys: {'amount', 'refund_ref'},
                            );
                            if (form != null && mounted) {
                              await _action('refund_delivery_complete', {
                                'operation_id': const Uuid().v4(),
                                'amount': parseDirectOrderVnd(form['amount']!),
                                'reference': form['refund_ref'],
                              });
                            }
                          },
                    child: Text(
                      '${_copy.text('pickup_delivery_refund')} · ${formatDirectOrderVnd(supportNumber(_support['pickup_delivery_refund_due']))} VND',
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (terminal)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _copy.text('refund'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    '${_copy.text('remaining')}: ${formatDirectOrderVnd(supportNumber(_support['refund_due']))} VND',
                  ),
                  Text(
                    '${_support['refund_status'] ?? ''} · ${formatDirectOrderVnd(supportNumber(_support['refunded_total']))} VND',
                  ),
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            final current = supportMap(_support['refund']);
                            final form = await _form(_copy.text('refund'), {
                              for (final k in [
                                'bank',
                                'account',
                                'holder',
                                'note',
                              ])
                                k: '${current[k] ?? ''}',
                            });
                            if (form != null && mounted) {
                              await _action('refund_details', form);
                            }
                          },
                    child: Text(_copy.text('save')),
                  ),
                  OutlinedButton(
                    onPressed:
                        _busy ||
                            supportNumber(_support['refund_due']) <= 0 ||
                            _support['chat_open'] == false
                        ? null
                        : () async {
                            final form = await _form(
                              _copy.text('refund_complete'),
                              {'amount': '', 'refund_ref': ''},
                              requiredKeys: {'amount', 'refund_ref'},
                            );
                            if (form != null && mounted) {
                              await _action('refund_complete', {
                                'operation_id': const Uuid().v4(),
                                'amount': parseDirectOrderVnd(form['amount']!),
                                'reference': form['refund_ref'],
                              });
                            }
                          },
                    child: Text(_copy.text('refund_complete')),
                  ),
                  TextButton(
                    onPressed:
                        _busy ||
                            supportNumber(_support['refund_due']) > 0 ||
                            _support['chat_open'] == false
                        ? null
                        : () => _action('close_chat', {}),
                    child: Text(_copy.text('close_chat')),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class DirectOrderCustomerSupportPanel extends StatelessWidget {
  const DirectOrderCustomerSupportPanel({
    super.key,
    required this.status,
    required this.session,
    required this.bank,
    required this.storeId,
    required this.service,
    required this.onChanged,
  });
  final DirectOrderStatus status;
  final DirectOrderSession session;
  final DirectOrderBank bank;
  final String storeId;
  final DirectOrderService service;
  final Future<void> Function() onChanged;
  @override
  Widget build(BuildContext context) {
    final copy = DirectOrderSupportCopy(
      Localizations.localeOf(context).languageCode,
    );
    final charges = supportRows(
      status.support['charges'],
    ).where((c) => c['status'] != 'void').toList();
    if (charges.isEmpty &&
        status.support['delivery_fee_finalized'] != false &&
        supportNumber(status.support['pickup_delivery_refund_due']) <= 0 &&
        supportRows(status.support['delivery_cost_changes']).isEmpty) {
      return const SizedBox.shrink();
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              copy.text('payments'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final change in supportRows(
              status.support['delivery_cost_changes'],
            ))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${change['provider']} · ${change['reference']}'),
                subtitle: Text(
                  '${formatDirectOrderVnd(supportNumber(change['previous_fee']))} → ${formatDirectOrderVnd(supportNumber(change['actual_fee']))} VND',
                ),
              ),
            if (supportNumber(
                  status.support['delivery_adjustment_refund_due'],
                ) >
                0)
              Text(
                '${copy.text('cost_refund')}: ${formatDirectOrderVnd(supportNumber(status.support['delivery_adjustment_refund_due']))} VND',
              ),
            if (supportNumber(status.support['pickup_delivery_refund_due']) > 0)
              Text(copy.text('pickup_refund_pending')),
            if (status.support['delivery_fee_finalized'] == false)
              Text(copy.text('fee_pending')),
            for (final charge in charges)
              _CustomerChargeCard(
                key: ValueKey(charge['id']),
                charge: charge,
                status: status,
                session: session,
                bank: bank,
                storeId: storeId,
                service: service,
                onChanged: onChanged,
              ),
          ],
        ),
      ),
    );
  }
}

class _CustomerChargeCard extends StatefulWidget {
  const _CustomerChargeCard({
    super.key,
    required this.charge,
    required this.status,
    required this.session,
    required this.bank,
    required this.storeId,
    required this.service,
    required this.onChanged,
  });
  final Map<String, dynamic> charge;
  final DirectOrderStatus status;
  final DirectOrderSession session;
  final DirectOrderBank bank;
  final String storeId;
  final DirectOrderService service;
  final Future<void> Function() onChanged;
  @override
  State<_CustomerChargeCard> createState() => _CustomerChargeCardState();
}

class _CustomerChargeCardState extends State<_CustomerChargeCard> {
  @override
  Widget build(BuildContext context) {
    final c = widget.charge,
        copy = DirectOrderSupportCopy(
          Localizations.localeOf(context).languageCode,
        );
    final due = supportNumber(c['amount']) - supportNumber(c['received']);
    final qrData = VietQrPayload.bankTransfer(
      bankBin: widget.bank.bin,
      accountNumber: widget.bank.accountNumber,
      amount: due.toInt(),
      purpose:
          '${widget.status.referenceCode} ${c['id'].toString().substring(0, 8)}',
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${copy.text(c['kind'].toString())}: ${formatDirectOrderVnd(due)} VND',
          ),
          Text(c['reason'].toString()),
          Text(
            copy.text(
              c['status'] == 'review'
                  ? 'review_status'
                  : c['status'].toString(),
            ),
          ),
          if (c['status'] == 'awaiting_consent')
            Text(copy.text('legacy_cost_review')),
          if (c['status'] == 'pending' && due > 0) ...[
            Center(child: QrImageView(data: qrData, size: 240)),
            Text(
              '${widget.bank.label}\n${widget.bank.accountHolder}\n${widget.bank.accountNumber}\n${widget.status.referenceCode}',
            ),
            DirectOrderAttachmentButton(
              key: ValueKey('${c['id']}:proof'),
              storeId: widget.storeId,
              requestId: widget.status.requestId,
              proofOnly: true,
              upload: (path, name, mime, bytes) =>
                  widget.service.uploadSupportAttachment(
                    session: widget.session,
                    requestId: widget.status.requestId,
                    chargeId: c['id'].toString(),
                    path: path,
                    filename: name,
                    mimeType: mime,
                    bytes: bytes,
                  ),
              onSent: widget.onChanged,
            ),
          ],
        ],
      ),
    );
  }
}

Future<void> openDirectOrderAttachment(
  BuildContext context,
  Future<Map<String, dynamic>> Function() load,
) async {
  try {
    final result = await load();
    final uri = Uri.tryParse(result['signed_url'].toString());
    if (uri == null ||
        uri.scheme != 'https' ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw const DirectOrderException('DIRECT_ORDER_ATTACHMENT_INVALID');
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            DirectOrderSupportCopy(
              Localizations.localeOf(context).languageCode,
            ).text('error'),
          ),
        ),
      );
    }
  }
}
