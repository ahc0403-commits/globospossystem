import 'package:supabase_flutter/supabase_flutter.dart';

class AccessibleStore {
  const AccessibleStore({
    required this.id,
    required this.name,
    this.brandId,
    this.brandName,
  });

  final String id;
  final String name;
  final String? brandId;
  final String? brandName;
}

class PosAuthState {
  final bool isLoading;
  final User? user;
  final String? role;
  final String? storeId;
  final String? primaryStoreId;
  final List<AccessibleStore> accessibleStores;
  final List<String> extraPermissions;
  final bool passwordChangeRequired;
  final bool isPasswordChangeSubmitting;
  final bool privacyConsentRequired;
  final bool isPrivacyConsentSubmitting;
  final String? errorMessage;

  const PosAuthState({
    this.isLoading = false,
    this.user,
    this.role,
    this.storeId,
    this.primaryStoreId,
    this.accessibleStores = const [],
    this.extraPermissions = const [],
    this.passwordChangeRequired = false,
    this.isPasswordChangeSubmitting = false,
    this.privacyConsentRequired = false,
    this.isPrivacyConsentSubmitting = false,
    this.errorMessage,
  });

  PosAuthState copyWith({
    bool? isLoading,
    User? user,
    String? role,
    String? storeId,
    String? primaryStoreId,
    List<AccessibleStore>? accessibleStores,
    List<String>? extraPermissions,
    bool? passwordChangeRequired,
    bool? isPasswordChangeSubmitting,
    bool? privacyConsentRequired,
    bool? isPrivacyConsentSubmitting,
    String? errorMessage,
    bool clearError = false,
    bool clearUser = false,
  }) {
    return PosAuthState(
      isLoading: isLoading ?? this.isLoading,
      user: clearUser ? null : (user ?? this.user),
      role: clearUser ? null : (role ?? this.role),
      storeId: clearUser ? null : (storeId ?? this.storeId),
      primaryStoreId: clearUser
          ? null
          : (primaryStoreId ?? this.primaryStoreId),
      accessibleStores: clearUser
          ? const []
          : (accessibleStores ?? this.accessibleStores),
      extraPermissions: clearUser
          ? const []
          : (extraPermissions ?? this.extraPermissions),
      passwordChangeRequired: clearUser
          ? false
          : (passwordChangeRequired ?? this.passwordChangeRequired),
      isPasswordChangeSubmitting: clearUser
          ? false
          : (isPasswordChangeSubmitting ?? this.isPasswordChangeSubmitting),
      privacyConsentRequired: clearUser
          ? false
          : (privacyConsentRequired ?? this.privacyConsentRequired),
      isPrivacyConsentSubmitting: clearUser
          ? false
          : (isPrivacyConsentSubmitting ?? this.isPrivacyConsentSubmitting),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}
