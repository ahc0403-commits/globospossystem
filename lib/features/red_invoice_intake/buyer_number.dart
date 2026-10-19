enum BuyerNumberType {
  vnTax('vn_tax'),
  household('household_id'),
  personal('personal_id'),
  foreignTax('foreign_tax'),
  passport('passport');

  const BuyerNumberType(this.value);
  final String value;
  static BuyerNumberType parse(String? value) =>
      values.firstWhere((type) => type.value == value, orElse: () => vnTax);
}

class BuyerNumberIssue {
  const BuyerNumberIssue(this.code, {this.actual, this.left, this.right});
  final String code;
  final int? actual, left, right;
}

/// Format only. No registration lookup or invented checksum calculation.
BuyerNumberIssue? validateBuyerNumber(BuyerNumberType type, String raw) {
  final value = raw.trim();
  if (value.isEmpty) return const BuyerNumberIssue('required');
  if (type == BuyerNumberType.foreignTax || type == BuyerNumberType.passport) {
    return value.length > 64 ? const BuyerNumberIssue('too_long') : null;
  }
  if (type != BuyerNumberType.vnTax) {
    if (!RegExp(r'^[0-9]+$').hasMatch(value)) {
      return const BuyerNumberIssue('digits');
    }
    return value.length == 12
        ? null
        : BuyerNumberIssue('identity_length', actual: value.length);
  }
  if (!RegExp(r'^[0-9-]+$').hasMatch(value)) {
    return const BuyerNumberIssue('tax_characters');
  }
  if (value.contains('-')) {
    final parts = value.split('-');
    if (parts.length != 2) return const BuyerNumberIssue('hyphen');
    if (parts[0].length != 10 || parts[1].length != 3) {
      return BuyerNumberIssue(
        'branch_length',
        left: parts[0].length,
        right: parts[1].length,
      );
    }
    if (parts[1] == '000') return const BuyerNumberIssue('branch_zero');
    return null;
  }
  return value.length == 10
      ? null
      : BuyerNumberIssue('tax_length', actual: value.length);
}

class BuyerNumberCopy {
  const BuyerNumberCopy(this.language);
  final String language;
  String pick(String ko, String vi, String en) => switch (language) {
    'ko' => ko,
    'en' => en,
    _ => vi,
  };
  String label(BuyerNumberType type) => switch (type) {
    BuyerNumberType.vnTax => pick(
      '베트남 세금코드',
      'Mã số thuế Việt Nam',
      'Vietnam tax code',
    ),
    BuyerNumberType.household => pick(
      '개인사업자 대표 식별번호',
      'Số định danh chủ hộ kinh doanh',
      'Household business owner ID',
    ),
    BuyerNumberType.personal => pick(
      '일반 개인 CCCD',
      'CCCD người mua không kinh doanh',
      'Personal buyer CCCD',
    ),
    BuyerNumberType.foreignTax => pick(
      '외국 세금번호',
      'Mã số thuế nước ngoài',
      'Foreign tax number',
    ),
    BuyerNumberType.passport => pick(
      '여권·외국 개인 식별번호',
      'Hộ chiếu / Định danh nước ngoài',
      'Passport / Foreign personal ID',
    ),
  };
  String get type => pick('번호 유형', 'Loại số', 'Number type');
  String get formatOnly => pick(
    '형식만 검사합니다. 실제 등록 여부 확인이 아닙니다.',
    'Chỉ kiểm tra định dạng, không xác nhận đăng ký thực tế.',
    'Format check only; registration has not been verified.',
  );
  String error(BuyerNumberIssue issue) => switch (issue.code) {
    'required' => pick(
      '번호를 입력해 주세요.',
      'Vui lòng nhập số.',
      'Enter the number.',
    ),
    'too_long' => pick(
      '번호는 64자 이하여야 합니다.',
      'Số không được vượt quá 64 ký tự.',
      'The number must be at most 64 characters.',
    ),
    'digits' => pick(
      '식별번호는 숫자만 입력해 주세요.',
      'Số định danh chỉ gồm chữ số.',
      'Use digits only for the identity number.',
    ),
    'identity_length' => pick(
      '식별번호는 숫자 12자리여야 합니다. 현재 ${issue.actual}자리입니다.',
      'Số định danh phải có 12 chữ số. Hiện có ${issue.actual}.',
      'The identity number needs 12 digits; ${issue.actual} were entered.',
    ),
    'tax_characters' => pick(
      '세금코드는 숫자와 구분용 하이픈만 입력해 주세요.',
      'Mã số thuế chỉ gồm chữ số và dấu gạch nối phân cách.',
      'Use digits and the separating hyphen only for the tax code.',
    ),
    'hyphen' => pick(
      '확장 세금코드는 10자리-3자리 형식으로 하이픈을 한 번 사용합니다.',
      'Mã số thuế mở rộng có dạng 10 số-3 số, chỉ một dấu gạch nối.',
      'Use one hyphen in the 10-digit-3-digit tax code.',
    ),
    'branch_length' => pick(
      '세금코드는 10자리-3자리여야 합니다. 현재 하이픈 앞 ${issue.left}자리, 뒤 ${issue.right}자리입니다. 정확한 번호를 확인해 주세요.',
      'Mã số thuế phải có dạng 10 số-3 số. Hiện có ${issue.left} số trước và ${issue.right} số sau dấu gạch nối. Vui lòng kiểm tra.',
      'The tax code needs 10 digits-3 digits. Currently ${issue.left} precede the hyphen and ${issue.right} follow it. Check the number.',
    ),
    'branch_zero' => pick(
      '확장 뒷번호는 001~999여야 합니다. 000은 사용할 수 없습니다.',
      'Ba số cuối phải từ 001 đến 999, không được là 000.',
      'The suffix must be 001–999; 000 is invalid.',
    ),
    _ => pick(
      '세금코드는 숫자 10자리 또는 10자리-3자리여야 합니다. 현재 ${issue.actual}자리입니다.',
      'Mã số thuế phải có 10 số hoặc dạng 10 số-3 số. Hiện có ${issue.actual} số.',
      'Use 10 digits or 10 digits-3 digits for the tax code; ${issue.actual} were entered.',
    ),
  };
}
