import 'dart:typed_data';

import '../arena/arena_reader.dart';
import '../layout/struct_builder.dart';
import '../layout/struct_factory.dart';
import '../layout/struct_reader.dart';
import '../stream/packed_codec.dart';
import 'message_reader_options.dart';

class MessageReader {
  final ArenaReader _arena;

  MessageReader._(this._arena);

  static MessageReader deserialize(
    Uint8List bytes, [
    MessageReaderOptions options = const MessageReaderOptions(),
  ]) =>
      MessageReader._(ArenaReader.fromBytes(bytes, options));

  static MessageReader deserializePacked(
    Uint8List bytes, [
    MessageReaderOptions options = const MessageReaderOptions(),
  ]) =>
      MessageReader._(ArenaReader.fromBytes(unpackBytes(bytes), options));

  R getRoot<R extends StructReader, B extends StructBuilder>(
    StructFactory<R, B> factory,
  ) =>
      factory.fromRawReader(_arena.getRootRaw());
}
