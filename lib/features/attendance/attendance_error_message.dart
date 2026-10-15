import '../../l10n/app_localizations.dart';

String attendanceErrorMessage(
  AppLocalizations l10n,
  String? code,
) => switch (code) {
  'EMPLOYEE_NOT_FOUND' => l10n.attendanceEmployeeNotFound,
  'EMPLOYEE_INACTIVE' => l10n.attendanceEmployeeInactive,
  'ATTENDANCE_ALREADY_CLOCKED_IN_TODAY' => l10n.attendanceAlreadyClockedInToday,
  'ATTENDANCE_ALREADY_CLOCKED_OUT_TODAY' =>
    l10n.attendanceAlreadyClockedOutToday,
  'ATTENDANCE_CLOCK_IN_REQUIRED' => l10n.attendanceClockInRequired,
  'ATTENDANCE_FORBIDDEN' => l10n.attendanceEmployeeForbidden,
  'ATTENDANCE_PHOTO_FAILED' => l10n.attendancePhotoUploadFailed,
  'ATTENDANCE_PHOTO_LINK_FAILED' => _copy(
    l10n,
    ko: '사진은 업로드됐지만 근태에 연결하지 못했습니다. 재촬영 없이 다시 시도하세요.',
    en: 'The photo was uploaded, but could not be prepared for attendance. Retry without taking another photo.',
    vi: 'Ảnh đã được tải lên nhưng chưa thể dùng để chấm công. Hãy thử lại, không cần chụp ảnh mới.',
  ),
  'ATTENDANCE_NETWORK_FAILED' => _copy(
    l10n,
    ko: '사진을 전송하지 못했습니다. 네트워크 연결을 확인하고 다시 시도하세요. 근태는 저장되지 않았습니다.',
    en: 'The photo could not be sent. Check the network connection and try again. Attendance was not recorded.',
    vi: 'Không thể gửi ảnh. Hãy kiểm tra kết nối mạng rồi thử lại. Chấm công chưa được lưu.',
  ),
  'ATTENDANCE_RESULT_UNCONFIRMED' => _copy(
    l10n,
    ko: '응답이 끊겨 저장 여부를 확인하지 못했습니다. 다시 입력하기 전에 저장 결과를 확인하거나 관리자에게 근태 기록 확인을 요청하세요.',
    en: 'The response was interrupted. Attendance may already be saved. Check the result before trying again, or ask a manager to review the attendance records.',
    vi: 'Phản hồi bị gián đoạn. Chấm công có thể đã được lưu. Hãy kiểm tra kết quả trước khi nhập lại hoặc nhờ quản lý kiểm tra bản ghi.',
  ),
  _ => l10n.attendanceRecordFailed,
};

String attendanceVerifyResultLabel(AppLocalizations l10n) => _copy(
  l10n,
  ko: '저장 결과 확인',
  en: 'Check saved result',
  vi: 'Kiểm tra kết quả lưu',
);

// Keep attendance-only copy independent of the frozen shared alert catalog.
String _copy(
  AppLocalizations l10n, {
  required String ko,
  required String en,
  required String vi,
}) => switch (l10n.localeName.split(RegExp('[_-]')).first) {
  'ko' => ko,
  'vi' => vi,
  _ => en,
};
