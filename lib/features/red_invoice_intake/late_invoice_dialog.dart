import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../core/services/company_tax_lookup_service.dart';
import 'buyer_information_form.dart';
import 'buyer_number.dart';
import 'late_invoice_service.dart';
import 'red_invoice_intake_service.dart';

class LateInvoiceCopy extends BuyerNumberCopy {
  LateInvoiceCopy(super.language);

  String get title =>
      pick('레드인보이스 추가 발행', 'Yêu cầu xuất hóa đơn VAT', 'Request VAT invoice');
  String get submit =>
      pick('등록하고 발행 요청', 'Lưu và yêu cầu xuất', 'Save and request invoice');
  String get draft => pick('임시 저장', 'Lưu nháp', 'Save draft');
  String get edit => pick(
    '구매자 정보 보완',
    'Bổ sung thông tin người mua',
    'Complete buyer information',
  );
  String get view =>
      pick('발행 상태 보기', 'Xem trạng thái hóa đơn', 'View invoice status');
  String get misa => pick('MISA에서 확인', 'Xem trên MISA', 'Open in MISA');
  String get accepted => pick(
    '레드인보이스 요청이 접수되었습니다',
    'Đã tiếp nhận yêu cầu xuất hóa đơn VAT',
    'VAT invoice request received',
  );
  String status(String state) => switch (state) {
    'none' => pick('미요청', 'Chưa yêu cầu', 'Not requested'),
    'draft' => pick('정보 보완 대기', 'Chờ bổ sung thông tin', 'Information needed'),
    'ready' => pick('발행 대기', 'Chờ xuất hóa đơn', 'Awaiting issuance'),
    'issued' => pick('외부 발행·신고 확인', 'Đã xuất / kê khai', 'Issued / reported'),
    'processing' => pick(
      '전송 상태 확인 필요',
      'Cần kiểm tra trạng thái gửi',
      'Check dispatch status',
    ),
    _ => pick('관리자 확인 필요', 'Cần quản lý kiểm tra', 'Manager review required'),
  };
  String action(String state) => switch (state) {
    'none' => title,
    'draft' => edit,
    'issued' => misa,
    _ => view,
  };
}

Future<LateInvoiceContext?> showLateInvoiceDialog(
  BuildContext context, {
  required LateInvoiceTarget target,
  LateInvoiceService? service,
  CompanyTaxLookupService? lookupService,
}) => showDialog<LateInvoiceContext>(
  context: context,
  barrierDismissible: false,
  builder: (_) => LateInvoiceDialog(
    target: target,
    service: service ?? LateInvoiceService(),
    lookupService: lookupService,
  ),
);

/// Shared by the cashier ledger and the administrator's general-receipt ledger.
class LateInvoiceDialog extends StatefulWidget {
  const LateInvoiceDialog({
    super.key,
    required this.target,
    required this.service,
    this.lookupService,
  });

  final LateInvoiceTarget target;
  final LateInvoiceService service;
  final CompanyTaxLookupService? lookupService;

  @override
  State<LateInvoiceDialog> createState() => _LateInvoiceDialogState();
}

class _LateInvoiceDialogState extends State<LateInvoiceDialog> {
  LateInvoiceContext? data;
  BuyerInformationController? buyer;
  String? error;
  bool loading = true, saving = false, advanced = false, saved = false;
  XFile? evidence;
  String? lastPayload;
  String requestId = const Uuid().v4();

  LateInvoiceCopy get copy =>
      LateInvoiceCopy(Localizations.localeOf(context).languageCode);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final value = await widget.service.load(widget.target);
      if (!mounted) return;
      buyer?.dispose();
      buyer = BuyerInformationController(value.buyer);
      setState(() {
        data = value;
        loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          error = copy.pick(
            '상태를 불러오지 못했습니다. 다시 확인해 주세요.',
            'Không tải được trạng thái. Vui lòng thử lại.',
            'Could not load the latest status. Try again.',
          );
        });
      }
    }
  }

  @override
  void dispose() {
    buyer?.dispose();
    super.dispose();
  }

  Future<void> _save(bool confirm) async {
    if (saving || data?.canEdit != true || buyer == null) return;
    buyer!.confirm = confirm;
    if (!buyer!.validate()) {
      setState(() {});
      return;
    }
    final patch = buyer!.patch;
    final payload = jsonEncode({
      'patch': patch,
      'confirm': confirm,
      'versions': data!.versions,
    });
    // Retry an uncertain request with its original ID. Edited inputs use a new ID.
    if (lastPayload != null && lastPayload != payload) {
      requestId = const Uuid().v4();
    }
    lastPayload = payload;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final value = await widget.service.submit(
        target: widget.target,
        requestId: requestId,
        versions: data!.versions,
        patch: patch,
        confirm: confirm,
      );
      if (!mounted) return;
      String? attachmentError;
      if (evidence != null && value.buyer['id'] is String) {
        try {
          await redInvoiceIntakeService.uploadEvidence(
            intakeId: value.buyer['id'] as String,
            storeId: widget.target.storeId,
            file: evidence!,
          );
        } catch (_) {
          attachmentError = copy.pick(
            '요청은 저장되었습니다. 증빙 첨부에 실패하여 관리자에게 별도 전달해 주세요.',
            'Yêu cầu đã được lưu. Tệp đính kèm lỗi; vui lòng chuyển riêng cho quản lý.',
            'The request is saved. Attachment upload failed; provide the evidence to your manager.',
          );
        }
      }
      if (mounted) {
        setState(() {
          data = value;
          saved = true;
          error = attachmentError;
        });
      }
    } catch (failure) {
      if (!mounted) return;
      final message = failure is PostgrestException ? failure.message : '';
      setState(() {
        error = message == 'POS_BUYER_CHANGED'
            ? copy.pick(
                '다른 직원이 정보를 변경했습니다. 입력을 복사해 보관한 뒤 최신 상태를 다시 확인해 주세요.',
                'Thông tin đã thay đổi. Giữ lại nội dung và kiểm tra trạng thái mới.',
                'Another employee changed this record. Keep your entries and reload the latest status.',
              )
            : message == 'LATE_INVOICE_PROTECTED'
            ? copy.pick(
                '전송·발행 또는 매출 확인 상태가 변경되었습니다. 새로 발행하지 않고 상태를 확인해 주세요.',
                'Trạng thái gửi, xuất hoặc xác nhận đã thay đổi. Vui lòng kiểm tra trước.',
                'Dispatch, issuance, or reporting status changed. Check the status before requesting again.',
              )
            : copy.pick(
                '저장 결과를 확인하지 못했습니다. 입력은 유지됩니다. 같은 요청으로 다시 시도할 수 있습니다.',
                'Chưa xác nhận được kết quả lưu. Nội dung được giữ lại; có thể thử lại cùng yêu cầu.',
                'Could not confirm the save. Your entries are retained; retrying uses the same request.',
              );
      });
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = data;
    final content = SizedBox(
      width: 680,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (value != null) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withValues(alpha: .35),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.target.receiptNumber,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    Text(value.storeName),
                    Text(
                      '${NumberFormat('#,##0', 'vi_VN').format(value.grossAmount)} VND',
                    ),
                    if (value.orderIds.length > 1)
                      Text(
                        copy.pick(
                          '연결 주문 ${value.orderIds.length}건',
                          '${value.orderIds.length} đơn liên kết',
                          '${value.orderIds.length} linked orders',
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (saved) ...[
                const Icon(
                  Icons.check_circle_outline,
                  color: Colors.green,
                  size: 44,
                ),
                Text(
                  value.state == 'draft' ? copy.status('draft') : copy.accepted,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(copy.status(value.state)),
                if (value.state == 'ready')
                  Text(switch (value.waitReason) {
                    'mapping' => copy.pick(
                      '메뉴 계산서 항목 확인 후 발행됩니다.',
                      'Chờ kiểm tra thông tin hàng hóa trên hóa đơn.',
                      'Awaiting invoice item review.',
                    ),
                    'configuration' => copy.pick(
                      '계산서 연동 설정 확인이 필요합니다.',
                      'Cần kiểm tra cấu hình kết nối hóa đơn.',
                      'Invoice integration configuration needs review.',
                    ),
                    _ => copy.pick(
                      '관리자가 기존 발행 절차에서 요청을 확인하고 처리합니다.',
                      'Quản lý sẽ kiểm tra và xử lý theo quy trình xuất hóa đơn.',
                      'Your manager will process the request through the existing issuance workflow.',
                    ),
                  }),
                Text(
                  copy.pick(
                    '발행 상태는 영수증에서 확인할 수 있습니다.',
                    'Có thể xem trạng thái xuất hóa đơn trên biên lai.',
                    'Check the receipt for the issuance status.',
                  ),
                ),
              ] else if (value.canEdit) ...[
                AbsorbPointer(
                  absorbing: saving,
                  child: BuyerInformationFields(
                    controller: buyer!,
                    storeId: widget.target.storeId,
                    lookupService: widget.lookupService,
                    compact: !advanced,
                  ),
                ),
                TextButton(
                  onPressed: saving
                      ? null
                      : () => setState(() => advanced = !advanced),
                  child: Text(
                    copy.pick(
                      '추가 구매자 정보',
                      'Thông tin người mua bổ sung',
                      'Additional buyer information',
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: saving
                      ? null
                      : () async {
                          final file = await ImagePicker().pickImage(
                            source: ImageSource.gallery,
                            imageQuality: 90,
                          );
                          if (mounted && file != null) {
                            setState(() => evidence = file);
                          }
                        },
                  icon: const Icon(Icons.attach_file),
                  label: Text(
                    evidence?.name ??
                        copy.pick(
                          '명함·고객 메시지 첨부 (선택)',
                          'Đính kèm danh thiếp / tin nhắn (tùy chọn)',
                          'Attach business card / message (optional)',
                        ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  copy.pick(
                    '추가 요청 사유: 결제 시 발행 요청 누락',
                    'Lý do: Bỏ sót yêu cầu khi thanh toán',
                    'Reason: Invoice request missed at checkout',
                  ),
                ),
              ] else ...[
                Text(
                  copy.status(value.state),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  copy.pick(
                    '기존 계산서와 매출 처리 상태를 관리자에게 확인해 주세요.',
                    'Vui lòng nhờ quản lý kiểm tra hóa đơn và trạng thái doanh thu.',
                    'Ask your manager to check the existing invoice and reporting status.',
                  ),
                ),
                if (value.state == 'issued' || value.state == 'processing')
                  OutlinedButton.icon(
                    onPressed: () => launchUrl(
                      Uri.parse('https://app3.meinvoice.vn/v3/'),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.open_in_new),
                    label: Text(copy.misa),
                  ),
              ],
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  error!,
                  key: const Key('late_invoice_error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
    final actions = [
      TextButton(
        onPressed: saving
            ? null
            : () => Navigator.pop(context, saved ? data : null),
        child: Text(
          copy.pick(
            saved ? '영수증으로 돌아가기' : '닫기',
            saved ? 'Về biên lai' : 'Đóng',
            saved ? 'Return to receipt' : 'Close',
          ),
        ),
      ),
      if (!loading && !saved)
        OutlinedButton(
          onPressed: saving ? null : _load,
          child: Text(
            copy.pick('상태 다시 확인', 'Kiểm tra lại trạng thái', 'Refresh status'),
          ),
        ),
      if (!loading && !saved && value?.canEdit == true) ...[
        OutlinedButton(
          key: const Key('late_invoice_draft'),
          onPressed: saving ? null : () => _save(false),
          child: Text(copy.draft),
        ),
        FilledButton.icon(
          key: const Key('late_invoice_submit'),
          onPressed: saving ? null : () => _save(true),
          icon: saving
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.post_add),
          label: Text(copy.submit),
        ),
      ],
    ];
    return PopScope(
      canPop: !saving,
      child: MediaQuery.sizeOf(context).width < 700
          ? Dialog.fullscreen(
              key: const Key('late_invoice_dialog'),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        copy.title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 12),
                      Expanded(child: content),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.end,
                        children: actions,
                      ),
                    ],
                  ),
                ),
              ),
            )
          : AlertDialog(
              key: const Key('late_invoice_dialog'),
              title: Text(copy.title),
              content: content,
              actions: actions,
            ),
    );
  }
}
