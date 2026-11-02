import 'dart:convert';
import 'dart:js_interop';

import 'payment_intent_journal.dart';

@JS('globosPaymentIntentJournal')
external JSPromise<JSString> _journal(JSString action, JSString input);

Future<PaymentIntentJournal> openPaymentIntentJournal() async =>
    WebPaymentIntentJournal();

class WebPaymentIntentJournal implements PaymentIntentJournal {
  Future<dynamic> _call(String action, Map<String, dynamic> input) async =>
      jsonDecode(
        (await _journal(action.toJS, jsonEncode(input).toJS).toDart).toDart,
      );
  @override
  Future<Map<String, dynamic>?> mutate(
    String action,
    Map<String, dynamic> input,
  ) async {
    final value = await _call(action, input);
    if (value == null) return null;
    final result = Map<String, dynamic>.from(value as Map);
    validatePaymentIntent(result);
    return result;
  }

  @override
  Future<List<Map<String, dynamic>>> list(
    String project,
    String actor,
    String store,
  ) async {
    final value = await _call('list', {
      'project': project,
      'actor': actor,
      'store': store,
    });
    if (value is! List || value.length > 100) {
      throw const FormatException('PAYMENT_JOURNAL_INVALID');
    }
    return value.map((r) {
      final row = Map<String, dynamic>.from(r as Map);
      validatePaymentIntent(row);
      return row;
    }).toList();
  }
}
