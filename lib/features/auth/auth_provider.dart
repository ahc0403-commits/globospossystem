import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthException, PostgrestException, User;
import '../../core/services/navigation_history_service.dart';
import '../../main.dart';
import 'auth_state.dart';

class AuthNotifier extends StateNotifier<PosAuthState> {
  AuthNotifier() : super(const PosAuthState()) {
    _init();
  }

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

      state = state.copyWith(
        isLoading: false,
        user: user,
        role: data['role'] as String?,
        storeId: data['restaurant_id'] as String?,
        extraPermissions: extraPermissions,
        clearError: true,
      );

      final role = data['role'] as String?;
      final homeRoute = switch (role) {
        'super_admin' => '/super-admin',
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
}

final authProvider = StateNotifierProvider<AuthNotifier, PosAuthState>(
  (ref) => AuthNotifier(),
);
