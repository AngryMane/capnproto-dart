import '../arena/arena_builder.dart';
import '../arena/arena_reader.dart';
import 'struct_builder.dart';
import 'struct_reader.dart';

/// Factory that carries struct layout information and constructs typed
/// reader/builder instances from raw arena pointers.
///
/// Generated code produces a concrete subclass for each Cap'n Proto struct.
abstract class StructFactory<R extends StructReader, B extends StructBuilder> {
  /// Number of 8-byte words in the struct's data section.
  int get dataWords;

  /// Number of 8-byte words in the struct's pointer section.
  int get ptrWords;

  /// Wraps [raw] in a typed reader.
  R fromRawReader(RawStructReader raw);

  /// Wraps [raw] in a typed builder.
  B fromRawBuilder(RawStructBuilder raw);
}
