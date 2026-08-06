import 'dart:async';

import '../calls/outgoing_call.dart';

/// What a capability object turns out to be, from the wire protocol's own
/// point of view: nothing special (`NotWireCapability`), a proxy for an
/// import this same connection holds (`ImportedWireCapability`), or a
/// not-yet-resolved pipelined result targeting one of this connection's own
/// outgoing questions (`PipelinedWireCapability`). Exists so capTable
/// encoding/decoding logic (`CapabilityProtocol`) can classify a capability
/// without needing to reference the wire-capability implementation types
/// directly (`_ImportedCapability`/`_PipelinedCapability` are private to
/// `rpc_capability.dart`'s library) — `classifyWireCapability` is
/// the only thing that can construct one of these, via its own `identical()`
/// check against the owning connection's `RpcCapabilityDelegate` (not `==`:
/// `RpcCapabilityDelegate`
/// is a public interface a future implementation could override `==` on,
/// so identity is the only check that reliably means "this capability
/// belongs to this connection").
sealed class WireCapabilityKind {
  const WireCapabilityKind();
}

/// Not a wire capability this connection recognizes as its own (a plain
/// local `Capability`, or one belonging to a different connection) —
/// encoded as a fresh `senderHosted` export.
final class NotWireCapability extends WireCapabilityKind {
  const NotWireCapability();
}

/// A proxy for a capability this connection imports from its peer.
/// [importId] is `FutureOr<int>` for the same reason
/// [ImportedCapabilityTarget.importId] is: an `int` when the import's state
/// is already cached, a `Future<int>` when it isn't yet.
final class ImportedWireCapability extends WireCapabilityKind {
  final FutureOr<int> importId;
  const ImportedWireCapability(this.importId);
}

/// A pipelined result targeting [parentQuestionId] (one of this
/// connection's own outgoing questions) at [transformPath] — classified as
/// this regardless of [hasResolved], which only affects how capTable
/// encoding treats it: while `false`, it's still safe to encode as a
/// receiverAnswer reference; once `true`, encoding falls back to exporting
/// it normally instead (the same path a genuine [NotWireCapability] takes,
/// even though classification itself never actually downgrades to
/// [NotWireCapability]).
final class PipelinedWireCapability extends WireCapabilityKind {
  final bool hasResolved;
  final int parentQuestionId;
  final List<int> transformPath;
  const PipelinedWireCapability({
    required this.hasResolved,
    required this.parentQuestionId,
    required this.transformPath,
  });
}
