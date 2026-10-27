/// Official VietQR HTTPS bank-app handoff; no payment callback is trusted.
/// Contracts verified 2026-10-23: vietqr.io/deeplink and vietqr.io/changelog.
class VietQrBankLink {
  VietQrBankLink._();

  static const apps = <String, String>{
    'mb': 'MBBank',
    'icb': 'VietinBank iPay',
    'bidv': 'BIDV SmartBanking',
    'ocb': 'OCB OMNI',
    'acb': 'ACB ONE',
    'vcb': 'VCB Digibank',
    'tcb': 'Techcombank Mobile',
    'vpb': 'VPBank NEO',
    'vba': 'Agribank Plus',
    'tpb': 'TPBank Mobile',
    'hdb': 'HDBank',
    'vib-2': 'MyVIB',
    'shb': 'SHB SAHA',
    'lpb': 'LPBank',
    'seab': 'SeAMobile',
    'scb': 'SCB Mobile Banking',
    'cake': 'CAKE',
    'timo': 'Timo',
    'shbvn': 'Shinhan SOL Việt Nam',
    'abb': 'ABBank',
    'pvcb': 'PVConnect',
    'eib': 'Eximbank EDigi',
    'wvn': 'Woori WON Vietnam',
    'cimb': 'OCTO by CIMB Vietnam',
    'ncb': 'NCB iziMobile',
    'klb': 'KienlongBank Plus',
    'bvb': 'BAOVIET Smart',
    'pbvn': 'PB engage VN',
    'coopbank': 'Co-opBank Mobile Banking',
    'sgicb': 'SAIGONBANK Smart Banking',
  };

  static const autofillApps = {'mb', 'icb', 'bidv', 'ocb', 'acb'};

  // Recipient bank codes, separate from the app selected by the customer.
  // Official bank directory: https://api.vietqr.io/v2/banks.
  static const recipientCodes = <String, String>{
    '970426': 'msb',
    '970436': 'vcb',
    '970415': 'icb',
    '970418': 'bidv',
    '970448': 'ocb',
    '970422': 'mb',
    '970416': 'acb',
    '970405': 'vba',
    '970407': 'tcb',
    '970432': 'vpb',
    '970423': 'tpb',
    '970403': 'stb',
    '970437': 'hdb',
    '970454': 'vccb',
    '970429': 'scb',
    '970441': 'vib',
    '970443': 'shb',
    '970431': 'eib',
  };

  static Uri? safeReturnUri(Uri current, String slug) {
    if (!{'https', 'http'}.contains(current.scheme) ||
        current.host.isEmpty ||
        !RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(slug)) {
      return null;
    }
    return Uri(
      scheme: current.scheme,
      host: current.host,
      port: current.hasPort ? current.port : null,
      path: '/',
      fragment: '/order/$slug',
    );
  }

  static Uri build({
    required String app,
    required String bankBin,
    required String accountNumber,
    required String accountHolder,
    required int amount,
    required String reference,
    required Uri returnUri,
  }) {
    final bank = recipientCodes[bankBin];
    if (!apps.containsKey(app) ||
        bank == null ||
        !RegExp(r'^[A-Za-z0-9]{5,19}$').hasMatch(accountNumber) ||
        amount <= 0 ||
        amount > 9999999999999 ||
        reference.trim().isEmpty ||
        reference.length > 100 ||
        !{'https', 'http'}.contains(returnUri.scheme) ||
        returnUri.host.isEmpty ||
        returnUri.userInfo.isNotEmpty ||
        returnUri.hasQuery ||
        !RegExp(
          r'^/order/[a-z0-9][a-z0-9-]{0,62}$',
        ).hasMatch(returnUri.fragment)) {
      throw ArgumentError('Invalid bank handoff');
    }
    return Uri.https('dl.vietqr.io', '/pay', {
      'app': app,
      'ba': '$accountNumber@$bank',
      'am': '$amount',
      'tn': reference.trim(),
      'bn': accountHolder,
      'url': returnUri.toString(),
    });
  }
}
