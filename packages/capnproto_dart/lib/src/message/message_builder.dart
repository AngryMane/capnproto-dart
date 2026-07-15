import 'dart:typed_data';

import '../arena/arena_builder.dart';
import '../layout/struct_builder.dart';
import '../layout/struct_factory.dart';
import '../layout/struct_reader.dart';
import '../stream/packed_codec.dart';

class MessageBuilder {
  final ArenaBuilder _arena = ArenaBuilder();

  MessageBuilder();

  B initRoot<R extends StructReader, B extends StructBuilder>(
    StructFactory<R, B> factory,
  ) {
    // Allocate the root pointer slot (word 0 of segment 0).
    final (ptrSeg, ptrWordOffset) = _arena.allocate(1);
    final raw = _arena.allocateStruct(
      ptrSeg: ptrSeg,
      ptrWordOffset: ptrWordOffset,
      dataWords: factory.dataWords,
      ptrWords: factory.ptrWords,
    );
    return factory.fromRawBuilder(raw);
  }

  Uint8List serialize() => _arena.serialize();

  Uint8List serializePacked() => packBytes(serialize());
}
