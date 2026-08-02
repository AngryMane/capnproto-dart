import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';

import '../capability/capability.dart' show Capability, DispatchResult;
import 'answer_table.dart';
import 'import_table.dart';

/// The narrow set of connection operations that wire-backed capability
/// implementations (`ImportedCapability`, `WirePipelinedCapability`,
/// `ReceiverAnswerCapability` in wire_capabilities.dart) need from their
/// owning `TwoPartyRpcConnection`.
///
/// Before this interface existed, those classes held a `TwoPartyRpcConnection`
/// directly and reached into its tables (`ImportTable`, `AnswerTable`) and
/// wire-sending internals at will. That made every wire capability
/// unavoidably coupled to the connection's full implementation, so its core
/// dispatch/dispose logic could only be exercised through a real connection.
/// Depending on this interface instead means that logic can be driven by any
/// fake implementation — see wire_capabilities.dart's `debugCreate*`
/// functions and their tests.
///
/// See https://github.com/AngryMane/capnproto-dart/issues/64.
abstract interface class WireCapabilityContext {
  /// Current resolution state of import [importId] — see [ImportState].
  ImportState importStateFor(int importId);

  /// Releases this vat's reference to import [importId], batching the
  /// outgoing wire Release with any other releases in the same microtask.
  Future<void> releaseImport(int importId);

  /// Starts a call against [target] with [params]. Returns the question ID
  /// immediately (for pipelining) alongside the eventual result — see
  /// [StartedCall].
  StartedCall startOutgoingCall({
    required OutgoingCallTarget target,
    required OutgoingParams params,
    required int interfaceId,
    required int methodId,
    List<Capability> paramsCapabilities,
  });

  /// Resolves to the result of a call this vat has already answered, for
  /// `receiverAnswer` targets. Completes with an error if [questionId] names
  /// no answer this vat is tracking.
  Future<ResolvedAnswer> resolveAnswer(int questionId);

  /// Flow-control window size (bytes) for streaming (`-> stream`) calls —
  /// see `FlowController`.
  int get streamWindowSize;
}

/// The target of an outgoing Call — see `TwoPartyRpcConnection.
/// _buildOutgoingCallBytes` for how each variant is encoded on the wire.
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
/// See `Capability.dispatchBuilding`.
final class BuilderParams extends OutgoingParams {
  final void Function(AnyPointerBuilder) build;
  const BuilderParams(this.build);
}

/// The result of [WireCapabilityContext.startOutgoingCall]: [questionId] is
/// available immediately — even though the Call may still be building/
/// sending asynchronously — so a pipelined call can target it right away
/// (see [PromisedAnswerTarget]); [result] resolves once the matching Return
/// arrives.
final class StartedCall {
  final int questionId;
  final Future<DispatchResult> result;
  const StartedCall(this.questionId, this.result);
}
