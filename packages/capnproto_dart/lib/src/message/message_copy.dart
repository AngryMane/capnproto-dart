// Deep-copy utilities for Cap'n Proto objects.
//
// Used by the RPC layer to extract AnyPointer struct fields (Payload.content)
// into standalone messages, enabling interoperability with non-Dart peers.

import 'dart:typed_data';

import '../arena/arena_builder.dart';
import '../arena/arena_reader.dart';
import '../arena/segment_builder.dart';
import '../arena/segment_reader.dart';
import '../wire/pointer.dart';
import '../wire/wire_helpers.dart';
import 'message_reader_options.dart';

/// Deep-copies [messageBytes] into a new single-segment message.
///
/// This is a bytes-only copy: capability pointers are zeroed because their
/// indices are meaningful only together with the original message's capability
/// table, which is not represented in raw serialized bytes.
Uint8List ensureSingleSegment(
  Uint8List messageBytes, {
  bool preserveCapabilityPointers = false,
}) {
  if (messageBytes.lengthInBytes < 4) return messageBytes;
  final hdr = ByteData.sublistView(messageBytes, 0, messageBytes.lengthInBytes);
  final numSegmentsMinusOne = readUint32(hdr, 0);

  if (preserveCapabilityPointers && numSegmentsMinusOne == 0) {
    return messageBytes;
  }

  // Calculate total source data words to size the destination arena.
  int totalSourceWords = 0;
  for (int i = 0; i <= numSegmentsMinusOne; i++) {
    totalSourceWords += readUint32(hdr, 4 + i * 4);
  }

  // Deep-copy the root pointer into a pre-sized single-segment arena.
  final srcArena = ArenaReader.fromBytes(
    messageBytes,
    const MessageReaderOptions(),
  );
  // Add 64 words of overhead for the root pointer slot and alignment.
  final dst = ArenaBuilder(totalSourceWords + 64);
  final (ptrSeg, rootPtrOffset) = dst.allocate(1);
  _copyPointer(
    srcArena,
    srcArena.getSegment(0),
    0,
    srcArena.nestingLimit,
    dst,
    ptrSeg,
    rootPtrOffset,
    preserveCapabilityPointers: preserveCapabilityPointers,
  );
  return dst.serialize();
}

/// Reads the AnyPointer at ptr slot [ptrIndex] of [host], deep-copies the
/// referenced struct into a new standalone message, and returns the serialized
/// bytes.  Returns null if the pointer is null or a CapabilityPointer
/// (capabilities cannot be deep-copied).
Uint8List? copyAnyPointerToNewMessage(
  RawStructReader host,
  int ptrIndex, {
  bool preserveCapabilityPointers = false,
}) {
  if (ptrIndex >= host.ptrWords) return null;
  final ptrWordOffset = host.ptrWordOffset + ptrIndex;

  // Peek at the pointer type before attempting resolution.
  final peeked = WirePointer.decode(host.segment.data, ptrWordOffset);
  if (peeked is NullPointer || peeked is CapabilityPointer) return null;

  final src = host.arena.resolveOptionalStructAt(
    host.segment,
    ptrWordOffset,
    host.nestingLimit,
  );
  if (src == null) return null;

  final dst = ArenaBuilder();
  final (ptrSeg, rootPtrOffset) = dst.allocate(1);
  _copyStruct(
    src,
    host.arena,
    dst,
    ptrSeg,
    rootPtrOffset,
    preserveCapabilityPointers: preserveCapabilityPointers,
  );
  return dst.serialize();
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

void _copyStruct(
  RawStructReader src,
  ArenaReader srcArena,
  ArenaBuilder dstArena,
  SegmentBuilder dstPtrSeg,
  int dstPtrWordOffset, {
  bool preserveCapabilityPointers = false,
}) {
  final dst = dstArena.allocateStruct(
    ptrSeg: dstPtrSeg,
    ptrWordOffset: dstPtrWordOffset,
    dataWords: src.dataWords,
    ptrWords: src.ptrWords,
  );

  // Copy data section byte-by-byte.
  if (src.dataWords > 0) {
    final byteCount = src.dataWords * bytesPerWord;
    final srcBase = src.dataWordOffset * bytesPerWord;
    final dstBase = dst.dataWordOffset * bytesPerWord;
    final srcBuf = src.segment.data.buffer.asUint8List(
      src.segment.data.offsetInBytes,
    );
    final dstBuf = dst.segment.data.buffer.asUint8List();
    dstBuf.setRange(dstBase, dstBase + byteCount, srcBuf, srcBase);
  }

  // Recursively copy pointer section.
  for (var i = 0; i < src.ptrWords; i++) {
    _copyPointer(
      srcArena,
      src.segment,
      src.ptrWordOffset + i,
      src.nestingLimit,
      dstArena,
      dst.segment,
      dst.ptrWordOffset + i,
      preserveCapabilityPointers: preserveCapabilityPointers,
    );
  }
}

void _copyPointer(
  ArenaReader srcArena,
  SegmentReader srcSeg,
  int srcPtrWordOffset,
  int nestingLimit,
  ArenaBuilder dstArena,
  SegmentBuilder dstSeg,
  int dstPtrWordOffset, {
  bool preserveCapabilityPointers = false,
}) {
  final ptr = WirePointer.decode(srcSeg.data, srcPtrWordOffset);
  switch (ptr) {
    case NullPointer():
      return; // leave destination slot as zero

    case FarPointer():
      final targetSeg = srcArena.getSegment(ptr.segmentId);
      if (!ptr.isDoubleFar) {
        _copyPointer(
          srcArena,
          targetSeg,
          ptr.landingPadOffset,
          nestingLimit,
          dstArena,
          dstSeg,
          dstPtrWordOffset,
          preserveCapabilityPointers: preserveCapabilityPointers,
        );
      } else {
        // Double-far landing pad: [far_ptr, struct_tag]
        final inner = WirePointer.decode(targetSeg.data, ptr.landingPadOffset);
        final tag = WirePointer.decode(
          targetSeg.data,
          ptr.landingPadOffset + 1,
        );
        if (inner is FarPointer && !inner.isDoubleFar && tag is StructPointer) {
          final dataSeg = srcArena.getSegment(inner.segmentId);
          final structSrc = RawStructReader(
            segment: dataSeg,
            arena: srcArena,
            dataWordOffset: inner.landingPadOffset,
            dataWords: tag.dataWords,
            ptrWordOffset: inner.landingPadOffset + tag.dataWords,
            ptrWords: tag.ptrWords,
            nestingLimit: nestingLimit - 1,
          );
          _copyStruct(
            structSrc,
            srcArena,
            dstArena,
            dstSeg,
            dstPtrWordOffset,
            preserveCapabilityPointers: preserveCapabilityPointers,
          );
        }
      }

    case StructPointer():
      final structSrc = srcArena.resolveStructAt(
        srcSeg,
        srcPtrWordOffset,
        nestingLimit,
      );
      _copyStruct(
        structSrc,
        srcArena,
        dstArena,
        dstSeg,
        dstPtrWordOffset,
        preserveCapabilityPointers: preserveCapabilityPointers,
      );

    case ListPointer():
      _copyList(
        srcArena,
        srcSeg,
        srcPtrWordOffset,
        nestingLimit,
        dstArena,
        dstSeg,
        dstPtrWordOffset,
        preserveCapabilityPointers: preserveCapabilityPointers,
      );

    case CapabilityPointer():
      if (preserveCapabilityPointers) {
        final byteOffset = srcPtrWordOffset * bytesPerWord;
        final dstByteOffset = dstPtrWordOffset * bytesPerWord;
        writeUint32(
          dstSeg.data,
          dstByteOffset,
          readUint32(srcSeg.data, byteOffset),
        );
        writeUint32(
          dstSeg.data,
          dstByteOffset + 4,
          readUint32(srcSeg.data, byteOffset + 4),
        );
        break;
      }
      // Zero out capability pointers during deep copy: a capabilityIndex is
      // only meaningful within its own message's cap table. Without also
      // copying the cap table the index would be a dangling reference.
      // Callers that need capability-aware transfer (e.g. RPC dispatch) use
      // MessageReader.deserialize() directly rather than going through this
      // deep-copy path.
      break; // destination slot remains zeroed
  }
}

void _copyList(
  ArenaReader srcArena,
  SegmentReader srcSeg,
  int srcPtrWordOffset,
  int nestingLimit,
  ArenaBuilder dstArena,
  SegmentBuilder dstSeg,
  int dstPtrWordOffset, {
  bool preserveCapabilityPointers = false,
}) {
  final raw = srcArena.resolveListAt(srcSeg, srcPtrWordOffset, nestingLimit);
  if (raw == null) return;

  switch (raw.elementSize) {
    case ListElementSize.byte:
      // Text or Data: copy elementCount bytes verbatim (includes null
      // terminator for Text, which is counted in elementCount).
      final bytes = Uint8List(raw.elementCount);
      final srcBuf = raw.segment.data.buffer.asUint8List(
        raw.segment.data.offsetInBytes,
      );
      bytes.setRange(0, raw.elementCount, srcBuf, raw.dataByteOffset);
      dstArena.writeDataField(dstSeg, dstPtrWordOffset, bytes);

    case ListElementSize.composite:
      final dstList = dstArena.allocateList(
        ptrSeg: dstSeg,
        ptrWordOffset: dstPtrWordOffset,
        elementSize: ListElementSize.composite,
        elementCount: raw.elementCount,
        structDataWords: raw.structDataWords,
        structPtrWords: raw.structPtrWords,
      );
      final elementWords = raw.structDataWords + raw.structPtrWords;
      for (var i = 0; i < raw.elementCount; i++) {
        final srcElemWordOff =
            raw.dataByteOffset ~/ bytesPerWord + i * elementWords;
        final dstElemWordOff =
            dstList.dataByteOffset ~/ bytesPerWord + i * elementWords;
        // Copy data section.
        if (raw.structDataWords > 0) {
          final byteCount = raw.structDataWords * bytesPerWord;
          final srcBase = srcElemWordOff * bytesPerWord;
          final dstBase = dstElemWordOff * bytesPerWord;
          final srcBuf = raw.segment.data.buffer.asUint8List(
            raw.segment.data.offsetInBytes,
          );
          final dstBuf = dstList.segment.data.buffer.asUint8List();
          dstBuf.setRange(dstBase, dstBase + byteCount, srcBuf, srcBase);
        }
        // Copy pointer section recursively.
        for (var p = 0; p < raw.structPtrWords; p++) {
          _copyPointer(
            srcArena,
            raw.segment,
            srcElemWordOff + raw.structDataWords + p,
            nestingLimit - 1,
            dstArena,
            dstList.segment,
            dstElemWordOff + raw.structDataWords + p,
            preserveCapabilityPointers: preserveCapabilityPointers,
          );
        }
      }

    case ListElementSize.pointer:
      final dstList = dstArena.allocateList(
        ptrSeg: dstSeg,
        ptrWordOffset: dstPtrWordOffset,
        elementSize: ListElementSize.pointer,
        elementCount: raw.elementCount,
      );
      for (var i = 0; i < raw.elementCount; i++) {
        final srcSlot = raw.dataByteOffset ~/ bytesPerWord + i;
        final dstSlot = dstList.dataByteOffset ~/ bytesPerWord + i;
        _copyPointer(
          srcArena,
          raw.segment,
          srcSlot,
          nestingLimit - 1,
          dstArena,
          dstList.segment,
          dstSlot,
          preserveCapabilityPointers: preserveCapabilityPointers,
        );
      }

    default:
      // Primitive lists (void, bit, 2/4/8-byte values): raw byte copy.
      final wordCount = listDataWordCount(raw.elementSize, raw.elementCount);
      if (wordCount == 0) return;
      final dstList = dstArena.allocateList(
        ptrSeg: dstSeg,
        ptrWordOffset: dstPtrWordOffset,
        elementSize: raw.elementSize,
        elementCount: raw.elementCount,
      );
      final byteCount = wordCount * bytesPerWord;
      final srcBuf = raw.segment.data.buffer.asUint8List(
        raw.segment.data.offsetInBytes,
      );
      final dstBuf = dstList.segment.data.buffer.asUint8List();
      dstBuf.setRange(
        dstList.dataByteOffset,
        dstList.dataByteOffset + byteCount,
        srcBuf,
        raw.dataByteOffset,
      );
  }
}
