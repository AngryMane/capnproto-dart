import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';

import '../../capability/capability.dart' show DispatchResult;

/// The target of an outgoing Call — see `OutgoingCallCoordinator`'s
/// internal `_buildOutgoingCallBytes` for how each variant is encoded on
/// the wire.
sealed class OutgoingCallTarget {
  const OutgoingCallTarget();
}

/// Targets an already-imported capability by its import id.
///
/// [importId] is `FutureOr<int>`, not a plain `int` or `Future<int>`, so one
/// variant covers both "the id is already known synchronously" (the common
/// case, once an import's state is cached — construct this directly with no
/// `Future.value(...)` wrapping) and "the id must still be awaited" (e.g. a
/// tail-forwarded call's target, whose import future may not have resolved
/// yet). The internal dispatch logic branches on `importId is int` to take
/// the synchronous fast path whenever possible.
final class ImportedCapabilityTarget extends OutgoingCallTarget {
  final FutureOr<int> importId;
  const ImportedCapabilityTarget(this.importId);
}

/// Targets a pending question's result (wire-level promise pipelining).
/// [transformPath] is the full getPointerField hop sequence into the parent
/// answer — not just a single index, so a capability nested more than one
/// struct deep is expressible (see `RpcCapDescriptor`'s path field).
final class PromisedAnswerTarget extends OutgoingCallTarget {
  final int questionId;
  final List<int> transformPath;
  const PromisedAnswerTarget(this.questionId, {this.transformPath = const []});
}

/// The params of an outgoing Call.
sealed class OutgoingParams {
  const OutgoingParams();
}

/// Pre-built, standalone params bytes, copied into the outgoing Call's
/// Payload.content.
final class SerializedParams extends OutgoingParams {
  final Uint8List bytes;
  const SerializedParams(this.bytes);
}

/// Zero-copy params: [build] writes directly into the outgoing Call's
/// Payload.content instead of the caller pre-building a standalone message.
/// See `Capability.dispatchWithParamsBuilder`.
final class BuilderParams extends OutgoingParams {
  final void Function(AnyPointerBuilder) build;
  const BuilderParams(this.build);
}

/// The result of `RpcCapabilityDelegate.startOutgoingCall`: [questionId] is
/// available immediately — even though the Call may still be building/
/// sending asynchronously — so a pipelined call can target it right away
/// (see [PromisedAnswerTarget]); [result] resolves once the matching Return
/// arrives.
final class StartedCall {
  final int questionId;
  final Future<DispatchResult> result;
  const StartedCall(this.questionId, this.result);
}
