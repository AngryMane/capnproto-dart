import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';

import '../capability/capability.dart'
    show CapCall, Capability, DispatchResult, NullCapability;
import '../capability/capability_factory.dart';
import 'rpc_exception.dart';
import 'rpc_proto.dart';

/// A Cap'n Proto RPC Level 1 two-party connection.
///
/// Manages the question/answer/export/import tables and drives the message
/// loop over a byte stream pair.
///
/// Usage (client side):
/// ```dart
/// final conn = TwoPartyRpcConnection.client(
///   incoming: socket.incoming,
///   outgoing: socket.outgoing,
/// );
/// final cap = conn.bootstrap(MyClientFactory());
/// ```
///
/// Usage (server side):
/// ```dart
/// final conn = TwoPartyRpcConnection.server(
///   incoming: socket.incoming,
///   outgoing: socket.outgoing,
///   bootstrap: MyServerImpl(),
/// );
/// ```
class TwoPartyRpcConnection implements RpcConnection {
  final StreamSink<Uint8List> _outgoing;
  final bool _isClient;

  // Exports: capabilities we have sent to the peer.
  // Key = export ID; value tracks the remote reference count so we know
  // when the peer has released all references and we can dispose the cap.
  final Map<int, _ExportEntry> _exports = {};
  // Reverse map: capability object → its export ID (for dedup on re-export).
  final Map<Capability, int> _exportIds = {};
  // Bootstrap is registered at export ID 0; subsequent exports start at 1.
  int _nextExportId = 1;

  // Questions: outgoing calls waiting for a Return. Key = question ID.
  final Map<int, Completer<RpcMessage>> _questions = {};
  // Completes when the Call message for a given question has been sent on the
  // wire.  Pipelined calls (promisedAnswer target) await this to guarantee
  // their Call arrives AFTER the parent Call.
  final Map<int, Completer<void>> _questionSent = {};
  int _nextQuestionId = 0;

  // Imports: remote capabilities we hold. Key = import ID (= peer's export ID).
  // We track refcounts to know when to send Release.
  final Map<int, int> _importRefCounts = {};

  // Answers: incoming calls whose Return has been sent.
  // Key = question ID from the peer; value = export IDs included in the Return.
  // Used to release result caps when the peer sends Finish(releaseResultCaps: true).
  final Map<int, List<int>> _answers = {};

  // Promise-pipeline support (server side):
  //   _answerCaps[qid]  — resolved answer for a completed incoming call
  //   _pendingCaps[qid] — future that resolves to the answer when dispatch completes
  // Needed to handle promisedAnswer-targeted calls that arrive while qid is pending.
  // Both store _ResolvedAnswer (result bytes + cap table) so that
  // _handlePipelinedCall can parse the pointer slot to get the correct cap table index.
  final Map<int, _ResolvedAnswer> _answerCaps = {};
  final Map<int, Future<_ResolvedAnswer>> _pendingCaps = {};

  // Set to a non-null error once the connection is closed.
  Object? _closedError;
  final Completer<void> _closedCompleter = Completer<void>();

  // The bootstrap capability reference on this connection (client side).
  // Resolved after the Bootstrap exchange completes.
  _ImportedCapability? _bootstrapCap;
  // Completer for the bootstrap handshake.
  Completer<int>? _bootstrapCompleter;
  // Question ID used for the Bootstrap message (so _handleReturn can
  // distinguish the bootstrap return from regular call returns).
  int? _bootstrapQuestionId;

  TwoPartyRpcConnection._(
    Stream<Uint8List> incoming,
    this._outgoing,
    this._isClient,
  ) {
    _runMessageLoop(incoming);
  }

  /// Creates a client-side connection.
  factory TwoPartyRpcConnection.client({
    required Stream<Uint8List> incoming,
    required StreamSink<Uint8List> outgoing,
  }) =>
      TwoPartyRpcConnection._(incoming, outgoing, true);

  /// Creates a server-side connection.
  factory TwoPartyRpcConnection.server({
    required Stream<Uint8List> incoming,
    required StreamSink<Uint8List> outgoing,
    required Capability bootstrap,
  }) {
    final conn = TwoPartyRpcConnection._(incoming, outgoing, false);
    // Register bootstrap as export 0.
    conn._exports[0] = _ExportEntry(bootstrap);
    conn._exportIds[bootstrap] = 0;
    return conn;
  }

  // ---------------------------------------------------------------------------
  // RpcConnection interface
  // ---------------------------------------------------------------------------

  @override
  T bootstrap<T extends Capability>(CapabilityFactory<T> factory) {
    if (_closedError != null) {
      throw RpcException('connection is closed');
    }
    if (!_isClient) {
      throw RpcException('bootstrap() must be called on the client side');
    }

    // Return the cached capability if the bootstrap exchange already completed
    // or is in progress.  bootstrap() is idempotent per connection.
    if (_bootstrapCap != null) {
      return factory.fromCapability(_bootstrapCap!);
    }

    // Send Bootstrap message.
    final qid = _nextQuestionId++;
    _bootstrapQuestionId = qid;
    _bootstrapCompleter = Completer<int>();
    _questions[qid] = Completer<RpcMessage>();

    _sendRaw(buildBootstrapMessage(qid));

    _bootstrapCap = _ImportedCapability(this, _bootstrapCompleter!.future);
    return factory.fromCapability(_bootstrapCap!);
  }

  @override
  Future<void> close() async {
    if (_closedError != null) return;
    await _tearDown(null);
  }

  // ---------------------------------------------------------------------------
  // Internal: sending a method call through an imported capability
  // ---------------------------------------------------------------------------

  /// Allocates a question ID immediately, then asynchronously builds the
  /// cap-table entries and sends the Call message.  Returns both the question
  /// ID (available synchronously for pipelining) and the result future.
  ///
  /// Use [importIdFuture] for an `importedCap` target; set
  /// [targetPromisedAnswerQid] + [targetPtrIndex] for a `promisedAnswer`
  /// target (wire-level pipelining).
  (int, Future<DispatchResult>) _startCall(
    Future<int>? importIdFuture,
    int interfaceId,
    int methodId,
    Uint8List paramsBytes, {
    List<Capability> paramsCapabilities = const [],
    int? targetPromisedAnswerQid,
    int targetPtrIndex = 0,
  }) {
    if (_closedError != null) throw RpcException('connection is closed');

    final qid = _nextQuestionId++;
    final completer = Completer<RpcMessage>();
    _questions[qid] = completer;
    final sentCompleter = Completer<void>();
    _questionSent[qid] = sentCompleter;

    // Build cap table and send the wire message (may need async for cap resolution).
    _buildAndSendCall(
      qid: qid,
      sentCompleter: sentCompleter,
      importIdFuture: importIdFuture,
      targetPromisedAnswerQid: targetPromisedAnswerQid,
      targetPtrIndex: targetPtrIndex,
      interfaceId: interfaceId,
      methodId: methodId,
      paramsBytes: paramsBytes,
      paramsCapabilities: paramsCapabilities,
    ).catchError((Object e) {
      if (!sentCompleter.isCompleted) sentCompleter.completeError(e);
      if (!completer.isCompleted) completer.completeError(e);
    });

    final resultFuture = _awaitReturn(qid, completer);
    return (qid, resultFuture);
  }

  Future<void> _buildAndSendCall({
    required int qid,
    required Completer<void> sentCompleter,
    required Future<int>? importIdFuture,
    required int? targetPromisedAnswerQid,
    required int targetPtrIndex,
    required int interfaceId,
    required int methodId,
    required Uint8List paramsBytes,
    required List<Capability> paramsCapabilities,
  }) async {
    // For promisedAnswer targets, wait until the parent Call is on the wire so
    // the server always receives the parent before the pipelined call.
    if (targetPromisedAnswerQid != null) {
      final parentSent = _questionSent[targetPromisedAnswerQid];
      if (parentSent != null) await parentSent.future;
    }

    // Categorize each capability param:
    //   - Imported cap from this same peer → receiverHosted
    //   - Everything else → senderHosted export
    final capEntries = <(int, int)>[];
    for (final cap in paramsCapabilities) {
      if (cap is _ImportedCapability && cap._conn == this) {
        final id = await cap._importIdFuture;
        capEntries.add((3, id)); // disc=3: receiverHosted
      } else {
        capEntries.add((1, _getOrCreateExportId(cap))); // disc=1: senderHosted
      }
    }

    if (targetPromisedAnswerQid != null) {
      _sendRaw(buildCallMessage(
        questionId: qid,
        targetPromisedAnswerQid: targetPromisedAnswerQid,
        targetPtrIndex: targetPtrIndex,
        interfaceId: interfaceId,
        methodId: methodId,
        paramsBytes: paramsBytes,
        capTableEntries: capEntries,
      ));
    } else {
      final importId = await importIdFuture!;
      _sendRaw(buildCallMessage(
        questionId: qid,
        targetImportId: importId,
        interfaceId: interfaceId,
        methodId: methodId,
        paramsBytes: paramsBytes,
        capTableEntries: capEntries,
      ));
    }

    // Signal to any pipelined calls waiting on this question.
    if (!sentCompleter.isCompleted) sentCompleter.complete();
    _questionSent.remove(qid);
  }

  Future<DispatchResult> _awaitReturn(
      int qid, Completer<RpcMessage> completer) async {
    final ret = await completer.future;
    _sendRaw(buildFinishMessage(qid, releaseResultCaps: false));

    if (ret.isReturnException) {
      throw RpcException(ret.exceptionReason ?? 'remote exception');
    }

    // Convert capTable entries into ImportedCapabilities.
    final caps = <Capability>[];
    for (final exportId in ret.capTableExportIds) {
      _importRefCounts[exportId] = (_importRefCounts[exportId] ?? 0) + 1;
      caps.add(_ImportedCapability.resolved(this, exportId));
    }

    return DispatchResult(
        bytes: ret.resultsBytes ?? _emptyResultBytes, caps: caps);
  }

  // Pre-built 16-byte message: single segment (1 word), null root pointer.
  // Used as fallback for `-> stream` and void methods that return no content.
  static final _emptyResultBytes =
      Uint8List.fromList([0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);

  Future<void> _releaseImport(int importId) async {
    final count = _importRefCounts.remove(importId);
    if (count == null || count <= 0) return;
    _sendRaw(buildReleaseMessage(importId, count));
  }

  // ---------------------------------------------------------------------------
  // Internal: message loop
  // ---------------------------------------------------------------------------

  void _runMessageLoop(Stream<Uint8List> incoming) {
    // Use raw-bytes stream so the Unimplemented handler can echo the original.
    MessageStream.deserializeStreamRaw(incoming).listen(
      (rawBytes) {
        final msg = parseRpcMessage(rawBytes);
        _handleIncomingMessage(msg, rawBytes);
      },
      onError: (Object err) => _tearDown(err),
      onDone: () => _tearDown(null),
    );
  }

  void _handleIncomingMessage(RpcMessage msg, Uint8List rawBytes) {
    if (_closedError != null) return;

    switch (msg.type) {
      case RpcMessageType.bootstrap:
        _handleBootstrap(msg);
      case RpcMessageType.call:
        _handleCall(msg);
      case RpcMessageType.return_:
        _handleReturn(msg);
      case RpcMessageType.finish:
        _handleFinish(msg);
      case RpcMessageType.release:
        _handleRelease(msg);
      case RpcMessageType.abort:
        _tearDown(RpcException(msg.exceptionReason ?? 'peer aborted'));
      case RpcMessageType.unimplemented:
        // The peer couldn't handle a message we sent; no action needed.
        break;
      case RpcMessageType.other:
        // Unknown message type: echo it back as Unimplemented so the peer
        // knows we didn't handle it, rather than silently dropping it.
        _sendRaw(buildUnimplementedMessage(rawBytes));
    }
  }

  void _handleBootstrap(RpcMessage msg) {
    // Server side: send Return with our bootstrap capability (export 0).
    _sendRaw(buildBootstrapReturnMessage(
      answerId: msg.questionId,
      exportId: 0,
    ));
  }

  void _handleCall(RpcMessage msg) {
    if (msg.targetIsPromisedAnswer) {
      _handlePipelinedCall(msg);
      return;
    }

    final entry = _exports[msg.targetImportId];
    if (entry == null) {
      _sendRaw(buildReturnExceptionMessage(
        answerId: msg.questionId,
        reason: 'unknown export id: ${msg.targetImportId}',
      ));
      return;
    }
    _dispatchToCapability(msg, entry.capability);
  }

  void _handlePipelinedCall(RpcMessage msg) {
    final parentQid = msg.targetPromisedAnswerQid;
    final ptrIndex = msg.targetPtrIndex;

    // Already resolved: dispatch immediately.
    final resolved = _answerCaps[parentQid];
    if (resolved != null) {
      final cap = _capFromPtrIndex(resolved, ptrIndex);
      if (cap == null) {
        _sendRaw(buildReturnExceptionMessage(
          answerId: msg.questionId,
          reason: 'pointer slot $ptrIndex in result struct is not a capability',
        ));
        return;
      }
      _dispatchToCapability(msg, cap);
      return;
    }

    // Still pending: queue behind the parent dispatch.
    final pending = _pendingCaps[parentQid];
    if (pending == null) {
      _sendRaw(buildReturnExceptionMessage(
        answerId: msg.questionId,
        reason: 'unknown promisedAnswer questionId: $parentQid',
      ));
      return;
    }
    pending.then((resolved) {
      final cap = _capFromPtrIndex(resolved, ptrIndex);
      if (cap == null) {
        _sendRaw(buildReturnExceptionMessage(
          answerId: msg.questionId,
          reason: 'pointer slot $ptrIndex in result struct is not a capability',
        ));
        return;
      }
      _dispatchToCapability(msg, cap);
    }).catchError((Object err) {
      _sendRaw(buildReturnExceptionMessage(
        answerId: msg.questionId,
        reason: 'parent call failed: $err',
      ));
    });
  }

  /// Resolves the capability at pointer slot [ptrIndex] of the result struct
  /// encoded in [resolved].
  ///
  /// Returns null if [ptrIndex] is out of range, the pointer at that slot is
  /// not a [CapabilityPointer], or the cap table index is out of range.
  Capability? _capFromPtrIndex(_ResolvedAnswer resolved, int ptrIndex) {
    if (resolved.caps.isEmpty) return null;
    try {
      final root = MessageReader.deserialize(resolved.resultBytes).getRootRaw();
      if (ptrIndex >= root.ptrWords) return null;
      final ptr = WirePointer.decode(
          root.segment.data, root.ptrWordOffset + ptrIndex);
      if (ptr is! CapabilityPointer) return null;
      final capIdx = ptr.capabilityIndex;
      if (capIdx >= resolved.caps.length) return null;
      return resolved.caps[capIdx];
    } catch (_) {
      return null;
    }
  }

  void _dispatchToCapability(RpcMessage msg, Capability cap) {
    final qid = msg.questionId;
    final params = msg.paramsBytes ?? _emptyResultBytes;

    // Resolve capabilities from the incoming capTable.
    // Each entry in the list must correspond 1-to-1 with the capTable index,
    // because capability pointers in the params struct reference these indices.
    // Unsupported or unresolvable descriptors get a NullCapability placeholder
    // so subsequent indices remain correct.
    final paramsCapabilities = <Capability>[];
    for (final (disc, id) in msg.paramsCapTable) {
      switch (disc) {
        case 1: // senderHosted: the remote peer exports this cap
          _importRefCounts[id] = (_importRefCounts[id] ?? 0) + 1;
          paramsCapabilities.add(_ImportedCapability.resolved(this, id));
        case 3: // receiverHosted: we (the receiver) export this cap
          final hosted = _exports[id];
          paramsCapabilities.add(hosted?.capability ?? NullCapability());
        default: // senderPromise, thirdPartyHosted, or unknown — placeholder
          paramsCapabilities.add(NullCapability());
      }
    }

    final dispatchFuture = cap.dispatch(
      msg.interfaceId, msg.methodId, params,
      paramsCapabilities: paramsCapabilities,
    );

    // Track the resolved-answer future so pipelined calls can queue behind it.
    // Attach .ignore() to prevent unhandled-rejection if dispatch throws —
    // pipelined callers handle the error via their own catchError.
    final resolvedFuture = dispatchFuture
        .then((r) => _ResolvedAnswer(r.bytes, r.caps));
    resolvedFuture.ignore();
    _pendingCaps[qid] = resolvedFuture;

    dispatchFuture.then((result) {
      _pendingCaps.remove(qid);
      _answerCaps[qid] = _ResolvedAnswer(result.bytes, result.caps);

      final resultExportIds = <int>[];
      if (result.caps.isEmpty) {
        _sendRaw(buildReturnResultsMessage(
          answerId: qid,
          resultsBytes: result.bytes,
        ));
      } else {
        for (final c in result.caps) {
          resultExportIds.add(_getOrCreateExportId(c));
        }
        _sendRaw(buildReturnResultsWithCapsMessage(
          answerId: qid,
          resultsBytes: result.bytes,
          exportIds: resultExportIds,
        ));
      }
      _answers[qid] = resultExportIds;
    }).catchError((Object err) {
      _pendingCaps.remove(qid);
      _answerCaps.remove(qid);
      _answers[qid] = const [];
      _sendRaw(buildReturnExceptionMessage(
        answerId: qid,
        reason: err is RpcException ? err.message : err.toString(),
      ));
    });
  }

  void _handleFinish(RpcMessage msg) {
    final qid = msg.questionId;
    _answerCaps.remove(qid);
    final resultExportIds = _answers.remove(qid);
    if (resultExportIds == null || !msg.releaseResultCaps) return;
    for (final eid in resultExportIds) {
      _releaseExport(eid);
    }
  }

  void _handleReturn(RpcMessage msg) {
    final completer = _questions.remove(msg.answerId);
    if (completer == null) return;

    // Only drive the bootstrap completer for the bootstrap question itself.
    if (msg.answerId == _bootstrapQuestionId) {
      _bootstrapQuestionId = null;
      if (msg.isReturnResults && msg.capTableExportIds.isNotEmpty) {
        final importId = msg.capTableExportIds.first;
        _importRefCounts[importId] = (_importRefCounts[importId] ?? 0) + 1;
        if (_bootstrapCompleter != null && !_bootstrapCompleter!.isCompleted) {
          _bootstrapCompleter!.complete(importId);
        }
      } else if (msg.isReturnException) {
        if (_bootstrapCompleter != null && !_bootstrapCompleter!.isCompleted) {
          _bootstrapCompleter!.completeError(
              RpcException(msg.exceptionReason ?? 'bootstrap failed'));
        }
      }
    }

    if (!completer.isCompleted) {
      completer.complete(msg);
    }
  }

  void _handleRelease(RpcMessage msg) {
    final entry = _exports[msg.releaseId];
    if (entry == null) return;
    entry.remoteRefCount -= msg.referenceCount;
    if (entry.remoteRefCount <= 0) {
      _exports.remove(msg.releaseId);
      _exportIds.remove(entry.capability);
      entry.capability.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Returns the existing export ID for [cap] (incrementing its remote ref
  /// count), or allocates a new export ID if this is the first export.
  int _getOrCreateExportId(Capability cap) {
    final existing = _exportIds[cap];
    if (existing != null) {
      _exports[existing]!.remoteRefCount++;
      return existing;
    }
    final eid = _nextExportId++;
    _exports[eid] = _ExportEntry(cap);
    _exportIds[cap] = eid;
    return eid;
  }

  /// Decrements the remote ref count for [eid] and disposes the capability
  /// if no remote references remain.
  void _releaseExport(int eid) {
    final entry = _exports[eid];
    if (entry == null) return;
    entry.remoteRefCount--;
    if (entry.remoteRefCount <= 0) {
      _exports.remove(eid);
      _exportIds.remove(entry.capability);
      entry.capability.dispose();
    }
  }

  void _sendRaw(Uint8List bytes) {
    if (_closedError != null) return;
    _outgoing.add(bytes);
  }

  Future<void> _tearDown(Object? error) async {
    if (_closedError != null) return;
    _closedError = error ?? 'closed';

    final err = error != null
        ? RpcException(error.toString())
        : const RpcException('connection closed');

    // Fail all pending questions.
    for (final c in _questions.values) {
      if (!c.isCompleted) {
        c.future.ignore();
        c.completeError(err);
      }
    }
    _questions.clear();
    for (final c in _questionSent.values) {
      if (!c.isCompleted) c.completeError(err);
    }
    _questionSent.clear();

    if (_bootstrapCompleter != null && !_bootstrapCompleter!.isCompleted) {
      _bootstrapCompleter!.future.ignore();
      _bootstrapCompleter!.completeError(err);
    }

    // Dispose all exported capabilities.
    for (final entry in _exports.values) {
      entry.capability.dispose();
    }
    _exports.clear();
    _exportIds.clear();
    _answers.clear();
    _answerCaps.clear();
    _pendingCaps.clear();

    try {
      await _outgoing.close();
    } catch (_) {}

    if (!_closedCompleter.isCompleted) {
      if (error != null) {
        _closedCompleter.completeError(error);
      } else {
        _closedCompleter.complete();
      }
    }
  }

  /// A future that completes when the connection is closed.
  Future<void> get done => _closedCompleter.future;
}

// ---------------------------------------------------------------------------
// _ExportEntry: tracks a locally-exported capability and its remote ref count
// ---------------------------------------------------------------------------

class _ExportEntry {
  final Capability capability;
  // How many times the peer holds a reference to this export.
  // Incremented on every export (or re-export); decremented on Release.
  int remoteRefCount;
  _ExportEntry(this.capability) : remoteRefCount = 1;
}

// ---------------------------------------------------------------------------
// _ImportedCapability: client-side proxy for a remote capability
// ---------------------------------------------------------------------------

class _ImportedCapability extends Capability {
  final TwoPartyRpcConnection _conn;

  // Resolves to the import ID once the bootstrap handshake completes.
  final Future<int> _importIdFuture;

  _ImportedCapability(this._conn, this._importIdFuture) {
    // Suppress unhandled rejection if nobody awaits this future before the
    // connection closes (e.g. bootstrap() called then close() immediately).
    _importIdFuture.ignore();
  }

  _ImportedCapability.resolved(TwoPartyRpcConnection conn, int importId)
      : this(conn, Future.value(importId));

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) {
    final (_, future) = _conn._startCall(
      _importIdFuture,
      interfaceId,
      methodId,
      params,
      paramsCapabilities: paramsCapabilities,
    );
    return future;
  }

  @override
  CapCall beginDispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) {
    final (qid, future) = _conn._startCall(
      _importIdFuture,
      interfaceId,
      methodId,
      params,
      paramsCapabilities: paramsCapabilities,
    );
    return _WireCapCall(future, _conn, qid);
  }

  @override
  Future<void> dispose() async {
    final id = await _importIdFuture.catchError((_) => -1);
    if (id >= 0) await _conn._releaseImport(id);
  }
}

// ---------------------------------------------------------------------------
// _WireCapCall: CapCall backed by a pending question on the wire
// ---------------------------------------------------------------------------

class _WireCapCall implements CapCall {
  @override
  final Future<DispatchResult> result;
  final TwoPartyRpcConnection _conn;
  final int _qid;

  _WireCapCall(this.result, this._conn, this._qid);

  @override
  Capability pipelineResult(int ptrIndex) =>
      _WirePipelinedCapability(_conn, _qid, ptrIndex, result);
}

// ---------------------------------------------------------------------------
// _WirePipelinedCapability: targets a promisedAnswer on the wire, then
// switches to the resolved imported capability once the parent completes.
// ---------------------------------------------------------------------------

class _WirePipelinedCapability extends Capability {
  final TwoPartyRpcConnection _conn;
  final int _parentQid;
  final int _ptrIndex;

  // Set once the parent question resolves; null while still pending.
  // After resolution all new calls go directly to this cap (no pipelining).
  Capability? _resolved;

  _WirePipelinedCapability(
      this._conn, this._parentQid, this._ptrIndex, Future<DispatchResult> parentResult) {
    parentResult.then((result) {
      _resolved = _capFromDispatchResult(result, _ptrIndex) ?? NullCapability();
    }).catchError((_) {
      _resolved = NullCapability();
    });
  }

  /// Reads the capability at pointer slot [ptrIndex] from a [DispatchResult].
  static Capability? _capFromDispatchResult(DispatchResult result, int ptrIndex) {
    if (result.caps.isEmpty) return null;
    try {
      final root = MessageReader.deserialize(result.bytes).getRootRaw();
      if (ptrIndex >= root.ptrWords) return null;
      final ptr =
          WirePointer.decode(root.segment.data, root.ptrWordOffset + ptrIndex);
      if (ptr is! CapabilityPointer) return null;
      final capIdx = ptr.capabilityIndex;
      if (capIdx >= result.caps.length) return null;
      return result.caps[capIdx];
    } catch (_) {
      return null;
    }
  }

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) {
    final r = _resolved;
    if (r != null) {
      return r.dispatch(interfaceId, methodId, params,
          paramsCapabilities: paramsCapabilities);
    }
    final (_, future) = _conn._startCall(
      null,
      interfaceId,
      methodId,
      params,
      paramsCapabilities: paramsCapabilities,
      targetPromisedAnswerQid: _parentQid,
      targetPtrIndex: _ptrIndex,
    );
    return future;
  }

  @override
  CapCall beginDispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) {
    final r = _resolved;
    if (r != null) {
      return r.beginDispatch(interfaceId, methodId, params,
          paramsCapabilities: paramsCapabilities);
    }
    final (qid, future) = _conn._startCall(
      null,
      interfaceId,
      methodId,
      params,
      paramsCapabilities: paramsCapabilities,
      targetPromisedAnswerQid: _parentQid,
      targetPtrIndex: _ptrIndex,
    );
    return _WireCapCall(future, _conn, qid);
  }

  @override
  Future<void> dispose() async {}
}

// ---------------------------------------------------------------------------
// _ResolvedAnswer: result bytes + cap table for a completed server dispatch
// ---------------------------------------------------------------------------

/// Holds the serialized result message and the corresponding cap table for a
/// completed incoming call.  Both are needed by [TwoPartyRpcConnection] to
/// resolve promise-pipelined calls: the result bytes encode which pointer slot
/// maps to which cap table index via a [CapabilityPointer], so the lookup must
/// parse the pointer rather than using the pointer-slot number as a cap table
/// index directly.
class _ResolvedAnswer {
  final Uint8List resultBytes;
  final List<Capability> caps;
  _ResolvedAnswer(this.resultBytes, this.caps);
}

// ---------------------------------------------------------------------------
// RpcConnection abstract interface (declared here to avoid circular imports)
// ---------------------------------------------------------------------------

/// Manages an RPC connection to a remote peer.
abstract class RpcConnection {
  /// Returns a typed capability backed by the peer's bootstrap capability.
  T bootstrap<T extends Capability>(CapabilityFactory<T> factory);

  /// Closes the connection and releases all associated capabilities.
  Future<void> close();
}
