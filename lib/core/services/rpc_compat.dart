import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

bool isLegacyStoreSignatureMiss(Object error, String fnName) {
  final message = error.toString();
  return message.contains('Could not find the function public.$fnName') &&
      message.contains('p_store_id');
}

bool isLegacyStorePostgrestSignatureMiss(
  PostgrestException error,
  List<String> functionNames,
) {
  if (error.code != 'PGRST202') return false;
  return functionNames.any(error.message.contains);
}

Map<String, dynamic> withLegacyRestaurantParam(Map<String, dynamic> params) {
  final next = Map<String, dynamic>.from(params);
  final storeId = next.remove('p_store_id');
  if (storeId != null) {
    next['p_restaurant_id'] = storeId;
  }
  return next;
}

Future<T> runRpcWithStoreCompat<T>({
  required String fnName,
  required Map<String, dynamic> params,
  required Future<T> Function(Map<String, dynamic> params) invoke,
}) async {
  try {
    return await invoke(params);
  } catch (error) {
    final isLegacyPostgrestError =
        error is PostgrestException &&
        isLegacyStorePostgrestSignatureMiss(error, [fnName]);
    if (!isLegacyPostgrestError && !isLegacyStoreSignatureMiss(error, fnName)) {
      rethrow;
    }
    return invoke(withLegacyRestaurantParam(params));
  }
}
