String vietnameseBankTransferMessage(int amount) {
  return 'Chuyển khoản, $amount đồng đã được nhận.';
}

const vietnameseBankTransferAudioAssetTokens = <String>{
  'prefix',
  'suffix',
  'khong',
  'mot',
  'hai',
  'ba',
  'bon',
  'nam',
  'sau',
  'bay',
  'tam',
  'chin',
  'mot_sau_muoi',
  'tu',
  'lam',
  'muoi',
  'muoi_hang_chuc',
  'tram',
  'le',
  'nghin',
  'trieu',
};

List<String> vietnameseBankTransferAudioTokens(int amount) {
  if (amount <= 0 || amount > 999999999) {
    throw RangeError.range(amount, 1, 999999999, 'amount');
  }

  final tokens = <String>['prefix'];
  final millions = amount ~/ 1000000;
  final thousands = (amount ~/ 1000) % 1000;
  final units = amount % 1000;

  if (millions > 0) {
    tokens
      ..addAll(_vietnameseTripletTokens(millions))
      ..add('trieu');
  }
  if (thousands > 0) {
    tokens
      ..addAll(
        _vietnameseTripletTokens(
          thousands,
          includeLeadingHundreds: millions > 0 && thousands < 100,
        ),
      )
      ..add('nghin');
  }
  if (units > 0) {
    tokens.addAll(
      _vietnameseTripletTokens(
        units,
        includeLeadingHundreds: (millions > 0 || thousands > 0) && units < 100,
      ),
    );
  }

  return tokens..add('suffix');
}

List<String> _vietnameseTripletTokens(
  int value, {
  bool includeLeadingHundreds = false,
}) {
  final tokens = <String>[];
  final hundreds = value ~/ 100;
  final tens = (value ~/ 10) % 10;
  final units = value % 10;

  if (hundreds > 0 || includeLeadingHundreds) {
    tokens
      ..add(_digitToken(hundreds))
      ..add('tram');
  }

  if (tens > 1) {
    tokens
      ..add(_digitToken(tens))
      ..add('muoi_hang_chuc');
  } else if (tens == 1) {
    tokens.add('muoi');
  } else if (units > 0 && (hundreds > 0 || includeLeadingHundreds)) {
    tokens.add('le');
  }

  if (units > 0) {
    if (tens > 1 && units == 1) {
      tokens.add('mot_sau_muoi');
    } else if (tens > 1 && units == 4) {
      tokens.add('tu');
    } else if (tens >= 1 && units == 5) {
      tokens.add('lam');
    } else {
      tokens.add(_digitToken(units));
    }
  }

  return tokens;
}

String _digitToken(int digit) => const [
  'khong',
  'mot',
  'hai',
  'ba',
  'bon',
  'nam',
  'sau',
  'bay',
  'tam',
  'chin',
][digit];
