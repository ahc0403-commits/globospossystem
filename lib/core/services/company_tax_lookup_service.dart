import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum CompanyLookupOutcome {
  success,
  unavailable,
  disabled,
  rateLimited,
  forbidden,
}

class CompanyLookupResult {
  const CompanyLookupResult(
    this.outcome, {
    this.taxCode,
    this.companyName,
    this.fetchedAt,
  });
  final CompanyLookupOutcome outcome;
  final String? taxCode, companyName;
  final DateTime? fetchedAt;

  static CompanyLookupResult parse(dynamic raw, String requestedCode) {
    if (raw is! Map) {
      return const CompanyLookupResult(CompanyLookupOutcome.unavailable);
    }
    if (raw['outcome'] == 'success') {
      final name = raw['company_name'];
      final at = raw['fetched_at'];
      if (raw['source'] != 'esgoo' ||
          raw['tax_code'] != requestedCode ||
          name is! String ||
          name.trim().isEmpty ||
          name.runes.length > 300 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
          at is! String ||
          DateTime.tryParse(at) == null) {
        return const CompanyLookupResult(CompanyLookupOutcome.unavailable);
      }
      return CompanyLookupResult(
        CompanyLookupOutcome.success,
        taxCode: requestedCode,
        companyName: name.trim(),
        fetchedAt: DateTime.parse(at),
      );
    }
    return CompanyLookupResult(switch (raw['outcome']) {
      'disabled' => CompanyLookupOutcome.disabled,
      'rate_limited' => CompanyLookupOutcome.rateLimited,
      'forbidden' => CompanyLookupOutcome.forbidden,
      _ => CompanyLookupOutcome.unavailable,
    });
  }
}

typedef CompanyLookupTransport =
    Future<dynamic> Function(String storeId, String taxCode);

/// Name-only, bounded session cache. No reads on list rendering or realtime events.
class CompanyTaxLookupService extends ChangeNotifier {
  CompanyTaxLookupService({
    required CompanyLookupTransport transport,
    required String Function() sessionScope,
    DateTime Function()? clock,
  }) : _transport = transport,
       _scope = sessionScope,
       _clock = clock ?? DateTime.now {
    _lastScope = _scope();
  }

  factory CompanyTaxLookupService.supabase(SupabaseClient client) {
    final service = CompanyTaxLookupService(
      transport: (store, code) async {
        try {
          final response = await client.functions
              .invoke(
                'company-tax-lookup',
                body: {'store_id': store, 'tax_code': code},
              )
              .timeout(const Duration(seconds: 12));
          return response.data;
        } on FunctionException catch (failure) {
          return failure.details;
        } catch (_) {
          return const {'outcome': 'unavailable'};
        }
      },
      sessionScope: () => client.auth.currentSession?.accessToken ?? '',
    );
    service._authSubscription = client.auth.onAuthStateChange.listen(
      (_) => service.clear(),
    );
    return service;
  }

  final CompanyLookupTransport _transport;
  final String Function() _scope;
  final DateTime Function() _clock;
  StreamSubscription<AuthState>? _authSubscription;
  final _cache = <String, ({DateTime expires, CompanyLookupResult result})>{};
  final _pending = <String, Future<CompanyLookupResult>>{};
  String? _lastScope;
  int _generation = 0, _active = 0;
  bool _disposed = false;
  String get sessionScope => _scope();

  void clear() {
    _generation++;
    _cache.clear();
    _pending.clear();
    _lastScope = _scope();
    if (!_disposed) notifyListeners();
  }

  Future<CompanyLookupResult> lookup({
    required String storeId,
    required String taxCode,
  }) {
    const unavailable = CompanyLookupResult(CompanyLookupOutcome.unavailable);
    final code = taxCode.trim();
    if (_disposed ||
        storeId.isEmpty ||
        !RegExp(r'^[0-9]{10}(?:-[0-9]{3})?$').hasMatch(code) ||
        code.endsWith('-000')) {
      return Future.value(unavailable);
    }
    final scope = _scope();
    if (_lastScope != scope) clear();
    if (scope.isEmpty) {
      return Future.value(
        const CompanyLookupResult(CompanyLookupOutcome.forbidden),
      );
    }
    final key = '$scope|$storeId|$code|esgoo';
    final now = _clock();
    _cache.removeWhere((_, value) => !now.isBefore(value.expires));
    final cached = _cache[key];
    if (cached != null) return Future.value(cached.result);
    final pending = _pending[key];
    if (pending != null) return pending;
    if (_active >= 2) {
      return Future.value(
        const CompanyLookupResult(CompanyLookupOutcome.rateLimited),
      );
    }
    final generation = _generation;
    _active++;
    late final Future<CompanyLookupResult> request;
    request = Future.sync(() => _transport(storeId, code))
        .then((raw) {
          if (_disposed || generation != _generation || scope != _scope()) {
            return unavailable;
          }
          final result = CompanyLookupResult.parse(raw, code);
          if (result.outcome == CompanyLookupOutcome.success) {
            if (_cache.length >= 50) _cache.remove(_cache.keys.first);
            _cache[key] = (
              expires: _clock().add(const Duration(minutes: 5)),
              result: result,
            );
          }
          return result;
        }, onError: (Object _) => unavailable)
        .whenComplete(() {
          _active--;
          if (identical(_pending[key], request)) _pending.remove(key);
        });
    _pending[key] = request;
    return request;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _cache.clear();
    _pending.clear();
    _authSubscription?.cancel();
    super.dispose();
  }
}

CompanyTaxLookupService? _companyLookup;
CompanyTaxLookupService get companyTaxLookupService => _companyLookup ??=
    CompanyTaxLookupService.supabase(Supabase.instance.client);
