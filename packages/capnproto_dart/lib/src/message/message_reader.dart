import 'dart:typed_data';

import '../arena/arena_reader.dart';
import '../debug/perf_log.dart';
import '../layout/struct_builder.dart';
import '../layout/struct_factory.dart';
import '../layout/struct_reader.dart';
import '../stream/packed_codec.dart';
import '../wire/wire_helpers.dart';
import 'message_copy.dart';
import 'message_reader_options.dart';

/// Reads a validated Cap'n Proto message from framed or packed bytes.
///
/// **Intended users**
/// * Application and library developers working with Cap'n Proto messages.
///
/// **Primary use cases**
/// * Reads, writes, validates, or reports failures for application messages.
class MessageReader {
  final ArenaReader _arena;

  MessageReader._(this._arena);

  /// Parses standard framed message [bytes] using [options].
  ///
  /// Returns a reader that validates pointers lazily while traversing them.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final reader = MessageReader.deserialize(bytes);
  /// ```
  static MessageReader deserialize(
    Uint8List bytes, [
    MessageReaderOptions options = const MessageReaderOptions(),
  ]) => timePerf(
    'MessageReader.deserialize',
    () => MessageReader._(ArenaReader.fromBytes(bytes, options)),
  );

  /// Unpacks and parses packed message [bytes] using [options].
  ///
  /// Throws [DecodeException] when packed data is malformed or expands beyond
  /// the configured traversal limit.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final reader = MessageReader.deserializePacked(packedBytes);
  /// ```
  static MessageReader deserializePacked(
    Uint8List bytes, [
    MessageReaderOptions options = const MessageReaderOptions(),
  ]) => timePerf(
    'MessageReader.deserializePacked',
    () => MessageReader._(
      ArenaReader.fromBytes(
        unpackBytes(
          bytes,
          maxOutputBytes: options.traversalLimitInWords * bytesPerWord,
        ),
        options,
      ),
    ),
  );

  /// Returns the root as the typed reader created by [factory].
  ///
  /// [capabilities] is the side-channel capability table used by RPC-aware
  /// generated readers.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final root = reader.getRoot(myStructFactory);
  /// ```
  R getRoot<R extends StructReader, B extends StructBuilder>(
    StructFactory<R, B> factory, {
    List<Object?> capabilities = const [],
  }) => timePerf(
    'MessageReader.getRoot',
    () => factory.fromRawReaderWithCapabilities(
      _arena.getRootRaw(),
      capabilities,
    ),
  );

  /// Returns the raw struct reader for the root object.
  ///
  /// Used by low-level consumers (e.g. the RPC layer) that need to inspect
  /// pointer slots directly without a typed factory.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getRootRaw();
  /// ```
  RawStructReader getRootRaw() => _arena.getRootRaw();

  /// Returns the [canonical](https://capnproto.org/encoding.html#canonicalization)
  /// encoding of this message: every struct's data and pointer sections are
  /// trimmed of trailing default-valued words, and lists of structs are
  /// re-packed to the smallest uniform element size that still fits every
  /// element.
  ///
  /// The result is the raw words of that single canonical segment, with no
  /// Cap'n Proto message framing — matching capnp-rust's
  /// `message::Reader::canonicalize()` and the `capnp` CLI's `canonical`
  /// output format. Throws [DecodeException] if the message contains a
  /// capability pointer anywhere, since a capability's meaning depends on a
  /// side-channel table that isn't part of the canonical byte
  /// representation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final canonical = reader.canonicalize();
  /// ```
  Uint8List canonicalize() => canonicalizeArena(_arena);
}
