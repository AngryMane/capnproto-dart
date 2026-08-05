import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';

import '../capability/capability.dart';
import 'embargo_table.dart';
import 'export_table.dart';
import 'import_table.dart';
import 'question_table.dart';
import 'rpc_exception.dart';
import 'rpc_proto.dart';
import 'wire_capability_context.dart';

/// Capability wire protocol: descriptor encode/decode, import/export
/// bookkeeping glue, senderPromise resolution, Release, Resolve, and
/// Disembargo handling. Extracted from `TwoPartyRpcConnection` as a
/// standalone, constructor-injected class — like [OutgoingCallCoordinator],
/// a plain top-level class (not a `part`-file extension) so it can be
/// constructed and tested directly, without a real connection or sockets.
///
/// Five of its methods (`resolveCapTableMaybeSync` and its private helpers)
/// need to classify a [Capability] as wire-hosted or not, and construct
/// wire-backed capabilities — both of which would otherwise require naming
/// `_ImportedCapability`/`_WirePipelinedCapability`, private to
/// `wire_capabilities.dart`'s library. [classifyCapability]/
/// [importedCapabilityFromState]/[receiverAnswerCapability] are wired to
/// `WireCapabilityRuntime`'s own methods of the same shape at the
/// connection's construction site, the same way [OutgoingCallCoordinator]'s
/// own injected closures bridge its narrower needs — see
/// [WireCapabilityKind]'s doc comment.
final class CapabilityProtocol {
  /// Shared with the owning connection — [exportTable]/[questions] are
  /// also held directly by `IncomingCallCoordinator`, so this class does
  /// not own any of these exclusively.
  final ExportTable exportTable;
  final ImportTable importTable;
  final EmbargoTable embargoTable;
  final QuestionTable questions;

  final Duration? disembargoTimeout;
  final void Function(Uint8List bytes) sendBytes;
  final void Function(Capability) disposeIgnoringErrors;

  /// Whether the owning connection has already torn down — the only
  /// closed-check anywhere in this class (`_flushPendingReleases`'s
  /// best-effort "stop trying, don't retry" early exit). Most other methods
  /// here are already unreachable post-teardown one layer up (the owning
  /// connection's own message-loop gate, or its dispatch-result callback's
  /// own `_closedError` check) — [releaseImport] is the one exception,
  /// reachable at any time via `_ImportedCapability.dispose()` regardless
  /// of connection state, but safely: once the owning connection tears
  /// down, `ImportTable.tearDown()` has already dropped the import's
  /// tracking, so `releaseAndBatch` finds nothing to batch and returns
  /// immediately, without ever reaching this check at all. No `tearDown()`
  /// lifecycle method is needed here, unlike [OutgoingCallCoordinator],
  /// since nothing in this class ever gates its *own* entry points the way
  /// `OutgoingCallCoordinator.start` does.
  final bool Function() isClosed;

  /// Tears the whole connection down — called only from [handleRelease],
  /// on a detected protocol violation (a peer releasing a reference count
  /// it doesn't hold).
  final void Function(RpcException error) tearDownConnection;

  /// Classifies [cap] from the wire protocol's own point of view — see
  /// [WireCapabilityKind]'s own doc comment for why this indirection
  /// exists instead of a direct `is _ImportedCapability` check.
  final WireCapabilityKind Function(Capability cap) classifyCapability;

  /// Constructs the capability a `senderHosted`/`senderPromise` descriptor
  /// decodes to, once its [ImportState] is retained.
  final Capability Function(ImportState state) importedCapabilityFromState;

  /// Constructs the capability a `receiverAnswer` descriptor decodes to.
  final Capability Function(int questionId, List<int> path)
  receiverAnswerCapability;

  CapabilityProtocol({
    required this.exportTable,
    required this.importTable,
    required this.embargoTable,
    required this.questions,
    required this.disembargoTimeout,
    required this.sendBytes,
    required this.disposeIgnoringErrors,
    required this.isClosed,
    required this.tearDownConnection,
    required this.classifyCapability,
    required this.importedCapabilityFromState,
    required this.receiverAnswerCapability,
  });

  /// Canonical async capTable resolution — the fallback [resolveCapTableMaybeSync]
  /// delegates to when it can't resolve everything synchronously. When [qid]
  /// is given, records every senderHosted/senderPromise export ID produced
  /// (this call's own params capabilities) against it — see
  /// [_recordParamExportIds].
  ///
  /// [ensureActive] (see `OutgoingCallCoordinator.resolveCapTableMaybeSync`'s
  /// doc comment for the invariant this establishes) is called before the
  /// loop, at the top of every iteration, and immediately after each
  /// `await` inside it — i.e. at every point execution resumes after a
  /// suspension that `tearDown` could have run during, and before the very
  /// next side effect (`exportTable.getOrCreate`, adding to [capEntries])
  /// that resuming would otherwise lead to. Once torn down,
  /// [ExportTable.tearDown]/[QuestionTable.tearDown] have already disposed
  /// and cleared everything this loop could have created *before* that
  /// point — but nothing ever revisits an export created *after* it, since
  /// [qid]'s own `QuestionTable` tracking (where such an export's ID would
  /// otherwise be recorded for rollback) is already gone by then too. This
  /// loop must never reach a new [ExportTable.getOrCreate] call past that
  /// point, since nothing would ever release it.
  Future<List<RpcCapDescriptor>> _resolveCapTableAsync(
    List<Capability> paramsCapabilities, {
    int? qid,
    required void Function() ensureActive,
  }) async {
    ensureActive();
    final capEntries = <RpcCapDescriptor>[];
    // try/finally, not a plain trailing call: a broken import or a rejected
    // importIdFuture partway through this loop (importTable.throwIfBroken/
    // await above) must still record whatever senderHosted/senderPromise exports
    // getOrCreate already created for entries processed *before*
    // that point — otherwise their refcount bump would never be visible to
    // a rollback and would leak. See that method's doc comment for the
    // failure this guards against.
    try {
      for (final rawCap in paramsCapabilities) {
        ensureActive();
        // Generated client stubs commonly hand out a fresh
        // vendCapabilityHandle wrapper every time their underlying
        // capability is accessed (e.g. a `.capability` getter), so a
        // classification check against the wrapper itself never matches
        // even when it's genuinely an import/pipeline from this same
        // connection — unwrap first. See unwrapVendedCapability's doc
        // comment for the concrete failure this avoids (a receiverHosted
        // hand-back gets mis-encoded as a brand-new senderHosted export
        // instead).
        final cap = unwrapVendedCapability(rawCap);
        final kind = classifyCapability(cap);
        if (kind is ImportedWireCapability) {
          final id = await kind.importId;
          ensureActive();
          importTable.throwIfBroken(id);
          capEntries.add(RpcCapDescriptor.receiverHosted(id));
        } else if (kind is PipelinedWireCapability && !kind.hasResolved) {
          // The parent Call (kind.parentQuestionId) must reach the wire
          // before this receiverAnswer descriptor referencing it does —
          // otherwise the peer sees a question id it hasn't been told about
          // yet and rejects it (e.g. capnp-rust's "invalid 'receiver
          // answer'"). Mirrors the promisedAnswer-*target* guard in
          // OutgoingCallCoordinator's own `_buildOutgoingCallBytesAsync`,
          // but for a param capability referencing another question instead
          // of this call's own target.
          final parentSent = questions.sentCompleterFor(kind.parentQuestionId);
          if (parentSent != null) await parentSent.future;
          ensureActive();
          capEntries.add(
            RpcCapDescriptor.receiverAnswer(
              kind.parentQuestionId,
              kind.transformPath,
            ),
          );
        } else {
          ensureActive();
          capEntries.add(
            RpcCapDescriptor.senderHosted(exportTable.getOrCreate(cap)),
          );
        }
      }
    } finally {
      if (qid != null) _recordParamExportIds(qid, capEntries);
    }
    return capEntries;
  }

  /// Records the senderHosted/senderPromise export IDs among [capEntries]
  /// (an outgoing Call's own capTable — this vat's params capabilities)
  /// against [qid], so `OutgoingCallCoordinator`'s internal `_awaitReturn`
  /// can apply `Return.releaseParamCaps` locally once the matching Return
  /// arrives. A call with no such entries (no capability params, or every
  /// one an import/promisedAnswer pass-through) records nothing — nothing
  /// to release either way.
  void _recordParamExportIds(int qid, List<RpcCapDescriptor> capEntries) {
    final ids = <int>[
      for (final d in capEntries)
        if (d.disc == 1 || d.disc == 2) d.id,
    ];
    questions.recordParamExportIds(qid, ids);
  }

  /// Synchronous variant of [_resolveCapTableAsync] for
  /// `OutgoingCallCoordinator`'s sync fast path: resolves synchronously when
  /// every capability is already locally resolvable (true for everything
  /// except an imported capability whose own import ID isn't cached yet),
  /// falling back to [_resolveCapTableAsync] as a whole otherwise. Checking
  /// "is everything resolvable" up front, before touching anything with a
  /// side effect (like `ExportTable.getOrCreate`, which isn't idempotent —
  /// it bumps a refcount on every call), avoids resolving some entries
  /// synchronously and then re-resolving the whole list again through
  /// [_resolveCapTableAsync].
  ///
  /// [ensureActive] is [_resolveCapTableAsync]'s guard, threaded through
  /// here unchanged — this sync branch never suspends (nothing in it
  /// `await`s), so `tearDown` can't land mid-loop the way it can in
  /// [_resolveCapTableAsync]; the one entry call below is there purely so
  /// every route into capTable resolution checks up front, not because this
  /// branch specifically needs a re-check partway through.
  FutureOr<List<RpcCapDescriptor>> resolveCapTableMaybeSync(
    List<Capability> paramsCapabilities, {
    int? qid,
    required void Function() ensureActive,
  }) {
    ensureActive();
    if (paramsCapabilities.isEmpty) return const [];
    final needsAsync = paramsCapabilities.any((rawCap) {
      final cap = unwrapVendedCapability(rawCap);
      final kind = classifyCapability(cap);
      return (kind is ImportedWireCapability && kind.importId is! int) ||
          // A not-yet-sent parent Call means the receiverAnswer branch below
          // would need to await it (see the matching comment in
          // _resolveCapTableAsync) — fall through to the async path instead
          // of racing it.
          (kind is PipelinedWireCapability &&
              !kind.hasResolved &&
              questions.sentCompleterFor(kind.parentQuestionId) != null);
    });
    if (needsAsync) {
      return _resolveCapTableAsync(
        paramsCapabilities,
        qid: qid,
        ensureActive: ensureActive,
      );
    }

    final capEntries = <RpcCapDescriptor>[];
    // See _resolveCapTableAsync's matching comment: try/finally so a broken
    // import discovered partway through still records whatever exports
    // earlier entries in this loop already created.
    try {
      for (final rawCap in paramsCapabilities) {
        // See _resolveCapTableAsync's matching comment on why this unwraps
        // vendCapabilityHandle wrappers before classifying.
        final cap = unwrapVendedCapability(rawCap);
        final kind = classifyCapability(cap);
        if (kind is ImportedWireCapability) {
          // needsAsync above already confirmed this is cached — a
          // still-uncached one would have routed through the async branch.
          final id = kind.importId as int;
          importTable.throwIfBroken(id);
          capEntries.add(RpcCapDescriptor.receiverHosted(id));
        } else if (kind is PipelinedWireCapability && !kind.hasResolved) {
          // Safe to encode without waiting here: needsAsync above already
          // routed any case where the parent Call hasn't been sent yet
          // through the async (awaiting) version instead.
          capEntries.add(
            RpcCapDescriptor.receiverAnswer(
              kind.parentQuestionId,
              kind.transformPath,
            ),
          );
        } else {
          capEntries.add(
            RpcCapDescriptor.senderHosted(exportTable.getOrCreate(cap)),
          );
        }
      }
    } finally {
      if (qid != null) _recordParamExportIds(qid, capEntries);
    }
    return capEntries;
  }

  /// The returned Future always completes successfully (never with an
  /// error), and does so even if the underlying sink fails partway through
  /// the batched flush — see [_flushPendingReleases]'s doc comment for why.
  /// Callers (only `_ImportedCapability.dispose`) can therefore always
  /// `await` it without a `try`/`catch`.
  Future<void> releaseImport(int importId) {
    if (!importTable.releaseAndBatch(importId, disposeIgnoringErrors)) {
      return Future.value();
    }
    return _releaseFlushFuture ??= Future.microtask(_flushPendingReleases);
  }

  // Batches Release sends: releaseImport() decrements the local refcount
  // immediately (via ImportTable.releaseAndBatch) but only records the count
  // there, deferring the actual wire send to a microtask. Several dispose()
  // calls issued without an intervening await (e.g. disposing a whole
  // observer list in one synchronous pass, or
  // `Future.wait([...].map((c) => c.dispose()))`) therefore coalesce into a
  // single Release per import ID with referenceCount > 1, instead of one
  // wire message each. Sequential `await`ed dispose() calls are unaffected —
  // each already resumes after the previous flush has run, so every Release
  // still carries referenceCount == 1 as before.
  Future<void>? _releaseFlushFuture;

  /// Sends one batched Release per import ID accumulated since the last
  /// flush — see [releaseImport]/[ImportTable.takeBatchedReleases].
  ///
  /// Never throws, and never leaves a Release permanently un-sent while the
  /// connection is still usable: [sendBytes] catches any synchronous sink
  /// failure itself and tears the connection down rather than propagating
  /// it here, so this loop can't partially fail in a way callers would need
  /// to react to. Once torn down, this loop stops calling [sendBytes] for
  /// the remaining entries instead of trying (and silently no-op'ing on)
  /// each one — deliberately dropping them unsent, not retrying later: a
  /// torn-down connection means the peer discards every export it held for
  /// this vat anyway (matching this vat's own teardown clearing its side
  /// symmetrically), so there is no longer anything for a Release to
  /// reconcile.
  void _flushPendingReleases() {
    _releaseFlushFuture = null;
    final pending = importTable.takeBatchedReleases();
    if (pending.isEmpty) return;
    for (final entry in pending.entries) {
      if (isClosed()) return;
      sendBytes(buildReleaseMessage(entry.key, entry.value));
    }
  }

  void handleRelease(RpcMessage msg) {
    final remoteRefCount = exportTable.remoteRefCountFor(msg.releaseId);
    if (remoteRefCount == null) return;
    // Releasing zero references is meaningless — a legitimate peer never
    // sends one — and silently accepting it would be a no-op that masks the
    // same kind of peer bug the excessive-count check below guards against.
    if (msg.referenceCount <= 0) {
      tearDownConnection(
        RpcException(
          'protocol violation: Release(id=${msg.releaseId}) referenceCount '
          'must be positive, got ${msg.referenceCount}',
        ),
      );
      return;
    }
    // A peer can only release references it actually holds. Silently
    // clamping an excessive referenceCount to zero would mask a peer/local
    // refcount mismatch — treat it as a protocol violation instead, since a
    // legitimate peer implementation never sends one.
    if (msg.referenceCount > remoteRefCount) {
      tearDownConnection(
        RpcException(
          'protocol violation: Release(id=${msg.releaseId}) referenceCount '
          '${msg.referenceCount} exceeds outstanding remote reference count '
          '$remoteRefCount',
        ),
      );
      return;
    }
    exportTable.releaseRef(msg.releaseId, msg.referenceCount, disposeIgnoringErrors);
  }

  /// Releases one local export reference for every ID in [exportIds]. Used
  /// in two equivalent-effect cases:
  ///
  /// 1. Applying `Return.releaseParamCaps` locally: for each export ID this
  ///    vat put in the answered Call's own capTable (its params
  ///    capabilities, from [_recordParamExportIds]), the same effect an
  ///    explicit `Release(id, 1)` from the peer would have had, without the
  ///    peer needing to actually send one.
  /// 2. Undoing [_recordParamExportIds]/`ExportTable.getOrCreate`'s refcount
  ///    bump for an outgoing Call's params capabilities when the Call itself
  ///    never reached [sendBytes] — e.g. `importIdFuture` rejects, or a
  ///    broken-import check throws, after cap table resolution already ran.
  ///    The peer never received anything in that case, so there is no
  ///    reference for it to `Release`. Callers (the `onError` handler in
  ///    `OutgoingCallCoordinator.startUsing`, shared by every outgoing Call
  ///    attempt) only ever run for a build/send that failed before
  ///    committing anything to the wire — see that method's own doc comment
  ///    for why that invariant holds — so this is safe to call
  ///    unconditionally there, with no separate "was it actually sent" flag
  ///    to track.
  void applyReleaseParamCaps(List<int> exportIds) {
    for (final id in exportIds) {
      exportTable.releaseRef(id, 1, disposeIgnoringErrors);
    }
  }

  void handleResolve(RpcMessage msg) {
    if (msg.isResolveException) {
      // Mirror the success branch below: if we've already fully released
      // this import, a Resolve that arrives late must not resurrect
      // tracking state for it — ImportTable.stateFor would otherwise create
      // a brand new ImportState/broken-import entry that nothing will ever
      // clean up.
      if (!importTable.isTracked(msg.promiseId)) return;
      final state = importTable.stateFor(msg.promiseId);
      final error = RpcException(
        msg.exceptionReason ?? 'promise resolved to exception',
        kind: msg.exceptionKind,
      );
      importTable.markBroken(msg.promiseId, error);
      state.resolveError(error);
      return;
    }

    final descriptor = msg.resolveCapDescriptor;
    if (descriptor == null) return;
    if (!importTable.isTracked(msg.promiseId)) {
      if (descriptor.disc == 1 || descriptor.disc == 2) {
        sendBytes(buildReleaseMessage(descriptor.id, 1));
      }
      return;
    }

    final state = importTable.stateFor(msg.promiseId);
    final replacement = capabilityFromDescriptor(descriptor);
    if (state.receivedCall && _isLocalCapability(replacement)) {
      final completer = Completer<void>();
      final embargoId = embargoTable.register(
        completer,
        timeout: disembargoTimeout,
      );
      sendBytes(
        buildDisembargoMessage(
          targetImportId: msg.promiseId,
          contextDisc: 0,
          contextId: embargoId,
        ),
      );
      state.resolveCapability(
        DeferredCapability(completer.future.then((_) => replacement)),
      );
    } else {
      state.resolveCapability(replacement);
    }
  }

  void handleDisembargo(RpcMessage msg) {
    if (msg.disembargoContextDisc == 1) {
      embargoTable.resolve(msg.disembargoContextId);
      return;
    }

    // For Level 1 loopback disembargo, senderLoopback is answered with a
    // receiverLoopback carrying the same target and embargo id. Higher-level
    // accept/provide contexts are Level 3/4 and are intentionally ignored.
    if (msg.disembargoContextDisc != 0) return;
    sendBytes(
      buildDisembargoMessage(
        targetImportId: msg.disembargoTargetImportId,
        targetPromisedAnswerQid:
            msg.disembargoTargetIsPromisedAnswer
                ? msg.disembargoTargetPromisedAnswerQid
                : null,
        targetTransformPath: msg.disembargoTargetTransformPath,
        contextDisc: 1,
        contextId: msg.disembargoContextId,
      ),
    );
  }

  /// [cap] may be a [vendCapabilityHandle] handle — e.g. an application's
  /// dispatch handler read a capability out of another call's result via
  /// [requireCapabilityFromResult] and is now returning that same handle as
  /// part of its own result (or relaying it into a call on a different
  /// connection's — see [ExportTable]'s `_ExportEntry.ownedReference`) —
  /// so it's unwrapped to its real identity before being used as
  /// [ExportTable.getOrCreate]'s dedup key.
  ///
  /// `DispatchResult.caps` transfers ownership of [cap] to this connection
  /// — [ExportTable.getOrCreate] establishes (or reuses) this connection's
  /// own owning reference to [identity], so if [cap] was itself a distinct
  /// vended handle, it's now redundant with that owning reference and is
  /// disposed here: otherwise its share of [identity]'s refcount (see
  /// [vendCapabilityHandle]) would never be released, leaking the
  /// underlying capability even after every other reference to it —
  /// including this connection's own owning one — is properly disposed.
  RpcCapDescriptor returnCapDescriptor(Capability cap) {
    final identity = unwrapVendedCapability(cap);
    final RpcCapDescriptor descriptor;
    if (identity is DeferredCapability) {
      final promiseId = exportTable.getOrCreate(identity);
      _scheduleSenderPromiseResolve(promiseId, identity);
      descriptor = RpcCapDescriptor.senderPromise(promiseId);
    } else {
      descriptor = RpcCapDescriptor.senderHosted(
        exportTable.getOrCreate(identity),
      );
    }
    if (!identical(cap, identity)) {
      disposeIgnoringErrors(cap);
    }
    return descriptor;
  }

  void _scheduleSenderPromiseResolve(int promiseId, DeferredCapability promise) {
    if (!exportTable.markScheduled(promiseId)) return;

    promise.resolution
        .then(
          (resolved) async {
            exportTable.clearScheduled(promiseId);
            if (!_isStillExportedPromise(promiseId, promise)) return;

            final RpcCapDescriptor descriptor;
            try {
              descriptor = await _resolveDescriptorForCapability(resolved);
            } catch (error) {
              if (!_isStillExportedPromise(promiseId, promise)) return;
              sendBytes(
                buildResolveExceptionMessage(
                  promiseId: promiseId,
                  reason:
                      error is RpcException ? error.message : error.toString(),
                ),
              );
              return;
            }
            if (!_isStillExportedPromise(promiseId, promise)) {
              if (descriptor.disc == 1 || descriptor.disc == 2) {
                exportTable.release(descriptor.id, disposeIgnoringErrors);
              }
              return;
            }

            sendBytes(
              buildResolveCapMessage(
                promiseId: promiseId,
                capDisc: descriptor.disc,
                capId: descriptor.id,
              ),
            );
          },
          onError: (Object error) {
            exportTable.clearScheduled(promiseId);
            if (!_isStillExportedPromise(promiseId, promise)) return;
            sendBytes(
              buildResolveExceptionMessage(
                promiseId: promiseId,
                reason: error is RpcException ? error.message : error.toString(),
              ),
            );
          },
        )
        .ignore();
  }

  bool _isStillExportedPromise(int promiseId, DeferredCapability promise) =>
      exportTable.isCurrentIdentity(promiseId, promise);

  /// See [returnCapDescriptor]'s doc comment — [cap] is unwrapped to its
  /// real identity first, and a redundant vended [cap] is disposed at the
  /// end, for the same ownership-transfer reason (this resolves a promise
  /// a [DeferredCapability] returned from `DispatchResult.caps` settled
  /// to, which transfers ownership exactly like an already-settled result
  /// capability does). The `receiverHosted` branch establishes no owning
  /// reference of its own locally (it's just handing the peer back its own
  /// capability) — [cap] disposal is what releases its share of
  /// [identity]'s refcount there, since nothing else will.
  Future<RpcCapDescriptor> _resolveDescriptorForCapability(Capability cap) async {
    final identity = unwrapVendedCapability(cap);
    final RpcCapDescriptor descriptor;
    final kind = classifyCapability(identity);
    if (kind is ImportedWireCapability) {
      final id = await kind.importId;
      importTable.throwIfBroken(id);
      descriptor = RpcCapDescriptor.receiverHosted(id);
    } else if (identity is DeferredCapability) {
      final nestedPromiseId = exportTable.getOrCreate(identity);
      _scheduleSenderPromiseResolve(nestedPromiseId, identity);
      descriptor = RpcCapDescriptor.senderPromise(nestedPromiseId);
    } else {
      descriptor = RpcCapDescriptor.senderHosted(
        exportTable.getOrCreate(identity),
      );
    }
    if (!identical(cap, identity)) {
      disposeIgnoringErrors(cap);
    }
    return descriptor;
  }

  Capability capabilityFromDescriptor(RpcCapDescriptor descriptor) {
    switch (descriptor.disc) {
      case 0: // none
        return NullCapability();
      case 1: // senderHosted
        final state = importTable.retain(descriptor.id);
        return importedCapabilityFromState(state);
      case 2: // senderPromise
        final state = importTable.retain(descriptor.id, isPromise: true);
        return importedCapabilityFromState(state);
      case 3: // receiverHosted: we (the receiver) export this cap
        // A fresh vendCapabilityHandle, not the export's own identity/
        // ownedReference directly: this capability is handed to
        // application code (a call's paramsCapabilities, a Return's result
        // caps, or a resolved promise replacement), which routinely
        // disposes params/result capabilities it's done with — that must
        // decrement the shared refcount (see vendCapabilityHandle) rather
        // than tearing down the export's identity directly, which would
        // invalidate the export's own still-live ownedReference (and any
        // other outstanding reference to the same identity) out from under
        // it. Code that needs to recognize the concrete capability this
        // wraps (e.g. an `is`/identity check against a locally-known
        // object) must unwrap it first — see unwrapVendedCapability's doc
        // comment; this is the same discipline every other decode path
        // (requireCapabilityFromResult et al.) already requires.
        final identity = exportTable.identityFor(descriptor.id);
        if (identity == null) {
          // A well-behaved peer, honoring the protocol's causal ordering
          // guarantees, never references an export id we haven't actually
          // exported to it — this is a genuine protocol violation (a buggy
          // or malicious peer), not a legitimate race. Silently mapping it
          // to NullCapability would conflate it with a schema-level `none`
          // descriptor (disc 0), losing that distinction and changing the
          // meaning of an otherwise valid call.
          throw RpcException(
            'unknown receiverHosted export id: ${descriptor.id}',
          );
        }
        return vendCapabilityHandle(identity);
      case 4: // receiverAnswer: capability in one of our outstanding answers
        return receiverAnswerCapability(
          descriptor.questionId,
          // An empty/noop-only transform is normalized to a single hop at
          // pointer slot 0 (legitimate only for a Bootstrap answer's
          // capability, which has no wrapping struct to traverse).
          descriptor.path.isEmpty ? const [0] : descriptor.path,
        );
      default:
        throw RpcException(
          'unsupported capability descriptor (disc=${descriptor.disc})',
          kind: ErrorKind.unimplemented,
        );
    }
  }

  int? importIdFromDescriptor(RpcCapDescriptor descriptor) {
    if (descriptor.disc != 1 && descriptor.disc != 2) return null;
    importTable.retain(descriptor.id, isPromise: descriptor.disc == 2);
    return descriptor.id;
  }

  bool _isLocalCapability(Capability cap) {
    return classifyCapability(cap) is NotWireCapability;
  }
}
