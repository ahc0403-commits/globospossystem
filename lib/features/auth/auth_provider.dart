import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthException, PostgrestException, User;
import '../../core/services/navigation_history_service.dart';
import '../../main.dart';
import 'auth_state.dart';

class AuthNotifier extends StateNotifier<PosAuthState> {
  AuthNotifier() : super(const PosAuthState()) {
    _init();
  }

  static const _activeStorePrefsPrefix = 'active_store_';
  StreamSubscription<dynamic>? _authSub;
  String? _pendingSignedOutErrorMessage;

  void _init() {
    final session = supabase.auth.currentSession;
    if (session != null) {
      _fetchUserProfile(session.user);
    }

    _authSub = supabase.auth.onAuthStateChange.listen((data) async {
      final event = data.event;
      final session = data.session;
      if (event == AuthChangeEvent.signedIn && session != null) {
        await _fetchUserProfile(session.user);
      } else if (event == AuthChangeEvent.signedOut) {
        NavigationHistoryService.instance.clear();
        state = PosAuthState(errorMessage: _pendingSignedOutErrorMessage);
        _pendingSignedOutErrorMessage = null;
      }
    });
  }

  Future<void> _fetchUserProfile(User user) async {
    try {
      final data = await supabase
          .from('users')
          .select('role, restaurant_id, is_active, extra_permissions')
          .eq('auth_id', user.id)
          .single();

      final isActive = data['is_active'] as bool? ?? true;
      if (!isActive) {
        await _signOutWithError(
          'Account is deactivated. Contact your administrator.',
        );
        return;
      }

      final extraRaw = data['extra_permissions'];
      final extraPermissions = extraRaw is List
          ? extraRaw.map((e) => e.toString()).toList()
          : const <String>[];
      final stores = await _resolveAccessibleStores(
        user: user,
        fallbackStoreId: data['restaurant_id'] as String?,
      );
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

      state = state.copyWith(
        isLoading: false,
        user: user,
        role: data['role'] as String?,
        storeId: activeStoreId,
        primaryStoreId: primaryStoreId,
        accessibleStores: stores,
        extraPermissions: extraPermissions,
        clearError: true,
      );

      final role = data['role'] as String?;
      final homeRoute = switch (role) {
        'super_admin' => '/super-admin',
        'photo_objet_master' || 'photo_objet_store_admin' => '/photo-ops',
        'brand_admin' || 'store_admin' => '/admin',
        'admin' => '/admin',
        'waiter' => '/waiter',
        'kitchen' => '/kitchen',
        'cashier' => '/cashier',
        _ => '/login',
      };
      NavigationHistoryService.instance.push(homeRoute);
    } on PostgrestException catch (error) {
      await _handleProfileLoadError(error);
    } catch (_) {
      state = state.copyWith(
        isLoading: false,
        clearUser: true,
        errorMessage:
            'Login succeeded, but your POS account profile could not be loaded.',
      );
    }
  }

  Future<void> login(String email, String password) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final response = await supabase.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
      if (response.user != null) {
        await _fetchUserProfile(response.user!);
      }
    } on AuthException catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.message);
    } catch (_) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'An error occurred during login.',
      );
    }
  }

  Future<void> _handleProfileLoadError(PostgrestException error) async {
    final code = error.code?.toUpperCase() ?? '';
    final message = error.message.toUpperCase();

    if (code == 'PGRST116' ||
        message.contains('0 ROWS') ||
        message.contains('NO ROWS') ||
        message.contains('JSON OBJECT REQUESTED')) {
      await _signOutWithError(
        'Login succeeded, but this account is not linked to a POS user profile.',
      );
      return;
    }

    if (code == '42501' ||
        message.contains('PERMISSION') ||
        message.contains('ROW-LEVEL SECURITY') ||
        message.contains('JWT')) {
      await _signOutWithError(
        'Login succeeded, but this account does not have permission to load its POS profile.',
      );
      return;
    }

    state = state.copyWith(
      isLoading: false,
      clearUser: true,
      errorMessage:
          'Login succeeded, but the POS profile lookup failed: ${error.message}',
    );
  }

  Future<void> _signOutWithError(String message) async {
    _pendingSignedOutErrorMessage = message;
    await supabase.auth.signOut();
    state = PosAuthState(errorMessage: message);
  }

  Future<void> logout() async {
    await supabase.auth.signOut();
    NavigationHistoryService.instance.clear();
    state = const PosAuthState();
  }

  Future<void> setActiveStore(String storeId) async {
    final user = state.user;
    if (user == null) return;

    final isAccessible = state.accessibleStores.any(
      (store) => store.id == storeId,
    );
    if (!isAccessible) return;

    state = state.copyWith(storeId: storeId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_activeStorePrefsPrefix${user.id}', storeId);
  }

  Future<void> refreshProfile() async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      state = const PosAuthState();
      return;
    }
    await _fetchUserProfile(user);
  }

  @override
  void dispose() {
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

    final storeIds = {
      ...claimedStoreIds,
      if (fallbackStoreId != null && fallbackStoreId.isNotEmpty)
        fallbackStoreId,
    }.toList();

    if (storeIds.isEmpty) return const [];

    try {
      final rows = await supabase
          .from('restaurants')
          .select('id, name, brand_id, brands(name)')
          .inFilter('id', storeIds);

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
}

final authProvider = StateNotifierProvider<AuthNotifier, PosAuthState>(
  (ref) => AuthNotifier(),
);
