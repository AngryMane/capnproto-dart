import 'capability.dart';

/// Factory for creating a typed capability stub backed by an underlying
/// [Capability] reference (typically an imported remote capability).
///
/// Generated client stub factories extend this class.
///
/// Example (generated code):
/// ```dart
/// class FooClientFactory extends CapabilityFactory<FooClient> {
///   @override
///   FooClient fromCapability(Capability cap) => FooClient(cap);
/// }
/// ```
abstract class CapabilityFactory<T extends Capability> {
  T fromCapability(Capability cap);
}
