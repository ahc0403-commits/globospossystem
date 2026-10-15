import '../../l10n/app_localizations.dart';

String attendanceErrorMessage(AppLocalizations l10n, String? code) =>
    switch (code) {
      'EMPLOYEE_NOT_FOUND' => l10n.attendanceEmployeeNotFound,
      'EMPLOYEE_INACTIVE' => l10n.attendanceEmployeeInactive,
      'ATTENDANCE_ALREADY_CLOCKED_IN_TODAY' =>
        l10n.attendanceAlreadyClockedInToday,
      'ATTENDANCE_ALREADY_CLOCKED_OUT_TODAY' =>
        l10n.attendanceAlreadyClockedOutToday,
      'ATTENDANCE_CLOCK_IN_REQUIRED' => l10n.attendanceClockInRequired,
      'ATTENDANCE_FORBIDDEN' => l10n.attendanceEmployeeForbidden,
      'ATTENDANCE_PHOTO_FAILED' => l10n.attendancePhotoUploadFailed,
      'ATTENDANCE_PHOTO_LINK_FAILED' => l10n.attendancePhotoLinkFailed,
      'ATTENDANCE_NETWORK_FAILED' => l10n.attendanceNetworkFailed,
      'ATTENDANCE_RESULT_UNCONFIRMED' => l10n.attendanceResultUnconfirmed,
      _ => l10n.attendanceRecordFailed,
    };
