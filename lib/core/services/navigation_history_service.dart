class NavigationHistoryService {
  NavigationHistoryService._();
  static final NavigationHistoryService instance = NavigationHistoryService._();

  final List<String> _history = <String>[];
  int _currentIndex = -1;

  void push(String location) {
    if (location.isEmpty) {
      return;
    }
    if (_currentIndex < _history.length - 1) {
      _history.removeRange(_currentIndex + 1, _history.length);
    }
    if (_history.isEmpty || _history.last != location) {
      _history.add(location);
      _currentIndex = _history.length - 1;
    }
  }

  bool get canGoBack => _currentIndex > 0;
  bool get canGoForward =>
      _currentIndex >= 0 && _currentIndex < _history.length - 1;

  String? goBack() {
    if (!canGoBack) {
      return null;
    }
    _currentIndex -= 1;
    return _history[_currentIndex];
  }

  String? goForward() {
    if (!canGoForward) {
      return null;
    }
    _currentIndex += 1;
    return _history[_currentIndex];
  }

  String? get currentLocation =>
      _currentIndex >= 0 ? _history[_currentIndex] : null;

  void clear() {
    _history.clear();
    _currentIndex = -1;
  }
}
