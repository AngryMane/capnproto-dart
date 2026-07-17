import 'dart:async';

/// Fixed-window flow control for streaming (`-> stream`) method calls.
///
/// Mirrors capnp-rust's `FixedWindowFlowController`: a streaming call is
/// always sent immediately (message order on the wire must be preserved),
/// but the [Future] returned by [send] only completes once the number of
/// in-flight bytes drops back under [windowSize] — i.e. once enough prior
/// calls have been acknowledged (their [DispatchResult] future completed).
///
/// This gives callers cooperative backpressure for free: a loop that awaits
/// each [send] before making the next call is automatically throttled to
/// roughly [windowSize] bytes of outstanding, unacknowledged calls, instead
/// of either buffering an unbounded number of in-flight calls or forcing a
/// full round-trip between every single call.
class FlowController {
  /// Matches capnp-rust's `DEFAULT_WINDOW_SIZE`.
  static const int defaultWindowSize = 64 * 1024;

  final int windowSize;

  int _inFlight = 0;
  // The window is extended by the largest message seen so far so that a
  // single message larger than the window doesn't permanently stall the
  // stream (it would never be "under window" on its own otherwise).
  int _maxMessageSize = 0;
  final List<Completer<void>> _blocked = [];
  Object? _failure;
  StackTrace? _failureStackTrace;

  FlowController({this.windowSize = defaultWindowSize});

  bool get _isReady => _inFlight < windowSize + _maxMessageSize;

  /// Charges [messageSize] bytes against the window and returns a future
  /// that completes once the window has room for another message.
  ///
  /// The caller must have already sent the message on the wire before
  /// calling this — [send] only tracks accounting and backpressure, it does
  /// not perform the send itself, so message ordering is unaffected by
  /// whether the window is currently full.
  ///
  /// [ack] should complete when the call this message belongs to has been
  /// acknowledged by the peer (its Return arrived), freeing this message's
  /// share of the window. If [ack] fails, the flow controller records the
  /// failure and every subsequently-blocked (and future) [send] fails with
  /// the same error — matching capnp-rust, one failed streaming call poisons
  /// the stream rather than silently continuing to buffer behind it.
  Future<void> send(int messageSize, Future<void> ack) {
    _maxMessageSize = messageSize > _maxMessageSize
        ? messageSize
        : _maxMessageSize;
    _inFlight += messageSize;

    ack.then(
      (_) => _onAcked(messageSize),
      onError: (Object error, StackTrace stackTrace) {
        // Bookkeeping only (mirrors _onAcked's decrement) — deliberately not
        // calling _onAcked itself, since it would release any now-unblocked
        // waiters with a *successful* completion before we get a chance to
        // fail them below.
        _inFlight -= messageSize;
        _failure ??= error;
        _failureStackTrace ??= stackTrace;
        final blocked = _blocked.toList();
        _blocked.clear();
        for (final c in blocked) {
          if (!c.isCompleted) c.completeError(error, stackTrace);
        }
      },
    );

    final failure = _failure;
    if (failure != null) {
      return Future.error(failure, _failureStackTrace);
    }
    if (_isReady) return Future.value();
    final completer = Completer<void>();
    _blocked.add(completer);
    return completer.future;
  }

  void _onAcked(int messageSize) {
    _inFlight -= messageSize;
    if (!_isReady) return;
    final blocked = _blocked.toList();
    _blocked.clear();
    for (final c in blocked) {
      if (!c.isCompleted) c.complete();
    }
  }

  /// Number of bytes sent but not yet acknowledged. Exposed for testing.
  int get debugInFlight => _inFlight;
}
