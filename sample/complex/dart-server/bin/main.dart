// Dart-as-server reverse interop test server.
//
// Implements ComplexTestService to be tested by the Rust client
// (sample/complex/rust-client). Listens on 127.0.0.1:12347.
//
// Run before starting the Rust client:
//   dart run sample/complex/dart-server/bin/main.dart

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';
import '../../schema/complex.capnp.dart';

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

Uint8List? _anyPointerBytes(AnyPointerReader? reader) =>
    reader?.asMessageBytes(preserveCapabilityPointers: true);

bool _bytesEqual(Uint8List? a, Uint8List? b) {
  if (a == null || b == null) return a == null && b == null;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// RepositoryImpl — generic AnyPointer key/value store.
//
// Cap'n Proto generics are wire-erased to AnyPointer, so a single
// implementation serves both Repository(Text, Person) (ComplexTestService's
// getRepository) and Repository(AnyPointer, AnyPointer)
// (CapabilityFactory.newRepository).
// ---------------------------------------------------------------------------

class RepositoryImpl extends RepositoryServer {
  final Map<String, (Uint8List key, Uint8List value, int revision)> _store =
      {};
  int _revision = 0;

  String _token(Uint8List? bytes) => base64Encode(bytes ?? Uint8List(0));

  @override
  Future<DispatchResult> get(
    RepositoryGetParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final entry = _store[_token(_anyPointerBytes(params.key))];
    final mb = MessageBuilder();
    final out = mb.initRoot(repositoryGetResultsFactory);
    if (entry != null) {
      out.revision = entry.$3;
      final result = out.initResult();
      result.setUint16Field(0, 1);
      result.setAnyPointerFromMessage(0, entry.$2);
    } else {
      out.revision = 0;
      out.initResult().selectNone();
    }
    return DispatchResult(bytes: mb.serialize());
  }

  @override
  Future<DispatchResult> put(
    RepositoryPutParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final keyBytes = _anyPointerBytes(params.key) ?? Uint8List(0);
    final valueBytes = _anyPointerBytes(params.value) ?? Uint8List(0);
    final token = _token(keyBytes);
    final previous = _store[token];
    _revision += 1;
    _store[token] = (keyBytes, valueBytes, _revision);

    final mb = MessageBuilder();
    final out = mb.initRoot(repositoryPutResultsFactory);
    out.newRevision = _revision;
    final prev = out.initPrevious();
    if (previous != null) {
      prev.setUint16Field(0, 1);
      prev.setAnyPointerFromMessage(0, previous.$2);
    } else {
      prev.selectNone();
    }
    return DispatchResult(bytes: mb.serialize());
  }

  @override
  Future<DispatchResult> remove(
    RepositoryRemoveParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final removed = _store.remove(_token(_anyPointerBytes(params.key)));
    _revision += 1;
    final mb = MessageBuilder();
    final out = mb.initRoot(repositoryRemoveResultsFactory);
    out.newRevision = _revision;
    final removedB = out.initRemoved();
    if (removed != null) {
      removedB.setUint16Field(0, 1);
      removedB.setAnyPointerFromMessage(0, removed.$2);
    } else {
      removedB.selectNone();
    }
    return DispatchResult(bytes: mb.serialize());
  }

  @override
  Future<DispatchResult> list(
    RepositoryListParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final entries = _store.values.toList();
    final mb = MessageBuilder();
    final out = mb.initRoot(repositoryListResultsFactory);
    final list = out.initEntries(entries.length);
    for (var i = 0; i < entries.length; i++) {
      list[i].setAnyPointerFromMessage(0, entries[i].$1);
      list[i].setAnyPointerFromMessage(1, entries[i].$2);
    }
    return DispatchResult(bytes: mb.serialize());
  }

  @override
  Future<DispatchResult> openCursor(
    RepositoryOpenCursorParamsReader params,
    List<Capability> paramsCapabilities,
  ) => throw const RpcException('openCursor not implemented on Dart server');

  @override
  Future<DispatchResult> watch(
    RepositoryWatchParamsReader params,
    List<Capability> paramsCapabilities,
  ) => throw const RpcException('watch not implemented on Dart server');

  @override
  Future<void> dispose() async {}
}

// ---------------------------------------------------------------------------
// GenericCellImpl — ReadWrite(AnyPointer) backing CapabilityFactory.newCell /
// newEmptyCell.
// ---------------------------------------------------------------------------

class GenericCellImpl extends ReadWriteServer {
  Uint8List? _value;
  int _revision = 1;

  GenericCellImpl(this._value);

  @override
  Future<DispatchResult> read(
    ReadableReadParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final mb = MessageBuilder();
    final out = mb.initRoot(readableReadResultsFactory);
    out.revision = _revision;
    out.setValueMessage(_value);
    return DispatchResult(bytes: mb.serialize());
  }

  @override
  Future<DispatchResult> write(
    WritableWriteParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    _value = _anyPointerBytes(params.value);
    _revision += 1;
    final mb = MessageBuilder();
    mb.initRoot(writableWriteResultsFactory).newRevision = _revision;
    return DispatchResult(bytes: mb.serialize());
  }

  @override
  Future<DispatchResult> compareAndSwap(
    ReadWriteCompareAndSwapParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final expectedBytes = _anyPointerBytes(params.expected);
    final replacementBytes = _anyPointerBytes(params.replacement);
    final swapped = _bytesEqual(_value, expectedBytes);

    final mb = MessageBuilder();
    final out = mb.initRoot(readWriteCompareAndSwapResultsFactory);
    out.swapped = swapped;
    out.setActualMessage(_value);
    if (swapped) {
      _value = replacementBytes;
      _revision += 1;
    }
    out.revision = _revision;
    return DispatchResult(bytes: mb.serialize());
  }

  @override
  Future<void> dispose() async {}
}

// ---------------------------------------------------------------------------
// ByteSinkImpl / ByteSourceImpl
// ---------------------------------------------------------------------------

class ByteSinkImpl extends ByteSinkServer {
  final List<int> _chunks = [];

  @override
  Future<DispatchResult> write(
    ByteSinkWriteParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final chunk = params.chunk;
    if (chunk != null) _chunks.addAll(chunk);
    return DispatchResult.empty;
  }

  @override
  Future<DispatchResult> finish(
    ByteSinkFinishParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    var checksum = 0;
    for (final b in _chunks) {
      checksum ^= b;
    }
    final mb = MessageBuilder();
    final out = mb.initRoot(byteSinkFinishResultsFactory);
    out.byteCount = _chunks.length;
    out.checksum = Uint8List.fromList([checksum]);
    return DispatchResult(bytes: mb.serialize());
  }

  @override
  Future<DispatchResult> abort(
    ByteSinkAbortParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    _chunks.clear();
    return DispatchResult.empty;
  }

  @override
  Future<void> dispose() async {}
}

class ByteSourceImpl extends ByteSourceServer {
  final Uint8List _data;
  ByteSourceImpl(this._data);

  @override
  Future<DispatchResult> pumpTo(
    ByteSourcePumpToParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final sink = params.sink;
    if (sink == null) {
      throw const RpcException('pumpTo: sink is null');
    }
    final chunkSize = params.chunkSize == 0 ? 65536 : params.chunkSize;
    var offset = 0;
    while (offset < _data.length) {
      final end = (offset + chunkSize < _data.length)
          ? offset + chunkSize
          : _data.length;
      await sink.write((b) => b.chunk = _data.sublist(offset, end));
      offset = end;
    }
    final finishResult = await sink.finish((_) {});
    final mb = MessageBuilder();
    mb.initRoot(byteSourcePumpToResultsFactory).byteCount =
        finishResult.byteCount;
    return DispatchResult(bytes: mb.serialize());
  }

  @override
  Future<void> dispose() async {}
}

// ---------------------------------------------------------------------------
// CapabilityFactoryImpl
// ---------------------------------------------------------------------------

class CapabilityFactoryImpl extends CapabilityFactoryServer {
  @override
  Future<DispatchResult> newCell(
    CapabilityFactoryNewCellParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final cell = GenericCellImpl(_anyPointerBytes(params.initialValue));
    final mb = MessageBuilder();
    mb.initRoot(capabilityFactoryNewCellResultsFactory).setCell(0);
    return DispatchResult(bytes: mb.serialize(), caps: [cell]);
  }

  @override
  Future<DispatchResult> newEmptyCell(
    CapabilityFactoryNewEmptyCellParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final cell = GenericCellImpl(null);
    final mb = MessageBuilder();
    mb.initRoot(capabilityFactoryNewEmptyCellResultsFactory).setCell(0);
    return DispatchResult(bytes: mb.serialize(), caps: [cell]);
  }

  @override
  Future<DispatchResult> newRepository(
    CapabilityFactoryNewRepositoryParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final repo = RepositoryImpl();
    final mb = MessageBuilder();
    mb.initRoot(capabilityFactoryNewRepositoryResultsFactory).setRepository(0);
    return DispatchResult(bytes: mb.serialize(), caps: [repo]);
  }

  @override
  Future<DispatchResult> echoCapability(
    CapabilityFactoryEchoCapabilityParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final mb = MessageBuilder();
    final out = mb.initRoot(capabilityFactoryEchoCapabilityResultsFactory);
    out.sameCapability = params.capability;
    return DispatchResult(bytes: mb.serialize(), caps: paramsCapabilities);
  }

  @override
  Future<DispatchResult> getUntyped(
    CapabilityFactoryGetUntypedParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final name = params.name ?? '';
    print('[dart-server] factory.getUntyped($name)');
    final mb = MessageBuilder();
    final out = mb.initRoot(capabilityFactoryGetUntypedResultsFactory);
    final scalars = out.initValue().initStruct(allScalarsFactory);
    if (name == 'scalars' || name == 'AllScalars') {
      scalars.int32Value = 20260717;
      scalars.uint16Value = 4242;
      scalars.textValue = 'untyped from Dart';
    } else {
      scalars.int32Value = -1;
      scalars.textValue = 'unknown untyped payload';
    }
    return DispatchResult(bytes: mb.serialize());
  }

  @override
  Future<void> dispose() async {}
}

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
    print('[dart-server] $name.getRepository()');
    final repo = RepositoryImpl();
    final mb = MessageBuilder();
    mb.initRoot(pipelineTargetGetRepositoryResultsFactory).setRepository(0);
    return DispatchResult(bytes: mb.serialize(), caps: [repo]);
  }

  @override
  Future<void> dispose() async {}
}

// ---------------------------------------------------------------------------
// DartComplexServiceImpl
// ---------------------------------------------------------------------------

class DartComplexServiceImpl extends ComplexTestServiceServer {
  final Completer<void> _shutdownCompleter = Completer<void>();
  Future<void> get onShutdown => _shutdownCompleter.future;

  @override
  Future<DispatchResult> echo(
    ComplexTestServiceEchoParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    print('[dart-server] echo()');
    final mb = MessageBuilder();
    final resp = mb.initRoot(complexTestServiceEchoResultsFactory).initResponse();
    resp.accepted = true;
    resp.status = Status.running;
    resp.message = 'echo from Dart';
    return DispatchResult(bytes: mb.serialize());
  }

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
  Future<DispatchResult> echoLists(
    ComplexTestServiceEchoListsParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    print('[dart-server] echoLists()');
    final mb = MessageBuilder();
    final out = mb.initRoot(complexTestServiceEchoListsResultsFactory);
    out.setAnyPointerField(0, params.getAnyPointerField(0));
    return DispatchResult(bytes: mb.serialize());
  }

  @override
  Future<DispatchResult> echoUnion(
    ComplexTestServiceEchoUnionParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    print('[dart-server] echoUnion()');
    final mb = MessageBuilder();
    final out = mb.initRoot(complexTestServiceEchoUnionResultsFactory);
    out.setAnyPointerField(0, params.getAnyPointerField(0));
    return DispatchResult(bytes: mb.serialize());
  }

  @override
  Future<DispatchResult> echoAnyPointer(
    ComplexTestServiceEchoAnyPointerParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    print('[dart-server] echoAnyPointer()');
    final mb = MessageBuilder();
    final out = mb.initRoot(complexTestServiceEchoAnyPointerResultsFactory);
    out.value = params.value;
    return DispatchResult(bytes: mb.serialize(), caps: paramsCapabilities);
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
  Future<DispatchResult> getRepository(
    ComplexTestServiceGetRepositoryParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    print('[dart-server] getRepository()');
    final repo = RepositoryImpl();
    final mb = MessageBuilder();
    mb.initRoot(complexTestServiceGetRepositoryResultsFactory).setRepository(0);
    return DispatchResult(bytes: mb.serialize(), caps: [repo]);
  }

  @override
  Future<DispatchResult> getFactory(
    ComplexTestServiceGetFactoryParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    print('[dart-server] getFactory()');
    final factory = CapabilityFactoryImpl();
    final mb = MessageBuilder();
    mb.initRoot(complexTestServiceGetFactoryResultsFactory).setFactory(0);
    return DispatchResult(bytes: mb.serialize(), caps: [factory]);
  }

  @override
  Future<DispatchResult> useDiamond(
    ComplexTestServiceUseDiamondParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final diamond = params.diamond;
    final value = params.value;
    print('[dart-server] useDiamond(value=$value)');
    if (diamond == null) {
      throw const RpcException('useDiamond: diamond is null');
    }
    final result = await diamond.both((b) {
      b.leftValue = value;
      b.rightValue = value;
    });
    final mb = MessageBuilder();
    mb.initRoot(complexTestServiceUseDiamondResultsFactory).result =
        result.sum;
    return DispatchResult(bytes: mb.serialize());
  }

  @override
  Future<DispatchResult> probePipelineTarget(
    ComplexTestServiceProbePipelineTargetParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final target = params.target;
    final payload = params.payload ?? Uint8List(0);
    print('[dart-server] probePipelineTarget(${payload.length} bytes)');
    if (target == null) {
      throw const RpcException('probePipelineTarget: target is null');
    }
    final pingResult = await target.ping((b) => b.payload = payload);
    final mb = MessageBuilder();
    mb.initRoot(complexTestServiceProbePipelineTargetResultsFactory).payload =
        pingResult.payload;
    return DispatchResult(bytes: mb.serialize());
  }

  @override
  Future<DispatchResult> makePromisedPipeline(
    ComplexTestServiceMakePromisedPipelineParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final delayMs = params.delayMs;
    print('[dart-server] makePromisedPipeline(delayMs=$delayMs)');
    final target = DeferredCapability(
      Future.delayed(
        Duration(milliseconds: delayMs),
        () => DartPipelineTargetImpl('dart-promised(delay=$delayMs)'),
      ),
    );
    final mb = MessageBuilder();
    mb.initRoot(complexTestServiceMakePromisedPipelineResultsFactory)
        .setTarget(0);
    return DispatchResult(bytes: mb.serialize(), caps: [target]);
  }

  @override
  Future<DispatchResult> echoPipelineTargetLater(
    ComplexTestServiceEchoPipelineTargetLaterParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final target = params.target;
    final delayMs = params.delayMs;
    print('[dart-server] echoPipelineTargetLater(delayMs=$delayMs)');
    if (target == null) {
      throw const RpcException('echoPipelineTargetLater: target is null');
    }
    final promised = DeferredCapability(
      Future.delayed(Duration(milliseconds: delayMs), () => target.capability),
    );
    final mb = MessageBuilder();
    mb.initRoot(complexTestServiceEchoPipelineTargetLaterResultsFactory)
        .setTarget(0);
    return DispatchResult(bytes: mb.serialize(), caps: [promised]);
  }

  @override
  Future<DispatchResult> openUpload(
    ComplexTestServiceOpenUploadParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    print('[dart-server] openUpload()');
    final sink = ByteSinkImpl();
    final mb = MessageBuilder();
    mb.initRoot(complexTestServiceOpenUploadResultsFactory).setSink(0);
    return DispatchResult(bytes: mb.serialize(), caps: [sink]);
  }

  @override
  Future<DispatchResult> openDownload(
    ComplexTestServiceOpenDownloadParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final resourceId = params.resourceId;
    Uint8List data;
    switch (resourceId?.which) {
      case 1:
        data = Uint8List.fromList(utf8.encode(resourceId?.textual ?? ''));
        break;
      case 2:
        data = resourceId?.binary ?? Uint8List(0);
        break;
      default:
        data = Uint8List.fromList(utf8.encode('default-data'));
    }
    print('[dart-server] openDownload(${data.length} bytes)');
    final source = ByteSourceImpl(data);
    final mb = MessageBuilder();
    mb.initRoot(complexTestServiceOpenDownloadResultsFactory).setSource(0);
    return DispatchResult(bytes: mb.serialize(), caps: [source]);
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
