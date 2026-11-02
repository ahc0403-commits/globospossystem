import 'dart:convert';
import 'dart:js_interop';

import 'order_intent_journal.dart';

@JS('globosOrderIntentJournal')
external JSPromise<JSString> _journal(JSString action, JSString input);

Future<OrderIntentJournal> openOrderIntentJournal() async =>
    WebOrderIntentJournal();

class WebOrderIntentJournal implements OrderIntentJournal {
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
    validateOrderIntent(result);
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
      throw const FormatException('ORDER_JOURNAL_INVALID');
    }
    return value.map((r) {
      final row = Map<String, dynamic>.from(r as Map);
      validateOrderIntent(row);
      return row;
    }).toList();
  }
}
