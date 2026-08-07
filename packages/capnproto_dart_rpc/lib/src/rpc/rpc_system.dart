import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../capability/capability.dart';
import 'flow_controller.dart';
import 'rpc_connection.dart';
import 'rpc_exception.dart';
import 'rpc_server.dart';
import 'two_party_connection.dart';

/// Entry point for establishing and serving Cap'n Proto RPC connections.
///
/// Supports `tcp://host:port` (a bare byte stream) and `ws://`/`wss://
/// host:port[/path]` (Cap'n Proto framing carried over WebSocket binary
/// frames — one frame per message, which lines up naturally since
/// [TwoPartyRpcConnection] always sends one complete framed message per
/// `add()` call). Because that one-frame-per-message contract holds, the
/// `ws://`/`wss://` connections built here pass `preFramed: true` so
/// [TwoPartyRpcConnection] reads each frame directly instead of feeding it
/// through the generic byte-accumulation deframer `tcp://` needs. Either
/// transport can be reached with a matching [Uri.scheme]; anything else
/// needs the lower-level
/// [TwoPartyRpcConnection.client]/[TwoPartyRpcConnection.server]
/// constructors directly, which accept any `Stream<Uint8List>` /
/// `StreamSink<Uint8List>` pair.
class RpcSystem {
  RpcSystem._();

  /// Connects to a Cap'n Proto RPC server at [address].
  ///
  /// [onDisposeError] is invoked whenever a capability's `dispose()` throws
  /// during internal cleanup (Release handling, re-export, or connection
  /// teardown); such a failure never blocks or fails the surrounding
  /// operation, so this is the only way to observe it.
  ///
  /// [streamWindowSize] sets the flow-control window (in bytes) for
  /// `-> stream` method calls — see [StreamingCallFlowController].
  static Future<RpcConnection> connect(
    Uri address, {
    void Function(Object error, StackTrace stackTrace)? onDisposeError,
    int streamWindowSize = StreamingCallFlowController.defaultWindowSize,
  }) async {
    switch (address.scheme) {
      case 'tcp':
        final socket = await Socket.connect(address.host, address.port);
        return TwoPartyRpcConnection.client(
          incoming: socket.cast<Uint8List>(),
          outgoing: _SocketSink(socket),
          onDisposeError: onDisposeError,
          streamWindowSize: streamWindowSize,
        );
      case 'ws':
      case 'wss':
        final ws = await WebSocket.connect(address.toString());
        return TwoPartyRpcConnection.client(
          incoming: _webSocketIncoming(ws),
          outgoing: _WebSocketSink(ws),
          onDisposeError: onDisposeError,
          streamWindowSize: streamWindowSize,
          preFramed: true,
        );
      default:
        throw RpcException('unsupported scheme: ${address.scheme}');
    }
  }

  /// Starts a Cap'n Proto RPC server at [address] and serves [bootstrap]
  /// to incoming clients.
  ///
  /// [bootstrap]'s ownership transfers to the returned [RpcServer] the
  /// moment this call returns successfully (mirroring
  /// [TwoPartyRpcConnection.server]'s own contract, which this delegates
  /// to per accepted connection): only the returned server's own
  /// [RpcServer.close] disposes it from then on, once every connection's own
  /// reference has also been released — callers must not separately dispose
  /// [bootstrap] themselves, nor reuse it for anything else afterward. If
  /// this call throws instead (invalid arguments, a bind failure, an
  /// unsupported scheme), no such transfer happened and [bootstrap] is left
  /// exactly as it was passed in.
  ///
  /// [securityContext], when given, upgrades a `wss://` server to TLS via
  /// [HttpServer.bindSecure]; a `wss://` address without one is rejected,
  /// since silently falling back to plaintext `ws://` would violate what
  /// the caller's own address explicitly asked for. Ignored for `tcp://`
  /// and `ws://`.
  ///
  /// [maxConnections] caps how many clients may be connected at once.
  /// WebSocket handshakes currently being upgraded count toward the cap, so
  /// concurrent upgrade requests cannot oversubscribe it. Once
  /// the cap is reached, additional incoming connections are rejected
  /// immediately (before any [TwoPartyRpcConnection] is created for them)
  /// rather than accepted — without this, a remote peer able to reach the
  /// listening port could open unbounded connections and exhaust
  /// memory/file descriptors, since each accepted connection allocates its
  /// own message loop and question/answer/export/import tables. Defaults
  /// to 1024; pass `null` for no limit.
  ///
  /// For WebSocket transports, the request path must equal [Uri.path] from
  /// [address] (or a single slash when it is empty). Query parameters are
  /// accepted and are not part of this routing check.
  ///
  /// See [connect] for [onDisposeError] and [streamWindowSize].
  static Future<RpcServer> serve(
    Uri address,
    Capability bootstrap, {
    void Function(Object error, StackTrace stackTrace)? onDisposeError,
    int streamWindowSize = StreamingCallFlowController.defaultWindowSize,
    int? maxConnections = 1024,
    SecurityContext? securityContext,
  }) async {
    // Validates maxConnections synchronously, before anything else — same
    // timing as the standalone check this constructor replaced.
    final registry = _ConnectionRegistry(maxConnections);
    final options = _RpcServeOptions(
      onDisposeError: onDisposeError,
      streamWindowSize: streamWindowSize,
      maxConnections: maxConnections,
      securityContext: securityContext,
    );
    // Passed straight through to ServerSocket.bind/HttpServer.bind(Secure),
    // which both accept a bare hostname (resolving it themselves) just as
    // readily as an InternetAddress literal — unlike the previous
    // `InternetAddress.tryParse(address.host) ?? InternetAddress.loopbackIPv4`,
    // which silently fell back to 127.0.0.1 for *any* non-literal host
    // (a real hostname, a container name, ...) instead of actually binding
    // what the caller asked for. `connect()` above already hands
    // `address.host` straight to `Socket.connect`/`WebSocket.connect` the
    // same way; only an empty host component (no host in `address` at all)
    // gets an explicit default, matching that being the one case with
    // nothing meaningful to resolve.
    final Object host =
        address.host.isEmpty ? InternetAddress.loopbackIPv4 : address.host;
    switch (address.scheme) {
      case 'tcp':
        return _TcpRpcListener.bind(
          host,
          address,
          bootstrap,
          registry,
          options,
        );
      case 'ws':
      case 'wss':
        return _WebSocketRpcListener.bind(
          host,
          address,
          bootstrap,
          registry,
          options,
        );
      default:
        throw RpcException('unsupported scheme: ${address.scheme}');
    }
  }
}

/// Bundles [RpcSystem.serve]'s options (everything but the required
/// [Uri]/[Capability] arguments) so they can be threaded through
/// [_TcpRpcListener]/[_WebSocketRpcListener] as one value.
class _RpcServeOptions {
  final void Function(Object error, StackTrace stackTrace)? onDisposeError;
  final int streamWindowSize;
  final int? maxConnections;
  final SecurityContext? securityContext;

  const _RpcServeOptions({
    this.onDisposeError,
    this.streamWindowSize = StreamingCallFlowController.defaultWindowSize,
    this.maxConnections = 1024,
    this.securityContext,
  });
}

/// Enforces [RpcSystem.serve]'s `maxConnections` cap, tracks currently-open
/// connections, and closes them on server shutdown.
///
/// [maxConnections] caps how many clients may be connected at once.
/// WebSocket handshakes currently being upgraded count toward the cap (see
/// [beginWebSocketUpgrade]), so concurrent upgrade requests cannot
/// oversubscribe it. Once the cap is reached, additional incoming
/// connections are rejected immediately (before any [TwoPartyRpcConnection]
/// is created for them) rather than accepted — without this, a remote peer
/// able to reach the listening port could open unbounded connections and
/// exhaust memory/file descriptors, since each accepted connection allocates
/// its own message loop and question/answer/export/import tables.
class _ConnectionRegistry {
  final int? maxConnections;
  final Set<TwoPartyRpcConnection> _connections = {};
  int _pendingWebSocketUpgrades = 0;

  _ConnectionRegistry(this.maxConnections) {
    if (maxConnections != null && maxConnections! < 0) {
      throw ArgumentError.value(
        maxConnections,
        'maxConnections',
        'must be non-negative or null',
      );
    }
  }

  /// True once accepted connections plus in-flight WebSocket upgrades reach
  /// [maxConnections]. Always false when [maxConnections] is null (no cap).
  bool get atCapacity =>
      maxConnections != null &&
      _connections.length + _pendingWebSocketUpgrades >= maxConnections!;

  /// Adds [conn] to the tracked set, removing it again once [conn.done]
  /// completes (success or failure).
  void track(TwoPartyRpcConnection conn) {
    _connections.add(conn);
    // `conn.done` completes with an error for a connection that was torn
    // down abnormally (malformed peer data, reset, etc.) — TwoPartyRpcConnection
    // itself already calls `.ignore()` on that completer before erroring it
    // specifically so an unobserved `.done` doesn't print as an unhandled
    // error. `.whenComplete()` observes the future but replays the same
    // error onto the future it returns; without also silencing *that* one,
    // a single malformed/aborted connection (e.g. a stray TCP probe) would
    // surface as a top-level unhandled exception instead of just being
    // logged via `onDisposeError` like every other per-connection failure.
    conn.done.whenComplete(() => _connections.remove(conn)).ignore();
  }

  /// Reserves a capacity slot for a WebSocket upgrade in progress — call
  /// before awaiting [WebSocketTransformer.upgrade], so concurrent upgrade
  /// requests can't collectively exceed [maxConnections] before any of them
  /// has actually become a tracked connection. Always pair with
  /// [endWebSocketUpgrade] in a `finally`.
  void beginWebSocketUpgrade() => _pendingWebSocketUpgrades++;

  /// Releases the slot reserved by [beginWebSocketUpgrade].
  void endWebSocketUpgrade() => _pendingWebSocketUpgrades--;

  /// Closes every currently-tracked connection. Snapshots the set first,
  /// since each connection's own teardown (via [track]'s `done` callback)
  /// would otherwise mutate it while this iterates.
  Future<void> closeAll() =>
      Future.wait(_connections.toList().map((c) => c.close()));
}

/// Owns the server-lifetime reference to a [RpcSystem.serve] call's
/// bootstrap capability.
class _BootstrapLease {
  /// The real, unwrapped capability every accepted connection is handed as
  /// its own `bootstrap:` argument.
  final Capability identity;
  final CapabilityLease _serverRef;
  _BootstrapLease._(this.identity, this._serverRef);

  /// Takes ownership of [bootstrap] for the server-lifetime reference every
  /// accepted connection will go on to share (see the class doc) — called
  /// only *after* every way the caller can still fail on its own (scheme
  /// validation, `ServerSocket`/`HttpServer` binding) has already succeeded,
  /// so that a failed `serve()` call never touches the caller's `bootstrap`
  /// at all: matching [RpcSystem.serve]'s own doc comment, which promises
  /// `bootstrap` is left exactly as passed in when it throws. Every step
  /// here can itself fail (an already-spent `bootstrap` makes
  /// [acquireCapabilityLease] throw; the caller's own lease's `dispose()`
  /// could throw too) — [onFailure] is always given a chance to release
  /// whatever the caller managed to allocate before this call itself fails
  /// or a later step throws, taking the server-lifetime reference with it
  /// (an already-bound listener/HTTP server has no other owner at that
  /// point).
  static Future<_BootstrapLease> acquire(
    Capability bootstrap,
    Future<void> Function() onFailure,
  ) async {
    // [bootstrap] may itself already be a [CapabilityLease], because that type is
    // public API and a caller may pass one directly instead of a bare capability — unwrap first, the same way
    // TwoPartyRpcConnection.server itself does, so the lease below targets
    // the true underlying identity. Leasing against `bootstrap` as-is when
    // it is itself a lease would create a second, disconnected refcount
    // cycle keyed on that lease object rather than on the identity every
    // connection's own export ends up sharing — leaving the server-lifetime
    // reference holding on to nothing that actually keeps the real
    // bootstrap identity alive.
    final identity = unwrapCapabilityLease(bootstrap);

    // Every accepted connection is handed `identity` and (per
    // TwoPartyRpcConnection.server's ownership contract) disposes its own
    // reference to it on close — with connections coming and going over
    // the server's lifetime (not all simultaneously alive), the *last*
    // connection open at any given moment closing would otherwise drop the
    // shared refcount (see acquireCapabilityLease) to zero and trigger real
    // disposal, even though the server itself is still accepting new
    // connections that will go on to reuse the same identity (and
    // acquireCapabilityLease deliberately refuses to acquire a fresh
    // lease for an identity whose disposal has already been triggered — see its own
    // doc comment — so that reuse would fail loudly instead of silently
    // returning a later connection a lease to an already-torn-down object).
    // Holding this server-lifetime reference for as long as `serve()`'s own
    // returned RpcServer is open keeps the shared refcount above zero
    // throughout, so no individual connection closing can ever trigger
    // identity's real disposal while the server is still running — only
    // this server's own close() (via [release], below) does, once every
    // connection's own reference has also been released.
    final CapabilityLease serverRef;
    try {
      serverRef = acquireCapabilityLease(identity);
    } catch (_) {
      await onFailure();
      rethrow;
    }
    // Released *after* acquiring the reference above, never before, so the
    // shared refcount never has a window where it could pass through zero
    // during this handoff.
    if (!identical(bootstrap, identity)) {
      // The caller passed an existing [CapabilityLease] rather than a bare
      // capability — serverRef above now holds an equivalent reference to
      // the same identity, so this one is redundant and must be released,
      // or its share of identity's refcount would never be balanced.
      try {
        await bootstrap.dispose();
      } catch (_) {
        await serverRef.dispose();
        await onFailure();
        rethrow;
      }
    }
    return _BootstrapLease._(identity, serverRef);
  }

  /// Releases the server-lifetime reference — call from [RpcServer.close].
  Future<void> release() => _serverRef.dispose();
}

/// TCP (`tcp://`) bind/accept behavior for [RpcSystem.serve].
class _TcpRpcListener {
  static Future<RpcServer> bind(
    Object host,
    Uri address,
    Capability bootstrap,
    _ConnectionRegistry registry,
    _RpcServeOptions options,
  ) async {
    final serverSocket = await ServerSocket.bind(host, address.port);
    final lease = await _BootstrapLease.acquire(bootstrap, serverSocket.close);
    serverSocket.listen((socket) {
      if (registry.atCapacity) {
        socket.destroy();
        return;
      }
      registry.track(
        TwoPartyRpcConnection.server(
          incoming: socket.cast<Uint8List>(),
          outgoing: _SocketSink(socket),
          bootstrap: lease.identity,
          onDisposeError: options.onDisposeError,
          streamWindowSize: options.streamWindowSize,
        ),
      );
    });
    // Tracked so close() can tear down already-accepted connections, not
    // just stop accepting new ones — closing only the listening socket
    // would otherwise leave every client connected at the time of close()
    // running (and its underlying TCP socket open) indefinitely.
    return _ListenerRpcServer(
      () => serverSocket.port,
      serverSocket.close,
      registry,
      lease,
    );
  }
}

/// HTTP(S) bind, path validation, upgrade tracking, and close behavior for
/// [RpcSystem.serve]'s `ws://`/`wss://` transport.
class _WebSocketRpcListener {
  static Future<RpcServer> bind(
    Object host,
    Uri address,
    Capability bootstrap,
    _ConnectionRegistry registry,
    _RpcServeOptions options,
  ) async {
    if (address.scheme == 'wss' && options.securityContext == null) {
      throw RpcException(
        'wss:// server requires a securityContext (see RpcSystem.serve)',
      );
    }
    final httpServer =
        address.scheme == 'wss'
            ? await HttpServer.bindSecure(
              host,
              address.port,
              options.securityContext!,
            )
            : await HttpServer.bind(host, address.port);
    final lease = await _BootstrapLease.acquire(bootstrap, httpServer.close);

    // For WebSocket transports, the request path must equal [Uri.path] from
    // [address] (or a single slash when it is empty). Query parameters are
    // accepted and are not part of this routing check.
    final expectedWebSocketPath = address.path.isEmpty ? '/' : address.path;
    var closing = false;
    final upgradeTasks = <Future<void>>{};

    Future<void> handleRequest(HttpRequest request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      if (request.uri.path != expectedWebSocketPath) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      if (registry.atCapacity) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }
      registry.beginWebSocketUpgrade();
      try {
        final ws = await WebSocketTransformer.upgrade(request);
        if (closing) {
          await ws.close();
          return;
        }
        registry.track(
          TwoPartyRpcConnection.server(
            incoming: _webSocketIncoming(ws),
            outgoing: _WebSocketSink(ws),
            bootstrap: lease.identity,
            onDisposeError: options.onDisposeError,
            streamWindowSize: options.streamWindowSize,
            preFramed: true,
          ),
        );
      } catch (_) {
        try {
          request.response.statusCode = HttpStatus.badRequest;
          await request.response.close();
        } catch (_) {
          // The upgrade may already have committed or closed the response.
        }
      } finally {
        registry.endWebSocketUpgrade();
      }
    }

    httpServer.listen((request) {
      late final Future<void> task;
      task = handleRequest(
        request,
      ).catchError((Object _) {}).whenComplete(() => upgradeTasks.remove(task));
      upgradeTasks.add(task);
      task.ignore();
    });
    return _ListenerRpcServer(
      () => httpServer.port,
      () async {
        closing = true;
        await httpServer.close();
        while (upgradeTasks.isNotEmpty) {
          await Future.wait(upgradeTasks.toList());
        }
      },
      registry,
      lease,
    );
  }
}

/// Converts a WebSocket's frame stream into [Uint8List] messages.
///
/// Each Cap'n Proto message is sent as exactly one binary frame (see the
/// class doc on [RpcSystem]), so no re-framing is needed here — just a type
/// adaptation. A text frame is a protocol violation from the peer (this
/// transport is binary-only) and is surfaced as a stream error, tearing the
/// connection down the same way a malformed byte frame would.
Stream<Uint8List> _webSocketIncoming(WebSocket ws) => ws.map((data) {
  if (data is Uint8List) return data;
  if (data is List<int>) return Uint8List.fromList(data);
  throw RpcException(
    'expected a binary WebSocket frame, got ${data.runtimeType}',
  );
});

/// Adapts a [WebSocket] to [StreamSink<Uint8List>] for use with
/// [TwoPartyRpcConnection]. [WebSocket.add] sends its argument as a binary
/// frame for any `List<int>` (which [Uint8List] is), so no extra framing is
/// needed on the way out either.
class _WebSocketSink implements StreamSink<Uint8List> {
  final WebSocket _ws;
  _WebSocketSink(this._ws);

  @override
  void add(Uint8List data) => _ws.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _ws.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<Uint8List> stream) => _ws.addStream(stream);

  @override
  Future<void> close() => _ws.close();

  @override
  Future<void> get done => _ws.done;
}

/// Adapts [IOSink] to [StreamSink<Uint8List>] for use with
/// [TwoPartyRpcConnection].
class _SocketSink implements StreamSink<Uint8List> {
  final IOSink _sink;
  _SocketSink(this._sink);

  @override
  void add(Uint8List data) => _sink.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _sink.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<Uint8List> stream) => _sink.addStream(stream);

  @override
  Future<void> close() => _sink.close();

  @override
  Future<void> get done => _sink.done;
}

/// Shared [RpcServer] implementation for both the `tcp://` ([ServerSocket])
/// and `ws://`/`wss://` ([HttpServer]) listeners — the only things that
/// differ between them are how to read the port and how to stop accepting
/// new connections, both supplied as closures.
class _ListenerRpcServer implements RpcServer {
  final int Function() _getPort;
  final Future<void> Function() _closeListener;
  final _ConnectionRegistry _registry;
  final _BootstrapLease _bootstrapLease;
  _ListenerRpcServer(
    this._getPort,
    this._closeListener,
    this._registry,
    this._bootstrapLease,
  );

  @override
  int get port => _getPort();

  @override
  Future<void> close() async {
    try {
      await _closeListener();
      await _registry.closeAll();
    } finally {
      // Release this server's own server-lifetime reference regardless of
      // whether closing the listener or any connection above threw —
      // otherwise a failure partway through close() would leak the
      // bootstrap lease's reference forever, with no other owner left to
      // release it (see `_BootstrapLease.acquire`'s matching comment).
      await _bootstrapLease.release();
    }
  }
}
