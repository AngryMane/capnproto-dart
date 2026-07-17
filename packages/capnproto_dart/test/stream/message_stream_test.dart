import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart/src/arena/arena_builder.dart';
import 'package:capnproto_dart/src/arena/arena_reader.dart';
import 'package:capnproto_dart/src/exception/decode_exception.dart';
import 'package:capnproto_dart/src/layout/struct_builder.dart';
import 'package:capnproto_dart/src/layout/struct_factory.dart';
import 'package:capnproto_dart/src/layout/struct_reader.dart';
import 'package:capnproto_dart/src/message/message_builder.dart';
import 'package:capnproto_dart/src/message/message_reader.dart';
import 'package:capnproto_dart/src/message/message_reader_options.dart';
import 'package:capnproto_dart/src/stream/message_stream.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Minimal hand-written struct:  struct Point { x @0 :Int32; y @1 :Int32; }
// ---------------------------------------------------------------------------
class PointReader extends StructReader {
  PointReader(super.raw);
  int get x => getInt32Field(0);
  int get y => getInt32Field(4);
}

class PointBuilder extends StructBuilder {
  PointBuilder(super.raw);
  set x(int v) => setInt32Field(0, v);
  set y(int v) => setInt32Field(4, v);
  @override
  PointReader asReader() => throw UnimplementedError();
}

class _PointFactory extends StructFactory<PointReader, PointBuilder> {
  @override int get dataWords => 1;
  @override int get ptrWords => 0;
  @override PointReader fromRawReader(RawStructReader r) => PointReader(r);
  @override PointBuilder fromRawBuilder(RawStructBuilder r) => PointBuilder(r);
}

final _factory = _PointFactory();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a serialized Point message.
Uint8List _buildPoint(int x, int y) {
  final msg = MessageBuilder();
  final pt = msg.initRoot(_factory);
  pt.x = x;
  pt.y = y;
  return msg.serialize();
}

/// Add [data] to a StreamController in [chunkSize]-byte pieces, close it,
/// then deserialize the stream and return all decoded PointReaders.
Future<List<PointReader>> _deserializeChunked(
  Uint8List data,
  int chunkSize,
) async {
  final ctrl = StreamController<Uint8List>();
  for (int offset = 0; offset < data.length; offset += chunkSize) {
    final end = (offset + chunkSize).clamp(0, data.length);
    ctrl.add(Uint8List.sublistView(data, offset, end));
  }
  ctrl.close(); // don't await — queue close before subscribing

  return MessageStream.deserializeStream(ctrl.stream)
      .map((msg) => msg.getRoot(_factory))
      .toList();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
void main() {
  group('MessageStream.serializeStream', () {
    test('serializes one message', () async {
      final ctrl = StreamController<MessageBuilder>();

      final msg = MessageBuilder();
      (msg.initRoot(_factory))
        ..x = 10
        ..y = 20;
      ctrl.add(msg);
      ctrl.close();

      final chunks = await MessageStream.serializeStream(ctrl.stream).toList();
      expect(chunks.length, equals(1));
      final pt = MessageReader.deserialize(chunks[0]).getRoot(_factory);
      expect(pt.x, equals(10));
      expect(pt.y, equals(20));
    });

    test('serializes three messages', () async {
      final ctrl = StreamController<MessageBuilder>();
      for (int i = 0; i < 3; i++) {
        final msg = MessageBuilder();
        (msg.initRoot(_factory)).x = i;
        ctrl.add(msg);
      }
      ctrl.close();

      final chunks = await MessageStream.serializeStream(ctrl.stream).toList();
      expect(chunks.length, equals(3));
      for (int i = 0; i < 3; i++) {
        expect(
          MessageReader.deserialize(chunks[i]).getRoot(_factory).x,
          equals(i),
        );
      }
    });

    test('empty stream yields nothing', () async {
      final ctrl = StreamController<MessageBuilder>()..close();
      final chunks = await MessageStream.serializeStream(ctrl.stream).toList();
      expect(chunks, isEmpty);
    });
  });

  group('MessageStream.deserializeStream', () {
    test('reads a single message delivered in one chunk', () async {
      final bytes = _buildPoint(3, 4);
      final results = await _deserializeChunked(bytes, bytes.length);
      expect(results.length, equals(1));
      expect(results[0].x, equals(3));
      expect(results[0].y, equals(4));
    });

    test('reads a single message delivered 1 byte at a time', () async {
      final bytes = _buildPoint(5, 6);
      final results = await _deserializeChunked(bytes, 1);
      expect(results.length, equals(1));
      expect(results[0].x, equals(5));
      expect(results[0].y, equals(6));
    });

    test('reads three concatenated messages in one chunk', () async {
      final pts = [(1, 2), (3, 4), (5, 6)];
      final concat = Uint8List.fromList(
          pts.expand((p) => _buildPoint(p.$1, p.$2)).toList());

      final results = await _deserializeChunked(concat, concat.length);
      expect(results.length, equals(3));
      for (int i = 0; i < 3; i++) {
        expect(results[i].x, equals(pts[i].$1));
        expect(results[i].y, equals(pts[i].$2));
      }
    });

    test('reads three concatenated messages delivered in 3-byte chunks', () async {
      final pts = [(10, 20), (30, 40), (50, 60)];
      final concat = Uint8List.fromList(
          pts.expand((p) => _buildPoint(p.$1, p.$2)).toList());

      final results = await _deserializeChunked(concat, 3);
      expect(results.length, equals(3));
      for (int i = 0; i < 3; i++) {
        expect(results[i].x, equals(pts[i].$1));
        expect(results[i].y, equals(pts[i].$2));
      }
    });

    test('empty stream yields nothing', () async {
      final results = await _deserializeChunked(Uint8List(0), 8);
      expect(results, isEmpty);
    });

    test('serialize-then-deserialize round-trip via stream', () async {
      // Build 5 messages, serialize to stream, concatenate, then deserialize.
      final serCtrl = StreamController<MessageBuilder>();
      for (int i = 0; i < 5; i++) {
        final msg = MessageBuilder();
        (msg.initRoot(_factory))
          ..x = i * 10
          ..y = i * 10 + 1;
        serCtrl.add(msg);
      }
      serCtrl.close();

      final serialized =
          await MessageStream.serializeStream(serCtrl.stream).toList();
      final concat =
          Uint8List.fromList(serialized.expand((b) => b).toList());

      final results = await _deserializeChunked(concat, 7);
      expect(results.length, equals(5));
      for (int i = 0; i < 5; i++) {
        expect(results[i].x, equals(i * 10));
        expect(results[i].y, equals(i * 10 + 1));
      }
    });
  });

  group('MessageStream.deserializeStreamRaw size limits', () {
    // Regression coverage: a declared (not yet delivered) message size must
    // be rejected as soon as the declaring bytes are seen, not only after
    // enough bytes have already been buffered to reach that size — otherwise
    // a peer could force unbounded buffering just by sending a header that
    // claims an enormous message.

    test(
      'rejects an oversized declared segment count from only 4 header bytes',
      () async {
        final ctrl = StreamController<Uint8List>();
        // numSegments - 1 = 1000 → 1001 segments, exceeding the default
        // maxSegments (512). Only the 4-byte segment-count field is sent —
        // if this weren't rejected immediately, the stream would sit
        // waiting for a header (1001 further uint32s) that never arrives.
        final header = Uint8List(4);
        ByteData.view(header.buffer).setUint32(0, 1000, Endian.little);
        ctrl.add(header);

        final results = MessageStream.deserializeStreamRaw(ctrl.stream);
        final future = results.toList();
        await expectLater(future, throwsA(isA<DecodeException>()));
        await ctrl.close();
      },
    );

    test(
      'rejects an oversized declared word count without buffering it',
      () async {
        final ctrl = StreamController<Uint8List>();
        // 1 segment declaring 10,000,000 words — exceeds a small
        // traversalLimitInWords passed below. Only the 8-byte header is
        // sent, no segment data — if this weren't rejected immediately, the
        // stream would sit waiting for ~76MB of segment bytes that never
        // arrive.
        final header = Uint8List(8);
        final bd = ByteData.view(header.buffer);
        bd.setUint32(0, 0, Endian.little); // numSegments - 1 = 0
        bd.setUint32(4, 10000000, Endian.little); // segment 0: 10M words
        ctrl.add(header);

        final results = MessageStream.deserializeStreamRaw(
          ctrl.stream,
          const MessageReaderOptions(traversalLimitInWords: 1024),
        );
        final future = results.toList();
        await expectLater(future, throwsA(isA<DecodeException>()));
        await ctrl.close();
      },
    );
  });

  group('MessageReader.deserializePacked / MessageBuilder.serializePacked', () {
    test('packed round-trip for a Point message', () {
      final msg = MessageBuilder();
      (msg.initRoot(_factory))
        ..x = 42
        ..y = -7;
      final packed = msg.serializePacked();
      final pt = MessageReader.deserializePacked(packed).getRoot(_factory);
      expect(pt.x, equals(42));
      expect(pt.y, equals(-7));
    });

    test('packed bytes are shorter than unpacked for a sparse message', () {
      final msg = MessageBuilder();
      (msg.initRoot(_factory)).x = 1; // y stays 0 → lots of zero bytes
      expect(msg.serializePacked().length, lessThan(msg.serialize().length));
    });

    test('multiple packed round-trips', () {
      for (final pair in [(0, 0), (1, -1), (0x7FFFFFFF, -0x80000000)]) {
        final msg = MessageBuilder();
        (msg.initRoot(_factory))
          ..x = pair.$1
          ..y = pair.$2;
        final pt =
            MessageReader.deserializePacked(msg.serializePacked()).getRoot(_factory);
        expect(pt.x, equals(pair.$1), reason: 'x mismatch for $pair');
        expect(pt.y, equals(pair.$2), reason: 'y mismatch for $pair');
      }
    });
  });
}
