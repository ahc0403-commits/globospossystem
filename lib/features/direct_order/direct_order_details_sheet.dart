import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'direct_order_copy.dart';
import 'direct_order_customer_details.dart';
import 'direct_order_models.dart';

class DirectOrderDetailsSheet extends StatelessWidget {
  const DirectOrderDetailsSheet({
    super.key,
    required this.status,
    required this.languageCode,
  });

  final DirectOrderStatus status;
  final String languageCode;

  @override
  Widget build(BuildContext context) {
    final copy = DirectOrderCopy(languageCode);
    final money = NumberFormat.currency(
      locale: 'vi_VN',
      symbol: '₫',
      decimalDigits: 0,
    );
    final quote = status.quote;
    final delivery = status.delivery;
    final recipientPaysDriver =
        delivery?.isPickup != true &&
        (status.support['delivery_policy_version'] == 2 ||
            quote?.deliveryPaymentMode == 'customer_direct');
    final paid = status.state == 'approved';
    Widget amount(String label, num value, {bool strong = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: 12),
          Text(
            money.format(value),
            style: strong ? Theme.of(context).textTheme.titleMedium : null,
          ),
        ],
      ),
    );
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Column(
          children: [
            ListTile(
              title: Text(copy.orderDetails),
              trailing: IconButton(
                tooltip: copy.close,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                key: const Key('direct_order_details_list'),
                padding: const EdgeInsets.all(20),
                children: [
                  Text('${copy.orderNumber}: #${status.referenceCode}'),
                  Text(
                    '${copy.orderTime}: ${status.createdAt == null ? "—" : DateFormat("yyyy-MM-dd HH:mm").format(status.createdAt!.toUtc().add(const Duration(hours: 7)))}',
                  ),
                  Text(status.isPickup ? copy.pickup : copy.delivery),
                  const SizedBox(height: 12),
                  Text(
                    copy.packingCount(
                      delivery?.dinerCount,
                      utensilsRequested: delivery?.utensilsRequested ?? true,
                    ),
                    key: const Key('direct_details_diner_count'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Divider(height: 28),
                  Text(
                    copy.customerDetails,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  DirectOrderCustomerDetailsBody(
                    key: const Key('direct_details_customer'),
                    customer: status.customer,
                    languageCode: languageCode,
                    isPickup: status.isPickup,
                  ),
                  const Divider(height: 28),
                  if (status.items.isEmpty)
                    Text(copy.noItemSnapshot)
                  else
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(copy.itemPricesBeforeTax),
                    ),
                  for (final item in status.items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.localizedName(languageCode),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          amount(
                            '${money.format(item.unitPrice)} × ${item.quantity}',
                            item.amount,
                          ),
                          DirectOrderInstructions(
                            label: copy.itemRequest,
                            note: item.note?.trim().isNotEmpty == true
                                ? item.note
                                : copy.noInstructions,
                          ),
                        ],
                      ),
                    ),
                  const Divider(),
                  if (quote != null) ...[
                    amount(copy.menuTotal, quote.menuTotal),
                    amount(copy.serviceCharge, quote.serviceChargeTotal),
                    if (recipientPaysDriver)
                      Text(copy.customerPaysDriverHelp)
                    else if (delivery?.isPickup != true) ...[
                      amount(copy.deliveryFee, quote.deliveryFeeTotal),
                      Text(copy.deliveryFeeIncluded),
                    ],
                    const Divider(height: 24),
                    amount(
                      paid ? copy.totalPaid : copy.finalTotal,
                      paid
                          ? delivery?.paidTotal ?? quote.finalTotal
                          : quote.finalTotal,
                      strong: true,
                    ),
                    amount(copy.includedVat, quote.vatTotal),
                  ] else ...[
                    if (recipientPaysDriver)
                      Text(copy.customerPaysDriverHelp)
                    else if (delivery?.isPickup != true)
                      Text(copy.deliveryFeePending),
                    if (paid && delivery?.paidTotal != null)
                      amount(copy.totalPaid, delivery!.paidTotal!, strong: true)
                    else
                      Text(copy.amountPending),
                  ],
                  if ((delivery?.refundedTotal ?? 0) > 0) ...[
                    amount(copy.refundedAmount, delivery!.refundedTotal),
                    if (delivery.paidTotal != null)
                      amount(
                        copy.netReceived,
                        delivery.paidTotal! - delivery.refundedTotal,
                        strong: true,
                      ),
                  ],
                  if ((delivery?.offer?.refundDue ?? 0) > 0 &&
                      delivery?.offer?.refundRecorded == false)
                    amount(copy.refundPending, delivery!.offer!.refundDue),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
