import 'package:flutter/material.dart';

import 'direct_order_dialog.dart';
import 'direct_order_translation.dart';

class DirectOrderRequirement {
  const DirectOrderRequirement({
    required this.id,
    required this.version,
    required this.requestText,
    required this.status,
    this.replyText,
    this.replyMessageId,
    this.replyLocale,
    this.replyTranslationStatus = 'original',
    this.followupText,
    this.customerContextText,
    this.sourceLocale = 'vi',
    this.itemLabelVi,
    this.printRequestVi,
    this.printReplyVi,
    this.printScope = 'both',
    this.needsConfirmation = true,
    this.requestTranslations = const {},
    this.replyTranslations = const {},
  });

  final String id, requestText, status, sourceLocale, printScope;
  final int version;
  final String? replyText, replyMessageId, followupText, itemLabelVi;
  final String? customerContextText;
  final String? replyLocale;
  final String replyTranslationStatus;
  final String? printRequestVi, printReplyVi;
  final bool needsConfirmation;
  final Map<String, dynamic> requestTranslations, replyTranslations;
  bool get isConfirmed => status == 'confirmed';
  bool get awaitingCustomer => status == 'awaiting_customer';

  factory DirectOrderRequirement.fromJson(Map<String, dynamic> json) {
    if (json['id'] is! String ||
        json['request_text'] is! String ||
        json['version'] is! int ||
        (json['version'] as int) < 1 ||
        !{
          'awaiting_reply',
          'awaiting_customer',
          'confirmed',
        }.contains(json['status'])) {
      throw const FormatException('Invalid customer requirement');
    }
    Map<String, dynamic> translations(String key) => json[key] is Map
        ? Map<String, dynamic>.from(json[key] as Map)
        : const {};
    return DirectOrderRequirement(
      id: json['id'] as String,
      version: json['version'] as int,
      requestText: json['request_text'] as String,
      status: json['status'] as String,
      replyText: json['reply_text'] as String?,
      replyMessageId: json['reply_message_id'] as String?,
      replyLocale: json['reply_locale'] as String?,
      replyTranslationStatus:
          json['reply_translation_status'] as String? ?? 'original',
      followupText: json['followup_text'] as String?,
      customerContextText: json['customer_context_text'] as String?,
      sourceLocale: json['source_locale'] as String? ?? 'vi',
      itemLabelVi: json['item_label_vi'] as String?,
      printRequestVi: json['print_request_vi'] as String?,
      printReplyVi: json['print_reply_vi'] as String?,
      printScope: json['print_scope'] as String? ?? 'both',
      needsConfirmation: json['needs_confirmation'] != false,
      requestTranslations: translations('request_translations'),
      replyTranslations: translations('reply_translations'),
    );
  }

  static List<DirectOrderRequirement> fromRows(Object? rows) => rows is List
      ? rows
            .map(
              (row) => DirectOrderRequirement.fromJson(
                Map<String, dynamic>.from(row as Map),
              ),
            )
            .toList(growable: false)
      : const [];
}

class DirectOrderRequirementCopy {
  const DirectOrderRequirementCopy(this.locale);
  final String locale;
  String text(String ko, String vi, String en) => switch (locale) {
    'ko' => ko,
    'en' => en,
    _ => vi,
  };
  String get requests =>
      text('고객 요청 사항', 'Yêu cầu của khách', 'Customer requests');
  String get replyDue => text('답변 필요', 'Cần trả lời', 'Reply needed');
  String get awaiting =>
      text('고객 확인 대기', 'Chờ khách xác nhận', 'Awaiting customer');
  String get confirmed => text(
    '확정 · 영수증 반영',
    'Đã thống nhất · In trên hóa đơn',
    'Confirmed · Included on receipt',
  );
  String get reply => text('요청에 답변하기', 'Trả lời yêu cầu', 'Reply to request');
  String get answer => text('캐셔 답변', 'Trả lời của thu ngân', 'Cashier reply');
  String get agree =>
      text('이 내용으로 확정', 'Đồng ý nội dung này', 'Confirm these details');
  String get clarify => text(
    '추가 요청 / 다시 문의',
    'Yêu cầu thêm / Hỏi lại',
    'Ask or request a change',
  );
  String get pendingGate => text(
    '모든 요청 사항의 답변과 확정 후 견적을 보낼 수 있습니다.',
    'Hãy trả lời và thống nhất mọi yêu cầu trước khi gửi báo giá.',
    'Reply to and confirm every request before sending a quote.',
  );
  String get required =>
      text('내용을 입력해주세요.', 'Vui lòng nhập nội dung.', 'Please enter text.');
  String get confirmNeeded =>
      text('고객 확인 필요', 'Cần khách xác nhận', 'Customer confirmation required');
  String get confirmHelp => text(
    '변경·제약·대안이 있으면 고객의 확인을 받습니다. 해제하면 답변 전송과 함께 확정됩니다.',
    'Nếu có thay đổi hoặc hạn chế, hãy xin khách xác nhận. Bỏ chọn để thống nhất ngay khi gửi.',
    'Keep checked for changes, limitations or alternatives. Uncheck to confirm when sending.',
  );
  String get printHelp => text(
    '종이 전표는 베트남어로 출력합니다. 아래 요청·합의 문구를 확인해주세요. 고객은 위 답변에 동의합니다.',
    'Phiếu in bằng tiếng Việt. Kiểm tra yêu cầu và nội dung thống nhất bên dưới. Khách xác nhận câu trả lời phía trên.',
    'Paper slips use Vietnamese. Review the request and agreed wording below. The customer confirms your reply above.',
  );
  String get printRequest => text(
    '전표용 고객 요청 (베트남어)',
    'Yêu cầu để in (tiếng Việt)',
    'Printed request (Vietnamese)',
  );
  String get printReply => text(
    '전표용 합의 내용 (베트남어)',
    'Nội dung thống nhất để in (tiếng Việt)',
    'Printed agreement (Vietnamese)',
  );
  String get printInvalid => text(
    '베트남어 또는 영문 문자로 입력해주세요.',
    'Vui lòng dùng ký tự tiếng Việt hoặc Latin.',
    'Use Vietnamese or Latin characters.',
  );
  String get send => text('답변 전송', 'Gửi trả lời', 'Send reply');
  String get cancel => text('취소', 'Hủy', 'Cancel');
  String scope(String scope) => switch (scope) {
    'preparation' => text('주방·포장', 'Bếp / Đóng gói', 'Kitchen / Packing'),
    'delivery' => text('기사·배송', 'Tài xế / Giao hàng', 'Driver / Delivery'),
    _ => text('주방·기사 모두', 'Bếp và tài xế', 'Kitchen and driver'),
  };
}

class DirectOrderRequirementCard extends StatelessWidget {
  const DirectOrderRequirementCard({
    super.key,
    required this.requirement,
    required this.cashier,
    this.busy = false,
    this.onReply,
    this.onConfirm,
    this.onClarify,
  });
  final DirectOrderRequirement requirement;
  final bool cashier, busy;
  final VoidCallback? onReply, onConfirm, onClarify;

  @override
  Widget build(BuildContext context) {
    final copy = DirectOrderRequirementCopy(
      Localizations.localeOf(context).languageCode,
    );
    final q = requirement;
    return Card(
      key: Key('requirement_${q.id}'),
      color: q.isConfirmed ? const Color(0xffeef7ef) : const Color(0xfffff7e8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  q.isConfirmed
                      ? Icons.check_circle_outline
                      : Icons.push_pin_outlined,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    q.isConfirmed
                        ? copy.confirmed
                        : q.awaitingCustomer
                        ? copy.awaiting
                        : copy.replyDue,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            if (q.itemLabelVi != null) Text(q.itemLabelVi!),
            const SizedBox(height: 8),
            DirectOrderTranslatedText(
              original: q.requestText,
              translations: q.requestTranslations,
              status: 'original',
            ),
            if (q.replyText != null) ...[
              const Divider(),
              Text(copy.answer, style: Theme.of(context).textTheme.labelSmall),
              DirectOrderTranslatedText(
                original: q.replyText!,
                translations: q.replyTranslations,
                status: q.replyLocale != null && q.replyLocale != copy.locale
                    ? q.replyTranslationStatus
                    : 'original',
              ),
            ],
            if (q.followupText != null || q.customerContextText != null) ...[
              const Divider(),
              Text(
                copy.clarify,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(q.followupText ?? q.customerContextText!),
            ],
            if (cashier && !q.isConfirmed) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: Key('requirement_reply_${q.id}'),
                onPressed: busy ? null : onReply,
                icon: const Icon(Icons.reply),
                label: Text(copy.reply),
              ),
            ],
            if (!cashier && q.awaitingCustomer) ...[
              const SizedBox(height: 10),
              FilledButton(
                key: Key('requirement_confirm_${q.id}'),
                onPressed: busy ? null : onConfirm,
                child: Text(copy.agree),
              ),
              TextButton(
                key: Key('requirement_clarify_${q.id}'),
                onPressed: busy ? null : onClarify,
                child: Text(copy.clarify),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class DirectOrderRequirementReply {
  const DirectOrderRequirementReply(
    this.body,
    this.needsConfirmation,
    this.printRequestVi,
    this.printReplyVi,
    this.printScope,
  );
  final String body, printRequestVi, printReplyVi, printScope;
  final bool needsConfirmation;
}

// Match the server's printable Vietnamese/ASCII alphabet. Control characters and
// unsupported scripts cannot be silently stripped from the agreed paper copy.
bool directOrderPrintableVi(String text) => RegExp(
  r'^[ -~ÀÁÂÃÈÉÊÌÍÒÓÔÕÙÚÝàáâãèéêìíòóôõùúýĂăĐđĨĩŨũƠơƯưẠ-ỹ]+$',
).hasMatch(text);

class DirectOrderRequirementReplyDialog extends StatefulWidget {
  const DirectOrderRequirementReplyDialog({
    super.key,
    required this.requirement,
    this.draft,
  });
  final DirectOrderRequirement requirement;
  final DirectOrderRequirementReply? draft;
  @override
  State<DirectOrderRequirementReplyDialog> createState() =>
      _RequirementReplyDialogState();
}

class _RequirementReplyDialogState
    extends State<DirectOrderRequirementReplyDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _body, _requestVi, _replyVi;
  bool _needsConfirmation = true;
  String _scope = 'both';
  @override
  void initState() {
    super.initState();
    final q = widget.requirement;
    final draft = widget.draft;
    _body = TextEditingController(
      text: draft?.body ?? (q.followupText == null ? q.replyText : ''),
    );
    _requestVi = TextEditingController(
      text:
          draft?.printRequestVi ??
          q.printRequestVi ??
          q.requestTranslations['vi']?.toString() ??
          (q.sourceLocale == 'vi' ? q.requestText : ''),
    );
    _replyVi = TextEditingController(
      text:
          draft?.printReplyVi ?? (q.followupText == null ? q.printReplyVi : ''),
    );
    _scope = draft?.printScope ?? q.printScope;
    _needsConfirmation = draft?.needsConfirmation ?? true;
  }

  @override
  void dispose() {
    _body.dispose();
    _requestVi.dispose();
    _replyVi.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final copy = DirectOrderRequirementCopy(
      Localizations.localeOf(context).languageCode,
    );
    String? validate(String? text, {bool print = false}) {
      final value = text?.trim() ?? '';
      if (value.isEmpty) return copy.required;
      if (print && !directOrderPrintableVi(value)) return copy.printInvalid;
      return null;
    }

    return AlertDialog(
      title: Text(copy.reply),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.requirement.requestText,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                if (widget.requirement.followupText != null)
                  Text(widget.requirement.followupText!),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('requirement_reply_body'),
                  controller: _body,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: 2000,
                  validator: validate,
                  decoration: InputDecoration(labelText: copy.answer),
                  onChanged: (text) {
                    if (Localizations.localeOf(context).languageCode == 'vi') {
                      _replyVi.text = text;
                    }
                  },
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(copy.confirmNeeded),
                  subtitle: Text(copy.confirmHelp),
                  value: _needsConfirmation,
                  onChanged: (value) =>
                      setState(() => _needsConfirmation = value ?? true),
                ),
                Text(
                  copy.printHelp,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  key: const Key('requirement_print_request'),
                  controller: _requestVi,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 2000,
                  validator: (text) => validate(text, print: true),
                  decoration: InputDecoration(labelText: copy.printRequest),
                ),
                TextFormField(
                  key: const Key('requirement_print_reply'),
                  controller: _replyVi,
                  minLines: 2,
                  maxLines: 5,
                  maxLength: 2000,
                  validator: (text) => validate(text, print: true),
                  decoration: InputDecoration(labelText: copy.printReply),
                ),
                DropdownButtonFormField<String>(
                  initialValue: _scope,
                  isExpanded: true,
                  items: ['both', 'preparation', 'delivery']
                      .map(
                        (s) => DropdownMenuItem(
                          value: s,
                          child: Text(copy.scope(s)),
                        ),
                      )
                      .toList(),
                  onChanged: (s) => _scope = s ?? 'both',
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(copy.cancel),
        ),
        FilledButton(
          key: const Key('requirement_reply_submit'),
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            Navigator.pop(
              context,
              DirectOrderRequirementReply(
                _body.text.trim(),
                _needsConfirmation,
                _requestVi.text.trim(),
                _replyVi.text.trim(),
                _scope,
              ),
            );
          },
          child: Text(copy.send),
        ),
      ],
    );
  }
}

Future<String?> showRequirementClarification(BuildContext context) =>
    showDirectOrderDialog<String>(
      context: context,
      builder: (_) => const _RequirementClarificationDialog(),
    );

class _RequirementClarificationDialog extends StatefulWidget {
  const _RequirementClarificationDialog();
  @override
  State<_RequirementClarificationDialog> createState() =>
      _RequirementClarificationDialogState();
}

class _RequirementClarificationDialogState
    extends State<_RequirementClarificationDialog> {
  final controller = TextEditingController();
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final copy = DirectOrderRequirementCopy(
      Localizations.localeOf(context).languageCode,
    );
    return AlertDialog(
      title: Text(copy.clarify),
      content: Form(
        key: form,
        child: TextFormField(
          key: const Key('requirement_customer_followup'),
          controller: controller,
          autofocus: true,
          minLines: 3,
          maxLines: 6,
          maxLength: 2000,
          validator: (text) =>
              text?.trim().isNotEmpty == true ? null : copy.required,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(copy.cancel),
        ),
        FilledButton(
          onPressed: () {
            if (form.currentState!.validate()) {
              Navigator.pop(context, controller.text.trim());
            }
          },
          child: Text(copy.send),
        ),
      ],
    );
  }
}

class DirectOrderConfirmedNotes extends StatelessWidget {
  const DirectOrderConfirmedNotes({super.key, required this.text});
  final String? text;
  @override
  Widget build(BuildContext context) {
    if (text?.trim().isNotEmpty != true) return const SizedBox.shrink();
    final copy = DirectOrderRequirementCopy(
      Localizations.localeOf(context).languageCode,
    );
    final title = copy.text(
      '확정된 요청 사항',
      'Yêu cầu đã thống nhất',
      'Agreed instructions',
    );
    return InkWell(
      onTap: () => showDirectOrderDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(text!)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(copy.text('닫기', 'Đóng', 'Close')),
            ),
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          '✓ $title: $text',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
