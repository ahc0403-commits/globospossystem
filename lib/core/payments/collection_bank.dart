/// Public beneficiary data. The server resolves it within the store's legal entity.
class CollectionBank {
  const CollectionBank({
    required this.bin,
    required this.accountNumber,
    required this.accountHolder,
    required this.label,
    this.id = '',
  });
  final String id;
  final String bin;
  final String accountNumber;
  final String accountHolder;
  final String label;

  factory CollectionBank.fromJson(Map<String, dynamic> json) {
    final bin = json['bin']?.toString() ?? '';
    final account = json['account_number']?.toString() ?? '';
    final holder = json['account_holder']?.toString().trim() ?? '';
    final label = json['label']?.toString().trim() ?? '';
    if (!RegExp(r'^\d{6}$').hasMatch(bin) ||
        !RegExp(r'^[A-Za-z0-9]{5,19}$').hasMatch(account) ||
        holder.isEmpty ||
        label.isEmpty) {
      throw const FormatException('COLLECTION_BANK_INVALID');
    }
    return CollectionBank(
      id: json['id']?.toString() ?? '',
      bin: bin,
      accountNumber: account,
      accountHolder: holder,
      label: label,
    );
  }
}
