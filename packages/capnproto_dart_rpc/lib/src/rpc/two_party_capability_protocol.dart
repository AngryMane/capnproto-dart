/// Capability wire protocol: descriptor encode/decode, import/export
/// bookkeeping glue, senderPromise resolution, Release, Resolve, and
/// Disembargo handling. Moved out of [TwoPartyRpcConnection] verbatim --
/// see that class's own doc comment.

part of 'two_party_connection.dart';

extension _CapabilityProtocol on TwoPartyRpcConnection {
  /// Classifies [cap] from the wire protocol's own point of view — see
  /// [WireCapabilityKind]'s own doc comment. Centralizes every
  /// `is _ImportedCapability`/`is _WirePipelinedCapability`/
  /// `_ownedByThisConnection` check in this file into one place, in
  /// preparation for this logic moving behind an injected closure once
  /// capTable resolution/decoding is extracted into a standalone class that
  /// can no longer name these connection-private types directly.
  WireCapabilityKind _classifyCapability(Capability cap) {
    if (cap is _ImportedCapability && _ownedByThisConnection(cap._conn)) {
      return ImportedWireCapability(
        cap._cachedState?.importId ?? cap._importIdFuture,
      );
    }
    if (cap is _WirePipelinedCapability && _ownedByThisConnection(cap._conn)) {
      return PipelinedWireCapability(
        hasResolved: cap._hasResolved,
        parentQuestionId: cap._parentQid,
        transformPath: cap._transformPath,
      );
    }
    return const NotWireCapability();
  }

  Capability _importedCapabilityFromState(ImportState state) =>
      _ImportedCapability.fromState(_wireContext, state);

  Capability _receiverAnswerCapability(int questionId, List<int> path) =>
      _ReceiverAnswerCapability(_wireContext, questionId, path);

  /// Canonical async capTable resolution — the fallback [_resolveCapTableMaybeSync]
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
  /// next side effect (`_exportTable.getOrCreate`, adding to [capEntries])
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
    // _importIdFuture partway through this loop (_importTable.throwIfBroken/
    // await above) must still record whatever senderHosted/senderPromise exports
    // _getOrCreateExportId already created for entries processed *before*
    // that point — otherwise their refcount bump would never be visible to
    // _rollbackQuestionParamExports and would leak. See that method's doc
    // comment for the failure this guards against.
    try {
      for (final rawCap in paramsCapabilities) {
        ensureActive();
        // Generated client stubs commonly hand out a fresh
        // vendCapabilityHandle wrapper every time their underlying
        // capability is accessed (e.g. a `.capability` getter), so an `is
        // _ImportedCapability`/`is _WirePipelinedCapability` check against
        // the wrapper itself never matches even when it's genuinely an
        // import/pipeline from this same connection — unwrap first. See
        // unwrapVendedCapability's doc comment for the concrete failure
        // this avoids (a receiverHosted hand-back gets mis-encoded as a
        // brand-new senderHosted export instead).
        final cap = unwrapVendedCapability(rawCap);
        final kind = _classifyCapability(cap);
        if (kind is ImportedWireCapability) {
          final id = await kind.importId;
          ensureActive();
          _importTable.throwIfBroken(id);
          capEntries.add(RpcCapDescriptor.receiverHosted(id));
        } else if (kind is PipelinedWireCapability && !kind.hasResolved) {
          // The parent Call (kind.parentQuestionId) must reach the wire
          // before this receiverAnswer descriptor referencing it does —
          // otherwise the peer sees a question id it hasn't been told about
          // yet and rejects it (e.g. capnp-rust's "invalid 'receiver
          // answer'"). Mirrors the promisedAnswer-*target* guard in
          // _buildOutgoingCallBytesAsync, but for a param capability
          // referencing another question instead of this call's own target.
          final parentSent = _questionTable.sentCompleterFor(
            kind.parentQuestionId,
          );
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
            RpcCapDescriptor.senderHosted(_exportTable.getOrCreate(cap)),
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
    _questionTable.recordParamExportIds(qid, ids);
  }

  /// Synchronous variant of [_resolveCapTableAsync] for
  /// `OutgoingCallCoordinator`'s sync fast path: resolves synchronously when
  /// every capability is already locally resolvable (true for everything
  /// except an [_ImportedCapability] whose own import ID isn't cached yet),
  /// falling back to [_resolveCapTableAsync] as a whole otherwise. Checking
  /// "is everything resolvable" up front, before touching anything with a
  /// side effect (like [_getOrCreateExportId], which isn't idempotent — it
  /// bumps a refcount on every call), avoids resolving some entries
  /// synchronously and then re-resolving the whole list again through
  /// [_resolveCapTableAsync].
  ///
  /// [ensureActive] is [_resolveCapTableAsync]'s guard, threaded through
  /// here unchanged — this sync branch never suspends (nothing in it
  /// `await`s), so `tearDown` can't land mid-loop the way it can in
  /// [_resolveCapTableAsync]; the one entry call below is there purely so
  /// every route into capTable resolution checks up front, not because this
  /// branch specifically needs a re-check partway through.
  FutureOr<List<RpcCapDescriptor>> _resolveCapTableMaybeSync(
    List<Capability> paramsCapabilities, {
    int? qid,
    required void Function() ensureActive,
  }) {
    ensureActive();
    if (paramsCapabilities.isEmpty) return const [];
    final needsAsync = paramsCapabilities.any((rawCap) {
      final cap = unwrapVendedCapability(rawCap);
      final kind = _classifyCapability(cap);
      return (kind is ImportedWireCapability && kind.importId is! int) ||
          // A not-yet-sent parent Call means the receiverAnswer branch below
          // would need to await it (see _resolveCapTable's matching
          // comment) — fall through to the async path instead of racing it.
          (kind is PipelinedWireCapability &&
              !kind.hasResolved &&
              _questionTable.sentCompleterFor(kind.parentQuestionId) != null);
    });
    if (needsAsync) {
      return _resolveCapTableAsync(
        paramsCapabilities,
        qid: qid,
        ensureActive: ensureActive,
      );
    }

    final capEntries = <RpcCapDescriptor>[];
    // See _resolveCapTable's matching comment: try/finally so a broken
    // import discovered partway through still records whatever exports
    // earlier entries in this loop already created.
    try {
      for (final rawCap in paramsCapabilities) {
        // See _resolveCapTable's matching comment on why this unwraps
        // vendCapabilityHandle wrappers before checking the concrete type.
        final cap = unwrapVendedCapability(rawCap);
        final kind = _classifyCapability(cap);
        if (kind is ImportedWireCapability) {
          // needsAsync above already confirmed this is cached — a
          // still-uncached one would have routed through the async branch.
          final id = kind.importId as int;
          _importTable.throwIfBroken(id);
          capEntries.add(RpcCapDescriptor.receiverHosted(id));
        } else if (kind is PipelinedWireCapability && !kind.hasResolved) {
          // Safe to encode without waiting here: needsAsync above already
          // routed any case where the parent Call hasn't been sent yet
          // through _resolveCapTable's async (awaiting) version instead.
          capEntries.add(
            RpcCapDescriptor.receiverAnswer(
              kind.parentQuestionId,
              kind.transformPath,
            ),
          );
        } else {
          capEntries.add(
            RpcCapDescriptor.senderHosted(_exportTable.getOrCreate(cap)),
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
  /// Callers (only [_ImportedCapability.dispose]) can therefore always
  /// `await` it without a `try`/`catch`.
  Future<void> _releaseImport(int importId) {
    if (!_importTable.releaseAndBatch(importId, _disposeIgnoringErrors)) {
      return Future.value();
    }
    return _releaseFlushFuture ??= Future.microtask(_flushPendingReleases);
  }

  /// Sends one batched Release per import ID accumulated since the last
  /// flush — see [_releaseImport]/[ImportTable.takeBatchedReleases].
  ///
  /// Never throws, and never leaves a Release permanently un-sent while the
  /// connection is still usable: [_sendRaw] catches any synchronous sink
  /// failure itself and tears the connection down (setting [_closedError])
  /// rather than propagating it here, so this loop can't partially fail in
  /// a way callers would need to react to. Once torn down, this loop stops
  /// calling [_sendRaw] for the remaining entries instead of trying (and
  /// silently no-op'ing on) each one — deliberately dropping them
  /// unsent, not retrying later: a torn-down connection means the peer
  /// discards every export it held for this vat anyway (matching this
  /// vat's own [_tearDown] clearing its side symmetrically), so there is no
  /// longer anything for a Release to reconcile.
  void _flushPendingReleases() {
    _releaseFlushFuture = null;
    final pending = _importTable.takeBatchedReleases();
    if (pending.isEmpty) return;
    for (final entry in pending.entries) {
      if (_closedError != null) return;
      _sendRaw(buildReleaseMessage(entry.key, entry.value));
    }
  }

  void _handleRelease(RpcMessage msg) {
    final remoteRefCount = _exportTable.remoteRefCountFor(msg.releaseId);
    if (remoteRefCount == null) return;
    // Releasing zero references is meaningless — a legitimate peer never
    // sends one — and silently accepting it would be a no-op that masks the
    // same kind of peer bug the excessive-count check below guards against.
    if (msg.referenceCount <= 0) {
      _tearDown(
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
      _tearDown(
        RpcException(
          'protocol violation: Release(id=${msg.releaseId}) referenceCount '
          '${msg.referenceCount} exceeds outstanding remote reference count '
          '$remoteRefCount',
        ),
      );
      return;
    }
    _exportTable.releaseRef(
      msg.releaseId,
      msg.referenceCount,
      _disposeIgnoringErrors,
    );
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
  ///    never reached [_sendRaw] — e.g. `importIdFuture` rejects, or a
  ///    broken-import check throws, after cap table resolution already ran.
  ///    The peer never received anything in that case, so there is no
  ///    reference for it to `Release`. Callers (the `onError` handler in
  ///    `OutgoingCallCoordinator.startUsing`, shared by every outgoing Call
  ///    attempt) only ever run for a build/send that failed before
  ///    committing anything to the wire — see that method's own doc comment
  ///    for why that invariant holds — so this is safe to call
  ///    unconditionally there, with no separate "was it actually sent" flag
  ///    to track.
  void _applyReleaseParamCaps(List<int> exportIds) {
    for (final id in exportIds) {
      _exportTable.releaseRef(id, 1, _disposeIgnoringErrors);
    }
  }

  void _handleResolve(RpcMessage msg) {
    if (msg.isResolveException) {
      // Mirror the success branch below: if we've already fully released
      // this import, a Resolve that arrives late must not resurrect
      // tracking state for it — ImportTable.stateFor would otherwise create
      // a brand new ImportState/broken-import entry that nothing will ever
      // clean up.
      if (!_importTable.isTracked(msg.promiseId)) return;
      final state = _importTable.stateFor(msg.promiseId);
      final error = RpcException(
        msg.exceptionReason ?? 'promise resolved to exception',
        kind: msg.exceptionKind,
      );
      _importTable.markBroken(msg.promiseId, error);
      state.resolveError(error);
      return;
    }

    final descriptor = msg.resolveCapDescriptor;
    if (descriptor == null) return;
    if (!_importTable.isTracked(msg.promiseId)) {
      if (descriptor.disc == 1 || descriptor.disc == 2) {
        _sendRaw(buildReleaseMessage(descriptor.id, 1));
      }
      return;
    }

    final state = _importTable.stateFor(msg.promiseId);
    final replacement = _capabilityFromDescriptor(descriptor);
    if (state.receivedCall && _isLocalCapability(replacement)) {
      final completer = Completer<void>();
      final embargoId = _embargoTable.register(
        completer,
        timeout: _disembargoTimeout,
      );
      _sendRaw(
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

  void _handleDisembargo(RpcMessage msg) {
    if (msg.disembargoContextDisc == 1) {
      _embargoTable.resolve(msg.disembargoContextId);
      return;
    }

    // For Level 1 loopback disembargo, senderLoopback is answered with a
    // receiverLoopback carrying the same target and embargo id. Higher-level
    // accept/provide contexts are Level 3/4 and are intentionally ignored.
    if (msg.disembargoContextDisc != 0) return;
    _sendRaw(
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
  RpcCapDescriptor _returnCapDescriptor(Capability cap) {
    final identity = unwrapVendedCapability(cap);
    final RpcCapDescriptor descriptor;
    if (identity is DeferredCapability) {
      final promiseId = _exportTable.getOrCreate(identity);
      _scheduleSenderPromiseResolve(promiseId, identity);
      descriptor = RpcCapDescriptor.senderPromise(promiseId);
    } else {
      descriptor = RpcCapDescriptor.senderHosted(
        _exportTable.getOrCreate(identity),
      );
    }
    if (!identical(cap, identity)) {
      _disposeIgnoringErrors(cap);
    }
    return descriptor;
  }

  void _scheduleSenderPromiseResolve(
    int promiseId,
    DeferredCapability promise,
  ) {
    if (!_exportTable.markScheduled(promiseId)) return;

    promise.resolution
        .then(
          (resolved) async {
            _exportTable.clearScheduled(promiseId);
            if (!_isStillExportedPromise(promiseId, promise)) return;

            final RpcCapDescriptor descriptor;
            try {
              descriptor = await _resolveDescriptorForCapability(resolved);
            } catch (error) {
              if (!_isStillExportedPromise(promiseId, promise)) return;
              _sendRaw(
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
                _exportTable.release(descriptor.id, _disposeIgnoringErrors);
              }
              return;
            }

            _sendRaw(
              buildResolveCapMessage(
                promiseId: promiseId,
                capDisc: descriptor.disc,
                capId: descriptor.id,
              ),
            );
          },
          onError: (Object error) {
            _exportTable.clearScheduled(promiseId);
            if (!_isStillExportedPromise(promiseId, promise)) return;
            _sendRaw(
              buildResolveExceptionMessage(
                promiseId: promiseId,
                reason:
                    error is RpcException ? error.message : error.toString(),
              ),
            );
          },
        )
        .ignore();
  }

  bool _isStillExportedPromise(int promiseId, DeferredCapability promise) =>
      _exportTable.isCurrentIdentity(promiseId, promise);

  /// See [_returnCapDescriptor]'s doc comment — [cap] is unwrapped to its
  /// real identity first, and a redundant vended [cap] is disposed at the
  /// end, for the same ownership-transfer reason (this resolves a promise
  /// a [DeferredCapability] returned from `DispatchResult.caps` settled
  /// to, which transfers ownership exactly like an already-settled result
  /// capability does). The `receiverHosted` branch establishes no owning
  /// reference of its own locally (it's just handing the peer back its own
  /// capability) — [cap] disposal is what releases its share of
  /// [identity]'s refcount there, since nothing else will.
  Future<RpcCapDescriptor> _resolveDescriptorForCapability(
    Capability cap,
  ) async {
    final identity = unwrapVendedCapability(cap);
    final RpcCapDescriptor descriptor;
    final kind = _classifyCapability(identity);
    if (kind is ImportedWireCapability) {
      final id = await kind.importId;
      _importTable.throwIfBroken(id);
      descriptor = RpcCapDescriptor.receiverHosted(id);
    } else if (identity is DeferredCapability) {
      final nestedPromiseId = _exportTable.getOrCreate(identity);
      _scheduleSenderPromiseResolve(nestedPromiseId, identity);
      descriptor = RpcCapDescriptor.senderPromise(nestedPromiseId);
    } else {
      descriptor = RpcCapDescriptor.senderHosted(
        _exportTable.getOrCreate(identity),
      );
    }
    if (!identical(cap, identity)) {
      _disposeIgnoringErrors(cap);
    }
    return descriptor;
  }

  Capability _capabilityFromDescriptor(RpcCapDescriptor descriptor) {
    switch (descriptor.disc) {
      case 0: // none
        return NullCapability();
      case 1: // senderHosted
        final state = _importTable.retain(descriptor.id);
        return _importedCapabilityFromState(state);
      case 2: // senderPromise
        final state = _importTable.retain(descriptor.id, isPromise: true);
        return _importedCapabilityFromState(state);
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
        final identity = _exportTable.identityFor(descriptor.id);
        if (identity == null) {
          // A well-behaved peer, honoring the protocol's causal ordering
          // guarantees, never references an export id we haven't actually
          // exported to it — this is a genuine protocol violation (a buggy
          // or malicious peer), not a legitimate race. Silently mapping it
          // to NullCapability would conflate it with a schema-level `none`
          // descriptor (disc 0), losing that distinction and, per
          // _dispatchToCapability's own doc comment on this same class of
          // decision, changing the meaning of an otherwise valid call.
          throw RpcException(
            'unknown receiverHosted export id: ${descriptor.id}',
          );
        }
        return vendCapabilityHandle(identity);
      case 4: // receiverAnswer: capability in one of our outstanding answers
        return _receiverAnswerCapability(
          descriptor.questionId,
          // See _handlePipelinedCall's matching comment: an empty/noop-only
          // transform is normalized to a single hop at pointer slot 0
          // (legitimate only for a Bootstrap answer's capability, which has
          // no wrapping struct to traverse).
          descriptor.path.isEmpty ? const [0] : descriptor.path,
        );
      default:
        throw RpcException(
          'unsupported capability descriptor (disc=${descriptor.disc})',
          kind: ErrorKind.unimplemented,
        );
    }
  }

  int? _importIdFromDescriptor(RpcCapDescriptor descriptor) {
    if (descriptor.disc != 1 && descriptor.disc != 2) return null;
    _importTable.retain(descriptor.id, isPromise: descriptor.disc == 2);
    return descriptor.id;
  }

  bool _isLocalCapability(Capability cap) {
    return _classifyCapability(cap) is NotWireCapability;
  }
}
