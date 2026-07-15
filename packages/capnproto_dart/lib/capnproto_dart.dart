/// A pure Dart implementation of Cap'n Proto serialization and streaming.
library;

// ---------------------------------------------------------------------------
// Client application API
// ---------------------------------------------------------------------------

export 'src/exception/capnp_exception.dart';
export 'src/exception/decode_exception.dart';
export 'src/layout/list_reader.dart' show ListReader;
export 'src/layout/list_builder.dart' show ListBuilder;
export 'src/message/message_reader_options.dart';
export 'src/message/message_reader.dart';
export 'src/message/message_builder.dart';
export 'src/stream/message_stream.dart';

// ---------------------------------------------------------------------------
// For use by capnpc-dart generated code
// ---------------------------------------------------------------------------

export 'src/arena/arena_reader.dart' show RawStructReader;
export 'src/arena/arena_builder.dart' show RawStructBuilder;
export 'src/layout/struct_factory.dart';
export 'src/layout/struct_reader.dart';
export 'src/layout/struct_builder.dart';
