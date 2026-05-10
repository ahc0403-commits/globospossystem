import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/auth_provider.dart';

final adminScopedStoreIdProvider = Provider<String?>((ref) {
  return ref.watch(authProvider).storeId;
});
