const String paymentMethodCash = 'CASH';
const String paymentMethodCreditCard = 'CREDITCARD';
const String paymentMethodAtm = 'ATM';
const String paymentMethodMomo = 'MOMO';
const String paymentMethodZaloPay = 'ZALOPAY';
const String paymentMethodVnPay = 'VNPAY';
const String paymentMethodShopeePay = 'SHOPEEPAY';
const String paymentMethodBankTransfer = 'BANKTRANSFER';
const String paymentMethodVoucher = 'VOUCHER';
const String paymentMethodCreditSale = 'CREDITSALE';
const String paymentMethodOther = 'OTHER';
const String paymentMethodService = 'SERVICE';

const Set<String> revenuePaymentMethods = <String>{
  paymentMethodCash,
  paymentMethodCreditCard,
  paymentMethodAtm,
  paymentMethodMomo,
  paymentMethodZaloPay,
  paymentMethodVnPay,
  paymentMethodShopeePay,
  paymentMethodBankTransfer,
  paymentMethodVoucher,
  paymentMethodCreditSale,
  paymentMethodOther,
};

const List<String> cashierSelectablePaymentMethods = <String>[
  paymentMethodCash,
  paymentMethodCreditCard,
  paymentMethodAtm,
  paymentMethodMomo,
  paymentMethodZaloPay,
  paymentMethodVnPay,
  paymentMethodShopeePay,
  paymentMethodBankTransfer,
  paymentMethodVoucher,
  paymentMethodCreditSale,
  paymentMethodOther,
  paymentMethodService,
];

bool isRevenuePaymentMethod(String method) {
  return revenuePaymentMethods.contains(method);
}

bool isServicePaymentMethod(String method) {
  return method == paymentMethodService;
}

bool isSupportedPaymentMethodInput(String method) {
  return isRevenuePaymentMethod(method) || isServicePaymentMethod(method);
}

bool requiresPaymentProof(String method) {
  return !isServicePaymentMethod(method) && method != paymentMethodCash;
}

String normalizePaymentMethodForStorage(String method) {
  return isServicePaymentMethod(method) ? paymentMethodOther : method;
}

String paymentMethodDisplayLabel(String method) {
  switch (method) {
    case paymentMethodCash:
      return 'Cash';
    case paymentMethodCreditCard:
      return 'Card';
    case paymentMethodAtm:
      return 'ATM';
    case paymentMethodMomo:
      return 'MoMo';
    case paymentMethodZaloPay:
      return 'ZaloPay';
    case paymentMethodVnPay:
      return 'VNPay';
    case paymentMethodShopeePay:
      return 'ShopeePay';
    case paymentMethodBankTransfer:
      return 'Bank Transfer';
    case paymentMethodVoucher:
      return 'Voucher';
    case paymentMethodCreditSale:
      return 'Credit Sale';
    case paymentMethodOther:
      return 'E-Pay';
    case paymentMethodService:
      return 'Service';
    default:
      return method;
  }
}
