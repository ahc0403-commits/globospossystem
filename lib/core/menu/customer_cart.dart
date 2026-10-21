import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

String cartText(String language, String ko, String vi, String en) =>
    switch (language) {
      'ko' => ko,
      'vi' => vi,
      _ => en,
    };

class CustomerCartItemCard extends StatelessWidget {
  const CustomerCartItemCard({
    super.key,
    required this.id,
    required this.name,
    required this.price,
    required this.quantity,
    required this.language,
    required this.onMinus,
    required this.onPlus,
    required this.onRemove,
    this.onEdit,
    this.imageUrl,
    this.description,
    this.children = const [],
    this.maxQuantity = 50,
  });
  final String id, name, language;
  final String? imageUrl, description;
  final double price;
  final int quantity, maxQuantity;
  final VoidCallback onMinus, onPlus, onRemove;
  final VoidCallback? onEdit;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final money = NumberFormat.currency(
      locale: 'vi_VN',
      symbol: '₫',
      decimalDigits: 0,
    );
    String text(String ko, String vi, String en) =>
        cartText(language, ko, vi, en);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (imageUrl?.trim().isNotEmpty == true) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  imageUrl!,
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox(
                    width: 64,
                    height: 64,
                    child: Icon(Icons.restaurant),
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(name, style: Theme.of(context).textTheme.titleMedium),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          children: [
            Text('${money.format(price)} × $quantity'),
            Text(
              money.format(price * quantity),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
        ...children,
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconButton(
              key: Key('${id}_minus'),
              tooltip: text('수량 줄이기', 'Giảm số lượng', 'Decrease quantity'),
              onPressed: onMinus,
              icon: const Icon(Icons.remove_circle_outline),
            ),
            Text('$quantity', key: Key('${id}_quantity')),
            IconButton(
              key: Key('${id}_plus'),
              tooltip: text('수량 늘리기', 'Tăng số lượng', 'Increase quantity'),
              onPressed: quantity >= maxQuantity ? null : onPlus,
              icon: const Icon(Icons.add_circle_outline),
            ),
            if (onEdit != null)
              TextButton(
                key: Key('${id}_options'),
                onPressed: onEdit,
                child: Text(text('옵션 변경', 'Đổi tùy chọn', 'Change options')),
              ),
            TextButton(
              key: Key('${id}_remove'),
              onPressed: onRemove,
              child: Text(text('삭제', 'Xóa', 'Remove')),
            ),
            TextButton(
              key: Key('${id}_details'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(name),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (imageUrl?.trim().isNotEmpty == true)
                          Image.network(
                            imageUrl!,
                            height: 180,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) =>
                                const Icon(Icons.restaurant),
                          ),
                        if (description?.trim().isNotEmpty == true)
                          Text(description!),
                        Text(money.format(price)),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(text('닫기', 'Đóng', 'Close')),
                    ),
                  ],
                ),
              ),
              child: Text(text('메뉴 보기', 'Xem món', 'View item')),
            ),
          ],
        ),
      ],
    );
  }
}
