// Cap'n Proto RPC wire message codec.
//
// Binary offsets are derived from the rpc.capnp specification using the
// standard field layout algorithm (size class ordering: 64-bit, 32-bit,
// 16-bit, bool).
//
// Payload.content is encoded as an AnyPointer struct, fully spec-compliant
// with the Cap'n Proto RPC standard (interoperable with C++/Rust peers).

import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';

// ---------------------------------------------------------------------------
// Message discriminant values
// ---------------------------------------------------------------------------

const int _msgUnimplemented = 0;
const int _msgAbort = 1;
const int _msgCall = 2;
const int _msgReturn = 3;
const int _msgFinish = 4;
const int _msgRelease = 6;
const int _msgBootstrap = 8;

// ---------------------------------------------------------------------------
// Struct layout constants (byte offsets from data section start)
// ---------------------------------------------------------------------------

// Message (dw=1, pw=1)
//   bytes 0-1: discriminant (UInt16)
//   ptr 0: payload (union)
const int _msgDiscOff = 0;

// Bootstrap (dw=1, pw=1)
//   bytes 0-3: questionId (UInt32)
//   ptr 0: deprecatedObjectId (AnyPointer, ignored)
const int _bootstrapQid = 0;

// Call (dw=3, pw=3)
//   Fields allocated in ordinal order to smallest-fitting available slot:
//   bytes  0-3: questionId (UInt32, @0)
//   bytes  4-5: methodId (UInt16, @2)
//   bytes  6-7: sendResultsTo disc (UInt16, @5-@7 union disc)
//   bytes 8-15: interfaceId (UInt64, @1)
//   ptr 0: target (MessageTarget)
//   ptr 1: params (Payload)
//   ptr 2: sendResultsTo.thirdParty (AnyPointer, unused)
const int _callQid = 0;
const int _callMethodId = 4;
const int _callSendResultsDisc = 6;
const int _callIfaceId = 8;

// MessageTarget (dw=1, pw=1)
//   Slot assignment: UInt32 fields come before UInt16 (discriminant) in layout.
//   bytes 0-3: importedCap (UInt32, union data slot, @0)
//   bytes 4-5: discriminant (UInt16, discriminantOffset=2 → byte 4)
//   ptr 0: promisedAnswer (ignored)
// Verified against Rust rpc_capnp.rs: get_data_field::<u32>(0) and get_data_field::<u16>(2).
const int _targetImportCap = 0;
const int _targetDisc = 4;

// Payload (dw=0, pw=2)
//   ptr 0: content (AnyPointer → Data bytes in our convention)
//   ptr 1: capTable (List(CapDescriptor))
// (no data words)

// Return (dw=2, pw=1)
//   Fields allocated in ordinal order to smallest-fitting available slot:
//   bytes 0-3: answerId (UInt32, @0)
//   byte  4 bit 0: releaseParamCaps (Bool, @1)
//   byte  4 bit 1: noFinishNeeded (Bool, @8)
//   bytes 6-7: union discriminant (UInt16, @2-@7 union disc)
//              0=results, 1=exception, 2=canceled, 3=resultsSentElsewhere,
//              4=takeFromOtherQuestion, 5=acceptFromThirdParty
//   bytes 8-11: union data slot (UInt32, for takeFromOtherQuestion @6)
//   ptr 0: union ptr slot (Payload for results / Exception for exception)
const int _returnAnswerId = 0;
const int _returnDisc = 6;

const int _retResults = 0;
const int _retException = 1;

// Exception (dw=1, pw=2)
//   bytes 0-1: type (UInt16, 0=failed)
//   byte 2 bit 0: obsoleteIsCallersFault
//   ptr 0: reason (Text)
//   ptr 1: trace (Text, unused)
const int _excTypeOff = 0;

// Finish (dw=1, pw=0)
//   bytes 0-3: questionId (UInt32)
//   byte  4 bit 0: releaseResultCaps (Bool, default=true)
const int _finishQid = 0;
const int _finishRelease = 32; // bit index = byte 4 * 8 = 32

// Release (dw=1, pw=0)
//   bytes 0-3: id (UInt32)
//   bytes 4-7: referenceCount (UInt32)
const int _releaseId = 0;
const int _releaseRefCnt = 4;

// CapDescriptor (dw=1, pw=1)
//   All-union struct → discriminant first, then union data:
//   bytes 0-1: union discriminant (UInt16)
//   bytes 4-7: union data (senderHosted/senderPromise/receiverHosted as UInt32)
//              0=none, 1=senderHosted, 2=senderPromise, 3=receiverHosted,
//              4=receiverAnswer, 5=thirdPartyHosted
const int _capDescDisc = 0;
const int _capDescData = 4;
const int _capDescSenderHosted = 1;

// ---------------------------------------------------------------------------
// StructReader / StructBuilder subclasses (internal, rpc_proto only)
// ---------------------------------------------------------------------------

class _MsgReader extends StructReader {
  _MsgReader(super.raw);
  int get disc => getUint16Field(_msgDiscOff);
  _BootstrapReader? get asBootstrap => getStructFieldWith(0, _BootstrapReader.new);
  _CallReader? get asCall => getStructFieldWith(0, _CallReader.new);
  _ReturnReader? get asReturn => getStructFieldWith(0, _ReturnReader.new);
  _FinishReader? get asFinish => getStructFieldWith(0, _FinishReader.new);
  _ReleaseReader? get asRelease => getStructFieldWith(0, _ReleaseReader.new);
  _ExceptionReader? get asAbort => getStructFieldWith(0, _ExceptionReader.new);
}

class _MsgBuilder extends StructBuilder {
  _MsgBuilder(super.raw);
  @override StructReader asReader() => throw UnsupportedError('internal');
  void setDisc(int v) => setUint16Field(_msgDiscOff, v);
  _BootstrapBuilder initBootstrap() =>
      initStructFieldWith(0, _BootstrapBuilder.new, 1, 1);
  _CallBuilder initCall() =>
      initStructFieldWith(0, _CallBuilder.new, 3, 3);
  _ReturnBuilder initReturn() =>
      initStructFieldWith(0, _ReturnBuilder.new, 2, 1);
  _FinishBuilder initFinish() =>
      initStructFieldWith(0, _FinishBuilder.new, 1, 0);
  _ReleaseBuilder initRelease() =>
      initStructFieldWith(0, _ReleaseBuilder.new, 1, 0);
  _ExceptionBuilder initAbort() =>
      initStructFieldWith(0, _ExceptionBuilder.new, 1, 2);
}

class _BootstrapReader extends StructReader {
  _BootstrapReader(super.raw);
  int get questionId => getUint32Field(_bootstrapQid);
}

class _BootstrapBuilder extends StructBuilder {
  _BootstrapBuilder(super.raw);
  @override StructReader asReader() => throw UnsupportedError('internal');
  void setQuestionId(int v) => setUint32Field(_bootstrapQid, v);
}

class _CallReader extends StructReader {
  _CallReader(super.raw);
  int get questionId => getUint32Field(_callQid);
  int get interfaceId => getUint64Field(_callIfaceId);
  int get methodId => getUint16Field(_callMethodId);
  _MessageTargetReader? get target =>
      getStructFieldWith(0, _MessageTargetReader.new);
  _PayloadReader? get params => getStructFieldWith(1, _PayloadReader.new);
}

class _CallBuilder extends StructBuilder {
  _CallBuilder(super.raw);
  @override StructReader asReader() => throw UnsupportedError('internal');
  void setQuestionId(int v) => setUint32Field(_callQid, v);
  void setInterfaceId(int v) => setUint64Field(_callIfaceId, v);
  void setMethodId(int v) => setUint16Field(_callMethodId, v);
  void setSendResultsToCaller() => setUint16Field(_callSendResultsDisc, 0);
  _MessageTargetBuilder initTarget() =>
      initStructFieldWith(0, _MessageTargetBuilder.new, 1, 1);
  _PayloadBuilder initParams() =>
      initStructFieldWith(1, _PayloadBuilder.new, 0, 2);
}

class _MessageTargetReader extends StructReader {
  _MessageTargetReader(super.raw);
  int get disc => getUint16Field(_targetDisc);
  int get importedCap => getUint32Field(_targetImportCap);
}

class _MessageTargetBuilder extends StructBuilder {
  _MessageTargetBuilder(super.raw);
  @override StructReader asReader() => throw UnsupportedError('internal');
  void setImportedCap(int v) {
    setUint32Field(_targetImportCap, v);
    setUint16Field(_targetDisc, 0);
  }
}

class _PayloadReader extends StructReader {
  _PayloadReader(super.raw);
  // content (ptr 0): AnyPointer → deep-copied to a standalone message.
  Uint8List? get contentBytes => getAnyPointerAsMessageBytes(0);
  // capTable (ptr 1): composite list of CapDescriptor.
  ListReader<_CapDescReader>? get capTable =>
      getStructListFieldWith(1, _CapDescReader.new);
}

class _PayloadBuilder extends StructBuilder {
  _PayloadBuilder(super.raw);
  @override StructReader asReader() => throw UnsupportedError('internal');
  // content (ptr 0): embed [v] (a serialized Cap'n Proto message) as AnyPointer.
  void setContentBytes(Uint8List v) => setAnyPointerFromMessage(0, v);
  // capTable built via initCapTable
  ListBuilder<_CapDescBuilder> initCapTable(int count) =>
      initStructListFieldWith(1, count, _CapDescBuilder.new, 1, 1);
}

class _CapDescReader extends StructReader {
  _CapDescReader(super.raw);
  int get disc => getUint16Field(_capDescDisc);
  int get senderHostedId => getUint32Field(_capDescData);
}

class _CapDescBuilder extends StructBuilder {
  _CapDescBuilder(super.raw);
  @override StructReader asReader() => throw UnsupportedError('internal');
  void setSenderHosted(int exportId) {
    setUint32Field(_capDescData, exportId);
    setUint16Field(_capDescDisc, _capDescSenderHosted);
  }
}

class _ReturnReader extends StructReader {
  _ReturnReader(super.raw);
  int get answerId => getUint32Field(_returnAnswerId);
  int get disc => getUint16Field(_returnDisc);
  _PayloadReader? get results => getStructFieldWith(0, _PayloadReader.new);
  _ExceptionReader? get exception => getStructFieldWith(0, _ExceptionReader.new);
}

class _ReturnBuilder extends StructBuilder {
  _ReturnBuilder(super.raw);
  @override StructReader asReader() => throw UnsupportedError('internal');
  void setAnswerId(int v) => setUint32Field(_returnAnswerId, v);
  void setDiscResults() => setUint16Field(_returnDisc, _retResults);
  void setDiscException() => setUint16Field(_returnDisc, _retException);
  _PayloadBuilder initResults() =>
      initStructFieldWith(0, _PayloadBuilder.new, 0, 2);
  _ExceptionBuilder initException() =>
      initStructFieldWith(0, _ExceptionBuilder.new, 1, 2);
}

class _FinishReader extends StructReader {
  _FinishReader(super.raw);
  int get questionId => getUint32Field(_finishQid);
  bool get releaseResultCaps => getBoolField(_finishRelease, defaultValue: true);
}

class _FinishBuilder extends StructBuilder {
  _FinishBuilder(super.raw);
  @override StructReader asReader() => throw UnsupportedError('internal');
  void setQuestionId(int v) => setUint32Field(_finishQid, v);
  void setReleaseResultCaps({bool value = true}) =>
      setBoolField(_finishRelease, value, defaultValue: true);
}

class _ReleaseReader extends StructReader {
  _ReleaseReader(super.raw);
  int get id => getUint32Field(_releaseId);
  int get referenceCount => getUint32Field(_releaseRefCnt);
}

class _ReleaseBuilder extends StructBuilder {
  _ReleaseBuilder(super.raw);
  @override StructReader asReader() => throw UnsupportedError('internal');
  void setId(int v) => setUint32Field(_releaseId, v);
  void setReferenceCount(int v) => setUint32Field(_releaseRefCnt, v);
}

class _ExceptionReader extends StructReader {
  _ExceptionReader(super.raw);
  int get type => getUint16Field(_excTypeOff);
  String? get reason => getTextField(0);
}

class _ExceptionBuilder extends StructBuilder {
  _ExceptionBuilder(super.raw);
  @override StructReader asReader() => throw UnsupportedError('internal');
  void setType(int v) => setUint16Field(_excTypeOff, v);
  void setReason(String v) => setTextField(0, v);
}

// ---------------------------------------------------------------------------
// Factories
// ---------------------------------------------------------------------------

final class _MsgFactory extends StructFactory<_MsgReader, _MsgBuilder> {
  @override int get dataWords => 1;
  @override int get ptrWords => 1;
  @override _MsgReader fromRawReader(RawStructReader r) => _MsgReader(r);
  @override _MsgBuilder fromRawBuilder(RawStructBuilder r) => _MsgBuilder(r);
}

final _msgFactory = _MsgFactory();

// ---------------------------------------------------------------------------
// Parsed message type
// ---------------------------------------------------------------------------

/// Discriminant values from a decoded RPC message.
enum RpcMessageType {
  bootstrap,
  call,
  return_,
  finish,
  release,
  abort,
  other,
}

/// Decoded RPC message.
final class RpcMessage {
  final RpcMessageType type;

  // bootstrap / call
  final int questionId;

  // call
  final int interfaceId;
  final int methodId;
  final int targetImportId;
  final Uint8List? paramsBytes;
  // (disc, id) pairs from the Call's capTable, in order.
  // disc: 1=senderHosted, 3=receiverHosted
  final List<(int, int)> paramsCapTable;

  // return
  final int answerId;
  final bool isReturnResults;
  final bool isReturnException;
  final Uint8List? resultsBytes;
  final String? exceptionReason;
  // senderHosted export IDs from the return payload's capTable, in order.
  final List<int> capTableExportIds;

  // finish
  final bool releaseResultCaps;

  // release
  final int releaseId;
  final int referenceCount;

  const RpcMessage._({
    required this.type,
    this.questionId = 0,
    this.interfaceId = 0,
    this.methodId = 0,
    this.targetImportId = 0,
    this.paramsBytes,
    this.paramsCapTable = const [],
    this.answerId = 0,
    this.isReturnResults = false,
    this.isReturnException = false,
    this.resultsBytes,
    this.exceptionReason,
    this.capTableExportIds = const [],
    this.releaseResultCaps = true,
    this.releaseId = 0,
    this.referenceCount = 0,
  });
}

// ---------------------------------------------------------------------------
// Public encode helpers
// ---------------------------------------------------------------------------

/// Serializes a Bootstrap message.
Uint8List buildBootstrapMessage(int questionId) {
  final mb = MessageBuilder();
  final msg = mb.initRoot(_msgFactory);
  msg.setDisc(_msgBootstrap);
  msg.initBootstrap().setQuestionId(questionId);
  return mb.serialize();
}

/// Serializes a Call message. [paramsBytes] is a standalone serialized struct.
/// [paramsCapExportIds] are senderHosted export IDs to include in the capTable.
Uint8List buildCallMessage({
  required int questionId,
  required int targetImportId,
  required int interfaceId,
  required int methodId,
  required Uint8List paramsBytes,
  List<int> paramsCapExportIds = const [],
}) {
  final mb = MessageBuilder();
  final msg = mb.initRoot(_msgFactory);
  msg.setDisc(_msgCall);
  final call = msg.initCall();
  call.setQuestionId(questionId);
  call.setInterfaceId(interfaceId);
  call.setMethodId(methodId);
  call.setSendResultsToCaller();
  call.initTarget().setImportedCap(targetImportId);
  final params = call.initParams();
  params.setContentBytes(paramsBytes);
  if (paramsCapExportIds.isNotEmpty) {
    final capTable = params.initCapTable(paramsCapExportIds.length);
    for (int i = 0; i < paramsCapExportIds.length; i++) {
      capTable[i].setSenderHosted(paramsCapExportIds[i]);
    }
  }
  return mb.serialize();
}

/// Serializes a Return-results message.
Uint8List buildReturnResultsMessage({
  required int answerId,
  required Uint8List resultsBytes,
}) {
  final mb = MessageBuilder();
  final msg = mb.initRoot(_msgFactory);
  msg.setDisc(_msgReturn);
  final ret = msg.initReturn();
  ret.setAnswerId(answerId);
  ret.setDiscResults();
  ret.initResults().setContentBytes(resultsBytes);
  return mb.serialize();
}

/// Serializes a Return-results message that includes capabilities in the
/// capTable. [exportIds] are the server-side export IDs, in capTable order.
Uint8List buildReturnResultsWithCapsMessage({
  required int answerId,
  required Uint8List resultsBytes,
  required List<int> exportIds,
}) {
  final mb = MessageBuilder();
  final msg = mb.initRoot(_msgFactory);
  msg.setDisc(_msgReturn);
  final ret = msg.initReturn();
  ret.setAnswerId(answerId);
  ret.setDiscResults();
  final payload = ret.initResults();
  payload.setContentBytes(resultsBytes);
  final capTable = payload.initCapTable(exportIds.length);
  for (int i = 0; i < exportIds.length; i++) {
    capTable[i].setSenderHosted(exportIds[i]);
  }
  return mb.serialize();
}

/// Serializes a Return-results message for a Bootstrap call.
/// [exportId] is the server's export table ID for the capability.
Uint8List buildBootstrapReturnMessage({
  required int answerId,
  required int exportId,
}) {
  final mb = MessageBuilder();
  final msg = mb.initRoot(_msgFactory);
  msg.setDisc(_msgReturn);
  final ret = msg.initReturn();
  ret.setAnswerId(answerId);
  ret.setDiscResults();
  final payload = ret.initResults();
  // Empty content (no struct); capability is in capTable.
  final capTable = payload.initCapTable(1);
  capTable[0].setSenderHosted(exportId);
  return mb.serialize();
}

/// Serializes a Return-exception message.
Uint8List buildReturnExceptionMessage({
  required int answerId,
  required String reason,
}) {
  final mb = MessageBuilder();
  final msg = mb.initRoot(_msgFactory);
  msg.setDisc(_msgReturn);
  final ret = msg.initReturn();
  ret.setAnswerId(answerId);
  ret.setDiscException();
  final exc = ret.initException();
  exc.setType(0); // failed
  exc.setReason(reason);
  return mb.serialize();
}

/// Serializes a Finish message.
Uint8List buildFinishMessage(int questionId, {bool releaseResultCaps = true}) {
  final mb = MessageBuilder();
  final msg = mb.initRoot(_msgFactory);
  msg.setDisc(_msgFinish);
  final finish = msg.initFinish();
  finish.setQuestionId(questionId);
  finish.setReleaseResultCaps(value: releaseResultCaps);
  return mb.serialize();
}

/// Serializes a Release message.
Uint8List buildReleaseMessage(int id, int referenceCount) {
  final mb = MessageBuilder();
  final msg = mb.initRoot(_msgFactory);
  msg.setDisc(_msgRelease);
  final rel = msg.initRelease();
  rel.setId(id);
  rel.setReferenceCount(referenceCount);
  return mb.serialize();
}

/// Serializes an Abort message.
Uint8List buildAbortMessage(String reason) {
  final mb = MessageBuilder();
  final msg = mb.initRoot(_msgFactory);
  msg.setDisc(_msgAbort);
  final exc = msg.initAbort();
  exc.setType(0);
  exc.setReason(reason);
  return mb.serialize();
}

// ---------------------------------------------------------------------------
// Public decode
// ---------------------------------------------------------------------------

/// Parses a raw RPC message from bytes.
RpcMessage parseRpcMessage(Uint8List bytes) =>
    parseRpcMessageFromReader(MessageReader.deserialize(bytes));

/// Parses an RPC message from an already-deserialized [MessageReader].
RpcMessage parseRpcMessageFromReader(MessageReader mr) {
  final msg = mr.getRoot(_msgFactory);

  switch (msg.disc) {
    case _msgBootstrap:
      return RpcMessage._(
        type: RpcMessageType.bootstrap,
        questionId: msg.asBootstrap?.questionId ?? 0,
      );

    case _msgCall:
      final call = msg.asCall;
      final target = call?.target;
      final params = call?.params;
      final callCapTable = params?.capTable;
      final capTablePairs = <(int, int)>[];
      if (callCapTable != null) {
        for (int i = 0; i < callCapTable.length; i++) {
          final entry = callCapTable[i];
          capTablePairs.add((entry.disc, entry.senderHostedId));
        }
      }
      return RpcMessage._(
        type: RpcMessageType.call,
        questionId: call?.questionId ?? 0,
        interfaceId: call?.interfaceId ?? 0,
        methodId: call?.methodId ?? 0,
        targetImportId: target?.importedCap ?? 0,
        paramsBytes: params?.contentBytes,
        paramsCapTable: capTablePairs,
      );

    case _msgReturn:
      final ret = msg.asReturn;
      final retDisc = ret?.disc ?? 0;
      if (retDisc == _retResults) {
        final payload = ret?.results;
        // Collect all senderHosted export IDs from the capTable, in order.
        final capTable = payload?.capTable;
        final exportIds = <int>[];
        if (capTable != null) {
          for (int i = 0; i < capTable.length; i++) {
            final entry = capTable[i];
            if (entry.disc == _capDescSenderHosted) {
              exportIds.add(entry.senderHostedId);
            }
          }
        }
        return RpcMessage._(
          type: RpcMessageType.return_,
          answerId: ret?.answerId ?? 0,
          isReturnResults: true,
          resultsBytes: payload?.contentBytes,
          capTableExportIds: exportIds,
        );
      } else if (retDisc == _retException) {
        final exc = ret?.exception;
        return RpcMessage._(
          type: RpcMessageType.return_,
          answerId: ret?.answerId ?? 0,
          isReturnException: true,
          exceptionReason: exc?.reason ?? 'unknown error',
        );
      } else {
        return RpcMessage._(
          type: RpcMessageType.return_,
          answerId: ret?.answerId ?? 0,
        );
      }

    case _msgFinish:
      final finish = msg.asFinish;
      return RpcMessage._(
        type: RpcMessageType.finish,
        questionId: finish?.questionId ?? 0,
        releaseResultCaps: finish?.releaseResultCaps ?? true,
      );

    case _msgRelease:
      final rel = msg.asRelease;
      return RpcMessage._(
        type: RpcMessageType.release,
        releaseId: rel?.id ?? 0,
        referenceCount: rel?.referenceCount ?? 0,
      );

    case _msgAbort:
    case _msgUnimplemented:
      return RpcMessage._(
        type: RpcMessageType.abort,
        exceptionReason: msg.asAbort?.reason ?? 'peer aborted',
      );

    default:
      return const RpcMessage._(type: RpcMessageType.other);
  }
}
