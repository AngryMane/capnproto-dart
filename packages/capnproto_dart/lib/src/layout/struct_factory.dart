import '../arena/arena_builder.dart';
import '../arena/arena_reader.dart';
import 'struct_builder.dart';
import 'struct_reader.dart';
import '../schema/reflection.dart';

/// Factory that carries struct layout information and constructs typed
/// reader/builder instances from raw arena pointers.
///
/// Generated code produces a concrete subclass for each Cap'n Proto struct.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
abstract class StructFactory<R extends StructReader, B extends StructBuilder> {
  /// Optional generated schema metadata for this struct.
  StructSchemaInfo? get schema => null;

  /// Number of 8-byte words in the struct's data section.
  int get dataWords;

  /// Number of 8-byte words in the struct's pointer section.
  int get ptrWords;

  /// Wraps [raw] in a typed reader.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = factory.fromRawReader;
  /// ```
  R fromRawReader(RawStructReader raw);

  /// Wraps [raw] in a typed reader with an RPC capability table.
  ///
  /// Generated code overrides this so nested interface fields can be resolved
  /// as typed capabilities. Plain serialization callers can keep using
  /// [fromRawReader].
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = factory.fromRawReaderWithCapabilities;
  /// ```
  R fromRawReaderWithCapabilities(
    RawStructReader raw,
    List<Object?> capabilities,

    ///
    /// **Example**
    /// ```dart
    /// // Given the required message, schema, or raw-layout values:
    /// final operation = factory.fromRawReader;
    /// ```
  ) => fromRawReader(raw);

  /// Wraps [raw] in a typed builder.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = factory.fromRawBuilder;
  /// ```
  B fromRawBuilder(RawStructBuilder raw);
}
