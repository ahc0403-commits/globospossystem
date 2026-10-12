/// Cash movements are reconciled once; counted cash already includes them.
double expectedCashBalance({
  required double openingCash,
  required double cashSales,
  double cashRefunds = 0,
  double cashPaid = 0,
  double cashRecovered = 0,
}) => openingCash + cashSales - cashRefunds - cashPaid + cashRecovered;

String nextDepositDate(String businessDate) {
  final day = DateTime.parse(businessDate);
  return DateTime.utc(
    day.year,
    day.month,
    day.day + 1,
  ).toIso8601String().substring(0, 10);
}
