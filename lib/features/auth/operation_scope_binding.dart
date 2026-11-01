import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/operation_scope_provider.dart';
import '../../core/utils/operation_contract.dart';
import 'auth_state.dart';

/// This hash versions the client-visible trusted profile/access list. It is
/// deliberately not described as a server authorization revision. JWT tokens,
/// user_metadata, display names and loading/errors do not define authorization.
OperationScope? operationScopeFromAuth(PosAuthState auth) {
  final actorId = auth.user?.id;
  final role = auth.role;
  if (actorId == null ||
      actorId.isEmpty ||
      role == null ||
      role.isEmpty ||
      auth.passwordChangeRequired ||
      auth.privacyConsentRequired) {
    return null;
  }
  final permissions = auth.extraPermissions.toSet().toList()..sort();
  final stores =
      auth.accessibleStores
          .map((s) => jsonEncode([s.id, s.brandId, s.legalEntityId]))
          .toSet()
          .toList()
        ..sort();
  final revision = sha256.convert(
    utf8.encode(jsonEncode([auth.primaryStoreId, permissions, stores])),
  );
  String? legalEntityId;
  for (final store in auth.accessibleStores) {
    if (store.id == auth.storeId) {
      legalEntityId = store.legalEntityId;
      break;
    }
  }
  return OperationScope(
    actorId: actorId,
    legalEntityId: legalEntityId,
    storeId: auth.storeId,
    role: role,
    authorizationRevision: 'client-profile:$revision',
  );
}

/// Installed through a root override, keeping core/domain providers independent
/// of AuthNotifier's legacy feature imports. The eager listener preserves every
/// transition even when a consumer reads only after A → B → A has completed.
OperationScopeNotifier bindOperationScope(
  Ref ref,
  ProviderListenable<PosAuthState> auth,
) {
  final notifier = OperationScopeNotifier(isBound: true);
  notifier.publish(operationScopeFromAuth(ref.read(auth)));
  ref.listen(auth, (_, next) => notifier.publish(operationScopeFromAuth(next)));
  return notifier;
}
