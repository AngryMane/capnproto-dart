import 'dart:typed_data';

import '../arena/arena_reader.dart';
import '../layout/struct_builder.dart';
import '../layout/struct_factory.dart';
import '../layout/struct_reader.dart';
import '../stream/packed_codec.dart';
import 'message_copy.dart';
import 'message_reader_options.dart';

class MessageReader {
  final ArenaReader _arena;

  MessageReader._(this._arena);

  static MessageReader deserialize(
    Uint8List bytes, [
    MessageReaderOptions options = const MessageReaderOptions(),
  ]) => MessageReader._(ArenaReader.fromBytes(bytes, options));

  static MessageReader deserializePacked(
    Uint8List bytes, [
    MessageReaderOptions options = const MessageReaderOptions(),
  ]) => MessageReader._(ArenaReader.fromBytes(unpackBytes(bytes), options));

  R getRoot<R extends StructReader, B extends StructBuilder>(
    StructFactory<R, B> factory, {
    List<Object?> capabilities = const [],
  }) =>
      factory.fromRawReaderWithCapabilities(_arena.getRootRaw(), capabilities);

  /// Returns the raw struct reader for the root object.
  ///
  /// Used by low-level consumers (e.g. the RPC layer) that need to inspect
  /// pointer slots directly without a typed factory.
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
  Uint8List canonicalize() => canonicalizeArena(_arena);
}
