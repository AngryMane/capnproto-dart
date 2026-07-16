/// A pure Dart implementation of Cap'n Proto serialization and streaming.
library;

// ---------------------------------------------------------------------------
// Client application API
// ---------------------------------------------------------------------------

export 'src/exception/capnp_exception.dart';
export 'src/exception/decode_exception.dart';
export 'src/layout/list_reader.dart'
    show
        ListReader,
        NestedListReader,
        voidListFromRaw,
        boolListFromRaw,
        int8ListFromRaw,
        int16ListFromRaw,
        int32ListFromRaw,
        int64ListFromRaw,
        uint8ListFromRaw,
        uint16ListFromRaw,
        uint32ListFromRaw,
        uint64ListFromRaw,
        float32ListFromRaw,
        float64ListFromRaw,
        textListFromRaw,
        dataListFromRaw,
        enumListFromRaw,
        structListFromRaw;
export 'src/layout/list_builder.dart'
    show
        ListBuilder,
        NestedListBuilder,
        voidListBuilderFromRaw,
        boolListBuilderFromRaw,
        int8ListBuilderFromRaw,
        int16ListBuilderFromRaw,
        int32ListBuilderFromRaw,
        int64ListBuilderFromRaw,
        uint8ListBuilderFromRaw,
        uint16ListBuilderFromRaw,
        uint32ListBuilderFromRaw,
        uint64ListBuilderFromRaw,
        float32ListBuilderFromRaw,
        float64ListBuilderFromRaw,
        textListBuilderFromRaw,
        dataListBuilderFromRaw,
        enumListBuilderFromRaw,
        structListBuilderFromRaw;
export 'src/message/message_reader_options.dart';
export 'src/message/message_reader.dart';
export 'src/message/message_builder.dart';
export 'src/stream/message_stream.dart';

// ---------------------------------------------------------------------------
// For use by capnpc-dart generated code
// ---------------------------------------------------------------------------

export 'src/arena/arena_reader.dart' show RawStructReader, RawListReader;
export 'src/wire/pointer.dart' show WirePointer, CapabilityPointer, ListElementSize;
export 'src/arena/arena_builder.dart' show RawStructBuilder;
export 'src/layout/struct_factory.dart';
export 'src/layout/struct_reader.dart';
export 'src/layout/struct_builder.dart';
