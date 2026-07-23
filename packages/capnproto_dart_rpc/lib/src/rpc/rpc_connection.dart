import '../capability/capability.dart';
import '../capability/capability_factory.dart';

abstract class RpcConnection {
  T bootstrap<T extends Capability>(CapabilityFactory<T> factory);
  Future<void> close();
}
