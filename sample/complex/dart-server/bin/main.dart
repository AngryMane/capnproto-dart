// Dart-as-server reverse interop test server.
//
// Implements a subset of ComplexTestService to be tested by the Rust client
// (sample/complex/rust-client). Listens on 127.0.0.1:12347.
//
// Run before starting the Rust client:
//   dart run sample/complex/dart-server/bin/main.dart

import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';
import '../../schema/complex.capnp.dart';

// ---------------------------------------------------------------------------
// DartPipelineTargetImpl
// ---------------------------------------------------------------------------

class DartPipelineTargetImpl extends PipelineTargetServer {
  final String name;
  DartPipelineTargetImpl(this.name);

  @override
  Future<DispatchResult> ping(
    PipelineTargetPingParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final payload = params.payload ?? Uint8List(0);
    print('[dart-server] $name.ping(${payload.length} bytes)');
    final mb = MessageBuilder();
    mb.initRoot(pipelineTargetPingResultsFactory).payload = payload;
    return DispatchResult(bytes: mb.serialize());
  }

  @override
  Future<DispatchResult> getChild(
    PipelineTargetGetChildParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final childName = params.name ?? '';
    print('[dart-server] $name.getChild("$childName")');
    final child = DartPipelineTargetImpl('$name/$childName');
    final mb = MessageBuilder();
    mb.initRoot(pipelineTargetGetChildResultsFactory).setChild(0);
    return DispatchResult(bytes: mb.serialize(), caps: [child]);
  }

  @override
  Future<DispatchResult> getRepository(
    PipelineTargetGetRepositoryParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    throw const RpcException('getRepository not implemented on Dart server');
  }

  @override
  Future<void> dispose() async {}
}

// ---------------------------------------------------------------------------
// DartComplexServiceImpl
// ---------------------------------------------------------------------------

_Unimplemented _notImpl(String name) =>
    _Unimplemented('$name not implemented on Dart server');

class _Unimplemented implements Exception {
  final String message;
  const _Unimplemented(this.message);
  @override
  String toString() => message;
}

class DartComplexServiceImpl extends ComplexTestServiceServer {
  final Completer<void> _shutdownCompleter = Completer<void>();
  Future<void> get onShutdown => _shutdownCompleter.future;

  @override
  Future<DispatchResult> echoScalars(
    ComplexTestServiceEchoScalarsParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final v = params.value;
    print('[dart-server] echoScalars(boolean=${v?.boolean})');
    final mb = MessageBuilder();
    final out =
        mb.initRoot(complexTestServiceEchoScalarsResultsFactory).initValue();
    out.boolean = v?.boolean ?? false;
    out.int8Value = v?.int8Value ?? 0;
    out.int16Value = v?.int16Value ?? 0;
    out.int32Value = v?.int32Value ?? 0;
    out.int64Value = v?.int64Value ?? 0;
    out.uint8Value = v?.uint8Value ?? 0;
    out.uint16Value = v?.uint16Value ?? 0;
    out.uint32Value = v?.uint32Value ?? 0;
    out.uint64Value = v?.uint64Value ?? 0;
    out.float32Value = v?.float32Value ?? 0.0;
    out.float64Value = v?.float64Value ?? 0.0;
    out.textValue = v?.textValue;
    out.dataValue = v?.dataValue;
    if (v?.color != null) out.color = v!.color!;
    return DispatchResult(bytes: mb.serialize());
  }

  @override
  Future<DispatchResult> makePipeline(
    ComplexTestServiceMakePipelineParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final depth = params.depth;
    print('[dart-server] makePipeline(depth=$depth)');
    final target = DartPipelineTargetImpl('dart-root(depth=$depth)');
    final mb = MessageBuilder();
    mb.initRoot(complexTestServiceMakePipelineResultsFactory).setTarget(0);
    return DispatchResult(bytes: mb.serialize(), caps: [target]);
  }

  @override
  Future<DispatchResult> callObserver(
    ComplexTestServiceCallObserverParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final observer = params.observer;
    final events = params.events;
    final count = events?.length ?? 0;
    print('[dart-server] callObserver(events=$count)');
    for (int i = 0; i < count; i++) {
      await observer?.onNext((b) => b.sequence = i);
    }
    await observer?.onComplete((_) {});
    final mb = MessageBuilder();
    mb.initRoot(complexTestServiceCallObserverResultsFactory).delivered = count;
    return DispatchResult(bytes: mb.serialize());
  }

  @override
  Future<DispatchResult> exchangeCapabilities(
    ComplexTestServiceExchangeCapabilitiesParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final bundle = params.bundle;
    final primary = bundle?.primary;
    final targets = bundle?.targets;
    print('[dart-server] exchangeCapabilities(targets=${targets?.length ?? 0})');

    final caps = <Capability>[];
    final mb = MessageBuilder();
    final outBundle = mb
        .initRoot(complexTestServiceExchangeCapabilitiesResultsFactory)
        .initBundle();

    if (primary != null) {
      outBundle.setPrimary(caps.length);
      caps.add(primary.capability);
    }

    final tLen = targets?.length ?? 0;
    if (tLen > 0) {
      final tgts = outBundle.initTargets(tLen);
      for (int i = 0; i < tLen; i++) {
        final t = targets![i];
        if (t != null) {
          tgts[i] = caps.length;
          caps.add(t.capability);
        }
      }
    }

    return DispatchResult(bytes: mb.serialize(), caps: caps);
  }

  @override
  Future<void> failIntentionally(
    ComplexTestServiceFailIntentionallyParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final code = params.code;
    final message = params.message ?? '';
    print('[dart-server] failIntentionally(code=$code, message="$message")');
    throw RpcException('[code=$code] $message');
  }

  @override
  Future<void> shutdown(
    ComplexTestServiceShutdownParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    print('[dart-server] shutdown requested');
    if (!_shutdownCompleter.isCompleted) _shutdownCompleter.complete();
  }

  // ── Unimplemented stubs ──────────────────────────────────────────────────

  @override
  Future<DispatchResult> echo(
    ComplexTestServiceEchoParamsReader params,
    List<Capability> paramsCapabilities,
  ) => throw _notImpl('echo');

  @override
  Future<DispatchResult> echoLists(
    ComplexTestServiceEchoListsParamsReader params,
    List<Capability> paramsCapabilities,
  ) => throw _notImpl('echoLists');

  @override
  Future<DispatchResult> echoUnion(
    ComplexTestServiceEchoUnionParamsReader params,
    List<Capability> paramsCapabilities,
  ) => throw _notImpl('echoUnion');

  @override
  Future<DispatchResult> echoAnyPointer(
    ComplexTestServiceEchoAnyPointerParamsReader params,
    List<Capability> paramsCapabilities,
  ) => throw _notImpl('echoAnyPointer');

  @override
  Future<DispatchResult> openUpload(
    ComplexTestServiceOpenUploadParamsReader params,
    List<Capability> paramsCapabilities,
  ) => throw _notImpl('openUpload');

  @override
  Future<DispatchResult> openDownload(
    ComplexTestServiceOpenDownloadParamsReader params,
    List<Capability> paramsCapabilities,
  ) => throw _notImpl('openDownload');

  @override
  Future<DispatchResult> getRepository(
    ComplexTestServiceGetRepositoryParamsReader params,
    List<Capability> paramsCapabilities,
  ) => throw _notImpl('getRepository');

  @override
  Future<DispatchResult> getFactory(
    ComplexTestServiceGetFactoryParamsReader params,
    List<Capability> paramsCapabilities,
  ) => throw _notImpl('getFactory');

  @override
  Future<DispatchResult> useDiamond(
    ComplexTestServiceUseDiamondParamsReader params,
    List<Capability> paramsCapabilities,
  ) => throw _notImpl('useDiamond');

  @override
  Future<DispatchResult> probePipelineTarget(
    ComplexTestServiceProbePipelineTargetParamsReader params,
    List<Capability> paramsCapabilities,
  ) => throw _notImpl('probePipelineTarget');

  @override
  Future<DispatchResult> makePromisedPipeline(
    ComplexTestServiceMakePromisedPipelineParamsReader params,
    List<Capability> paramsCapabilities,
  ) => throw _notImpl('makePromisedPipeline');

  @override
  Future<DispatchResult> echoPipelineTargetLater(
    ComplexTestServiceEchoPipelineTargetLaterParamsReader params,
    List<Capability> paramsCapabilities,
  ) => throw _notImpl('echoPipelineTargetLater');

  @override
  Future<void> dispose() async {}
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

Future<void> main() async {
  const port = 12347;
  final svc = DartComplexServiceImpl();
  final server = await RpcSystem.serve(
    Uri.parse('tcp://127.0.0.1:$port'),
    svc,
  );
  print('[dart-server] listening on 127.0.0.1:$port');

  await svc.onShutdown;
  await server.close();
  print('[dart-server] shutdown complete');
}
