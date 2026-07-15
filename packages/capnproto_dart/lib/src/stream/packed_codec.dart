import 'dart:typed_data';

/// Packs [input] using the Cap'n Proto packed encoding.
///
/// [input] must be a multiple of 8 bytes (whole words). Encoding rules for
/// each 8-byte word:
/// - Tag byte: bit i is 1 iff byte i of the word is non-zero.
/// - The non-zero bytes (those flagged by the tag) follow the tag.
/// - Tag == 0x00: next byte is the count of additional zero words that follow.
/// - Tag == 0xFF: the 8 bytes of the word follow, then a count byte for
///   additional verbatim words, then those words' raw bytes.
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
      // Write all 8 bytes of the current word verbatim.
      for (int b = 0; b < 8; b++) { buf[outIdx++] = input[base + b]; }
      wordIdx++;

      // Look ahead: include consecutive words that have ≤ 1 zero byte as
      // additional verbatim ("literal") words. These words would not compress
      // well in tagged mode (the overhead would cancel any savings).
      final literalStart = wordIdx;
      int litCount = 0;
      while (litCount < 255 && wordIdx < wordCount) {
        final b2 = wordIdx * 8;
        int zeros = 0;
        for (int b = 0; b < 8; b++) {
          if (input[b2 + b] == 0) zeros++;
        }
        if (zeros > 1) break;
        litCount++;
        wordIdx++;
      }
      buf[outIdx++] = litCount;
      for (int j = 0; j < litCount * 8; j++) {
        buf[outIdx++] = input[literalStart * 8 + j]; // literal copy
      }
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
Uint8List unpackBytes(Uint8List packed) {
  // Use a List<int> because zero-run expansion can be large and unpredictable.
  final out = <int>[];
  int i = 0;

  while (i < packed.length) {
    final tag = packed[i++];

    // Reconstruct the 8 bytes of the current word.
    for (int b = 0; b < 8; b++) {
      out.add((tag >> b) & 1 == 1 ? packed[i++] : 0);
    }

    if (tag == 0x00) {
      // Emit additional zero words.
      final count = packed[i++];
      for (int j = 0; j < count * 8; j++) { out.add(0); }
    } else if (tag == 0xFF) {
      // Emit additional verbatim words.
      final count = packed[i++];
      for (int j = 0; j < count * 8; j++) { out.add(packed[i++]); }
    }
  }

  return Uint8List.fromList(out);
}
