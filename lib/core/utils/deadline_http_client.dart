import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// Owns per-request wrappers without owning the shared authenticated transport.
class RequestLifetime {
  final _clients = <DeadlineHttpClient>{};
  bool _disposed = false;

  void add(DeadlineHttpClient client) {
    if (_disposed) {
      client.close();
      throw StateError('Request owner disposed');
    }
    _clients.add(client);
  }

  void remove(DeadlineHttpClient client) => _clients.remove(client);

  void dispose() {
    _disposed = true;
    for (final client in _clients) {
      client.close();
    }
    _clients.clear();
  }
}

/// Per-job transport budget. Cancellation reaches IOClient/BrowserClient through
/// the Supabase auth wrapper; this client never closes the shared auth client.
class DeadlineHttpClient extends http.BaseClient {
  DeadlineHttpClient(
    this.inner,
    this.deadline, {
    this.callTimeout = const Duration(seconds: 10),
    this.maxResponseBytes = 1024 * 1024,
    this.responseTooLargeCode = 'PAYMENT_PROOF_RESPONSE_TOO_LARGE',
  });
  final http.Client inner;
  final DateTime deadline;
  final Duration callTimeout;
  final int maxResponseBytes;
  final String responseTooLargeCode;
  bool _closed = false;
  final _cancellations = <void Function()>{};

  @override
  void close() {
    _closed = true;
    for (final cancel in _cancellations.toList()) {
      cancel();
    }
    _cancellations.clear();
    // `inner` belongs to Supabase Auth, not this individual request.
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw StateError('Request transport closed');
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw TimeoutException('Job deadline reached');
    }
    final budget = remaining < callTimeout ? remaining : callTimeout;
    final abort = Completer<void>();
    final timer = Timer(budget, abort.complete);
    void cancel() {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
    }

    _cancellations.add(cancel);
    final outgoing =
        http.AbortableStreamedRequest(
            request.method,
            request.url,
            abortTrigger: abort.future,
          )
          ..headers.addAll(request.headers)
          ..contentLength = request.contentLength
          ..followRedirects = request.followRedirects
          ..maxRedirects = request.maxRedirects;
    try {
      final transfer = outgoing.sink
          .addStream(request.finalize())
          .then((_) => outgoing.sink.close());
      final response = await inner.send(outgoing);
      await transfer;
      // Consume the response while the abort timer remains active, including a
      // stalled body. These RPC/storage acknowledgements are small, never files.
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > maxResponseBytes) {
          if (!abort.isCompleted) abort.complete();
          throw FormatException(responseTooLargeCode);
        }
        bytes.add(chunk);
      }
      final body = bytes.takeBytes();
      return http.StreamedResponse(
        Stream.value(body),
        response.statusCode,
        headers: response.headers,
        reasonPhrase: response.reasonPhrase,
        request: request,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
      );
    } on http.RequestAbortedException {
      throw TimeoutException('HTTP request cancelled at job deadline', budget);
    } finally {
      timer.cancel();
      _cancellations.remove(cancel);
    }
  }
}
