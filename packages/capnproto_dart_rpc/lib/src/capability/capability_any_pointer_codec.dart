import 'package:capnproto_dart/capnproto_dart.dart';

import 'capability.dart';
import 'capability_factory.dart';

/// Encodes RPC capabilities through generic `AnyPointer` type parameters.
///
/// The codec stores the capability in the message capability table supplied by
/// generated generic-method helpers and writes a capability pointer to the
/// `AnyPointer` slot. Decoding resolves the pointer through the result
/// capability table and optionally wraps it in a generated client factory.
final class CapabilityAnyPointerCodec<T extends Capability>
    implements AnyPointerCodec<T> {
  /// Wraps a decoded capability in a generated client stub, if provided.
  final CapabilityFactory<T>? factory;

  /// Unwraps a generated client stub back to its underlying [Capability]
  /// before encoding, if provided.
  final Capability Function(T value)? toCapability;

  /// Creates a codec, optionally converting through a generated client stub
  /// via [factory]/[toCapability].
  const CapabilityAnyPointerCodec([this.factory, this.toCapability]);

  @override
  void encode(
    AnyPointerBuilder builder,
    T value, {
    List<Object?>? capabilities,
  }) {
    if (capabilities == null) {
      throw StateError(
        'CapabilityAnyPointerCodec requires a capability table when encoding',
      );
    }
    final index = capabilities.length;
    capabilities.add(toCapability?.call(value) ?? value);
    builder.setCapability(index);
  }

  @override
  T? decode(AnyPointerReader? reader) {
    final cap = reader?.asCapability();
    if (cap == null) return null;
    final capability = cap as Capability;
    final factory = this.factory;
    if (factory != null) return factory.fromCapability(capability);
    return capability as T;
  }
}
