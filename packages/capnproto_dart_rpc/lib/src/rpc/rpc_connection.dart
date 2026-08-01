import '../capability/capability.dart';
import '../capability/capability_factory.dart';

/// Manages an RPC connection to a remote peer.
abstract class RpcConnection {
  /// Returns a typed capability backed by the peer's bootstrap capability.
  T bootstrap<T extends Capability>(CapabilityFactory<T> factory);

  /// Closes the connection and releases all associated capabilities.
  Future<void> close();
}
