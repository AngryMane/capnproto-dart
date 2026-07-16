import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';

import '../capability/capability.dart';
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
  int _nextQuestionId = 0;

  // Imports: remote capabilities we hold. Key = import ID (= peer's export ID).
  // We track refcounts to know when to send Release.
  final Map<int, int> _importRefCounts = {};

  // Answers: incoming calls whose Return has been sent.
  // Key = question ID from the peer; value = export IDs included in the Return.
  // Used to release result caps when the peer sends Finish(releaseResultCaps: true).
  final Map<int, List<int>> _answers = {};

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

  Future<DispatchResult> _sendCall(
    Future<int> importIdFuture,
    int interfaceId,
    int methodId,
    Uint8List paramsBytes, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    if (_closedError != null) throw RpcException('connection is closed');

    // Categorize each capability param:
    //   - If it is a capability we imported from this same peer, send it back
    //     as receiverHosted so the peer sees its own export without a proxy hop.
    //   - Otherwise export it from our side as senderHosted.
    final capEntries = <(int, int)>[];
    for (final cap in paramsCapabilities) {
      if (cap is _ImportedCapability && cap._conn == this) {
        final importId = await cap._importIdFuture;
        capEntries.add((3, importId)); // disc=3: receiverHosted
      } else {
        capEntries.add((1, _getOrCreateExportId(cap))); // disc=1: senderHosted
      }
    }

    final importId = await importIdFuture;
    final qid = _nextQuestionId++;
    final completer = Completer<RpcMessage>();
    _questions[qid] = completer;

    _sendRaw(buildCallMessage(
      questionId: qid,
      targetImportId: importId,
      interfaceId: interfaceId,
      methodId: methodId,
      paramsBytes: paramsBytes,
      capTableEntries: capEntries,
    ));

    final ret = await completer.future;
    // Send Finish once we have the return.
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
    final exportId = msg.targetImportId;
    final entry = _exports[exportId];

    if (entry == null) {
      _sendRaw(buildReturnExceptionMessage(
        answerId: msg.questionId,
        reason: 'unknown export id: $exportId',
      ));
      return;
    }

    final qid = msg.questionId;
    final iid = msg.interfaceId;
    final mid = msg.methodId;
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

    entry.capability
        .dispatch(iid, mid, params, paramsCapabilities: paramsCapabilities)
        .then((result) {
      final resultExportIds = <int>[];
      if (result.caps.isEmpty) {
        _sendRaw(buildReturnResultsMessage(
          answerId: qid,
          resultsBytes: result.bytes,
        ));
      } else {
        // Register returned capabilities as exports; reuse IDs for dedup.
        for (final cap in result.caps) {
          resultExportIds.add(_getOrCreateExportId(cap));
        }
        _sendRaw(buildReturnResultsWithCapsMessage(
          answerId: qid,
          resultsBytes: result.bytes,
          exportIds: resultExportIds,
        ));
      }
      // Track which export IDs were returned so Finish can release them.
      _answers[qid] = resultExportIds;
    }).catchError((Object err) {
      _answers[qid] = const [];
      _sendRaw(buildReturnExceptionMessage(
        answerId: qid,
        reason: err is RpcException ? err.message : err.toString(),
      ));
    });
  }

  void _handleFinish(RpcMessage msg) {
    final resultExportIds = _answers.remove(msg.questionId);
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
  }) =>
      _conn._sendCall(_importIdFuture, interfaceId, methodId, params,
          paramsCapabilities: paramsCapabilities);

  @override
  Future<void> dispose() async {
    final id = await _importIdFuture.catchError((_) => -1);
    if (id >= 0) await _conn._releaseImport(id);
  }
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
