import 'package:flutter/material.dart';

/// Original text stays accessible when a translation is shown or unavailable.
class DirectOrderTranslatedText extends StatefulWidget {
  const DirectOrderTranslatedText({
    super.key,
    required this.original,
    this.translations = const {},
    this.status,
    this.style,
  });
  final String original;
  final Map<String, dynamic> translations;
  final String? status;
  final TextStyle? style;
  @override
  State<DirectOrderTranslatedText> createState() =>
      _DirectOrderTranslatedTextState();
}

class _DirectOrderTranslatedTextState extends State<DirectOrderTranslatedText> {
  bool _showOriginal = false;
  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    final translated = widget.translations[locale]?.toString();
    final hasTranslation =
        translated != null &&
        translated.isNotEmpty &&
        translated != widget.original;
    String label(String ko, String en, String vi) => locale == 'ko'
        ? ko
        : locale == 'vi'
        ? vi
        : en;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          hasTranslation ? translated : widget.original,
          style: widget.style,
        ),
        if (hasTranslation) ...[
          TextButton(
            onPressed: () => setState(() => _showOriginal = !_showOriginal),
            child: Text(
              label(
                _showOriginal ? '원문 숨기기' : '원문 보기',
                _showOriginal ? 'Hide original' : 'View original',
                _showOriginal ? 'Ẩn bản gốc' : 'Xem bản gốc',
              ),
            ),
          ),
          if (_showOriginal)
            Text(widget.original, style: Theme.of(context).textTheme.bodySmall),
        ] else if (widget.status == 'pending' || widget.status == 'failed')
          Text(
            widget.status == 'failed'
                ? label(
                    '번역을 완료하지 못해 원문을 표시합니다.',
                    'Translation unavailable; showing original.',
                    'Chưa dịch được; hiển thị bản gốc.',
                  )
                : label('자동 번역 중', 'Translating', 'Đang dịch'),
            style: Theme.of(context).textTheme.labelSmall,
          ),
      ],
    );
  }
}
