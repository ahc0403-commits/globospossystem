/// A local read lifetime. Equality of store/actor/permission/query keys is
/// supplied by each domain. Invalidating reads never cancels committed writes.
class ReadEpoch {
  Object? _scope;
  int _revision = 0;
  bool _disposed = false;

  Object? get scope => _scope;

  /// Capture a view without starting/cancelling a read. A later filter change,
  /// same-scope reload, A→B→A switch or disposal invalidates this snapshot.
  ReadEpochToken? get currentToken => _disposed || _scope == null
      ? null
      : ReadEpochToken._(this, _revision, _scope!);

  ReadEpochToken begin(Object scope) {
    if (_disposed) throw StateError('Read lifetime is disposed');
    _scope = scope;
    return ReadEpochToken._(this, ++_revision, scope);
  }

  bool accepts(ReadEpochToken token) =>
      !_disposed &&
      identical(token._owner, this) &&
      token._revision == _revision &&
      token.scope == _scope;

  void invalidate() {
    _revision++;
    _scope = null;
  }

  void dispose() {
    invalidate();
    _disposed = true;
  }
}

class ReadEpochToken {
  const ReadEpochToken._(this._owner, this._revision, this.scope);

  final ReadEpoch _owner;
  final int _revision;
  final Object scope;
}
