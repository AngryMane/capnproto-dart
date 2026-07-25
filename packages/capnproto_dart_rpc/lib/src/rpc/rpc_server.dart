/// A running RPC server accepting incoming connections.
abstract class RpcServer {
  /// The local TCP port this server is listening on. Useful when binding to
  /// port 0 (let the OS choose a free port) and needing to know which port
  /// clients should actually connect to.
  int get port;

  /// Stops accepting new connections and releases the underlying socket.
  Future<void> close();
}
