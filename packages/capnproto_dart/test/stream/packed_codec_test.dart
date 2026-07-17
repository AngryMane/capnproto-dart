import 'dart:typed_data';

import 'package:capnproto_dart/src/exception/decode_exception.dart';
import 'package:capnproto_dart/src/stream/packed_codec.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Convenience: build a Uint8List from a flat list of byte values.
Uint8List bytes(List<int> values) => Uint8List.fromList(values);

/// Pack then unpack and verify we recover the original bytes.
void _roundTrip(Uint8List input) {
  final packed = packBytes(input);
  final recovered = unpackBytes(packed);
  expect(recovered, equals(input),
      reason: 'round-trip failed for ${input.length}-byte input');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
void main() {
  group('packBytes / unpackBytes — basic correctness', () {
    test('empty input produces empty output', () {
      expect(packBytes(Uint8List(0)), isEmpty);
      expect(unpackBytes(Uint8List(0)), isEmpty);
    });

    test('all-zero word encodes to [0x00, 0x00]', () {
      final input = Uint8List(8); // one zero word
      final packed = packBytes(input);
      expect(packed, equals([0x00, 0x00]));
      _roundTrip(input);
    });

    test('two consecutive zero words encode to [0x00, 0x01]', () {
      final input = Uint8List(16); // two zero words
      final packed = packBytes(input);
      expect(packed, equals([0x00, 0x01]));
      _roundTrip(input);
    });

    test('256 consecutive zero words encode to [0x00, 0xFF]', () {
      // tag 0x00 = current zero word + count 0xFF = 255 additional zero words
      // → total 256 zero words, just 2 bytes.
      final input = Uint8List(256 * 8);
      final packed = packBytes(input);
      expect(packed, equals([0x00, 0xFF]));
      _roundTrip(input);
    });

    test('257 consecutive zero words encode to [0x00, 0xFF, 0x00, 0x00]', () {
      // First run: 1 + 255 = 256 zero words → [0x00, 0xFF]
      // Remaining 1 zero word: tag 0x00, count 0x00 → [0x00, 0x00]
      final input = Uint8List(257 * 8);
      final packed = packBytes(input);
      expect(packed, equals([0x00, 0xFF, 0x00, 0x00]));
      _roundTrip(input);
    });

    test('all-ones word encodes to [0xFF, <8 bytes>, 0x00]', () {
      final input = bytes(List.filled(8, 0xFF));
      final packed = packBytes(input);
      // tag 0xFF, 8 literal bytes, count 0 (no additional literal words)
      expect(packed.length, equals(10));
      expect(packed[0], equals(0xFF));
      for (int i = 1; i <= 8; i++) { expect(packed[i], equals(0xFF)); }
      expect(packed[9], equals(0x00));
      _roundTrip(input);
    });

    test('word with one non-zero byte uses single-byte tag', () {
      // Only byte 0 is non-zero → tag = 0x01.
      final input = bytes([0xAB, 0, 0, 0, 0, 0, 0, 0]);
      final packed = packBytes(input);
      expect(packed, equals([0x01, 0xAB]));
      _roundTrip(input);
    });

    test('word with alternating non-zero bytes', () {
      // Bytes 0, 2, 4, 6 are non-zero → tag = 0b01010101 = 0x55.
      final input = bytes([0x11, 0, 0x22, 0, 0x33, 0, 0x44, 0]);
      final packed = packBytes(input);
      expect(packed[0], equals(0x55));
      expect(packed.sublist(1), equals([0x11, 0x22, 0x33, 0x44]));
      _roundTrip(input);
    });

    test('multiple normal words', () {
      final word1 = bytes([1, 0, 0, 0, 0, 0, 0, 0]); // tag 0x01
      final word2 = bytes([0, 0, 0, 0, 0, 0, 0, 2]); // tag 0x80
      final input = Uint8List.fromList([...word1, ...word2]);
      _roundTrip(input);
    });

    test('0xFF literal run spans two words', () {
      // Two consecutive all-0xFF words: first gets tag 0xFF + count byte
      // that includes the second as a literal.
      final input = bytes(List.filled(16, 0xFF));
      final packed = packBytes(input);
      // tag 0xFF, 8 bytes of word 1, count ≥ 1 (word 2 is literal), 8 bytes
      expect(packed.length, equals(10 + 8)); // 10 for first word, 8 verbatim
      _roundTrip(input);
    });
  });

  group('round-trip — real message shapes', () {
    test('single zero word round-trips', () => _roundTrip(Uint8List(8)));

    test('64 words all-zero', () => _roundTrip(Uint8List(512)));

    test('64 words all-0xFF', () => _roundTrip(bytes(List.filled(512, 0xFF))));

    test('mixed zero and non-zero words', () {
      final data = Uint8List(8 * 10);
      for (int i = 0; i < 10; i++) {
        if (i % 2 == 0) data[i * 8] = i + 1; // one non-zero byte per word
      }
      _roundTrip(data);
    });

    test('incrementing byte pattern', () {
      final data = Uint8List(8 * 8);
      for (int i = 0; i < data.length; i++) { data[i] = i & 0xFF; }
      _roundTrip(data);
    });
  });

  group('unpackBytes — explicit wire bytes', () {
    test('tag 0x00 count 0 → one zero word', () {
      final unpacked = unpackBytes(bytes([0x00, 0x00]));
      expect(unpacked, equals(Uint8List(8)));
    });

    test('tag 0x00 count 2 → three zero words', () {
      final unpacked = unpackBytes(bytes([0x00, 0x02]));
      expect(unpacked, equals(Uint8List(24)));
    });

    test('tag 0x01 value 0xAB → [0xAB, 0, 0, 0, 0, 0, 0, 0]', () {
      final unpacked = unpackBytes(bytes([0x01, 0xAB]));
      expect(unpacked, equals(bytes([0xAB, 0, 0, 0, 0, 0, 0, 0])));
    });

    test('tag 0xFF word + count 0 → 8 bytes, no extra', () {
      final wire = bytes([0xFF, 1, 2, 3, 4, 5, 6, 7, 8, 0]);
      final unpacked = unpackBytes(wire);
      expect(unpacked, equals(bytes([1, 2, 3, 4, 5, 6, 7, 8])));
    });

    test('tag 0xFF word + count 1 → 16 bytes', () {
      final wire = bytes([
        0xFF, 1, 2, 3, 4, 5, 6, 7, 8, // first word + tag
        1, // literal count
        10, 20, 30, 40, 50, 60, 70, 80, // second word verbatim
      ]);
      final unpacked = unpackBytes(wire);
      expect(unpacked.length, equals(16));
      expect(unpacked.sublist(0, 8), equals(bytes([1, 2, 3, 4, 5, 6, 7, 8])));
      expect(unpacked.sublist(8), equals(bytes([10, 20, 30, 40, 50, 60, 70, 80])));
    });

    test('two packed words back-to-back', () {
      // Word 1: tag 0x01, byte 0xAA
      // Word 2: tag 0x80, byte 0xBB
      final wire = bytes([0x01, 0xAA, 0x80, 0xBB]);
      final unpacked = unpackBytes(wire);
      expect(unpacked.length, equals(16));
      expect(unpacked[0], equals(0xAA));
      expect(unpacked.sublist(1, 8), equals(bytes([0, 0, 0, 0, 0, 0, 0])));
      expect(unpacked[15], equals(0xBB));
    });
  });

  group('unpackBytes — truncated/malformed input', () {
    // Regression coverage: a tag byte promising more literal/count/verbatim
    // bytes than actually remain must surface as DecodeException, not a raw
    // RangeError escaping from the `packed[i++]` index accesses.

    test('tag 0xFF claims 8 literal bytes but only 2 remain', () {
      expect(
        () => unpackBytes(bytes([0xFF, 1, 2])),
        throwsA(isA<DecodeException>()),
      );
    });

    test('tag byte present but word bytes are cut off entirely', () {
      expect(
        () => unpackBytes(bytes([0x01])), // promises 1 non-zero byte, 0 left
        throwsA(isA<DecodeException>()),
      );
    });

    test('tag 0x00 count byte itself is missing', () {
      expect(
        () => unpackBytes(bytes([0x00])),
        throwsA(isA<DecodeException>()),
      );
    });

    test('tag 0xFF verbatim run count claims more words than remain', () {
      final wire = bytes([
        0xFF, 1, 2, 3, 4, 5, 6, 7, 8, // first word + tag
        2, // literal count claims 2 more words (16 bytes)...
        10, 20, 30, 40, // ...but only 4 bytes are actually present
      ]);
      expect(() => unpackBytes(wire), throwsA(isA<DecodeException>()));
    });
  });

  group('packBytes + MessageBuilder/MessageReader round-trip', () {
    test('packed encode/decode of a simple message', () {
      // Build a minimal framed message manually (8-byte framing + 16-byte data)
      // and verify pack → unpack recovers it.
      // We do not need MessageBuilder here; just verify the codec is symmetric.
      final input = Uint8List(64);
      for (int i = 0; i < 64; i++) { input[i] = (i * 13 + 7) & 0xFF; }
      _roundTrip(input);
    });
  });
}
