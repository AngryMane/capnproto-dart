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

  /// Starts a call against [importIdFuture] (an imported cap target) or,
  /// when null, against [targetPromisedAnswerQid]/[targetTransformPath] (a
  /// promisedAnswer target). Returns the question ID immediately (for
  /// pipelining) alongside the eventual result.
  (int, Future<DispatchResult>) startCall(
    Future<int>? importIdFuture,
    int interfaceId,
    int methodId,
    Uint8List paramsBytes, {
    List<Capability> paramsCapabilities,
    int? targetPromisedAnswerQid,
    List<int> targetTransformPath,
  });

  /// Zero-copy counterpart of [startCall]: [buildParams] writes params
  /// directly into the outgoing Call instead of the caller pre-building
  /// standalone bytes.
  (int, Future<DispatchResult>) startCallBuilding(
    Future<int>? importIdFuture,
    int interfaceId,
    int methodId,
    void Function(AnyPointerBuilder) buildParams, {
    List<Capability> paramsCapabilities,
    int? targetPromisedAnswerQid,
    List<int> targetTransformPath,
  });

  /// Fast path for [startCall] when [importId] is already known
  /// synchronously (no `Future` to await).
  (int, Future<DispatchResult>) startResolvedImportCall(
    int importId,
    int interfaceId,
    int methodId,
    void Function(AnyPointerBuilder) buildParams,
    List<Capability> paramsCapabilities,
  );

  /// Resolves to the result of a call this vat has already answered, for
  /// `receiverAnswer` targets. Completes with an error if [questionId] names
  /// no answer this vat is tracking.
  Future<ResolvedAnswer> resolveAnswer(int questionId);

  /// Flow-control window size (bytes) for streaming (`-> stream`) calls —
  /// see `FlowController`.
  int get streamWindowSize;
}
