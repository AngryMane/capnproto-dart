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

  // Exports: capabilities we have sent to the peer. Key = export ID.
  final Map<int, Capability> _exports = {};
  // Bootstrap is registered at export ID 0; subsequent exports start at 1.
  int _nextExportId = 1;

  // Questions: outgoing calls waiting for a Return. Key = question ID.
  final Map<int, Completer<RpcMessage>> _questions = {};
  int _nextQuestionId = 0;

  // Imports: remote capabilities we hold. Key = import ID (= peer's export ID).
  // We track refcounts to know when to send Release.
  final Map<int, int> _importRefCounts = {};

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
    conn._exports[0] = bootstrap;
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

    // Send Bootstrap message.
    final qid = _nextQuestionId++;
    _bootstrapQuestionId = qid;
    _bootstrapCompleter ??= Completer<int>();
    _questions[qid] = Completer<RpcMessage>();

    _sendRaw(buildBootstrapMessage(qid));

    // Create a lazy imported capability that waits for the bootstrap to resolve.
    _bootstrapCap ??= _ImportedCapability(this, _bootstrapCompleter!.future);
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

    // Register any capabilities being sent as params as new exports.
    final capExportIds = <int>[];
    for (final cap in paramsCapabilities) {
      final eid = _nextExportId++;
      _exports[eid] = cap;
      capExportIds.add(eid);
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
      paramsCapExportIds: capExportIds,
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
    // Use MessageStream to handle framing across chunks.
    MessageStream.deserializeStream(incoming).listen(
      (msgReader) => _handleIncomingMessage(msgReader),
      onError: (Object err) => _tearDown(err),
      onDone: () => _tearDown(null),
    );
  }

  void _handleIncomingMessage(MessageReader mr) {
    if (_closedError != null) return;
    final msg = parseRpcMessageFromReader(mr);

    switch (msg.type) {
      case RpcMessageType.bootstrap:
        _handleBootstrap(msg);
      case RpcMessageType.call:
        _handleCall(msg);
      case RpcMessageType.return_:
        _handleReturn(msg);
      case RpcMessageType.finish:
        // For Level 1, Finish is acknowledged but we don't track answers.
        break;
      case RpcMessageType.release:
        _handleRelease(msg);
      case RpcMessageType.abort:
        _tearDown(RpcException(msg.exceptionReason ?? 'peer aborted'));
      case RpcMessageType.other:
        // Ignore unknown messages.
        break;
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
    final cap = _exports[exportId];

    if (cap == null) {
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
    final paramsCapabilities = <Capability>[];
    for (final (disc, id) in msg.paramsCapTable) {
      switch (disc) {
        case 1: // senderHosted: the remote peer exports this cap
          _importRefCounts[id] = (_importRefCounts[id] ?? 0) + 1;
          paramsCapabilities.add(_ImportedCapability.resolved(this, id));
        case 3: // receiverHosted: we (the receiver) export this cap
          final hosted = _exports[id];
          if (hosted != null) paramsCapabilities.add(hosted);
      }
    }

    cap.dispatch(iid, mid, params, paramsCapabilities: paramsCapabilities).then((result) {
      if (result.caps.isEmpty) {
        _sendRaw(buildReturnResultsMessage(
          answerId: qid,
          resultsBytes: result.bytes,
        ));
      } else {
        // Register returned capabilities as new exports.
        final exportIds = <int>[];
        for (final cap in result.caps) {
          final eid = _nextExportId++;
          _exports[eid] = cap;
          exportIds.add(eid);
        }
        _sendRaw(buildReturnResultsWithCapsMessage(
          answerId: qid,
          resultsBytes: result.bytes,
          exportIds: exportIds,
        ));
      }
    }).catchError((Object err) {
      _sendRaw(buildReturnExceptionMessage(
        answerId: qid,
        reason: err is RpcException ? err.message : err.toString(),
      ));
    });
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
    final id = msg.releaseId;
    final refCount = msg.referenceCount;
    final current = _exportRefCount(id) - refCount;
    if (current <= 0) {
      _exports.remove(id);
    }
  }

  int _exportRefCount(int id) => _exports.containsKey(id) ? 1 : 0;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

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
