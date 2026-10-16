class DirectOrderCartDraft {
  const DirectOrderCartDraft({
    required this.id,
    required this.savedAt,
    required this.cart,
    required this.itemNotes,
    required this.comboChoices,
    required this.pickup,
    required this.dinerCount,
    required this.utensilsRequested,
  });

  final String id;
  final DateTime savedAt;
  final Map<String, int> cart;
  final Map<String, String> itemNotes;
  final Map<String, List<String>> comboChoices;
  final bool pickup, utensilsRequested;
  final int dinerCount;

  Map<String, dynamic> toJson() => {
    'id': id,
    'saved_at': savedAt.toUtc().toIso8601String(),
    'cart': cart,
    'item_notes': itemNotes,
    'combo_choices': comboChoices,
    'pickup': pickup,
    'diner_count': dinerCount,
    'utensils_requested': utensilsRequested,
  };

  factory DirectOrderCartDraft.fromJson(Map<String, dynamic> row) {
    final cart = Map<String, int>.from(row['cart'] as Map);
    final notes = Map<String, String>.from(row['item_notes'] as Map);
    final choices = (row['combo_choices'] as Map).map(
      (key, value) => MapEntry(key as String, List<String>.from(value as List)),
    );
    final id = row['id'] as String;
    final diners = row['diner_count'] as int;
    if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id) ||
        cart.length > 50 ||
        cart.entries.any((e) => e.key.isEmpty || e.value < 1 || e.value > 50) ||
        notes.length > 50 ||
        notes.values.any((value) => value.length > 500) ||
        choices.length > 50 ||
        choices.values.any((value) => value.length > 500) ||
        diners < 1 ||
        diners > 100) {
      throw const FormatException('DIRECT_ORDER_CART_DRAFT_INVALID');
    }
    return DirectOrderCartDraft(
      id: id,
      savedAt: DateTime.parse(row['saved_at'] as String),
      cart: cart,
      itemNotes: notes,
      comboChoices: choices,
      pickup: row['pickup'] as bool,
      dinerCount: diners,
      utensilsRequested: row['utensils_requested'] as bool,
    );
  }
}
