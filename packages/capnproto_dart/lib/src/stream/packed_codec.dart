import 'dart:typed_data';

import '../exception/decode_exception.dart';

/// Packs [input] using the Cap'n Proto packed encoding.
///
/// [input] must be a multiple of 8 bytes (whole words). Encoding rules for
/// each 8-byte word:
/// - Tag byte: bit i is 1 iff byte i of the word is non-zero.
/// - The non-zero bytes (those flagged by the tag) follow the tag.
/// - Tag == 0x00: next byte is the count of additional zero words that follow.
/// - Tag == 0xFF: the 8 bytes of the word follow, then a count byte for
///   additional verbatim words, then those words' raw bytes.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = packBytes;
/// ```
Uint8List packBytes(Uint8List input) {
  assert(input.length % 8 == 0, 'input length must be a multiple of 8');

  // Worst-case output size: a 0xFF word emits 1 + 8 + 1 bytes for 8 input
  // bytes → ratio ≤ 10/8. Allocate 2× to be safe.
  final buf = Uint8List(input.length * 2 + 2);
  int outIdx = 0;
  final wordCount = input.length ~/ 8;
  int wordIdx = 0;

  while (wordIdx < wordCount) {
    final base = wordIdx * 8;

    // Compute the tag byte: bit i set iff input[base + i] != 0.
    int tag = 0;
    for (int b = 0; b < 8; b++) {
      if (input[base + b] != 0) tag |= 1 << b;
    }

    buf[outIdx++] = tag;

    if (tag == 0x00) {
      wordIdx++;
      // Count additional consecutive zero words (up to 255).
      int count = 0;
      while (count < 255 && wordIdx < wordCount) {
        final b2 = wordIdx * 8;
        bool allZero = true;
        for (int b = 0; b < 8; b++) {
          if (input[b2 + b] != 0) {
            allZero = false;
            break;
          }
        }
        if (!allZero) break;
        count++;
        wordIdx++;
      }
      buf[outIdx++] = count;
    } else if (tag == 0xFF) {
      // Write all 8 bytes of the current word verbatim, in one bulk copy
      // rather than a byte-by-byte loop.
      buf.setRange(outIdx, outIdx + 8, input, base);
      outIdx += 8;
      wordIdx++;

      // Look ahead: include consecutive words that have ≤ 1 zero byte as
      // additional verbatim ("literal") words. These words would not compress
      // well in tagged mode (the overhead would cancel any savings). This
      // scan can't be a bulk op since each word's inclusion is conditional,
      // but it can bail out of a word's 8-byte check as soon as it's
      // disqualified instead of always counting all 8 bytes.
      final literalStart = wordIdx;
      int litCount = 0;
      while (litCount < 255 && wordIdx < wordCount) {
        final b2 = wordIdx * 8;
        int zeros = 0;
        for (int b = 0; b < 8; b++) {
          if (input[b2 + b] == 0) {
            zeros++;
            if (zeros > 1) break;
          }
        }
        if (zeros > 1) break;
        litCount++;
        wordIdx++;
      }
      buf[outIdx++] = litCount;
      // Bulk-copy the whole literal run in one shot instead of per byte.
      buf.setRange(outIdx, outIdx + litCount * 8, input, literalStart * 8);
      outIdx += litCount * 8;
    } else {
      // Normal case: write only the non-zero bytes.
      for (int b = 0; b < 8; b++) {
        if ((tag >> b) & 1 == 1) buf[outIdx++] = input[base + b];
      }
      wordIdx++;
    }
  }
  return Uint8List.sublistView(buf, 0, outIdx);
}

/// Unpacks packed Cap'n Proto bytes, returning the original byte stream.
///
/// The output length is always a multiple of 8 (whole words).
///
/// [maxOutputBytes], when given, bounds how many bytes the expansion is
/// allowed to produce. The packed encoding's zero-run tag lets 2 input bytes
/// (`0x00` + a count byte) expand to up to 2040 zero bytes — a ~1000x
/// amplification — so unpacking attacker-controlled input without a cap
/// lets a small message force an arbitrarily large allocation (a
/// "decompression bomb") before any other size limit in the library gets a
/// chance to run. Throws [DecodeException] as soon as the output would
/// exceed the cap, rather than finishing the expansion first.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = unpackBytes;
/// ```
Uint8List unpackBytes(Uint8List packed, {int? maxOutputBytes}) {
  if (maxOutputBytes != null && maxOutputBytes < 0) {
    throw ArgumentError.value(
      maxOutputBytes,
      'maxOutputBytes',
      'must be non-negative or null',
    );
  }

  // Growable Uint8List with manual capacity doubling, instead of a
  // List<int>: avoids per-element boxing/dispatch overhead and the final
  // full-array copy Uint8List.fromList(List<int>) would need, and lets
  // zero/verbatim runs be written with one fillRange/setRange call rather
  // than a byte-by-byte add() loop.
  var output = Uint8List(0);
  var length = 0;
  int i = 0;

  void checkCap(int additionalBytes) {
    if (maxOutputBytes != null && length + additionalBytes > maxOutputBytes) {
      throw DecodeException(
        'packed data expands beyond maxOutputBytes ($maxOutputBytes bytes)',
      );
    }
  }

  void ensureCapacity(int additionalBytes) {
    final required = length + additionalBytes;
    if (required <= output.length) return;
    var next = output.isEmpty ? 256 : output.length * 2;
    if (next < required) next = required;
    final grown = Uint8List(next);
    grown.setRange(0, length, output);
    output = grown;
  }

  try {
    while (i < packed.length) {
      final tag = packed[i++];

      if (tag == 0x00) {
        // Whole word is zero; count is the number of additional zero words.
        final count = packed[i++];
        final zeroBytes = (count + 1) * 8;
        checkCap(zeroBytes);
        ensureCapacity(zeroBytes);
        output.fillRange(length, length + zeroBytes, 0);
        length += zeroBytes;
      } else if (tag == 0xFF) {
        // Whole word is verbatim (every bit set): bulk-copy it, then any
        // additional verbatim words the count byte promises.
        checkCap(8);
        if (i + 8 > packed.length) throw RangeError('truncated');
        ensureCapacity(8);
        output.setRange(length, length + 8, packed, i);
        length += 8;
        i += 8;

        final count = packed[i++];
        final extraBytes = count * 8;
        checkCap(extraBytes);
        if (i + extraBytes > packed.length) throw RangeError('truncated');
        ensureCapacity(extraBytes);
        output.setRange(length, length + extraBytes, packed, i);
        length += extraBytes;
        i += extraBytes;
      } else {
        // Mixed word: bit b of the tag says whether byte b came through
        // (non-zero) or was elided (zero), so this can't be a single bulk
        // copy — reconstruct byte-by-byte from the tag bits.
        checkCap(8);
        ensureCapacity(8);
        for (int b = 0; b < 8; b++) {
          output[length++] = (tag >> b) & 1 == 1 ? packed[i++] : 0;
        }
      }
    }
  } on RangeError {
    // A tag promised more literal/verbatim bytes than actually remain —
    // truncated or otherwise malformed packed input. Surfaced as a
    // DecodeException like every other malformed-input case in this
    // library, rather than leaking the raw RangeError.
    throw DecodeException(
      'packed data truncated or malformed: expected more bytes after '
      'offset $i (have ${packed.length})',
    );
  }
  return Uint8List.sublistView(output, 0, length);
}
