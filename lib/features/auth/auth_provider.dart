import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show
        AuthChangeEvent,
        AuthException,
        PostgrestException,
        SignOutScope,
        SupabaseClient,
        User;
import '../../core/services/navigation_history_service.dart';
import '../../core/auth/terminal_auth.dart';
import '../../core/utils/role_routes.dart';
import '../../main.dart';
import '../admin/providers/settings_provider.dart';
import '../admin/providers/staff_provider.dart';
import '../inventory/inventory_provider.dart';
import '../kitchen/kitchen_provider.dart';
import '../emergency_fulfillment/emergency_fulfillment_provider.dart';
import '../order/order_provider.dart';
import '../payment/payment_provider.dart';
import '../photo_ops/photo_ops_provider.dart';
import '../qc/qc_provider.dart';
import '../table/table_provider.dart';
import 'auth_state.dart';

const authErrorAccountDeactivated = 'auth/account-deactivated';
const authErrorNoStoreScope = 'auth/no-store-scope';
const authErrorUnknownRolePrefix = 'auth/unknown-role:';
const authErrorGenericLogin = 'auth/login-generic';
const authErrorProfileLoadFailed = 'auth/profile-load-failed';
const authErrorProfileMissing = 'auth/profile-missing';
const authErrorProfilePermissionDenied = 'auth/profile-permission-denied';
const authErrorProfileLookupFailedPrefix = 'auth/profile-lookup-failed:';
const authErrorPrivacyConsentFailed = 'auth/privacy-consent-failed';
const authErrorPrivacyConsentFailedPrefix = 'auth/privacy-consent-failed:';
const authErrorPrivacyConsentPermissionDenied =
    'auth/privacy-consent-permission-denied';
const authErrorPrivacyConsentProfileMissing =
    'auth/privacy-consent-profile-missing';
const authErrorPrivacyConsentSetupMissing =
    'auth/privacy-consent-setup-missing';
const authErrorPasswordChangeFailed = 'auth/password-change-failed';
const authErrorPasswordChangeFailedPrefix = 'auth/password-change-failed:';
const privacyConsentDocumentVersion = 'vn-pdpl-2026-01';

class AuthNotifier extends StateNotifier<PosAuthState> {
  AuthNotifier({
    this.onLogout,
    SupabaseClient? client,
    TerminalStorage? profileStorage,
  }) : _client = client ?? supabase,
       _profileStorage =
           profileStorage ??
           (client == null ? TerminalAuth.current?.storage : null),
       super(const PosAuthState()) {
    _init();
  }

  final void Function()? onLogout;
  final SupabaseClient _client;
  final TerminalStorage? _profileStorage;
  Timer? _profileRetry;
  int _retryCount = 0;
  DateTime? _lastProfileSuccess;
  String? _activeUserId;
  bool _signedOutHandled = false;
  Future<void> _cacheCleanup = Future.value();
  Future<void>? _profileLoad;
  String? _profileUserId;
  int _sessionGeneration = 0;

  void _invalidateProfileLoad() {
    _profileRetry?.cancel();
    _profileRetry = null;
    _sessionGeneration++;
    _profileLoad = null;
    _profileUserId = null;
  }

  static const _activeStorePrefsPrefix = 'active_store_';
  StreamSubscription<dynamic>? _authSub;
  String? _pendingSignedOutErrorMessage;

  void _init() {
    final session = _client.auth.currentSession;
    if (session != null) {
      state = state.copyWith(isLoading: true, isRestoring: true);
      _fetchUserProfile(session.user);
    }

    _authSub = _client.auth.onAuthStateChange.listen(
      (data) {
        if (!mounted) return;
        final event = data.event;
        final session = data.session;
        if ((event == AuthChangeEvent.signedIn ||
                event == AuthChangeEvent.initialSession ||
                event == AuthChangeEvent.tokenRefreshed ||
                event == AuthChangeEvent.userUpdated) &&
            session != null) {
          if (state.user != null && state.user?.id != session.user.id) {
            _invalidateProfileLoad();
            state = state.copyWith(clearUser: true, isRestoring: true);
            onLogout?.call();
          }
          if (_client.auth.currentUser?.id == session.user.id &&
              (state.user?.id != session.user.id ||
                  state.isRecoveringSession ||
                  event == AuthChangeEvent.userUpdated)) {
            unawaited(_fetchUserProfile(session.user));
          }
        } else if (event == AuthChangeEvent.signedOut) {
          _finishSignOut();
        }
      },
      onError: (Object error, StackTrace stack) {
        final user = _client.auth.currentUser;
        if (mounted && user != null) {
          _profileFailed(user, authErrorProfileLoadFailed);
        }
      },
    );
  }

  Future<void> _fetchUserProfile(User user) {
    if (_profileUserId == user.id && _profileLoad != null) {
      return _profileLoad!;
    }
    _activeUserId = user.id;
    _signedOutHandled = false;
    _profileRetry?.cancel();
    final generation = ++_sessionGeneration;
    _profileUserId = user.id;
    final load = _loadUserProfile(user, generation);
    _profileLoad = load;
    return load.whenComplete(() {
      if (generation == _sessionGeneration) {
        _profileLoad = null;
        _profileUserId = null;
      }
    });
  }

  bool _isCurrentProfile(int generation) =>
      mounted && generation == _sessionGeneration;

  Future<void> _loadUserProfile(
    User user,
    int generation, {
    bool refreshed = false,
  }) async {
    try {
      if (!refreshed && state.user == null) {
        await _restoreCachedProfile(user, generation);
        if (!_isCurrentProfile(generation)) return;
      }
      final data = await _client
          .from('users')
          .select(
            'role, restaurant_id, is_active, extra_permissions, '
            'must_change_password',
          )
          .eq('auth_id', user.id)
          .single()
          .timeout(const Duration(seconds: 10));
      if (!_isCurrentProfile(generation)) return;

      final isActive = data['is_active'] as bool? ?? true;
      if (!isActive) {
        await _signOutWithError(authErrorAccountDeactivated);
        return;
      }

      final role = data['role'] as String?;
      if (role == null || !kKnownPosRoles.contains(role)) {
        await _signOutWithError('$authErrorUnknownRolePrefix${role ?? 'null'}');
        return;
      }

      final extraRaw = data['extra_permissions'];
      final extraPermissions = extraRaw is List
          ? extraRaw.map((e) => e.toString()).toList()
          : const <String>[];
      final consent = _hasAcceptedCurrentPrivacyConsent();
      final stores = await _resolveAccessibleStores(
        user: user,
        fallbackStoreId: data['restaurant_id'] as String?,
      );
      if (!_isCurrentProfile(generation)) return;
      if (stores.isEmpty && !kStoreScopeExemptRoles.contains(role)) {
        // A store-scoped role with no accessible store cannot operate any
        // POS surface — refuse the session instead of landing with
        // storeId=null (contract AC3 / harness C3).
        await _signOutWithError(authErrorNoStoreScope);
        return;
      }
      final primaryStoreId = _resolvePrimaryStoreId(
        user: user,
        fallbackStoreId: data['restaurant_id'] as String?,
        stores: stores,
      );
      final activeStoreId = await _resolveActiveStoreId(
        user: user,
        primaryStoreId: primaryStoreId,
        stores: stores,
      );
      final hasPrivacyConsent = await consent;
      if (!_isCurrentProfile(generation)) return;

      state = state.copyWith(
        isLoading: false,
        isRestoring: false,
        isRecoveringSession: false,
        user: user,
        role: role,
        storeId: activeStoreId,
        primaryStoreId: primaryStoreId,
        accessibleStores: stores,
        extraPermissions: extraPermissions,
        passwordChangeRequired: data['must_change_password'] as bool? ?? false,
        privacyConsentRequired:
            role != 'customer_display' && !hasPrivacyConsent,
        clearError: true,
      );
      _retryCount = 0;
      _lastProfileSuccess = DateTime.now();
      await _saveCachedProfile(user);
      if (!_isCurrentProfile(generation)) return;

      final homeRoute = homeRouteForRole(role);
      NavigationHistoryService.instance.push(homeRoute);
    } on PostgrestException catch (error) {
      if (!_isCurrentProfile(generation)) return;
      final code = error.code?.toUpperCase();
      if (!refreshed &&
          (code == 'PGRST301' ||
              code == 'PGRST303' ||
              error.message.toUpperCase().contains('JWT EXPIRED'))) {
        try {
          await _client.auth.refreshSession().timeout(
            const Duration(seconds: 10),
          );
          if (_isCurrentProfile(generation)) {
            await _loadUserProfile(user, generation, refreshed: true);
          }
        } catch (_) {
          if (_isCurrentProfile(generation)) {
            _profileFailed(user, authErrorProfileLoadFailed);
          }
        }
        return;
      }
      _handleProfileLoadError(user, error);
    } catch (_) {
      if (!_isCurrentProfile(generation)) return;
      _profileFailed(user, authErrorProfileLoadFailed);
    }
  }

  Future<void> login(String email, String password) async {
    _invalidateProfileLoad();
    _retryCount = 0;
    _signedOutHandled = false;
    state = state.copyWith(isLoading: true, clearUser: true, clearError: true);
    try {
      final response = await _client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
      if (mounted &&
          response.user != null &&
          state.user?.id != response.user!.id) {
        await _fetchUserProfile(response.user!);
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      state = state.copyWith(isLoading: false, errorMessage: e.message);
    } catch (_) {
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        errorMessage: authErrorGenericLogin,
      );
    }
  }

  void _handleProfileLoadError(User user, PostgrestException error) {
    final code = error.code?.toUpperCase() ?? '';
    final message = error.message.toUpperCase();

    if (code == 'PGRST116' ||
        message.contains('0 ROWS') ||
        message.contains('NO ROWS') ||
        message.contains('JSON OBJECT REQUESTED')) {
      _profileFailed(user, authErrorProfileMissing, block: true);
      return;
    }

    if (code == '42501' ||
        message.contains('PERMISSION') ||
        message.contains('ROW-LEVEL SECURITY') ||
        message.contains('JWT')) {
      _profileFailed(user, authErrorProfilePermissionDenied, block: true);
      return;
    }

    _profileFailed(user, authErrorProfileLookupFailedPrefix);
  }

  void _profileFailed(User user, String message, {bool block = false}) {
    if (!mounted || _client.auth.currentUser?.id != user.id) return;
    final keepUser = !block && state.user?.id == user.id;
    state = state.copyWith(
      isLoading: false,
      isRestoring: !keepUser,
      isRecoveringSession: true,
      clearUser: !keepUser,
      errorMessage: message,
    );
    if (block) unawaited(_removeCachedProfile(user.id));
    if (_profileRetry?.isActive == true || _retryCount >= 2) return;
    final generation = _sessionGeneration;
    final delay = Duration(
      milliseconds: (1000 << _retryCount) + DateTime.now().millisecond % 250,
    );
    _retryCount++;
    _profileRetry = Timer(delay, () {
      if (_isCurrentProfile(generation) &&
          _client.auth.currentUser?.id == user.id) {
        unawaited(_fetchUserProfile(user));
      }
    });
  }

  Future<void> _restoreCachedProfile(User user, int generation) async {
    try {
      final raw = await _profileStorage?.read('profile-v1:${user.id}');
      if (raw == null ||
          !_isCurrentProfile(generation) ||
          _client.auth.currentUser?.id != user.id) {
        return;
      }
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['user_id'] != user.id ||
          !kKnownPosRoles.contains(data['role'])) {
        return;
      }
      final stores = (data['stores'] as List)
          .map(
            (row) => AccessibleStore(
              id: row['id'] as String,
              name: row['name'] as String,
              brandId: row['brand_id'] as String?,
              brandName: row['brand_name'] as String?,
            ),
          )
          .toList();
      final storeId = data['store_id'] as String?;
      if (!kStoreScopeExemptRoles.contains(data['role']) &&
          !stores.any((store) => store.id == storeId)) {
        return;
      }
      state = state.copyWith(
        user: user,
        role: data['role'] as String,
        storeId: storeId,
        primaryStoreId: data['primary_store_id'] as String?,
        accessibleStores: stores,
        extraPermissions: (data['permissions'] as List).cast<String>(),
        passwordChangeRequired: data['password_change'] == true,
        privacyConsentRequired:
            data['consent_version'] != privacyConsentDocumentVersion ||
            data['consent_required'] == true,
        isLoading: false,
        isRestoring: false,
        isRecoveringSession: true,
      );
    } catch (_) {
      // A damaged or unavailable cache never becomes an authentication failure.
    }
  }

  Future<void> _saveCachedProfile(User user) async {
    if (state.user?.id != user.id) return;
    try {
      await _profileStorage?.write(
        'profile-v1:${user.id}',
        jsonEncode({
          'user_id': user.id,
          'role': state.role,
          'store_id': state.storeId,
          'primary_store_id': state.primaryStoreId,
          'permissions': state.extraPermissions,
          'password_change': state.passwordChangeRequired,
          'consent_required': state.privacyConsentRequired,
          'consent_version': privacyConsentDocumentVersion,
          'stores': state.accessibleStores
              .map(
                (s) => {
                  'id': s.id,
                  'name': s.name,
                  'brand_id': s.brandId,
                  'brand_name': s.brandName,
                },
              )
              .toList(),
        }),
      );
    } catch (_) {
      // Storage quota/private mode must not sign out a healthy in-memory session.
    }
  }

  Future<void> _removeCachedProfile(String userId) async {
    try {
      await _profileStorage?.remove('profile-v1:$userId');
    } catch (_) {}
  }

  void _finishSignOut() {
    if (_signedOutHandled) return;
    _signedOutHandled = true;
    final userId = _activeUserId;
    _invalidateProfileLoad();
    _retryCount = 0;
    _lastProfileSuccess = null;
    NavigationHistoryService.instance.clear();
    state = PosAuthState(errorMessage: _pendingSignedOutErrorMessage);
    _pendingSignedOutErrorMessage = null;
    onLogout?.call();
    _cacheCleanup = () async {
      if (userId != null) await _removeCachedProfile(userId);
      try {
        if (_client.auth.currentSession == null) {
          await _profileStorage?.remove('session');
        }
      } catch (_) {}
    }();
  }

  Future<void> _signOutWithError(String message) async {
    _pendingSignedOutErrorMessage = message;
    try {
      await _client.auth.signOut(scope: SignOutScope.local);
    } finally {
      if (mounted) _finishSignOut();
    }
  }

  Future<void> logout() async {
    _invalidateProfileLoad();
    try {
      await _client.auth.signOut(scope: SignOutScope.local);
    } catch (_) {
      /* Local logout must complete while the network is unavailable. */
    } finally {
      if (mounted) _finishSignOut();
      await _cacheCleanup;
    }
  }

  Future<bool> changeInitialPassword(String newPassword) async {
    if (state.user == null || !state.passwordChangeRequired) return false;

    return _changeOwnPassword(newPassword, selfService: false);
  }

  Future<bool> changeOwnPassword(String newPassword) async {
    if (state.user == null) return false;

    return _changeOwnPassword(newPassword, selfService: true);
  }

  Future<bool> _changeOwnPassword(
    String newPassword, {
    required bool selfService,
  }) async {
    state = state.copyWith(isPasswordChangeSubmitting: true, clearError: true);

    try {
      final response = await _client.functions.invoke(
        'complete-initial-password-change',
        body: {
          'new_password': newPassword,
          if (selfService) 'mode': 'self_service',
        },
      );
      if (response.status < 200 || response.status >= 300) {
        throw StateError('password change function rejected the request');
      }

      if (!selfService || state.passwordChangeRequired) {
        // A forced reset is cleared only for the generation that this request
        // started. Re-read the server-owned gate before POS navigation.
        final profile = await _client
            .from('users')
            .select('must_change_password, password_change_generation')
            .eq('auth_id', state.user!.id)
            .single();
        final isStillRequired =
            profile['must_change_password'] as bool? ?? true;
        if (isStillRequired) {
          throw StateError('password change was not confirmed by the server');
        }
      }

      state = state.copyWith(
        isPasswordChangeSubmitting: false,
        passwordChangeRequired: false,
        clearError: true,
      );
      final user = state.user;
      if (user != null) await _saveCachedProfile(user);
      return true;
    } on AuthException catch (error) {
      state = state.copyWith(
        isPasswordChangeSubmitting: false,
        passwordChangeRequired: state.passwordChangeRequired,
        errorMessage: '$authErrorPasswordChangeFailedPrefix ${error.message}',
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        isPasswordChangeSubmitting: false,
        passwordChangeRequired: state.passwordChangeRequired,
        errorMessage: authErrorPasswordChangeFailed,
      );
      return false;
    }
  }

  Future<void> acceptPrivacyConsent({required String localeName}) async {
    if (state.user == null) return;

    state = state.copyWith(isPrivacyConsentSubmitting: true, clearError: true);

    try {
      await _client.rpc(
        'accept_my_privacy_consent',
        params: {'p_consent_locale': localeName},
      );
      state = state.copyWith(
        isPrivacyConsentSubmitting: false,
        privacyConsentRequired: false,
        clearError: true,
      );
      final user = state.user;
      if (user != null) await _saveCachedProfile(user);
      final role = state.role;
      if (role != null) {
        NavigationHistoryService.instance.push(homeRouteForRole(role));
      }
    } catch (error) {
      state = state.copyWith(
        isPrivacyConsentSubmitting: false,
        privacyConsentRequired: true,
        errorMessage: _privacyConsentErrorMessage(error),
      );
    }
  }

  Future<void> setActiveStore(String storeId) => _selectActiveStore(storeId);

  Future<void> setActiveStoreForSetup(String storeId) =>
      _selectActiveStore(storeId, resolveSuperAdminStore: true);

  Future<void> _selectActiveStore(
    String storeId, {
    bool resolveSuperAdminStore = false,
  }) async {
    final user = state.user;
    if (user == null) return;

    var stores = state.accessibleStores;
    var isAccessible = stores.any((store) => store.id == storeId);
    // Super Admin setup can target a store created after login or omitted from
    // store-scoped claims. Resolve that one active store through server RLS;
    // claims and permissions remain unchanged, and other roles keep their scope.
    if (!isAccessible &&
        resolveSuperAdminStore &&
        state.role == 'super_admin') {
      final generation = _sessionGeneration;
      Map<String, dynamic>? row;
      try {
        row = await _client
            .from('restaurants')
            .select('id, name, brand_id, brands(name)')
            .eq('id', storeId)
            .eq('is_active', true)
            .maybeSingle();
      } catch (_) {
        return;
      }
      if (!mounted ||
          generation != _sessionGeneration ||
          state.user?.id != user.id ||
          state.role != 'super_admin' ||
          row == null ||
          row['id'] != storeId) {
        return;
      }
      final brand = row['brands'];
      stores = [
        ...state.accessibleStores,
        AccessibleStore(
          id: storeId,
          name: row['name']?.toString() ?? storeId,
          brandId: row['brand_id']?.toString(),
          brandName: brand is Map ? brand['name']?.toString() : null,
        ),
      ];
      isAccessible = true;
    }
    if (!isAccessible) return;

    _invalidateProfileLoad();
    state = state.copyWith(storeId: storeId, accessibleStores: stores);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_activeStorePrefsPrefix${user.id}', storeId);
    await _saveCachedProfile(user);
  }

  Future<void> refreshProfile({bool force = true}) async {
    final user = _client.auth.currentUser;
    if (user == null) {
      return;
    }
    if (!force &&
        !state.isRecoveringSession &&
        state.user?.id == user.id &&
        _lastProfileSuccess != null &&
        DateTime.now().difference(_lastProfileSuccess!) <
            const Duration(minutes: 5)) {
      return;
    }
    if (state.user == null) {
      state = state.copyWith(isLoading: true, isRestoring: true);
    }
    await _fetchUserProfile(user);
  }

  @override
  void dispose() {
    _invalidateProfileLoad();
    _authSub?.cancel();
    super.dispose();
  }

  Future<List<AccessibleStore>> _resolveAccessibleStores({
    required User user,
    required String? fallbackStoreId,
  }) async {
    final rawStoreIds = user.appMetadata['accessible_store_ids'];
    final claimedStoreIds = rawStoreIds is List
        ? rawStoreIds.map((item) => item.toString()).toSet().toList()
        : [];
    final usesFallbackStore =
        claimedStoreIds.isEmpty &&
        fallbackStoreId != null &&
        fallbackStoreId.isNotEmpty;

    if (usesFallbackStore) {
      debugPrint(
        'claims_fallback_used auth_user_id=${user.id} '
        'email=${user.email ?? 'unknown'} store_id=$fallbackStoreId',
      );
    }

    final storeIds = {
      ...claimedStoreIds,
      if (fallbackStoreId != null && fallbackStoreId.isNotEmpty)
        fallbackStoreId,
    }.toList();

    if (storeIds.isEmpty) return const [];

    try {
      final rows = await _client
          .from('restaurants')
          .select('id, name, brand_id, brands(name)')
          .inFilter('id', storeIds)
          // Closed stores must not appear in the client store list. The
          // server-side guard (user_accessible_stores) and refreshed claims
          // are the primary control; this filter keeps the UI consistent.
          .eq('is_active', true);

      final stores = rows.map<AccessibleStore>((row) {
        final map = Map<String, dynamic>.from(row);
        final brandRaw = map['brands'];
        return AccessibleStore(
          id: map['id'].toString(),
          name: map['name']?.toString() ?? 'Unknown Store',
          brandId: map['brand_id']?.toString(),
          brandName: brandRaw is Map<String, dynamic>
              ? brandRaw['name']?.toString()
              : null,
        );
      }).toList();

      stores.sort((a, b) => a.name.compareTo(b.name));
      return stores;
    } catch (_) {
      return storeIds
          .map(
            (id) => AccessibleStore(
              id: id,
              name: id == fallbackStoreId ? 'Current Store' : 'Store $id',
            ),
          )
          .toList();
    }
  }

  String? _resolvePrimaryStoreId({
    required User user,
    required String? fallbackStoreId,
    required List<AccessibleStore> stores,
  }) {
    final claimedPrimary = user.appMetadata['primary_store_id']?.toString();
    final candidateIds = {
      if (claimedPrimary != null && claimedPrimary.isNotEmpty) claimedPrimary,
      if (fallbackStoreId != null && fallbackStoreId.isNotEmpty)
        fallbackStoreId,
    };

    for (final store in stores) {
      if (candidateIds.contains(store.id)) {
        return store.id;
      }
    }

    return stores.isNotEmpty ? stores.first.id : fallbackStoreId;
  }

  Future<String?> _resolveActiveStoreId({
    required User user,
    required String? primaryStoreId,
    required List<AccessibleStore> stores,
  }) async {
    if (stores.isEmpty) return null;

    final prefs = await SharedPreferences.getInstance();
    final persistedStoreId = prefs.getString(
      '$_activeStorePrefsPrefix${user.id}',
    );

    final candidateIds = [
      if (persistedStoreId != null && persistedStoreId.isNotEmpty)
        persistedStoreId,
      if (primaryStoreId != null && primaryStoreId.isNotEmpty) primaryStoreId,
      stores.first.id,
    ];

    for (final candidateId in candidateIds) {
      if (stores.any((store) => store.id == candidateId)) {
        await prefs.setString(
          '$_activeStorePrefsPrefix${user.id}',
          candidateId,
        );
        return candidateId;
      }
    }

    return stores.first.id;
  }

  Future<bool> _hasAcceptedCurrentPrivacyConsent() async {
    try {
      final accepted = await _client.rpc(
        'has_accepted_current_privacy_consent',
      );
      return accepted == true;
    } catch (_) {
      if (state.user?.id == _client.auth.currentUser?.id) {
        return !state.privacyConsentRequired;
      }
      rethrow;
    }
  }

  String _privacyConsentErrorMessage(Object error) {
    if (error is PostgrestException) {
      final code = error.code?.toUpperCase() ?? '';
      final message = error.message.toUpperCase();

      if (code == 'PGRST202' ||
          code == '42P01' ||
          message.contains('ACCEPT_MY_PRIVACY_CONSENT') ||
          message.contains('HAS_ACCEPTED_CURRENT_PRIVACY_CONSENT') ||
          message.contains('USER_PRIVACY_CONSENTS') ||
          message.contains('SCHEMA CACHE')) {
        return authErrorPrivacyConsentSetupMissing;
      }

      if (message.contains('PRIVACY_CONSENT_USER_REQUIRED')) {
        return authErrorPrivacyConsentProfileMissing;
      }

      if (code == '42501' ||
          message.contains('PERMISSION') ||
          message.contains('ROW-LEVEL SECURITY')) {
        return authErrorPrivacyConsentPermissionDenied;
      }

      return '$authErrorPrivacyConsentFailedPrefix ${error.message}';
    }

    return authErrorPrivacyConsentFailed;
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, PosAuthState>(
  (ref) => AuthNotifier(
    onLogout: () {
      ref.invalidate(orderProvider);
      ref.invalidate(paymentProvider);
      ref.invalidate(kitchenProvider);
      ref.invalidate(emergencyFulfillmentProvider);
      ref.invalidate(waiterTableProvider);
      ref.invalidate(staffProvider);
      ref.invalidate(attendanceProvider);
      ref.invalidate(settingsProvider);
      ref.invalidate(recipeProvider);
      ref.invalidate(ingredientProvider);
      ref.invalidate(qcCheckProvider);
      ref.invalidate(qcTemplateProvider);
      ref.invalidate(photoOpsProvider);
    },
  ),
);
