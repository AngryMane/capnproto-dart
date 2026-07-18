import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../capability/capability.dart';
import 'flow_controller.dart';
import 'rpc_exception.dart';
import 'rpc_server.dart';
import 'two_party_connection.dart';

/// Entry point for establishing and serving Cap'n Proto RPC connections.
///
/// Supports `tcp://host:port` (a bare byte stream) and `ws://`/`wss://
/// host:port[/path]` (Cap'n Proto framing carried over WebSocket binary
/// frames — one frame per message, which lines up naturally since
/// [TwoPartyRpcConnection] always sends one complete framed message per
/// `add()` call). Either transport can be reached with a matching
/// [Uri.scheme]; anything else needs the lower-level
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
  /// `-> stream` method calls — see [FlowController].
  static Future<RpcConnection> connect(
    Uri address, {
    void Function(Object error, StackTrace stackTrace)? onDisposeError,
    int streamWindowSize = FlowController.defaultWindowSize,
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
        );
      default:
        throw RpcException('unsupported scheme: ${address.scheme}');
    }
  }

  /// Starts a Cap'n Proto RPC server at [address] and serves [bootstrap]
  /// to incoming clients.
  ///
  /// [securityContext], when given, upgrades a `wss://` server to TLS via
  /// [HttpServer.bindSecure]; a `wss://` address without one is rejected,
  /// since silently falling back to plaintext `ws://` would violate what
  /// the caller's own address explicitly asked for. Ignored for `tcp://`
  /// and `ws://`.
  ///
  /// [maxConnections] caps how many clients may be connected at once. Once
  /// the cap is reached, additional incoming connections are rejected
  /// immediately (before any [TwoPartyRpcConnection] is created for them)
  /// rather than accepted — without this, a remote peer able to reach the
  /// listening port could open unbounded connections and exhaust
  /// memory/file descriptors, since each accepted connection allocates its
  /// own message loop and question/answer/export/import tables. Defaults
  /// to 1024; pass `null` for no limit.
  ///
  /// See [connect] for [onDisposeError] and [streamWindowSize].
  static Future<RpcServer> serve(
    Uri address,
    Capability bootstrap, {
    void Function(Object error, StackTrace stackTrace)? onDisposeError,
    int streamWindowSize = FlowController.defaultWindowSize,
    int? maxConnections = 1024,
    SecurityContext? securityContext,
  }) async {
    if (maxConnections != null && maxConnections < 0) {
      throw ArgumentError.value(
        maxConnections,
        'maxConnections',
        'must be non-negative or null',
      );
    }
    final host =
        InternetAddress.tryParse(address.host) ?? InternetAddress.loopbackIPv4;
    final connections = <TwoPartyRpcConnection>{};

    void track(TwoPartyRpcConnection conn) {
      connections.add(conn);
      // `conn.done` completes with an error for a connection that was torn
      // down abnormally (malformed peer data, reset, etc.) — TwoPartyRpcConnection
      // itself already calls `.ignore()` on that completer before erroring it
      // specifically so an unobserved `.done` doesn't print as an unhandled
      // error. `.whenComplete()` observes the future but replays the same
      // error onto the future it returns; without also silencing *that* one,
      // a single malformed/aborted connection (e.g. a stray TCP probe) would
      // surface as a top-level unhandled exception instead of just being
      // logged via `onDisposeError` like every other per-connection failure.
      conn.done.whenComplete(() => connections.remove(conn)).ignore();
    }

    bool atCapacity() =>
        maxConnections != null && connections.length >= maxConnections;

    switch (address.scheme) {
      case 'tcp':
        final serverSocket = await ServerSocket.bind(host, address.port);
        serverSocket.listen((socket) {
          if (atCapacity()) {
            socket.destroy();
            return;
          }
          track(
            TwoPartyRpcConnection.server(
              incoming: socket.cast<Uint8List>(),
              outgoing: _SocketSink(socket),
              bootstrap: bootstrap,
              onDisposeError: onDisposeError,
              streamWindowSize: streamWindowSize,
            ),
          );
        });
        // Tracked so close() can tear down already-accepted connections, not
        // just stop accepting new ones — closing only the listening socket
        // would otherwise leave every client connected at the time of
        // close() running (and its underlying TCP socket open) indefinitely.
        return _ListenerRpcServer(
          () => serverSocket.port,
          serverSocket.close,
          connections,
        );

      case 'ws':
      case 'wss':
        if (address.scheme == 'wss' && securityContext == null) {
          throw RpcException(
            'wss:// server requires a securityContext (see RpcSystem.serve)',
          );
        }
        final httpServer =
            address.scheme == 'wss'
                ? await HttpServer.bindSecure(
                  host,
                  address.port,
                  securityContext!,
                )
                : await HttpServer.bind(host, address.port);
        httpServer.listen((request) async {
          if (!WebSocketTransformer.isUpgradeRequest(request)) {
            request.response.statusCode = HttpStatus.badRequest;
            await request.response.close();
            return;
          }
          if (atCapacity()) {
            request.response.statusCode = HttpStatus.serviceUnavailable;
            await request.response.close();
            return;
          }
          final ws = await WebSocketTransformer.upgrade(request);
          track(
            TwoPartyRpcConnection.server(
              incoming: _webSocketIncoming(ws),
              outgoing: _WebSocketSink(ws),
              bootstrap: bootstrap,
              onDisposeError: onDisposeError,
              streamWindowSize: streamWindowSize,
            ),
          );
        });
        return _ListenerRpcServer(
          () => httpServer.port,
          httpServer.close,
          connections,
        );

      default:
        throw RpcException('unsupported scheme: ${address.scheme}');
    }
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
  final Set<TwoPartyRpcConnection> _connections;
  _ListenerRpcServer(this._getPort, this._closeListener, this._connections);

  @override
  int get port => _getPort();

  @override
  Future<void> close() async {
    await _closeListener();
    // Snapshot first: each connection's `done.whenComplete` callback removes
    // itself from `_connections`, which would otherwise mutate the set while
    // this iterates it.
    await Future.wait(_connections.toList().map((c) => c.close()));
  }
}
