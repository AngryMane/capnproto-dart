import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../capability/capability.dart';
import 'rpc_exception.dart';
import 'rpc_server.dart';
import 'two_party_connection.dart';

/// Entry point for establishing and serving Cap'n Proto RPC connections.
class RpcSystem {
  RpcSystem._();

  /// Connects to a Cap'n Proto RPC server at [address].
  ///
  /// Supports `tcp://host:port` URIs.
  static Future<RpcConnection> connect(Uri address) async {
    if (address.scheme != 'tcp') {
      throw RpcException('unsupported scheme: ${address.scheme}');
    }
    final socket = await Socket.connect(address.host, address.port);
    return TwoPartyRpcConnection.client(
      incoming: socket.cast<Uint8List>(),
      outgoing: _SocketSink(socket),
    );
  }

  /// Starts a Cap'n Proto RPC server at [address] and serves [bootstrap]
  /// to incoming clients.
  ///
  /// Supports `tcp://host:port` URIs.
  static Future<RpcServer> serve(Uri address, Capability bootstrap) async {
    if (address.scheme != 'tcp') {
      throw RpcException('unsupported scheme: ${address.scheme}');
    }
    final host = InternetAddress.tryParse(address.host) ??
        InternetAddress.loopbackIPv4;
    final serverSocket = await ServerSocket.bind(host, address.port);

    serverSocket.listen((socket) {
      TwoPartyRpcConnection.server(
        incoming: socket.cast<Uint8List>(),
        outgoing: _SocketSink(socket),
        bootstrap: bootstrap,
      );
    });

    return _TcpRpcServer(serverSocket);
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
  _TcpRpcServer(this._socket);

  @override
  Future<void> close() => _socket.close();
}
