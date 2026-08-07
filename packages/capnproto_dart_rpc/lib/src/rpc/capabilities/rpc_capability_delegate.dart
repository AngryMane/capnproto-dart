import 'dart:async';

import '../../capability/capability.dart' show Capability;
import '../calls/answer_table.dart';
import '../calls/outgoing_call.dart';
import 'import_table.dart';

/// The narrow set of connection operations that RPC capability
/// implementations (`_ImportedCapability`, `_PipelinedCapability`,
/// `_ReceiverAnswerCapability` in `rpc_capability.dart`) need from their
/// owning `TwoPartyRpcConnection`.
///
/// Before this interface existed, those classes held a `TwoPartyRpcConnection`
/// directly and reached into its tables (`ImportTable`, `AnswerTable`) and
/// wire-sending internals at will. That made every RPC capability
/// unavoidably coupled to the connection's full implementation, so its core
/// dispatch/dispose logic could only be exercised through a real connection.
/// Depending on this interface instead means that logic can be driven by any
/// fake implementation — see rpc_capability.dart's `debugCreate*`
/// functions and their tests.
///
/// See https://github.com/AngryMane/capnproto-dart/issues/64.
abstract interface class RpcCapabilityDelegate {
  /// Returns the current [ImportState] for [importId], creating an unretained
  /// state if none exists.
  ImportState getOrCreateImportState(int importId);

  /// Releases this vat's reference to import [importId], batching the
  /// outgoing wire Release with any other releases in the same microtask.
  Future<void> releaseImport(int importId);

  /// Starts a call against [target] with [params]. Returns the question ID
  /// immediately (for pipelining) alongside the eventual result — see
  /// [StartedOutgoingCall].
  StartedOutgoingCall startOutgoingCall({
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
  /// see `StreamingCallFlowController`.
  int get streamWindowSize;
}
