import 'package:supabase_flutter/supabase_flutter.dart';

/// Small catalog projections, with UUID keyset pagination independent of the
/// API's row cap. Callers publish only the completed result.
Future<List<Map<String, dynamic>>> fetchCompleteCatalog(
  PostgrestFilterBuilder<List<Map<String, dynamic>>> Function() query, {
  List<String> keys = const ['id'],
}) async {
  final rows = <Map<String, dynamic>>[];
  final seen = <String>{};
  List<String>? cursor;
  final uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  while (true) {
    var pageQuery = query();
    if (cursor != null) {
      pageQuery = pageQuery.or(
        [
          for (var i = 0; i < keys.length; i++)
            i == 0
                ? '${keys[i]}.gt.${cursor[i]}'
                : 'and(${[for (var j = 0; j < i; j++) '${keys[j]}.eq.${cursor[j]}', '${keys[i]}.gt.${cursor[i]}'].join(',')})',
        ].join(','),
      );
    }
    PostgrestTransformBuilder<List<Map<String, dynamic>>> ordered = pageQuery;
    for (final key in keys) {
      ordered = ordered.order(key);
    }
    final page = await ordered.limit(100);
    if (page.isEmpty) return rows;
    for (final row in page) {
      final values = [for (final key in keys) row[key]?.toString() ?? ''];
      if (values.any((value) => !uuid.hasMatch(value)) ||
          !seen.add(values.join('|'))) {
        throw const FormatException('CATALOG_PAGE_INVALID');
      }
      cursor = values;
      rows.add(row);
    }
  }
}
