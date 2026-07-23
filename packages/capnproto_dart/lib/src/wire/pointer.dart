import 'dart:typed_data';

import 'wire_helpers.dart';

/// Returns the number of 8-byte words needed to hold [count] elements of [size].
/// Returns 0 for void and composite (composite depends on per-element layout).
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = listDataWordCount;
/// ```
int listDataWordCount(ListElementSize size, int count) => switch (size) {
  ListElementSize.void_ => 0,
  ListElementSize.bit => (count + 63) ~/ 64,
  ListElementSize.byte => (count + 7) ~/ 8,
  ListElementSize.twoBytes => (count * 2 + 7) ~/ 8,
  ListElementSize.fourBytes => (count * 4 + 7) ~/ 8,
  ListElementSize.eightBytes => count,
  ListElementSize.pointer => count,
  ListElementSize.composite => 0,
};

/// Element size encoding used in list pointers.
enum ListElementSize {
  /// Creates a [void_] instance.
  void_(0),

  /// Creates a [bit] instance.
  bit(1),

  /// Creates a [byte] instance.
  byte(2),

  /// Creates a [twoBytes] instance.
  twoBytes(3),

  /// Creates a [fourBytes] instance.
  fourBytes(4),

  /// Creates a [eightBytes] instance.
  eightBytes(5),

  /// Creates a [pointer] instance.
  pointer(6),

  /// Composite elements: each element is a struct. The list is preceded by a
  /// tag word that encodes the actual element count and per-element layout.
  composite(7);

  const ListElementSize(this.value);

  /// Holds the public [value] value.
  final int value;

  /// Performs the [fromInt] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final size = ListElementSize.fromInt(2);
  /// ```
  static ListElementSize fromInt(int v) => values.firstWhere(
    (e) => e.value == v,
    orElse: () => throw ArgumentError('invalid element size: $v'),
  );
}

/// Decoded representation of a single Cap'n Proto wire pointer (8 bytes).
///
/// Pointers use a tagged-union encoding. The bottom 2 bits of the low word
/// indicate the pointer kind; the remaining bits carry kind-specific fields.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
sealed class WirePointer {
  const WirePointer();

  /// Decodes the pointer stored at [wordOffset] (0-based) within [data].
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final decoded = WirePointer.decode(data, 0);
  /// ```
  static WirePointer decode(ByteData data, int wordOffset) {
    final byteOffset = wordOffset * bytesPerWord;
    final lo = readUint32(data, byteOffset);
    final hi = readUint32(data, byteOffset + 4);

    if (lo == 0 && hi == 0) return const NullPointer();

    final signedLo = reinterpretAsInt32(lo);
    return switch (lo & 3) {
      0 => StructPointer(
        offset: signedLo >> 2,
        dataWords: hi & 0xFFFF,
        ptrWords: (hi >> 16) & 0xFFFF,
      ),
      1 => ListPointer(
        offset: signedLo >> 2,
        elementSize: ListElementSize.fromInt(hi & 7),
        elementCountOrWordCount: hi >> 3,
      ),
      2 => FarPointer(
        isDoubleFar: (lo >> 2) & 1 == 1,
        landingPadOffset: lo >> 3,
        segmentId: hi,
      ),
      3 => CapabilityPointer(capabilityIndex: hi),
      _ => throw StateError('unreachable'),
    };
  }

  /// Encodes this pointer into [data] at the given [wordOffset].
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// WirePointer.encode(builder, value);
  /// ```
  void encode(ByteData data, int wordOffset);
}

/// The null pointer (all bits zero). Treated as a pointer to an empty struct.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
final class NullPointer extends WirePointer {
  /// Creates a [NullPointer] instance.
  const NullPointer();

  @override
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// pointer.encode(data, 0);
  /// ```
  void encode(ByteData data, int wordOffset) {
    final byteOffset = wordOffset * bytesPerWord;
    writeUint32(data, byteOffset, 0);
    writeUint32(data, byteOffset + 4, 0);
  }
}

/// Pointer to a struct object.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
final class StructPointer extends WirePointer {
  /// Signed 30-bit word offset from end of this pointer to the struct's data section.
  final int offset;

  /// Number of 8-byte words in the struct's data section.
  final int dataWords;

  /// Number of 8-byte words in the struct's pointer section.
  final int ptrWords;

  /// Creates a [StructPointer] instance.
  const StructPointer({
    required this.offset,
    required this.dataWords,
    required this.ptrWords,
  });

  @override
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// pointer.encode(data, 0);
  /// ```
  void encode(ByteData data, int wordOffset) {
    final byteOffset = wordOffset * bytesPerWord;
    writeUint32(data, byteOffset, (offset << 2) & 0xFFFFFFFF);
    writeUint32(
      data,
      byteOffset + 4,
      (dataWords & 0xFFFF) | ((ptrWords & 0xFFFF) << 16),
    );
  }
}

/// Pointer to a list object.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
final class ListPointer extends WirePointer {
  /// Signed 30-bit word offset from end of this pointer to the list's first element.
  final int offset;

  /// Encoding of each element's size.
  final ListElementSize elementSize;

  /// For non-composite lists: number of elements.
  /// For composite lists ([ListElementSize.composite]): total word count of list data
  /// (not counting the preceding tag word).
  final int elementCountOrWordCount;

  /// Creates a [ListPointer] instance.
  const ListPointer({
    required this.offset,
    required this.elementSize,
    required this.elementCountOrWordCount,
  });

  @override
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// pointer.encode(data, 0);
  /// ```
  void encode(ByteData data, int wordOffset) {
    final byteOffset = wordOffset * bytesPerWord;
    writeUint32(data, byteOffset, ((offset << 2) & 0xFFFFFFFF) | 1);
    writeUint32(
      data,
      byteOffset + 4,
      (elementSize.value & 7) | ((elementCountOrWordCount & 0x1FFFFFFF) << 3),
    );
  }
}

/// Inter-segment pointer that redirects traversal to a different segment.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
final class FarPointer extends WirePointer {
  /// If true, [landingPadOffset] points to a two-word landing pad (double-far).
  final bool isDoubleFar;

  /// Unsigned 29-bit word offset within [segmentId] of the landing pad.
  final int landingPadOffset;

  /// Target segment index.
  final int segmentId;

  /// Creates a [FarPointer] instance.
  const FarPointer({
    required this.isDoubleFar,
    required this.landingPadOffset,
    required this.segmentId,
  });

  @override
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// pointer.encode(data, 0);
  /// ```
  void encode(ByteData data, int wordOffset) {
    final byteOffset = wordOffset * bytesPerWord;
    writeUint32(
      data,
      byteOffset,
      2 | ((isDoubleFar ? 1 : 0) << 2) | ((landingPadOffset & 0x1FFFFFFF) << 3),
    );
    writeUint32(data, byteOffset + 4, segmentId);
  }
}

/// Pointer to an entry in the message's capability table.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
final class CapabilityPointer extends WirePointer {
  /// Index into the capability table.
  final int capabilityIndex;

  /// Creates a [CapabilityPointer] instance.
  const CapabilityPointer({required this.capabilityIndex});

  @override
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// pointer.encode(data, 0);
  /// ```
  void encode(ByteData data, int wordOffset) {
    final byteOffset = wordOffset * bytesPerWord;
    writeUint32(data, byteOffset, 3);
    writeUint32(data, byteOffset + 4, capabilityIndex);
  }
}
