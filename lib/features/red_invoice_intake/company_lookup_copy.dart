import '../../core/services/company_tax_lookup_service.dart';
import 'buyer_number.dart';

class CompanyLookupCopy extends BuyerNumberCopy {
  const CompanyLookupCopy(super.language);
  String get lookup =>
      pick('회사명 조회', 'Tra cứu tên công ty', 'Look up company name');
  String get loading => pick(
    '회사명을 조회하고 있습니다.',
    'Đang tra cứu tên công ty.',
    'Looking up the company name.',
  );
  String get filled => pick(
    '회사명을 자동 입력했습니다.',
    'Đã tự điền tên công ty.',
    'Company name filled automatically.',
  );
  String get matched =>
      pick('회사명 일치', 'Tên công ty khớp', 'Company name matches');
  String get mismatch =>
      pick('회사명 확인 필요', 'Cần kiểm tra tên công ty', 'Check the company name');
  String get provided =>
      pick('고객 제공명', 'Tên khách cung cấp', 'Customer-provided name');
  String get found =>
      pick('조회 회사명', 'Tên công ty tra cứu', 'Company name from lookup');
  String source(String provider) {
    final label = provider == 'vietqr' ? 'VietQR.io' : 'ESGOO';
    return pick(
      '$label 조회 결과 · 최신 등록 정보와 다를 수 있습니다.',
      'Kết quả $label · Có thể khác thông tin đăng ký mới nhất.',
      '$label result · May differ from the latest registered information.',
    );
  }

  String failure(CompanyLookupOutcome outcome) => switch (outcome) {
    CompanyLookupOutcome.disabled => pick(
      '이 매장은 회사명 자동 조회가 꺼져 있습니다. 직접 입력해 주세요.',
      'Tra cứu tự động đang tắt cho cửa hàng này. Vui lòng nhập thủ công.',
      'Automatic lookup is off for this store. Enter the name manually.',
    ),
    CompanyLookupOutcome.rateLimited => pick(
      '조회 요청이 많습니다. 잠시 후 다시 시도하거나 직접 입력해 주세요.',
      'Có quá nhiều yêu cầu. Thử lại sau hoặc nhập thủ công.',
      'Too many lookup requests. Try later or enter the name manually.',
    ),
    CompanyLookupOutcome.forbidden => pick(
      '조회 권한을 확인해 주세요. 직접 입력할 수 있습니다.',
      'Vui lòng kiểm tra quyền tra cứu. Có thể nhập thủ công.',
      'Check your lookup access. Manual entry is available.',
    ),
    _ => pick(
      '조회할 수 없습니다. 번호와 회사명을 확인하고 직접 입력해 주세요.',
      'Không thể tra cứu. Kiểm tra mã số thuế và nhập tên công ty thủ công.',
      'Lookup unavailable. Check the tax code and enter the company name manually.',
    ),
  };
}

/// Conservative equality only. Vietnamese diacritics and legal words are retained.
bool companyNamesMatch(String provided, String found) {
  String normalize(String text) =>
      text.trim().replaceAll(RegExp(r'\s+'), ' ').toUpperCase();
  return normalize(provided) == normalize(found);
}
