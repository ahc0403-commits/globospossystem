import '../../main.dart';

class QrTakeoutAvailability {
  const QrTakeoutAvailability({
    required this.configuredEnabled,
    required this.effectiveEnabled,
    this.resumeAt,
  });

  factory QrTakeoutAvailability.fromJson(Map<String, dynamic> json) {
    return QrTakeoutAvailability(
      configuredEnabled: json['configured_enabled'] == true,
      effectiveEnabled: json['effective_enabled'] == true,
      resumeAt: DateTime.tryParse(
        json['resume_at']?.toString() ?? '',
      )?.toLocal(),
    );
  }

  final bool configuredEnabled;
  final bool effectiveEnabled;
  final DateTime? resumeAt;
}

class QrTakeoutService {
  Future<QrTakeoutAvailability> getAvailability(String storeId) async {
    final result = await supabase.rpc(
      'get_qr_takeout_availability',
      params: {'p_store_id': storeId},
    );
    return QrTakeoutAvailability.fromJson(
      Map<String, dynamic>.from(result as Map),
    );
  }

  Future<QrTakeoutAvailability> setAvailability({
    required String storeId,
    required bool enabled,
    DateTime? resumeAt,
  }) async {
    final result = await supabase.rpc(
      'set_qr_takeout_availability',
      params: {
        'p_store_id': storeId,
        'p_enabled': enabled,
        'p_resume_at': resumeAt?.toUtc().toIso8601String(),
      },
    );
    return QrTakeoutAvailability.fromJson(
      Map<String, dynamic>.from(result as Map),
    );
  }
}

final qrTakeoutService = QrTakeoutService();
