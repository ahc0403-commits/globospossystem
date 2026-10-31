import 'pos_backend.dart';
import '../payments/collection_bank.dart';

class CollectionBankService {
  Future<CollectionBank> load(String storeId, {String? orderId}) async {
    final result = await supabase.rpc(
      orderId == null
          ? 'get_store_collection_bank'
          : 'get_order_collection_bank',
      params: {
        'p_store_id': storeId,
        if (orderId != null) 'p_order_id': orderId,
      },
    );
    return CollectionBank.fromJson(Map<String, dynamic>.from(result as Map));
  }
}

final collectionBankService = CollectionBankService();
