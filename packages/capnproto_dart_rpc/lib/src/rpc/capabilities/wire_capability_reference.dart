/// Semantic representation of Cap'n Proto RPC's `CapDescriptor`.
///
/// Unlike `rpc_message_codec.dart`'s `_CapDescriptorReader`/
/// `_CapDescriptorBuilder` — the schema-facing codec representation, which
/// mirrors `CapDescriptor`'s wire layout directly (a discriminant plus
/// whichever raw fields that variant happens to use) — each protocol variant
/// here is its own Dart type and exposes only the fields meaningful for that
/// variant, so a state like "senderHosted with a questionId" can't be
/// constructed at all. `rpc_message_codec.dart`'s `_readCapabilityReference`/
/// `_writeCapabilityReference` are the only code that ever converts between
/// the two representations; everywhere else in the RPC implementation reads
/// and constructs [WireCapabilityReference] values instead of inspecting a
/// raw discriminant.
sealed class WireCapabilityReference {
  const WireCapabilityReference();
}

/// No capability — the wire `CapDescriptor.none` variant.
final class NoCapabilityReference extends WireCapabilityReference {
  const NoCapabilityReference();
}

/// A capability the sender exports to the receiver by [exportId] — the wire
/// `CapDescriptor.senderHosted` variant.
final class SenderHostedCapabilityReference extends WireCapabilityReference {
  final int exportId;

  const SenderHostedCapabilityReference(this.exportId);
}

/// A capability the sender exports to the receiver by [exportId], whose
/// value is still an unresolved promise — the wire `CapDescriptor.
/// senderPromise` variant.
final class SenderPromiseCapabilityReference extends WireCapabilityReference {
  final int exportId;

  const SenderPromiseCapabilityReference(this.exportId);
}

/// A capability the receiver already hosts, referenced back to it by
/// [importId] (from the receiver's own perspective, its own export id) —
/// the wire `CapDescriptor.receiverHosted` variant.
final class ReceiverHostedCapabilityReference
    extends WireCapabilityReference {
  final int importId;

  const ReceiverHostedCapabilityReference(this.importId);
}

/// A capability living in one of the receiver's own outstanding answers,
/// named by [questionId] and the `getPointerField` hop sequence
/// [transformPath] into that answer's result — the wire `CapDescriptor.
/// receiverAnswer` variant. An empty [transformPath] is only legitimate for
/// a Bootstrap answer's capability, which has no wrapping struct to
/// traverse; every other caller normalizes an empty transform itself before
/// constructing this.
final class ReceiverAnswerCapabilityReference
    extends WireCapabilityReference {
  final int questionId;
  final List<int> transformPath;

  const ReceiverAnswerCapabilityReference(this.questionId, this.transformPath);
}

/// A `CapDescriptor` variant this implementation doesn't decode further
/// (either a future/Level 2+ variant such as `thirdPartyHosted`, or one this
/// vat simply hasn't implemented yet). [discriminant] is preserved exactly
/// as decoded so a caller can report it in a precise "unsupported capability
/// reference" error instead of losing the distinction between "unknown" and
/// "none". Never constructed for an outgoing message — only ever produced
/// by decoding, and rejected by [WireCapabilityReference] encoders.
final class UnsupportedCapabilityReference extends WireCapabilityReference {
  final int discriminant;

  const UnsupportedCapabilityReference(this.discriminant);
}
