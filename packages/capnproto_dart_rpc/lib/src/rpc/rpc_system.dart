import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../capability/capability.dart';
import 'flow_controller.dart';
import 'rpc_exception.dart';
import 'rpc_server.dart';
import 'two_party_connection.dart';

/// Entry point for establishing and serving Cap'n Proto RPC connections.
class RpcSystem {
  RpcSystem._();

  /// Connects to a Cap'n Proto RPC server at [address].
  ///
  /// Supports `tcp://host:port` URIs.
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
    if (address.scheme != 'tcp') {
      throw RpcException('unsupported scheme: ${address.scheme}');
    }
    final socket = await Socket.connect(address.host, address.port);
    return TwoPartyRpcConnection.client(
      incoming: socket.cast<Uint8List>(),
      outgoing: _SocketSink(socket),
      onDisposeError: onDisposeError,
      streamWindowSize: streamWindowSize,
    );
  }

  /// Starts a Cap'n Proto RPC server at [address] and serves [bootstrap]
  /// to incoming clients.
  ///
  /// Supports `tcp://host:port` URIs.
  ///
  /// [maxConnections] caps how many clients may be connected at once. Once
  /// the cap is reached, additional incoming sockets are closed immediately
  /// (before any [TwoPartyRpcConnection] is created for them) rather than
  /// accepted — without this, a remote peer able to reach the listening
  /// port could open unbounded connections and exhaust memory/file
  /// descriptors, since each accepted connection allocates its own
  /// message loop and question/answer/export/import tables. Defaults to
  /// 1024; pass `null` for no limit.
  ///
  /// See [connect] for [onDisposeError] and [streamWindowSize].
  static Future<RpcServer> serve(
    Uri address,
    Capability bootstrap, {
    void Function(Object error, StackTrace stackTrace)? onDisposeError,
    int streamWindowSize = FlowController.defaultWindowSize,
    int? maxConnections = 1024,
  }) async {
    if (address.scheme != 'tcp') {
      throw RpcException('unsupported scheme: ${address.scheme}');
    }
    final host = InternetAddress.tryParse(address.host) ??
        InternetAddress.loopbackIPv4;
    final serverSocket = await ServerSocket.bind(host, address.port);

    // Tracked so close() can tear down already-accepted connections, not
    // just stop accepting new ones — closing only the listening socket would
    // otherwise leave every client connected at the time of close() running
    // (and its underlying TCP socket open) indefinitely.
    final connections = <TwoPartyRpcConnection>{};

    serverSocket.listen((socket) {
      if (maxConnections != null && connections.length >= maxConnections) {
        socket.destroy();
        return;
      }
      final conn = TwoPartyRpcConnection.server(
        incoming: socket.cast<Uint8List>(),
        outgoing: _SocketSink(socket),
        bootstrap: bootstrap,
        onDisposeError: onDisposeError,
        streamWindowSize: streamWindowSize,
      );
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
    });

    return _TcpRpcServer(serverSocket, connections);
  }
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

class _TcpRpcServer implements RpcServer {
  final ServerSocket _socket;
  final Set<TwoPartyRpcConnection> _connections;
  _TcpRpcServer(this._socket, this._connections);

  @override
  int get port => _socket.port;

  @override
  Future<void> close() async {
    await _socket.close();
    // Snapshot first: each connection's `done.whenComplete` callback removes
    // itself from `_connections`, which would otherwise mutate the set while
    // this iterates it.
    await Future.wait(_connections.toList().map((c) => c.close()));
  }
}
